#!/usr/bin/env bash
# ============================================================================
# ci/rollback.sh <env>
#
# Manually roll back to whatever version is recorded in PREVIOUS_VERSION.
# Used by:
#   - the "rollback-int" / "rollback-prod" manual pipeline jobs
#   - deploy.sh's own automatic-rollback path (called via redeploy logic)
#   - smoke-prod's after_script, if the post-deploy smoke test fails
# ============================================================================
set -euo pipefail

ENV="${1:?usage: rollback.sh <env>}"

APP_DIR="${APP_DIR:-/opt/apps/reportapp}"
CURRENT_FILE="$APP_DIR/CURRENT_VERSION"
PREVIOUS_FILE="$APP_DIR/PREVIOUS_VERSION"
ENV_FILE="$APP_DIR/.env"
HEALTH_URL="http://localhost:8000/readyz"
HEALTH_TIMEOUT=90
HEALTH_INTERVAL=5

log() { echo "[rollback:$ENV] $*"; }

if [ ! -f "$PREVIOUS_FILE" ]; then
  log "ERROR: no PREVIOUS_VERSION recorded on this VM — nothing to roll back to"
  exit 1
fi

PREV=$(cat "$PREVIOUS_FILE")
CURRENT=$(cat "$CURRENT_FILE" 2>/dev/null || echo "unknown")

if [ "$PREV" == "none" ]; then
  log "ERROR: recorded previous version is 'none' (this was the first-ever deploy)"
  exit 1
fi

log "Current: $CURRENT -> Rolling back to: $PREV"
read -p "Type the version to confirm rollback [$PREV]: " CONFIRM
if [ "$CONFIRM" != "$PREV" ]; then
  log "Confirmation did not match. Aborting."
  exit 1
fi

# Figure out which repo the previous version lives in (staging vs stable)
# by checking which env this is — prod/int pull from stable/staging respectively.
case "$ENV" in
  prod) REPO="docker-stable-local" ;;
  int)  REPO="docker-staging-local" ;;
  dev)  REPO="docker-scratch-local" ;;
  *) log "Unknown env $ENV"; exit 1 ;;
esac

IMAGE="jfrog.company.com/${REPO}/reportapp:${PREV}"

cd "$APP_DIR"
log "Deploying $IMAGE"
IMAGE_REF="$IMAGE" docker compose --env-file "$ENV_FILE" up -d --pull always

waited=0
while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
  if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
    echo "$PREV" > "$CURRENT_FILE"
    echo "$CURRENT" > "$PREVIOUS_FILE"   # so you can "roll forward" again if needed
    log "Rollback to $PREV succeeded and is healthy"
    exit 0
  fi
  sleep "$HEALTH_INTERVAL"
  waited=$((waited + HEALTH_INTERVAL))
  log "waiting for healthy... (${waited}s/${HEALTH_TIMEOUT}s)"
done

log "CRITICAL: rollback target $PREV also failed health checks. Escalate immediately."
docker compose logs --tail=200
exit 1
