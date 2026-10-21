#!/usr/bin/env bash
# Shared helpers for all IMESH assignment scripts.
set -euo pipefail

export NAMESPACE="${NAMESPACE:-imesh-demo}"
export CLUSTER_NAME="${CLUSTER_NAME:-imesh}"
export IMAGE="${IMAGE:-imesh-demo-app:1.0.0}"
export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------- colours ----
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

step()  { printf '\n%s==> %s%s\n' "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %sOK   %s%s\n' "${C_GREEN}" "$*" "${C_RESET}"; }
warn()  { printf '    %s!    %s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"; }
fail()  { printf '    %sFAIL %s%s\n' "${C_RED}" "$*" "${C_RESET}"; }

banner() {
  printf '\n%s%s%s\n' "${C_BOLD}" "$(printf '=%.0s' {1..74})" "${C_RESET}"
  printf '%s  %s%s\n' "${C_BOLD}" "$*" "${C_RESET}"
  printf '%s%s%s\n' "${C_BOLD}" "$(printf '=%.0s' {1..74})" "${C_RESET}"
}

require_tools() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || { fail "required tool not found: $t"; exit 1; }
  done
}

# kubectl shorthand that always targets the right cluster + namespace
k() { kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" "$@"; }

# Run a command inside the first pod of a deployment (interactive).
kexec() {
  local deploy="$1"; shift
  local pod
  pod="$(k get pod -l "app.kubernetes.io/name=${deploy}" \
          -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || { fail "no pod found for deployment/${deploy}"; return 1; }
  kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" exec -it "$pod" -- "$@"
}

# Same as kexec but non-interactive (safe for CI / scripted runs).
kexec_q() {
  local deploy="$1"; shift
  local pod
  pod="$(k get pod -l "app.kubernetes.io/name=${deploy}" \
          -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || { fail "no pod found for deployment/${deploy}"; return 1; }
  kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" exec "$pod" -- "$@"
}

# Resolve the ClusterIP of a Service.
svc_ip() {
  k get svc "$1" -o jsonpath='{.spec.clusterIP}'
}

# ---------------------------------------------------------------------------
# Connectivity assertions used by the verify scripts.
# Each test prints a PASS/FAIL line and returns 0 (pass) or 1 (fail).
#
# Every test is retried a few times: on a freshly created cluster the
# EndpointSlice is not programmed into kube-proxy instantly, and a single
# premature probe would produce a misleading failure.
# ---------------------------------------------------------------------------

RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-5}"
RETRY_DELAY="${RETRY_DELAY:-3}"

# run_test <expected-substring> <deployment> <curl-url>
# Prints the response body, then "PASS" or "FAIL" on the last line.
run_test() {
  local expect="$1" deploy="$2" url="$3"
  local out="" code="FAIL"
  local i
  for ((i = 1; i <= RETRY_ATTEMPTS; i++)); do
    out="$(kexec_q "${deploy}" curl -sS --max-time 5 "${url}" 2>&1 || true)"
    if [[ "${out}" == *"${expect}"* ]]; then
      code="PASS"; break
    fi
    (( i < RETRY_ATTEMPTS )) && sleep "${RETRY_DELAY}"
  done
  printf '%s\n%s\n' "${out}" "${code}"
}

# Split the "body\nSTATUS" output of run_test into two variables.
_split_result() {
  RESULT_BODY="${1%$'\n'*}"
  RESULT_CODE="${1##*$'\n'}"
}

# client -> frontend : the first leg of the flow.
test_client_to_frontend() {
  local r; r="$(run_test "FRONTEND-OK" client "http://frontend.${NAMESPACE}.svc.cluster.local/")"
  _split_result "$r"
  if [[ "${RESULT_CODE}" == "PASS" ]]; then
    ok "client -> frontend            : PASS  (${RESULT_BODY})"
    return 0
  fi
  fail "client -> frontend            : FAIL  (${RESULT_BODY})"
  return 1
}

# frontend -> backend : the second leg of the flow (the one that breaks).
test_frontend_to_backend() {
  local r; r="$(run_test "BACKEND-OK" frontend "http://backend.${NAMESPACE}.svc.cluster.local/")"
  _split_result "$r"
  if [[ "${RESULT_CODE}" == "PASS" ]]; then
    ok "frontend -> backend           : PASS  (${RESULT_BODY})"
    return 0
  fi
  fail "frontend -> backend           : FAIL  (${RESULT_BODY})"
  return 1
}

# client -> frontend -> backend : end-to-end through the frontend reverse proxy.
test_end_to_end() {
  local r; r="$(run_test "BACKEND-OK" client "http://frontend.${NAMESPACE}.svc.cluster.local/api/")"
  _split_result "$r"
  if [[ "${RESULT_CODE}" == "PASS" ]]; then
    ok "client -> frontend -> backend  : PASS  (${RESULT_BODY})"
    return 0
  fi
  fail "client -> frontend -> backend  : FAIL  (${RESULT_BODY})"
  return 1
}

# A pod's own health - proves the application process is alive and serving.
test_app_healthy() {
  local deploy="$1" expect="$2" port="$3"
  local r; r="$(run_test "${expect}" "${deploy}" "http://127.0.0.1:${port}/")"
  _split_result "$r"
  if [[ "${RESULT_CODE}" == "PASS" ]]; then
    ok "${deploy} own port ${port}        : PASS  (app is alive and serving)"
    return 0
  fi
  fail "${deploy} own port ${port}        : FAIL  (${RESULT_BODY})"
  return 1
}

# Block until the Services in the namespace have ready endpoints programmed.
wait_for_endpoints() {
  local i n
  for ((i = 1; i <= 30; i++)); do
    n="$(k get endpointslices \
           -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{end}{end}' 2>/dev/null \
         | tr -d ' ' | grep -c 'true' || true)"
    if [[ "${n:-0}" -ge 3 ]]; then
      ok "Services have ready endpoints (${n} ready)"
      return 0
    fi
    sleep 2
  done
  warn "timed out waiting for ready endpoints"
  return 1
}
