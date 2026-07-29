#!/usr/bin/env bash
# =============================================================================
# setup_build_host.sh — one-time setup of the BUILD host (run as root)
#
# Configures:
#   1. GitLab runner running AS the service account (shell executor)
#   2. Docker daemon proxy (needed for docker PULL/PUSH through corp proxy)
#   3. Service account: docker group, pip config, vault CLI, ssh key
#
# Edit the CONFIG block, then: sudo bash setup_build_host.sh
# =============================================================================
set -euo pipefail

# ---------------- CONFIG ----------------
SVC_USER="svc-chatapp"                          # your service account
GITLAB_URL="https://gitlab.internal.corp"
RUNNER_TOKEN="glrt-XXXXXXXXXXXX"                # from Project > Settings > CI/CD > Runners
PROXY_URL="http://proxyuser:proxypass@proxy.corp:8080"
NO_PROXY="localhost,127.0.0.1,.internal.corp"
ARTIFACTORY_HOST="artifactory.internal.corp"
PIP_INDEX="https://$ARTIFACTORY_HOST/artifactory/api/pypi/pypi-remote/simple"
# ----------------------------------------

echo "==> 1. Docker daemon proxy (so docker pull/push traverse the corp proxy)"
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY_URL"
Environment="HTTPS_PROXY=$PROXY_URL"
Environment="NO_PROXY=$NO_PROXY,$ARTIFACTORY_HOST"
EOF
# NOTE: internal Artifactory is in NO_PROXY — registry traffic must go DIRECT,
# not through the proxy. This is the #1 misconfiguration in corp environments.
systemctl daemon-reload && systemctl restart docker

echo "==> 2. Service account exists + docker access"
id "$SVC_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$SVC_USER"
usermod -aG docker "$SVC_USER"

echo "==> 3. Service account environment: proxy + pip defaults"
SVC_HOME=$(getent passwd "$SVC_USER" | cut -d: -f6)
cat > "$SVC_HOME/.profile.d-proxy.sh" <<EOF
export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
export no_proxy="$NO_PROXY" NO_PROXY="$NO_PROXY"
EOF
grep -q profile.d-proxy "$SVC_HOME/.bashrc" || \
  echo 'source ~/.profile.d-proxy.sh' >> "$SVC_HOME/.bashrc"

mkdir -p "$SVC_HOME/.pip"
cat > "$SVC_HOME/.pip/pip.conf" <<EOF
[global]
index-url = $PIP_INDEX
trusted-host = $ARTIFACTORY_HOST
EOF
chown -R "$SVC_USER:$SVC_USER" "$SVC_HOME/.pip" "$SVC_HOME/.profile.d-proxy.sh"

echo "==> 4. SSH key for reaching deploy/POC hosts"
sudo -u "$SVC_USER" bash -c "
  [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
"
echo "    Public key (add to deploy@<poc-host>:~/.ssh/authorized_keys, and"
echo "    upload the PRIVATE key as GitLab CI File variable DEPLOY_SSH_KEY):"
cat "$SVC_HOME/.ssh/id_ed25519.pub"

echo "==> 5. Install gitlab-runner, run it AS the service account"
if ! command -v gitlab-runner >/dev/null; then
  curl -x "$PROXY_URL" -L \
    "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash
  apt-get install -y gitlab-runner
fi
gitlab-runner stop || true
gitlab-runner uninstall || true
gitlab-runner install --user "$SVC_USER" --working-directory "$SVC_HOME"
systemctl restart gitlab-runner

echo "==> 6. Register runner (shell executor, locked to project, tagged)"
gitlab-runner register --non-interactive \
  --url "$GITLAB_URL" \
  --token "$RUNNER_TOKEN" \
  --executor shell \
  --tag-list build-host \
  --locked=true \
  --description "chatapp build host ($SVC_USER)"

# Give the runner process itself proxy access (for cloning through proxy
# if gitlab isn't in NO_PROXY — usually internal gitlab IS in NO_PROXY):
mkdir -p /etc/systemd/system/gitlab-runner.service.d
cat > /etc/systemd/system/gitlab-runner.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY_URL"
Environment="HTTPS_PROXY=$PROXY_URL"
Environment="NO_PROXY=$NO_PROXY"
EOF
systemctl daemon-reload && systemctl restart gitlab-runner

echo ""
echo "==> DONE. Verify with:  sudo -u $SVC_USER gitlab-runner status"
echo "    and check the runner shows green in GitLab Project > Settings > CI/CD."
echo ""
echo "Remaining manual steps:"
echo "  - Add CI/CD variables in GitLab (see .gitlab-ci.yml header)"
echo "  - Run vault/vault_setup.sh (as vault admin) incl. the new poc AppRole"
echo "  - Run setup_poc_host.sh on the POC server"
