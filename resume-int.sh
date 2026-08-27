#!/usr/bin/env bash
# ============================================================================
# ci/resume-int.sh
#
# After a hotfix preempted int (nominate-int.sh --force), this restores the
# DISPLACED candidate — same image, no rebuild. Use once the hotfix has
# shipped and int is free again.
# ============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/apps/reportapp}"
PAUSED_FILE="$APP_DIR/INT_PAUSED"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-jfrog.company.com}"
STAGING_REPO="${STAGING_REPO:-docker-staging-local}"
IMAGE_NAME="${IMAGE_NAME:-reportapp}"

log() { echo "[resume:int] $*"; }

if [ ! -s "$PAUSED_FILE" ]; then
  log "ERROR: no paused candidate found — nothing to resume"
  exit 1
fi

VERSION=$(grep -oP 'version=\K.*' "$PAUSED_FILE")
log "Resuming paused candidate: $VERSION"

# The lock should already be free at this point — whoever shipped the
# hotfix runs ci/release-int-lock.sh as part of that flow (see
# promote:stable / nominate:int job comments in .gitlab-ci.yml). If the
# lock is somehow still held, this will correctly refuse rather than
# silently overwrite whatever is actually running.
IMAGE="$DOCKER_REGISTRY/$STAGING_REPO/$IMAGE_NAME:$VERSION"
"$(dirname "$0")/nominate-int.sh" "$IMAGE" "$VERSION"

rm -f "$PAUSED_FILE"
log "Resumed. UAT for $VERSION can continue."
