#!/usr/bin/env bash
# ============================================================================
# ci/rollback.sh <env>
#
# Runs ON the target VM. Redeploys the previous version.
# Called by:
#   - rollback:int / rollback:prod   (standing manual pipeline buttons)
#   - test:smoke-prod after_script   (automatic, when prod smoke fails)
#
# Verifies against docker inspect (ground truth of what's actually running)
# rather than trusting marker files blindly, and appends every action to the
# DEPLOY_LOG audit trail.
#
# Note: this targets the IMMEDIATELY previous version. To roll back further
# (2+ releases), use GitLab's native Environments page Rollback button to
# re-run an older successful deploy job instead.
# ============================================================================
set -euo pipefail

ENV="${1:?usage: rollback.sh <env>}"

APP_DIR="${APP_DIR:-/opt/apps/reportapp}"
CURRENT_FILE="$APP_DIR/CURRENT_VERSION"
PREVIOUS_FILE="$APP_DIR/PREVIOUS_VERSION"
DEPLOY_LOG="$APP_DIR/DEPLOY_LOG"
ENV_FILE="$APP_DIR/.env"
CONTAINER_NAME="reportapp"
HEALTH_URL="http://localhost:8000/readyz"
HEALTH_TIMEOUT=90
HEALTH_INTERVAL=5
DOCKER_REGISTRY="${DOCKER_REGISTRY:-jfrog.company.com}"
IMAGE_NAME="${IMAGE_NAME:-reportapp}"

log() { echo "[rollback:$ENV] $*"; }
audit() { echo "$(date -Iseconds) $*" >> "$DEPLOY_LOG"; }

# --- ground truth check -----------------------------------------------------
ACTUAL_RUNNING=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null | sed 's/.*://' || echo "none")
log "Actually running (docker inspect): $ACTUAL_RUNNING"

if [ ! -f "$PREVIOUS_FILE" ]; then
  log "ERROR: no PREVIOUS_VERSION recorded — nothing to roll back to"
  exit 1
fi

TARGET=$(cat "$PREVIOUS_FILE")
if [ "$TARGET" == "none" ] || [ -z "$TARGET" ]; then
  log "ERROR: no valid previous version recorded (first-ever deploy?)"
  log "Recent deploy history:"
  tail -5 "$DEPLOY_LOG" 2>/dev/null || echo "  (no deploy log)"
  exit 1
fi

if [ "$TARGET" == "$ACTUAL_RUNNING" ]; then
  log "ERROR: rollback target $TARGET is already what's running. Nothing to do."
  exit 1
fi

# --- pick the source repo by environment ------------------------------------
case "$ENV" in
  prod) REPO="docker-stable-local" ;;
  int)  REPO="docker-staging-local" ;;
  dev)  REPO="docker-scratch-local" ;;
  *) log "Unknown env: $ENV"; exit 1 ;;
esac

IMAGE="$DOCKER_REGISTRY/$REPO/$IMAGE_NAME:$TARGET"
log "Rolling back: $ACTUAL_RUNNING -> $TARGET"
log "Image: $IMAGE"
audit "$ACTUAL_RUNNING rollback-started target=$TARGET"

cd "$APP_DIR"
IMAGE_REF="$IMAGE" docker compose --env-file "$ENV_FILE" up -d --pull always

waited=0
while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
  if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
    # swap markers so you can roll FORWARD again if needed
    echo "$TARGET" > "$CURRENT_FILE"
    echo "$ACTUAL_RUNNING" > "$PREVIOUS_FILE"
    audit "$ACTUAL_RUNNING rolled-back-to $TARGET"
    log "Rollback to $TARGET succeeded and is healthy"
    exit 0
  fi
  sleep "$HEALTH_INTERVAL"
  waited=$((waited + HEALTH_INTERVAL))
  log "waiting for healthy... (${waited}s/${HEALTH_TIMEOUT}s)"
done

audit "rollback-failed target=$TARGET"
log "CRITICAL: rollback target $TARGET also failed health checks. Escalate immediately."
docker compose logs --tail=200 || true
exit 1
