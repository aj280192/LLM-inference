#!/usr/bin/env bash
# ============================================================================
# ci/preflight.sh <build|env>
#
# Fail-fast validation that a runner has what it needs, BEFORE any real
# work (build, deploy) starts. Called as the first line of relevant jobs.
#
# Why this exists: a missing tool / dead service on a VM should produce a
# clear, immediate, named failure ("FAIL vault reachable") — not a
# confusing error three steps into deploy.sh. Fixing the VM + re-running
# preflight.sh manually lets you CONFIRM the fix before retrying the job.
# ============================================================================
set -uo pipefail   # NOT -e: we want to run every check, not stop at first

MODE="${1:?usage: preflight.sh <build|env>}"
APP_DIR="${APP_DIR:-/opt/apps/reportapp}"
FAILED=0

check() {   # check "<name>" <command...>   -- hard failure
  local name="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "  OK    $name"
  else
    echo "  FAIL  $name"
    FAILED=1
  fi
}

warn() {    # warn "<name>" <command...>    -- soft warning, doesn't block
  local name="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "  OK    $name"
  else
    echo "  WARN  $name"
  fi
}

echo "[preflight:$MODE] running checks..."

# --- common to every runner --------------------------------------------
check "docker daemon responding"   docker info
check "disk space > 5GB free"      bash -c '[ "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -gt 5 ]'

if [ "$MODE" == "build" ]; then
  check "jf CLI present"            command -v jf
  check "jf authenticated"          jf rt ping
  check "uv present"                 command -v uv
  check "syft present"               command -v syft
  check "git present"                 command -v git
  check "vault CLI present"          command -v vault
  warn  "vault reachable"            vault status
fi

if [ "$MODE" == "env" ]; then
  check "docker compose present"     docker compose version
  check "curl present"                command -v curl
  check "app dir exists + writable"   test -w "$APP_DIR"
  check ".env exists"                 test -s "$APP_DIR/.env"
  warn  ".env fresh (<60 min)"        bash -c "[ -z \"\$(find $APP_DIR/.env -mmin +60 2>/dev/null)\" ]"
  warn  "registry reachable"          curl -sf --max-time 5 "https://jfrog.company.com/artifactory/api/system/ping"
fi

if [ "$FAILED" -eq 1 ]; then
  echo "[preflight:$MODE] FAILED — fix the FAIL items above, then retry this job"
  exit 1
fi
echo "[preflight:$MODE] all required checks passed"
