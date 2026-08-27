#!/usr/bin/env bash
# ============================================================================
# ci/rollback-int.sh
#
# Lightweight manual rollback for int: "the current occupant is behaving
# badly, put the last known-good version back." Distinct from resume-int.sh
# (which restores a hotfix-paused candidate — nothing was wrong with it).
#
# No health-check-loop machinery like prod's rollback.sh — int rollback is
# a deliberate human action taken because something looked wrong, not an
# automatic recovery, so a simple redeploy is sufficient.
# ============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/apps/reportapp}"
PREVIOUS_FILE="$APP_DIR/PREVIOUS_VERSION"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-jfrog.company.com}"
STAGING_REPO="${STAGING_REPO:-docker-staging-local}"
IMAGE_NAME="${IMAGE_NAME:-reportapp}"

log() { echo "[rollback:int] $*"; }

if [ ! -s "$PREVIOUS_FILE" ]; then
  log "ERROR: no previous version recorded on int"
  exit 1
fi

TARGET=$(cat "$PREVIOUS_FILE")
if [ "$TARGET" == "none" ]; then
  log "ERROR: no valid previous version to roll back to"
  exit 1
fi

log "Redeploying previous int version: $TARGET"
IMAGE="$DOCKER_REGISTRY/$STAGING_REPO/$IMAGE_NAME:$TARGET"
"$(dirname "$0")/deploy.sh" int "$IMAGE" "$TARGET"
