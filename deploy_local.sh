#!/usr/bin/env bash
# =============================================================================
# /opt/chatapp/deploy_local.sh <full_image_ref> <vault_secret_version> <env>
# Lives ON EACH DEPLOY HOST (installed with lib/log.sh at /opt/chatapp/lib/).
# Blue-green deploy with version-pinned Vault secret rendering.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

IMAGE="${1:?image ref required}"
VAULT_VERSION="${2:?vault version required}"
ENV="${3:?env required}"

APP=chatapp
SECRET_PATH="secret/$APP/$ENV"
ENVFILE="/run/$APP/$APP.env"           # /run = tmpfs, secrets never hit disk
STATE_DIR="/var/lib/$APP"
LOGFILE="/var/log/$APP/deploy.log"
BLUE_PORT=8080
GREEN_PORT=8081
HEALTH_PATH="/health"
HEALTH_RETRIES=12
HEALTH_INTERVAL=5

mkdir -p "$(dirname "$ENVFILE")" "$STATE_DIR" "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1
log_info "deploy start image=$IMAGE vault=v$VAULT_VERSION env=$ENV"

# --- 1. Render env file for the PINNED secret version ------------------------
log_section_start "render_env" "Rendering env from Vault (pinned v$VAULT_VERSION)"
export VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.corp:8200}"
[ -f /run/vault/token ] || die "no vault-agent token at /run/vault/token — is vault-agent-chatapp running?"
export VAULT_TOKEN=$(cat /run/vault/token)

vault kv get -version="$VAULT_VERSION" -format=json "$SECRET_PATH" \
  | python3 -c '
import json,sys
data = json.load(sys.stdin)["data"]["data"]
for k, v in data.items():
    if "\n" in str(v): raise SystemExit(f"secret {k} contains newline")
    print(f"{k}={v}")
' > "$ENVFILE.tmp" || die "failed to read $SECRET_PATH v$VAULT_VERSION"
chmod 400 "$ENVFILE.tmp"
mv "$ENVFILE.tmp" "$ENVFILE"
log_ok "env rendered from $SECRET_PATH v$VAULT_VERSION -> $ENVFILE (tmpfs, mode 400)"
log_section_end "render_env"

# --- 2. Determine slot + pull + start new container --------------------------
log_section_start "start_new" "Starting new container (blue-green)"
LIVE_SLOT=$(cat "$STATE_DIR/live_slot" 2>/dev/null || echo "blue")
if [ "$LIVE_SLOT" = "blue" ]; then
  NEW_SLOT=green; NEW_PORT=$GREEN_PORT; OLD_CONTAINER="$APP-blue"
else
  NEW_SLOT=blue;  NEW_PORT=$BLUE_PORT;  OLD_CONTAINER="$APP-green"
fi
NEW_CONTAINER="$APP-$NEW_SLOT"
log_info "live slot: $LIVE_SLOT -> deploying to $NEW_SLOT (port $NEW_PORT)"

docker pull "$IMAGE" || die "docker pull failed — check registry access/proxy NO_PROXY"
log_ok "image pulled"

docker rm -f "$NEW_CONTAINER" 2>/dev/null || true
docker run -d \
  --name "$NEW_CONTAINER" \
  --env-file "$ENVFILE" \
  --restart unless-stopped \
  --log-driver json-file --log-opt max-size=50m --log-opt max-file=5 \
  --label "deploy.image=$IMAGE" \
  --label "deploy.vault_version=$VAULT_VERSION" \
  --label "deploy.time=$(date -u +%FT%TZ)" \
  -p "127.0.0.1:$NEW_PORT:8080" \
  "$IMAGE" || die "docker run failed"
log_ok "container $NEW_CONTAINER started"
log_section_end "start_new"

# --- 3. Health check ---------------------------------------------------------
log_section_start "health" "Health checking new container"
ok=false
for i in $(seq 1 $HEALTH_RETRIES); do
  if curl -sf "http://127.0.0.1:$NEW_PORT$HEALTH_PATH" >/dev/null; then
    ok=true; break
  fi
  log_warn "health check $i/$HEALTH_RETRIES failed, retrying in ${HEALTH_INTERVAL}s"
  sleep $HEALTH_INTERVAL
done

if [ "$ok" != true ]; then
  log_fail "health check FAILED — old version stays live"
  log_info "last container logs:"
  docker logs --tail 50 "$NEW_CONTAINER" || true
  docker rm -f "$NEW_CONTAINER"
  log_section_end "health"
  exit 1
fi
log_ok "health check passed"
log_section_end "health"

# --- 4. Swap nginx, verify, retire old ---------------------------------------
log_section_start "swap" "Swapping traffic to new container"
sed "s/__PORT__/$NEW_PORT/" /opt/$APP/nginx-upstream.conf.tpl \
  > /etc/nginx/conf.d/$APP-upstream.conf
nginx -t || die "nginx config test failed — traffic NOT swapped"
nginx -s reload
sleep 2
if ! curl -sf "http://127.0.0.1$HEALTH_PATH" >/dev/null; then
  log_fail "post-swap check failed — reverting nginx to old slot"
  OLD_PORT=$( [ "$NEW_PORT" = "$BLUE_PORT" ] && echo $GREEN_PORT || echo $BLUE_PORT )
  sed "s/__PORT__/$OLD_PORT/" /opt/$APP/nginx-upstream.conf.tpl \
    > /etc/nginx/conf.d/$APP-upstream.conf
  nginx -s reload
  docker rm -f "$NEW_CONTAINER"
  log_section_end "swap"
  exit 1
fi
log_ok "traffic swapped to $NEW_SLOT"

# grace period for in-flight LLM streaming responses on the old container
sleep "${DRAIN_SECONDS:-10}"
docker rm -f "$OLD_CONTAINER" 2>/dev/null || true
log_ok "old container retired"
log_section_end "swap"

# --- 5. Persist local state --------------------------------------------------
echo "$NEW_SLOT"       > "$STATE_DIR/live_slot"
echo "$IMAGE"          > "$STATE_DIR/current_image"
echo "$VAULT_VERSION"  > "$STATE_DIR/current_vault_version"
echo "$(date -u +%FT%TZ),$IMAGE,$VAULT_VERSION,$NEW_SLOT" >> "$STATE_DIR/host_deploy_history.csv"

log_ok "deploy complete: $IMAGE (vault v$VAULT_VERSION) live on slot $NEW_SLOT"
