#!/usr/bin/env bash
# Step 9 - capture the incident timeline from the client workload's point of view.
#
# The client runs a 10 second health loop against the frontend Service and
# against the frontend's /api/ route (which reverse-proxies to the backend).
# This script injects the fault, watches the customer's symptom appear, fixes
# it, and watches the symptom disappear.
#
# The resulting file (artifacts/incident-timeline.txt) is the "before / during /
# after" evidence used in the README.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl

banner "STEP 9 - Capture the incident timeline"

OUT="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}/incident-timeline.txt"
mkdir -p "$(dirname "${OUT}")"

# Only consider log lines written from now on. When this step runs at the end
# of run-all.sh the log already contains an earlier fault window, and section 1
# must show a genuinely healthy state rather than stale 502s.
T0="$(date -u +%FT%TZ)"

log_client() {
  k logs deploy/client --since-time="${T0}" --tail=4 2>/dev/null | sed 's/^/      /' || true
}

# Give the client's 10-second loop time to produce four fresh healthy samples.
sleep 45

# --- 1. healthy state ------------------------------------------------------
{
  echo "==============================================================="
  echo " INCIDENT TIMELINE - observed from the client workload"
  echo " namespace : ${NAMESPACE}"
  echo " cluster   : kind-${CLUSTER_NAME}"
  echo "==============================================================="
  echo
  echo "### 1. HEALTHY  (before the fault)   $(date -u +%FT%TZ)"
  echo "    client -> frontend                                    -> 200"
  echo "    client -> frontend(/api/) -> backend                  -> 200"
  echo
  log_client
} > "${OUT}"

# --- 2. inject the fault and let the symptom show -------------------------
info "injecting the fault ..."
k apply -f "${REPO_ROOT}/manifests/40-fault-targetport.yaml" >/dev/null
sleep 25

{
  echo
  echo "---------------------------------------------------------------"
  echo "### 2. FAULT INJECTED  $(date -u +%FT%TZ)"
  echo "    backend Service .spec.ports[0].targetPort : 8080 -> 9090"
  echo
  log_client
  echo
  echo "    >>> customer symptom: the frontend itself is still healthy (200),"
  echo "    >>> but every API call the frontend makes to the backend fails (502)."
} >> "${OUT}"

# --- 3. fix it ------------------------------------------------------------
info "applying the fix ..."
k apply -f "${REPO_ROOT}/manifests/90-fix-targetport.yaml" >/dev/null
sleep 25

{
  echo
  echo "---------------------------------------------------------------"
  echo "### 3. ROOT CAUSE FIXED  $(date -u +%FT%TZ)"
  echo "    backend Service .spec.ports[0].targetPort : 9090 -> 8080"
  echo
  log_client
  echo
  echo "==============================================================="
  echo " END OF TIMELINE"
  echo "==============================================================="
} >> "${OUT}"

info "timeline written to ${OUT}"
cat "${OUT}"
