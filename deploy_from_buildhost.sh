#!/usr/bin/env bash
# =============================================================================
# deploy_from_buildhost.sh <env> <image_tag>
#
# Runs ON THE BUILD HOST (inside the GitLab runner job).
# For each deploy host:
#   1. Reads the current Vault secret version for this env (pins it)
#   2. SSHes to the deploy host and runs the local deploy script there
#   3. Appends a row to the central release manifest (in git! see below)
#
# The manifest is a git-tracked file in a dedicated "releases" repo so that
# the deployment state itself is version-controlled, auditable, and
# revertible — this is the poor-man's GitOps pattern.
# =============================================================================
set -euo pipefail

ENV="${1:?usage: deploy_from_buildhost.sh <env> <tag>}"
TAG="${2:?usage: deploy_from_buildhost.sh <env> <tag>}"

APP_NAME="chatapp"
IMAGE="$ARTIFACTORY_REGISTRY/$APP_NAME:$TAG"
SECRET_PATH="secret/$APP_NAME/$ENV"
RELEASES_REPO="git@gitlab.internal.corp:platform/chatapp-releases.git"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i $DEPLOY_SSH_KEY"

# --- 0. Authenticate to Vault via AppRole (short-lived token, read-only) -----
export VAULT_TOKEN=$(vault write -field=token auth/approle/login \
    role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID")
trap 'vault token revoke -self >/dev/null 2>&1 || true' EXIT

# --- 1. Pin the CURRENT secret version — this is the version this release uses
VAULT_VERSION=$(vault kv metadata get -field=current_version "$SECRET_PATH")
echo "==> Deploying $IMAGE to env=$ENV with vault secret version=$VAULT_VERSION"

# --- 2. Resolve deploy hosts for this env -----------------------------------
case "$ENV" in
  staging) HOSTS="$STAGING_HOSTS" ;;   # CI variable, e.g. "stg-deploy1.corp"
  prod)    HOSTS="$DEPLOY_HOSTS"  ;;   # e.g. "deploy1.corp deploy2.corp"
  *) echo "unknown env $ENV"; exit 1 ;;
esac

# --- 3. Rolling deploy: one host at a time, abort on first failure ----------
#     (with 2+ hosts behind a load balancer this gives zero-downtime rollout)
for HOST in $HOSTS; do
  echo "==> Deploying to $HOST"
  # Push the version-pinned instruction; the host-local script does the rest.
  ssh $SSH_OPTS "deploy@$HOST" \
    "sudo /opt/chatapp/deploy_local.sh '$IMAGE' '$VAULT_VERSION' '$ENV'" \
    || { echo "!! Deploy FAILED on $HOST — aborting rollout. Hosts already"
         echo "!! updated are running the new version; run rollback to converge."
         exit 1; }
done

# --- 4. Record the release in the git-tracked manifest -----------------------
WORKDIR=$(mktemp -d)
git clone --depth 1 "$RELEASES_REPO" "$WORKDIR/releases"
MANIFEST="$WORKDIR/releases/$ENV/manifest.csv"
mkdir -p "$(dirname "$MANIFEST")"
[ -f "$MANIFEST" ] || echo "timestamp,image_tag,vault_version,git_sha,pipeline_url,deployer" > "$MANIFEST"

echo "$(date -u +%FT%TZ),$TAG,$VAULT_VERSION,$CI_COMMIT_SHA,$CI_PIPELINE_URL,$GITLAB_USER_LOGIN" >> "$MANIFEST"

git -C "$WORKDIR/releases" add -A
git -C "$WORKDIR/releases" -c user.name="ci-bot" -c user.email="ci@internal.corp" \
  commit -m "release($ENV): $APP_NAME $TAG (vault v$VAULT_VERSION)"
git -C "$WORKDIR/releases" push origin HEAD

echo "==> Release recorded. env=$ENV tag=$TAG vault=$VAULT_VERSION"
