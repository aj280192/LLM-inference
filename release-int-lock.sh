#!/usr/bin/env bash
# ============================================================================
# ci/release-int-lock.sh
#
# Called after UAT concludes — either the candidate was approved (about to
# promote:stable) or rejected (going back for fixes). Either way, int's
# occupancy lock must be freed so the NEXT nomination isn't refused forever.
# ============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/apps/reportapp}"
LOCK_DIR="$APP_DIR/.int_lock"
OCCUPANT_FILE="$APP_DIR/INT_OCCUPANT"
DEPLOY_LOG="$APP_DIR/DEPLOY_LOG"

log() { echo "[release-int-lock] $*"; }
audit() { echo "$(date -Iseconds) $*" >> "$DEPLOY_LOG"; }

if [ -s "$OCCUPANT_FILE" ]; then
  VERSION=$(grep -oP 'version=\K.*' "$OCCUPANT_FILE" || echo "unknown")
  audit "$VERSION int-lock-released"
  log "Released lock held by $VERSION"
else
  log "No occupant recorded — releasing lock anyway"
fi

rm -rf "$LOCK_DIR"
rm -f "$OCCUPANT_FILE"
exit 0
