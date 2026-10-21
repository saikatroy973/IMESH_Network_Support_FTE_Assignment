#!/usr/bin/env bash
# Step 4 - baseline verification.
#
# Proves the expected healthy state before the fault is injected:
#     client -> frontend      WORKING
#     frontend -> backend     WORKING
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl

banner "STEP 4 - Baseline verification (healthy cluster)"

info "DNS resolution from the client pod:"
kexec_q client getent hosts "frontend.${NAMESPACE}.svc.cluster.local" 2>&1 | sed 's/^/      /' || true
kexec_q client getent hosts "backend.${NAMESPACE}.svc.cluster.local" 2>&1 | sed 's/^/      /' || true

info ""
rc=0
test_client_to_frontend || rc=1
test_frontend_to_backend || rc=1
test_end_to_end            || rc=1
test_app_healthy backend  BACKEND-OK  8080 || rc=1
test_app_healthy frontend FRONTEND-OK 8080 || rc=1

info ""
info "client health loop (last 3 lines):"
k logs -l app.kubernetes.io/name=client --tail=3 --tail=3 2>/dev/null | sed 's/^/      /' || true

if [[ $rc -eq 0 ]]; then
  ok "BASELINE HEALTHY - client -> frontend and frontend -> backend both work"
else
  fail "BASELINE UNEXPECTEDLY BROKEN - fix that before injecting the fault"
  exit 1
fi
