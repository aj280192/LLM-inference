#!/usr/bin/env bash
# ============================================================================
# ci/nominate-int.sh <image> <version> [force]
#
# int is ONE physical VM — only one UAT candidate can occupy it at a time.
# This script enforces that with an ATOMIC lock (mkdir, not a plain file
# read-check-write, which would race under near-simultaneous nominations).
#
# Normal case: refuses if int is already occupied by another candidate.
# Hotfix case: pass "force" as the 3rd arg to preempt — the current
# occupant is snapshotted to INT_PAUSED (nothing rebuilt, nothing lost)
# and can be brought back later with ci/resume-int.sh.
#
# No auto-rollback here by design (see rollback design decisions) — if
# THIS nomination's deploy fails health checks, it fails loudly and stays
# failed; a human decides whether to retry, force a different candidate,
# or investigate. int is allowed to be visibly broken.
# ============================================================================
set -euo pipefail

IMAGE="${1:?usage: nominate-int.sh <image> <version> [force]}"
VERSION="${2:?usage: nominate-int.sh <image> <version> [force]}"
FORCE="${3:-false}"

APP_DIR="${APP_DIR:-/opt/apps/reportapp}"
LOCK_DIR="$APP_DIR/.int_lock"          # mkdir = atomic, race-free claim
OCCUPANT_FILE="$APP_DIR/INT_OCCUPANT"
PAUSED_FILE="$APP_DIR/INT_PAUSED"
DEPLOY_LOG="$APP_DIR/DEPLOY_LOG"

log() { echo "[nominate:int] $*"; }
audit() { echo "$(date -Iseconds) $*" >> "$DEPLOY_LOG"; }

# --- atomic claim attempt ---------------------------------------------
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -s "$OCCUPANT_FILE" ]; then
    log "int is occupied:"
    cat "$OCCUPANT_FILE"
  fi
  if [ "$FORCE" != "force" ]; then
    log "Refusing to preempt. Wait for UAT to finish, or pass 'force' (hotfix)."
    exit 1
  fi
  log "FORCE requested — preempting current occupant"
  if [ -s "$OCCUPANT_FILE" ]; then
    cp "$OCCUPANT_FILE" "$PAUSED_FILE"
    audit "$(grep -oP 'version=\K.*' "$OCCUPANT_FILE" 2>/dev/null || echo unknown) paused-for-hotfix"
  fi
  # lock dir already exists (that's why mkdir failed) — reuse it, we hold
  # it now since we're the ones overwriting the occupant record below
fi

# --- record new occupant, then deploy -----------------------------------
cat > "$OCCUPANT_FILE" << EOF
version=$VERSION
nominated_at=$(date -Iseconds)
EOF
audit "$VERSION nominated-to-int force=$FORCE"

"$(dirname "$0")/deploy.sh" int "$IMAGE" "$VERSION"
DEPLOY_RESULT=$?

if [ "$DEPLOY_RESULT" -ne 0 ]; then
  log "Deploy to int FAILED for $VERSION — occupancy lock stays held."
  log "Fix and re-run nominate:int for this version, or force a different one."
  exit 1
fi

log "SUCCESS: $VERSION is live on int for UAT"
exit 0
