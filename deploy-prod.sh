#!/usr/bin/env bash
# ============================================================================
# ci/deploy-prod.sh <image> <version>
#
# Wraps deploy.sh with PROD-ONLY automatic rollback. Dev and int deliberately
# do NOT get this wrapper — a broken dev/int deploy should stay broken and
# visible for debugging, not silently revert (see rollback design rationale).
#
# On success: also stamps the artifact in JFrog with deployed.prod=true,
# for CVE/runtime correlation (see vulnerability-response design).
# ============================================================================
set -euo pipefail

IMAGE="${1:?usage: deploy-prod.sh <image> <version>}"
VERSION="${2:?usage: deploy-prod.sh <image> <version>}"
SCRIPT_DIR="$(dirname "$0")"

STABLE_REPO="${STABLE_REPO:-docker-stable-local}"
IMAGE_NAME="${IMAGE_NAME:-reportapp}"

if "$SCRIPT_DIR/deploy.sh" prod "$IMAGE" "$VERSION"; then
  jf rt set-props "$STABLE_REPO/$IMAGE_NAME/$VERSION" "deployed.prod=true"
  echo "[deploy-prod] $VERSION live, marked deployed.prod=true in JFrog"
  exit 0
fi

echo "[deploy-prod] deploy failed health check — auto-rolling back"
"$SCRIPT_DIR/rollback.sh" prod
# rollback.sh itself exits non-zero on success-of-rollback here, by design:
# the pipeline for $VERSION must stay red even though prod recovered, so
# this version can never be mistaken for having shipped successfully.
exit 1
