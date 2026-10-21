#!/usr/bin/env bash
# Step 3 - deploy the application (client / frontend / backend + Services).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl

banner "STEP 3 - Deploy the application"

k apply -f "${REPO_ROOT}/manifests/00-namespace.yaml"
k apply -f "${REPO_ROOT}/manifests/10-backend.yaml"
k apply -f "${REPO_ROOT}/manifests/20-frontend.yaml"
k apply -f "${REPO_ROOT}/manifests/30-client.yaml"

info "waiting for the workloads to become ready ..."
k rollout status deployment/backend  --timeout=180s
k rollout status deployment/frontend --timeout=180s
k rollout status deployment/client   --timeout=180s

info "waiting for the Service endpoints to be programmed into kube-proxy ..."
wait_for_endpoints || true

info "pods:"
k get pods -o wide --no-headers | sed 's/^/      /'

info "services:"
k get svc --no-headers | sed 's/^/      /'

ok "application deployed"
