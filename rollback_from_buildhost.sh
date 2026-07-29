#!/usr/bin/env bash
# =============================================================================
# rollback_from_buildhost.sh <env> [target_tag]
#
# If target_tag is given: roll back to the manifest row matching that tag.
# If omitted:             roll back to the second-to-last manifest row
#                         (the last known-good release before the current one).
#
# Restores BOTH the image and the paired Vault secret version, in the right
# order: secret first, then image — so the old image never starts against a
# newer secret it wasn't deployed with.
# =============================================================================
set -euo pipefail

ENV="${1:?usage: rollback_from_buildhost.sh <env> [tag]}"
TARGET_TAG="${2:-}"

APP_NAME="chatapp"
SECRET_PATH="secret/$APP_NAME/$ENV"
RELEASES_REPO="git@gitlab.internal.corp:platform/chatapp-releases.git"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i $DEPLOY_SSH_KEY"

export VAULT_TOKEN=$(vault write -field=token auth/approle/login \
    role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID")
trap 'vault token revoke -self >/dev/null 2>&1 || true' EXIT

# --- 1. Find the target release row in the manifest --------------------------
WORKDIR=$(mktemp -d)
git clone --depth 5 "$RELEASES_REPO" "$WORKDIR/releases"
MANIFEST="$WORKDIR/releases/$ENV/manifest.csv"

if [ -n "$TARGET_TAG" ]; then
  ROW=$(grep ",$TARGET_TAG," "$MANIFEST" | tail -n 1) \
    || { echo "tag $TARGET_TAG not found in manifest"; exit 1; }
else
  # second-to-last data row = previous known-good
  ROW=$(tail -n +2 "$MANIFEST" | tail -n 2 | head -n 1)
fi

OLD_TAG=$(echo "$ROW"  | cut -d, -f2)
OLD_VAULT=$(echo "$ROW" | cut -d, -f3)
IMAGE="$ARTIFACTORY_REGISTRY/$APP_NAME:$OLD_TAG"

echo "==> ROLLBACK env=$ENV to image=$OLD_TAG vault_version=$OLD_VAULT"

# --- 2. Roll back the Vault secret FIRST -------------------------------------
CURRENT_VAULT=$(vault kv metadata get -field=current_version "$SECRET_PATH")
if [ "$CURRENT_VAULT" != "$OLD_VAULT" ]; then
  echo "==> Restoring vault $SECRET_PATH from v$CURRENT_VAULT to v$OLD_VAULT"
  # NOTE: kv rollback creates a NEW version whose data == the old version.
  # Nothing is destroyed; history stays intact and auditable.
  vault kv rollback -mount=secret -version="$OLD_VAULT" "$APP_NAME/$ENV"
else
  echo "==> Vault already at target version $OLD_VAULT — no secret change"
fi

# --- 3. Roll back each deploy host (same local script as a normal deploy) ----
case "$ENV" in
  staging) HOSTS="$STAGING_HOSTS" ;;
  prod)    HOSTS="$DEPLOY_HOSTS"  ;;
esac

NEW_CURRENT=$(vault kv metadata get -field=current_version "$SECRET_PATH")
for HOST in $HOSTS; do
  echo "==> Rolling back $HOST"
  ssh $SSH_OPTS "deploy@$HOST" \
    "sudo /opt/chatapp/deploy_local.sh '$IMAGE' '$NEW_CURRENT' '$ENV'"
done

# --- 4. Record the rollback as its own manifest row (append-only history!) ---
echo "$(date -u +%FT%TZ),$OLD_TAG,$NEW_CURRENT,ROLLBACK,${CI_PIPELINE_URL:-manual},${GITLAB_USER_LOGIN:-$(whoami)}" >> "$MANIFEST"
git -C "$WORKDIR/releases" add -A
git -C "$WORKDIR/releases" -c user.name="ci-bot" -c user.email="ci@internal.corp" \
  commit -m "ROLLBACK($ENV): $APP_NAME -> $OLD_TAG (vault v$NEW_CURRENT)"
git -C "$WORKDIR/releases" push origin HEAD

echo "==> Rollback complete and recorded."
