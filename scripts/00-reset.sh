#!/usr/bin/env bash
# Tear everything down.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

banner "RESET - deleting the kind cluster '${CLUSTER_NAME}'"
kind delete cluster --name "${CLUSTER_NAME}"
docker rmi "${IMAGE}" >/dev/null 2>&1 || true
ok "cluster and image removed"
