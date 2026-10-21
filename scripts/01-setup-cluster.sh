#!/usr/bin/env bash
# Step 1 - create the local Kubernetes cluster (kind).
#
#   control-plane : runs the control plane, CoreDNS and the CNI
#   worker        : runs the client / frontend / backend workloads
#
# The client is later pinned to the control-plane node, so client -> frontend
# traffic crosses a node boundary.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kind kubectl docker

banner "STEP 1 - Create the kind cluster '${CLUSTER_NAME}'"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "cluster '${CLUSTER_NAME}' already exists - reusing it"
else
  info "creating cluster from ${REPO_ROOT}/kind-config.yaml ..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${REPO_ROOT}/kind-config.yaml" --wait 180s
  ok "cluster '${CLUSTER_NAME}' created"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

info "nodes:"
k get nodes -o wide --no-headers | sed 's/^/      /'

info "kube-system components (CNI + DNS):"
k get pods -n kube-system --no-headers | sed 's/^/      /' || true

info "coredns deployment:"
k get deployment coredns -n kube-system --no-headers 2>/dev/null | sed 's/^/      /' || true

ok "cluster is ready"
