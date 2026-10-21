#!/usr/bin/env bash
# Step 7 - apply the fix.
#
# Two equivalent ways to fix it are shown; the first one is the declarative
# route (the manifest is the source of truth), the second one is the quick
# imperative route a responder would use during an incident.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl

banner "STEP 7 - Fix the root cause"

info "targetPort BEFORE the fix:"
k get svc backend -o jsonpath='      {.spec.ports[0].targetPort}{"\n"}'

info ""
info "[1/2] applying the corrected manifest (declarative):"
k apply -f "${REPO_ROOT}/manifests/90-fix-targetport.yaml"

info ""
info "targetPort AFTER the fix:"
k get svc backend -o jsonpath='      {.spec.ports[0].targetPort}{"\n"}'

info ""
info "[2/2] the equivalent imperative command (for reference / live incidents):"
info "      kubectl -n ${NAMESPACE} patch svc backend --type=json \\"
info "        -p='[{\"op\":\"replace\",\"path\":\"/spec/ports/0/targetPort\",\"value\":8080}]'"

info ""
info "the backend pods were never restarted - only the Service was corrected:"
k get pods -l app.kubernetes.io/name=backend --no-headers | sed 's/^/      /'

ok "fix applied - Service targetPort now matches the container port"
