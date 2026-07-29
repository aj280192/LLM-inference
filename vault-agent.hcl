# =============================================================================
# /etc/vault/agent/chatapp.hcl — Vault Agent config on each DEPLOY host
#
# Role here: maintain a valid, auto-renewed Vault token at /run/vault/token.
# deploy_local.sh uses that token to read a PINNED secret version at deploy
# time — we deliberately do NOT use agent templates to render the .env,
# because templates always render "latest" and that breaks version pinning.
#
# systemd unit: vault-agent-chatapp.service ->
#   ExecStart=/usr/bin/vault agent -config=/etc/vault/agent/chatapp.hcl
# =============================================================================

pid_file = "/run/vault/agent.pid"

vault {
  address = "https://vault.internal.corp:8200"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/etc/vault/agent/role_id"
      secret_id_file_path                 = "/etc/vault/agent/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/run/vault/token"    # /run = tmpfs; token never hits disk
      mode = 0400
    }
  }
}

# Optional: keep a rendered "latest" env for humans to inspect (NOT used by
# the deploy flow). Comment out if you want zero rendered secrets at rest.
# template {
#   source      = "/etc/vault/agent/chatapp.env.tpl"
#   destination = "/run/chatapp/latest.env"
#   perms       = "0400"
# }
