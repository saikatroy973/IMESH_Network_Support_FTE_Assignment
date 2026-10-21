#!/usr/bin/env bash
# End-to-end reproduction of the whole assignment in one command.
#
#   cluster -> build -> deploy -> baseline OK -> inject fault -> diagnose -> fix -> verify
#
# Usage:
#   scripts/run-all.sh              full run (creates the cluster if needed)
#   scripts/run-all.sh --recreate   delete and recreate the cluster first
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECREATE=0
[[ "${1:-}" == "--recreate" ]] && RECREATE=1

S="${REPO_ROOT}/scripts"
# ARTIFACTS_DIR lets you keep a validation run out of the committed artifacts.
ART="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"
mkdir -p "${ART}"

if [[ $RECREATE -eq 1 ]]; then
  banner "RESET - deleting cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}" || true
fi

run() {
  local script="$1" out="$2"
  echo ""
  bash "${S}/${script}" 2>&1 | tee "${ART}/${out}"
  return "${PIPESTATUS[0]}"
}

run 01-setup-cluster.sh    01-setup-cluster.log
run 02-build-image.sh      02-build-image.log
run 03-deploy.sh           03-deploy.log
run 04-verify-baseline.sh  04-verify-baseline.log
run 05-inject-fault.sh     05-inject-fault.log
run 06-diagnose.sh         06-diagnose.log
run 07-fix.sh              07-fix.log
run 08-verify-fixed.sh     08-verify-fixed.log

banner "COMPLETE - full assignment flow reproduced end to end"
