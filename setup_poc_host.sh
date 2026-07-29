#!/usr/bin/env bash
# =============================================================================
# setup_poc_host.sh — one-time setup of the POC/deploy host (run as root)
#
# Configures:
#   1. deploy user that the build host SSHes in as (service account identity)
#   2. Docker + daemon proxy (NO_PROXY for Artifactory!)
#   3. vault-agent systemd service (token sink at /run/vault/token)
#   4. /opt/chatapp deploy scripts + sudoers rule
#   5. nginx for the blue-green swap
# =============================================================================
set -euo pipefail

# ---------------- CONFIG ----------------
DEPLOY_USER="deploy"
BUILD_HOST_PUBKEY="ssh-ed25519 AAAA... svc-chatapp@buildhost"   # paste from setup_build_host.sh output
PROXY_URL="http://proxyuser:proxypass@proxy.corp:8080"
NO_PROXY="localhost,127.0.0.1,.internal.corp,artifactory.internal.corp,vault.internal.corp"
VAULT_ADDR="https://vault.internal.corp:8200"
# AppRole creds for THIS host (from vault_setup.sh output; deliver securely):
VAULT_ROLE_ID_FILE_CONTENT="<role_id for chatapp-deploy-host>"
VAULT_SECRET_ID_FILE_CONTENT="<secret_id for chatapp-deploy-host>"
# ----------------------------------------

echo "==> 1. Deploy user + SSH trust from build host"
id "$DEPLOY_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEPLOY_USER"
DEPLOY_HOME=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
mkdir -p "$DEPLOY_HOME/.ssh" && chmod 700 "$DEPLOY_HOME/.ssh"
grep -qF "$BUILD_HOST_PUBKEY" "$DEPLOY_HOME/.ssh/authorized_keys" 2>/dev/null \
  || echo "$BUILD_HOST_PUBKEY" >> "$DEPLOY_HOME/.ssh/authorized_keys"
chmod 600 "$DEPLOY_HOME/.ssh/authorized_keys"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh"
usermod -aG docker "$DEPLOY_USER"

echo "==> 2. Docker daemon proxy (Artifactory in NO_PROXY -> direct)"
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=$PROXY_URL"
Environment="HTTPS_PROXY=$PROXY_URL"
Environment="NO_PROXY=$NO_PROXY"
EOF
systemctl daemon-reload && systemctl restart docker

echo "==> 3. Vault agent (token sink only; deploy script reads pinned versions)"
mkdir -p /etc/vault/agent /run/vault
echo "$VAULT_ROLE_ID_FILE_CONTENT"   > /etc/vault/agent/role_id
echo "$VAULT_SECRET_ID_FILE_CONTENT" > /etc/vault/agent/secret_id
chmod 600 /etc/vault/agent/role_id /etc/vault/agent/secret_id
cp "$(dirname "$0")/../vault/vault-agent.hcl" /etc/vault/agent/chatapp.hcl

cat > /etc/systemd/system/vault-agent-chatapp.service <<EOF
[Unit]
Description=Vault Agent (chatapp)
After=network-online.target
[Service]
Environment="VAULT_ADDR=$VAULT_ADDR"
Environment="NO_PROXY=$NO_PROXY"
ExecStart=/usr/bin/vault agent -config=/etc/vault/agent/chatapp.hcl
Restart=on-failure
RuntimeDirectory=vault
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now vault-agent-chatapp

echo "==> 4. Deploy scripts + sudoers"
mkdir -p /opt/chatapp /var/lib/chatapp /var/log/chatapp
cp "$(dirname "$0")/../deploy/deploy_local.sh"          /opt/chatapp/
cp "$(dirname "$0")/../deploy/nginx-upstream.conf.tpl"  /opt/chatapp/
chmod 750 /opt/chatapp/deploy_local.sh
chown root:root /opt/chatapp/deploy_local.sh
cat > /etc/sudoers.d/chatapp-deploy <<EOF
$DEPLOY_USER ALL=(root) NOPASSWD: /opt/chatapp/deploy_local.sh
EOF
chmod 440 /etc/sudoers.d/chatapp-deploy

echo "==> 5. nginx"
apt-get install -y nginx >/dev/null
# initial upstream -> blue port so first deploy has something to swap from
sed "s/__PORT__/8080/" /opt/chatapp/nginx-upstream.conf.tpl \
  > /etc/nginx/conf.d/chatapp-upstream.conf
nginx -t && systemctl reload nginx

echo ""
echo "==> DONE. Test the chain from the BUILD host:"
echo "    sudo -u svc-chatapp ssh $DEPLOY_USER@\$(hostname) 'sudo /opt/chatapp/deploy_local.sh --help || true'"
