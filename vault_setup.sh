#!/usr/bin/env bash
# =============================================================================
# vault_setup.sh — one-time Vault configuration (run by a Vault admin)
#
# Creates:
#   - KV v2 mount with version retention
#   - Three narrowly-scoped policies: ci (read+metadata+rollback),
#     deploy-host (read-only), secret-admin (write, for the rotation script)
#   - Matching AppRoles with short TTLs
#
# Principle: NOBODY writes prod secrets by hand. All writes go through
# scripts/rotate_secret.sh (which records a manifest row), using the
# secret-admin role. Humans get read access at most.
# =============================================================================
set -euo pipefail
APP=chatapp

# --- KV v2 with history retained (needed for version-pinned rollback) --------
vault secrets enable -path=secret kv-v2 2>/dev/null || true
vault kv metadata put -max-versions=30 secret/$APP/prod || true
vault kv metadata put -max-versions=30 secret/$APP/staging || true

# --- Policy: deploy hosts — read any VERSION of the secret, nothing else -----
vault policy write $APP-deploy-host - <<EOF
path "secret/data/$APP/+" {
  capabilities = ["read"]
}
path "secret/metadata/$APP/+" {
  capabilities = ["read"]
}
EOF

# --- Policy: CI — read + perform version rollback (an "undelete"-style write)
vault policy write $APP-ci - <<EOF
path "secret/data/$APP/+" {
  capabilities = ["read"]
}
path "secret/metadata/$APP/+" {
  capabilities = ["read"]
}
# kv rollback = write to data path with old contents
path "secret/data/$APP/+" {
  capabilities = ["read", "create", "update"]
}
EOF

# --- Policy: secret rotation (used only by rotate_secret.sh) -----------------
vault policy write $APP-secret-admin - <<EOF
path "secret/data/$APP/+" {
  capabilities = ["create", "update", "read"]
}
path "secret/metadata/$APP/+" {
  capabilities = ["read"]
}
EOF

# --- AppRoles ----------------------------------------------------------------
vault auth enable approle 2>/dev/null || true

vault write auth/approle/role/$APP-deploy-host \
  token_policies="$APP-deploy-host" \
  token_ttl=1h token_max_ttl=4h secret_id_ttl=0   # long-lived secret_id on host

vault write auth/approle/role/$APP-ci \
  token_policies="$APP-ci" \
  token_ttl=15m token_max_ttl=30m secret_id_ttl=90d

vault write auth/approle/role/$APP-secret-admin \
  token_policies="$APP-secret-admin" \
  token_ttl=15m token_max_ttl=30m secret_id_ttl=90d

echo "Role IDs (store secret_ids in GitLab CI variables / host files):"
for r in $APP-deploy-host $APP-ci $APP-secret-admin; do
  echo "  $r: $(vault read -field=role_id auth/approle/role/$r/role-id)"
done

# --- POC AppRole for FEATURE-BRANCH pipelines (weaker, unprotected CI var) ---
vault kv metadata put -max-versions=30 secret/$APP/poc || true

vault policy write $APP-poc-only - <<EOP
path "secret/data/$APP/poc" {
  capabilities = ["read"]
}
path "secret/metadata/$APP/poc" {
  capabilities = ["read"]
}
EOP

vault write auth/approle/role/$APP-poc-only \
  token_policies="$APP-poc-only" \
  token_ttl=15m token_max_ttl=30m secret_id_ttl=90d
echo "  $APP-poc-only: $(vault read -field=role_id auth/approle/role/$APP-poc-only/role-id)"
