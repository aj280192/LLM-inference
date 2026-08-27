#!/usr/bin/env bash
# ============================================================================
# ci/deploy.sh <env> <image> <version>
#
# Runs ON the target VM (shell-executor runner registered on that VM).
# Idempotent: docker compose up -d only recreates what actually changed,
# so running this twice with the same image is always safe.
#
# Does NOT perform rollback itself — that's layered on top per environment
# by the caller (prod's deploy:prod job calls rollback.sh on failure; int's
# nominate-int.sh does not; dev never rolls back at all — see doc on
# rollback design decisions).
#
# Called by: ci/nominate-int.sh (int), the deploy:prod job (prod),
# and directly for dev deploys.
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

# --- preflight ---------------------------------------------------------
"$(dirname "$0")/preflight.sh" env

# --- record what's running now, before touching anything ----------------
ACTUAL_RUNNING=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null | sed 's/.*://' || echo "none")
log "Currently running: $ACTUAL_RUNNING"
echo "$ACTUAL_RUNNING" > "$PREVIOUS_FILE"

# --- idempotent deploy: compose diffs desired vs actual state ----------
cd "$APP_DIR"
audit "$VERSION deploy-started env=$ENV"
IMAGE_REF="$IMAGE" docker compose --env-file "$ENV_FILE" up -d --pull always

# --- wait for health ------------------------------------------------------
waited=0
while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
  if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
    echo "$VERSION" > "$CURRENT_FILE"
    audit "$VERSION deployed env=$ENV"
    log "SUCCESS: $VERSION is healthy and live"
    exit 0
  fi
  sleep "$HEALTH_INTERVAL"
  waited=$((waited + HEALTH_INTERVAL))
  log "waiting for healthy... (${waited}s/${HEALTH_TIMEOUT}s)"
done

log "FAILED: $VERSION never became healthy within ${HEALTH_TIMEOUT}s"
audit "$VERSION deploy-failed env=$ENV"
docker compose logs --tail=100 || true
exit 1
