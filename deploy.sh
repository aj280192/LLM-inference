#!/usr/bin/env bash
# ============================================================================
# ci/deploy.sh <env> <image> <version>
#
# Runs ON the target VM itself (shell-executor runner registered on that VM).
# Called by pipeline jobs: deploy:dev, deploy:int, deploy:prod
#
# Flow:
#   1. Sanity checks (.env exists and is fresh — Vault Agent renders it)
#   2. Record rollback state:
#        - PREVIOUS_VERSION marker  (fast target for rollback.sh)
#        - DEPLOY_LOG append-only history (audit trail, multi-step history)
#   3. Deploy new image via docker compose
#   4. Poll /readyz until healthy (or timeout)
#   5. Healthy   -> record CURRENT_VERSION, log success, exit 0
#      Unhealthy -> AUTO-ROLLBACK to previous version, log it, exit 1
#                   (exit 1 keeps the pipeline red so the broken version
#                    can never be promoted further)
# ============================================================================
set -euo pipefail

ENV="${1:?usage: deploy.sh <env> <image> <version>}"
IMAGE="${2:?usage: deploy.sh <env> <image> <version>}"
VERSION="${3:?usage: deploy.sh <env> <image> <version>}"

APP_DIR="${APP_DIR:-/opt/apps/reportapp}"
CURRENT_FILE="$APP_DIR/CURRENT_VERSION"
PREVIOUS_FILE="$APP_DIR/PREVIOUS_VERSION"
DEPLOY_LOG="$APP_DIR/DEPLOY_LOG"
ENV_FILE="$APP_DIR/.env"
CONTAINER_NAME="reportapp"
HEALTH_URL="http://localhost:8000/readyz"
HEALTH_TIMEOUT=90
HEALTH_INTERVAL=5

log() { echo "[deploy:$ENV] $*"; }
audit() { echo "$(date -Iseconds) $*" >> "$DEPLOY_LOG"; }

# --- 1. sanity checks -------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  log "ERROR: $ENV_FILE not found — is Vault Agent running on this VM?"
  exit 1
fi
if [ -n "$(find "$ENV_FILE" -mmin +60 2>/dev/null)" ]; then
  log "WARNING: .env is older than 60 minutes — secrets may be stale"
fi

# --- 2. record rollback state ----------------------------------------------
# ground truth: what is ACTUALLY running right now (not just what a file says)
ACTUAL_RUNNING=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null | sed 's/.*://' || echo "none")
log "Actually running (docker inspect): $ACTUAL_RUNNING"

if [ "$ACTUAL_RUNNING" != "none" ]; then
  echo "$ACTUAL_RUNNING" > "$PREVIOUS_FILE"
else
  echo "none" > "$PREVIOUS_FILE"
  log "No container currently running (first deploy on this VM)"
fi

wait_for_healthy() {
  local waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
    waited=$((waited + HEALTH_INTERVAL))
    log "waiting for healthy... (${waited}s/${HEALTH_TIMEOUT}s)"
  done
  return 1
}

deploy_image() {
  local image_ref="$1"
  log "Deploying $image_ref"
  cd "$APP_DIR"
  IMAGE_REF="$image_ref" docker compose --env-file "$ENV_FILE" up -d --pull always
}

# --- 3+4. deploy and health check ------------------------------------------
audit "$VERSION deploy-started"
deploy_image "$IMAGE"

if wait_for_healthy; then
  echo "$VERSION" > "$CURRENT_FILE"
  audit "$VERSION deployed"
  log "SUCCESS: $VERSION is healthy and live"
  exit 0
fi

# --- 5. auto-rollback -------------------------------------------------------
log "FAILED: $VERSION never became healthy within ${HEALTH_TIMEOUT}s"
audit "$VERSION deploy-failed"
docker compose logs --tail=100 || true

PREV=$(cat "$PREVIOUS_FILE")
if [ "$PREV" == "none" ]; then
  log "No previous version to roll back to — manual intervention required"
  audit "$VERSION no-rollback-target"
  exit 1
fi

log "Rolling back to previous version: $PREV"
REPO=$(echo "$IMAGE" | sed "s/:$VERSION//")
deploy_image "${REPO}:${PREV}"

if wait_for_healthy; then
  echo "$PREV" > "$CURRENT_FILE"
  audit "$VERSION rolled-back-to $PREV"
  log "Rollback to $PREV succeeded. Deployment of $VERSION FAILED."
else
  audit "$VERSION rollback-also-failed target=$PREV"
  log "CRITICAL: rollback to $PREV also failed health checks. Escalate immediately."
  docker compose logs --tail=200 || true
fi

# always exit non-zero: even though the environment recovered, the pipeline
# for $VERSION must stay red so this version is never promoted further
exit 1
