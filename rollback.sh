#!/usr/bin/env bash
# ============================================================================
# ci/rollback.sh <env>
#
# Redeploys the PREVIOUS version for the given environment. Used for prod
# (manual button + automatic trigger from deploy-prod.sh / failed smoke)
# and can be reused for dev if ever needed, though dev has no caller for it
# by design.
#
# Verifies against `docker inspect` (ground truth) rather than trusting
# marker files blindly, and appends every action to DEPLOY_LOG.
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

ACTUAL_RUNNING=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null | sed 's/.*://' || echo "none")
log "Actually running: $ACTUAL_RUNNING"

if [ ! -f "$PREVIOUS_FILE" ]; then
  log "ERROR: no PREVIOUS_VERSION recorded — nothing to roll back to"
  exit 1
fi

TARGET=$(cat "$PREVIOUS_FILE")
if [ "$TARGET" == "none" ] || [ -z "$TARGET" ]; then
  log "ERROR: no valid previous version recorded (first-ever deploy?)"
  tail -5 "$DEPLOY_LOG" 2>/dev/null || echo "  (no deploy log)"
  exit 1
fi

if [ "$TARGET" == "$ACTUAL_RUNNING" ]; then
  log "ERROR: rollback target $TARGET already running. Nothing to do."
  exit 1
fi

case "$ENV" in
  prod) REPO="docker-stable-local" ;;
  int)  REPO="docker-staging-local" ;;
  dev)  REPO="docker-scratch-local" ;;
  *) log "Unknown env: $ENV"; exit 1 ;;
esac

IMAGE="$DOCKER_REGISTRY/$REPO/$IMAGE_NAME:$TARGET"
log "Rolling back: $ACTUAL_RUNNING -> $TARGET"
audit "$ACTUAL_RUNNING rollback-started target=$TARGET env=$ENV"

cd "$APP_DIR"
IMAGE_REF="$IMAGE" docker compose --env-file "$ENV_FILE" up -d --pull always

waited=0
while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
  if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
    echo "$TARGET" > "$CURRENT_FILE"
    echo "$ACTUAL_RUNNING" > "$PREVIOUS_FILE"   # swap — can roll forward again
    audit "$ACTUAL_RUNNING rolled-back-to $TARGET env=$ENV"
    log "Rollback to $TARGET succeeded and is healthy"
    exit 0
  fi
  sleep "$HEALTH_INTERVAL"
  waited=$((waited + HEALTH_INTERVAL))
  log "waiting for healthy... (${waited}s/${HEALTH_TIMEOUT}s)"
done

audit "rollback-failed target=$TARGET env=$ENV"
log "CRITICAL: rollback target $TARGET also failed health checks. Escalate immediately."
docker compose logs --tail=200 || true
exit 1
