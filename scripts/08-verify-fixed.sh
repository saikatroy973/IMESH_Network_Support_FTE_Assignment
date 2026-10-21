#!/usr/bin/env bash
# Step 8 - verify that the fix actually restored the flow.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl

banner "STEP 8 - Post-fix verification"

info "backend Service:"
k get svc backend -o wide --no-headers | sed 's/^/      /'
info "endpoints:"
k get endpoints backend --no-headers | sed 's/^/      /'

info ""
info "kube-proxy DNAT rules after the fix (the destination port is now 8080):"
if docker ps --format '{{.Names}}' | grep -q "^imesh-worker$"; then
  docker exec imesh-worker sh -c \
    'iptables -t nat -S KUBE-SERVICES 2>/dev/null | grep "imesh-demo/backend:http" | grep -oE "KUBE-SVC-[A-Z0-9]+" | head -1' \
    2>/dev/null | while read svc; do
      docker exec imesh-worker sh -c \
        "iptables -t nat -S ${svc} 2>/dev/null | grep -oE 'KUBE-SEP-[A-Z0-9]+' | while read sep; do iptables -t nat -S \"\$sep\" 2>/dev/null; done" \
        2>/dev/null | grep DNAT
    done | sed 's/^/      /' || true
else
  warn "kind node container not reachable - skipping kube-proxy rule inspection"
fi

info ""
rc=0
test_client_to_frontend || rc=1
test_frontend_to_backend || rc=1
test_end_to_end            || rc=1
test_app_healthy backend  BACKEND-OK  8080 || rc=1
test_app_healthy frontend FRONTEND-OK 8080 || rc=1

info ""
info "client health loop (last 3 lines):"
k logs -l app.kubernetes.io/name=client --tail=3 2>/dev/null | sed 's/^/      /' || true

if [[ $rc -eq 0 ]]; then
  ok "RESOLVED - the full flow client -> frontend -> backend works again"
else
  fail "STILL BROKEN - the root cause has not been corrected"
  exit 1
fi
