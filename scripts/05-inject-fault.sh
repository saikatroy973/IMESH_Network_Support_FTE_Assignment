#!/usr/bin/env bash
# Step 5 - inject the single intentional networking fault.
#
#   backend Service: targetPort 8080  ->  9090
#
# The backend container keeps listening on 8080.  From now on kube-proxy
# DNATs ClusterIP:80 to <podIP>:9090, where nothing is listening, so every
# frontend -> backend connection is answered with a TCP RST.
#
# NOTE: the pods are NOT restarted and NOTHING is deleted - the fault lives
#       purely in the Service object, exactly like a real "config drift"
#       incident.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl

banner "STEP 5 - Inject the networking fault"

info "backend Service BEFORE the fault:"
k get svc backend -o wide --no-headers | sed 's/^/      /'
k get svc backend -o jsonpath='{.spec.ports[*].targetPort}' | sed 's/^/      targetPort = /'; echo

info ""
info "applying manifests/40-fault-targetport.yaml ..."
k apply -f "${REPO_ROOT}/manifests/40-fault-targetport.yaml"

info ""
info "backend Service AFTER the fault:"
k get svc backend -o wide --no-headers | sed 's/^/      /'
k get svc backend -o jsonpath='{.spec.ports[*].targetPort}' | sed 's/^/      targetPort = /'; echo

info ""
info "the pods are untouched - no restart, no deletion:"
k get pods -l app.kubernetes.io/name=backend --no-headers | sed 's/^/      /'

ok "fault injected - frontend -> backend is now broken"
