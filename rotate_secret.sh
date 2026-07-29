#!/usr/bin/env bash
# =============================================================================
# rotate_secret.sh <env> KEY=VALUE [KEY=VALUE ...]
#
# THE ONLY SANCTIONED WAY to change chatapp's secrets.
# Why: an out-of-band `vault kv put` creates a secret version that no manifest
# row points to. Then a later rollback restores the wrong version (the trap:
# image2 was recorded with v3, you hand-rotated to v4, deployed image3+v5;
# rollback restores image2+v3 — but image2 was actually last good with v4).
#
# This script makes every secret change a *release event*:
#   1. Reads existing secret, merges in the new keys (partial update safe)
#   2. Writes the new version
#   3. Appends a manifest row pairing the CURRENT image with the NEW version
#   4. Re-deploys the current image so the running app picks it up immediately
# =============================================================================
set -euo pipefail

ENV="${1:?usage: rotate_secret.sh <env> KEY=VALUE ...}"; shift
[ $# -ge 1 ] || { echo "at least one KEY=VALUE required"; exit 1; }

APP=chatapp
SECRET_PATH="secret/$APP/$ENV"
RELEASES_REPO="git@gitlab.internal.corp:platform/chatapp-releases.git"

# Auth with the secret-admin AppRole (creds injected via CI vars or prompted)
export VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$VAULT_ADMIN_ROLE_ID" secret_id="$VAULT_ADMIN_SECRET_ID")
trap 'vault token revoke -self >/dev/null 2>&1 || true' EXIT

# --- 1. Merge: read current data, overlay new KVs ----------------------------
CURRENT_JSON=$(vault kv get -format=json "$SECRET_PATH" | python3 -c \
  'import json,sys; print(json.dumps(json.load(sys.stdin)["data"]["data"]))')

NEW_JSON=$(python3 - "$CURRENT_JSON" "$@" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    data[k] = v
print(json.dumps(data))
PY
)

# --- 2. Write new version ----------------------------------------------------
echo "$NEW_JSON" | vault kv put "$SECRET_PATH" -
NEW_VERSION=$(vault kv metadata get -field=current_version "$SECRET_PATH")
echo "==> $SECRET_PATH now at version $NEW_VERSION"

# --- 3. Record manifest row: current image + NEW secret version --------------
WORKDIR=$(mktemp -d)
git clone --depth 1 "$RELEASES_REPO" "$WORKDIR/releases"
MANIFEST="$WORKDIR/releases/$ENV/manifest.csv"
CURRENT_TAG=$(tail -n 1 "$MANIFEST" | cut -d, -f2)   # image currently deployed

echo "$(date -u +%FT%TZ),$CURRENT_TAG,$NEW_VERSION,SECRET-ROTATION,manual,$(whoami)" >> "$MANIFEST"
git -C "$WORKDIR/releases" add -A
git -C "$WORKDIR/releases" -c user.name="$(whoami)" -c user.email="$(whoami)@internal.corp" \
  commit -m "secret-rotation($ENV): $APP image=$CURRENT_TAG -> vault v$NEW_VERSION"
git -C "$WORKDIR/releases" push origin HEAD

# --- 4. Redeploy current image with the new secret version -------------------
echo "==> Redeploying $CURRENT_TAG with vault v$NEW_VERSION to pick up new secret"
bash "$(dirname "$0")/../ci/deploy_from_buildhost.sh" "$ENV" "$CURRENT_TAG"

echo "==> Rotation complete and recorded."
