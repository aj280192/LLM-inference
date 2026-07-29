#!/usr/bin/env bash
# =============================================================================
# /opt/chatapp/deploy_local.sh <full_image_ref> <vault_secret_version> <env>
#
# Lives ON EACH DEPLOY HOST. Invoked over SSH by the build host.
# Does a blue-green swap:
#   1. Renders the env file for the EXACT vault secret version requested
#      (does NOT trust vault-agent's "current" — version is pinned explicitly)
#   2. Pulls the image, starts it on the standby port
#   3. Health-checks it; only then swaps nginx upstream and kills the old one
#   4. Writes local state files used for tracking & disaster recovery
#
# Install: place at /opt/chatapp/deploy_local.sh, chmod 750, owned by root,
# and allow the deploy user to run it via sudoers:
#   deploy ALL=(root) NOPASSWD: /opt/chatapp/deploy_local.sh
# =============================================================================
set -euo pipefail

IMAGE="${1:?image ref required}"
VAULT_VERSION="${2:?vault version required}"
ENV="${3:?env required}"

APP=chatapp
SECRET_PATH="secret/$APP/$ENV"
ENVFILE="/run/$APP/$APP.env"           # /run = tmpfs, never touches disk
STATE_DIR="/var/lib/$APP"
LOG="/var/log/$APP/deploy.log"
BLUE_PORT=8080
GREEN_PORT=8081
HEALTH_PATH="/health"
HEALTH_RETRIES=12
HEALTH_INTERVAL=5

mkdir -p "$(dirname "$ENVFILE")" "$STATE_DIR" "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "===== $(date -u +%FT%TZ) deploy start image=$IMAGE vault=v$VAULT_VERSION ====="

# --- 1. Render env file for the PINNED secret version ------------------------
# The host authenticates to Vault via its own AppRole (or agent auto-auth token
# at /run/vault/token). We read the specific version, not "latest".
export VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.corp:8200}"
export VAULT_TOKEN=$(cat /run/vault/token)   # maintained by vault-agent auto-auth

vault kv get -version="$VAULT_VERSION" -format=json "$SECRET_PATH" \
  | python3 -c '
import json,sys
data = json.load(sys.stdin)["data"]["data"]
for k, v in data.items():
    # basic .env quoting; values with newlines are rejected
    if "\n" in str(v): raise SystemExit(f"secret {k} contains newline")
    print(f"{k}={v}")
' > "$ENVFILE.tmp"
chmod 400 "$ENVFILE.tmp"
mv "$ENVFILE.tmp" "$ENVFILE"
echo "==> Rendered env file from $SECRET_PATH v$VAULT_VERSION"

# --- 2. Figure out which slot is live, deploy to the other one ---------------
LIVE_SLOT=$(cat "$STATE_DIR/live_slot" 2>/dev/null || echo "blue")
if [ "$LIVE_SLOT" = "blue" ]; then
  NEW_SLOT=green; NEW_PORT=$GREEN_PORT; OLD_CONTAINER="$APP-blue"
else
  NEW_SLOT=blue;  NEW_PORT=$BLUE_PORT;  OLD_CONTAINER="$APP-green"
fi
NEW_CONTAINER="$APP-$NEW_SLOT"
echo "==> Live slot: $LIVE_SLOT -> deploying to $NEW_SLOT (port $NEW_PORT)"

docker pull "$IMAGE"
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
  "$IMAGE"

# --- 3. Health check before swapping traffic ---------------------------------
ok=false
for i in $(seq 1 $HEALTH_RETRIES); do
  if curl -sf "http://127.0.0.1:$NEW_PORT$HEALTH_PATH" >/dev/null; then
    ok=true; break
  fi
  echo "   health check $i/$HEALTH_RETRIES failed, retrying in ${HEALTH_INTERVAL}s"
  sleep $HEALTH_INTERVAL
done

if [ "$ok" != true ]; then
  echo "!! Health check FAILED — old version stays live. Cleaning up."
  docker logs --tail 50 "$NEW_CONTAINER" || true
  docker rm -f "$NEW_CONTAINER"
  exit 1
fi

# --- 4. Swap nginx upstream to the new port, verify, then retire old ---------
sed "s/__PORT__/$NEW_PORT/" /opt/$APP/nginx-upstream.conf.tpl \
  > /etc/nginx/conf.d/$APP-upstream.conf
nginx -t && nginx -s reload
sleep 2
curl -sf "http://127.0.0.1$HEALTH_PATH" >/dev/null \
  || { echo "!! Post-swap check failed — reverting nginx"; \
       sed "s/__PORT__/$( [ "$NEW_PORT" = "$BLUE_PORT" ] && echo $GREEN_PORT || echo $BLUE_PORT )/" \
         /opt/$APP/nginx-upstream.conf.tpl > /etc/nginx/conf.d/$APP-upstream.conf; \
       nginx -s reload; docker rm -f "$NEW_CONTAINER"; exit 1; }

docker rm -f "$OLD_CONTAINER" 2>/dev/null || true

# --- 5. Persist local state for tracking / disaster recovery -----------------
echo "$NEW_SLOT" > "$STATE_DIR/live_slot"
echo "$IMAGE"    > "$STATE_DIR/current_image"
echo "$VAULT_VERSION" > "$STATE_DIR/current_vault_version"
echo "$(date -u +%FT%TZ),$IMAGE,$VAULT_VERSION,$NEW_SLOT" >> "$STATE_DIR/host_deploy_history.csv"

echo "===== deploy OK: $IMAGE (vault v$VAULT_VERSION) live on slot $NEW_SLOT ====="
