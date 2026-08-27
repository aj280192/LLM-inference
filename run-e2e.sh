#!/usr/bin/env bash
# ============================================================================
# ci/run-e2e.sh <suite>
#
# Runs your own async Playwright scripts from a throwaway container. The
# official image already has python, playwright, and all browsers —
# nothing browser-related needs configuring. Only python-dotenv is
# installed here (your scripts use stdlib otherwise: asyncio, importlib,
# os, time, dataclasses, pathlib).
#
# Config reaches scripts via env vars (-e flags). python-dotenv's
# load_dotenv() is a no-op with no .env file present, so scripts fall
# through to os.environ, which these -e flags populate.
#
# Called by: test:smoke-dev, test:e2e-int, test:smoke-prod,
#            test:smoke-prod-full-query
# ============================================================================
set -euo pipefail

SUITE="${1:?usage: run-e2e.sh <e2e|smoke|smoke-full>}"
BASE_URL="${BASE_URL:?BASE_URL must be set}"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright/python:v1.47.0-jammy"

case "$SUITE" in
  e2e)        SCRIPT="run_e2e.py" ;;
  smoke)      SCRIPT="run_smoke.py" ;;
  smoke-full) SCRIPT="run_smoke_full.py" ;;
  *) echo "Unknown suite: $SUITE"; exit 1 ;;
esac

echo "[run-e2e] suite=$SUITE script=$SCRIPT base_url=$BASE_URL"

docker run --rm \
  --memory=512m --cpus=0.5 \
  -v "$(pwd)/tests:/tests" \
  -w /tests \
  -e BASE_URL="$BASE_URL" \
  -e E2E_USERNAME="${E2E_USERNAME:-}" \
  -e E2E_PASSWORD="${E2E_PASSWORD:-}" \
  "$PLAYWRIGHT_IMAGE" \
  bash -c "pip install --quiet python-dotenv && python $SCRIPT"

# the container's exit code IS your script's exit code — make sure your
# script exits non-zero on any failure so the pipeline job goes red
