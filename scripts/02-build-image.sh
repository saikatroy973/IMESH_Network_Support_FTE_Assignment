#!/usr/bin/env bash
# Step 2 - build the demo image and load it into every kind node.
#
# The image is built locally so that the whole assignment is reproducible
# offline and no registry is required.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools docker kind

banner "STEP 2 - Build and load the application image '${IMAGE}'"

info "building ${REPO_ROOT}/Dockerfile ..."
docker build -t "${IMAGE}" "${REPO_ROOT}"

info "loading into kind nodes ..."
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"

ok "image '${IMAGE}' is available in the cluster"
docker images "${IMAGE}" --format '      {{.Repository}}:{{.Tag}}  {{.ID}}  {{.Size}}'
