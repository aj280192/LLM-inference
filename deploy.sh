#!/usr/bin/env bash
# ============================================================================
# ci/deploy.sh <env> <image> <version>
#
# Deploys the given image to APP_DIR on the CURRENT machine (this script
# runs on the dev/int/prod VM itself, via the shell-executor runner
# registered on that VM).
#
# Rollback logic:
#   1. Before touching anything, read the CURRENTLY running tag from a
#      marker file and save it as the "previous" version.
#   2. Deploy the new image.
#   3. Poll /readyz for up to $HEALTH_TIMEOUT seconds.
#   4. If it never turns healthy -> redeploy the previous version
#      automatically and exit non-zero (fails the pipeline job loudly).
#   5. If healthy -> record the new version as current, exit 0.
# ============================================================================
set -euo pipefail

ENV="${1:?usage: deploy.sh <env> <image> <version>}"
IMAGE="${2:?usage: deploy.sh <env> <image> <version>}"
VERSION="${3:?usage: deploy.sh <env> <image> <version>}"

APP_DIR="${APP_DIR:-/opt/apps/reportapp}"
CURRENT_FILE="$APP_DIR/CURRENT_VERSION"
PREVIOUS_FILE="$APP_DIR/PREVIOUS_VERSION"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"          # rendered continuously by Vault Agent
HEALTH_URL="http://localhost:8000/readyz"
HEALTH_TIMEOUT=90                 # seconds to wait for healthy
HEALTH_INTERVAL=5

log() { echo "[deploy:$ENV] $*"; }

# --- sanity checks before touching anything -------------------------------
if [ ! -f "$ENV_FILE" ]; then
  log "ERROR: $ENV_FILE not found — is Vault Agent running on this VM?"
  exit 1
fi
if [ "$(find "$ENV_FILE" -mmin +60 2>/dev/null)" ]; then
  log "WARNING: .env file is older than 60 minutes, secrets may be stale"
fi

# --- record what's currently running, for rollback -------------------------
if [ -f "$CURRENT_FILE" ]; then
  cp "$CURRENT_FILE" "$PREVIOUS_FILE"
  log "Previous version recorded: $(cat "$PREVIOUS_FILE")"
else
  log "No previous deployment found on this VM (first deploy)"
  echo "none" > "$PREVIOUS_FILE"
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

deploy_version() {
  local image_ref="$1"
  log "Deploying $image_ref"
  cd "$APP_DIR"
  IMAGE_REF="$image_ref" docker compose --env-file "$ENV_FILE" up -d --pull always
}

# --- attempt the new deploy -------------------------------------------------
deploy_version "$IMAGE"

if wait_for_healthy; then
  echo "$VERSION" > "$CURRENT_FILE"
  log "SUCCESS: $VERSION is healthy and live"
  exit 0
fi

# --- health check failed: automatic rollback --------------------------------
log "FAILED: $VERSION never became healthy within ${HEALTH_TIMEOUT}s"
PREV=$(cat "$PREVIOUS_FILE")

if [ "$PREV" == "none" ]; then
  log "No previous version to roll back to — manual intervention required"
  docker compose -f "$COMPOSE_FILE" logs --tail=100
  exit 1
fi

log "Rolling back to previous version: $PREV"
REPO=$(echo "$IMAGE" | sed "s/:$VERSION//")   # same repo, previous tag
deploy_version "${REPO}:${PREV}"

if wait_for_healthy; then
  echo "$PREV" > "$CURRENT_FILE"
  log "Rollback to $PREV succeeded. Deployment of $VERSION FAILED."
else
  log "CRITICAL: rollback to $PREV also failed to become healthy. Manual intervention required."
  docker compose -f "$COMPOSE_FILE" logs --tail=200
fi

# Always exit non-zero here: even though we recovered, the pipeline for
# $VERSION must show red so the release doesn't get promoted further.
exit 1
