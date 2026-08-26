#!/usr/bin/env bash
# ============================================================================
# ci/run-e2e.sh <suite>
#
# Runs YOUR OWN async Playwright test scripts from a throwaway container.
# The official Playwright image already contains: python, the playwright
# package, all browsers (chromium/firefox/webkit) and sets
# PLAYWRIGHT_BROWSERS_PATH — nothing browser-related needs configuring.
#
# Your scripts use only stdlib (asyncio, importlib, os, time, dataclasses,
# pathlib) plus python-dotenv — so python-dotenv is the ONLY package
# installed here. No pytest needed.
#
# IMPORTANT: keep the image tag's Playwright version in sync with whatever
# playwright version your scripts were written against.
#
# Expected script layout (adapt names to yours):
#   tests/run_smoke.py        login-only check
#   tests/run_e2e.py          full user flow
#   tests/run_smoke_full.py   login + one real query
#
# Config reaches your scripts via environment variables (-e flags below).
# python-dotenv's load_dotenv() is a no-op when no .env file exists, so
# scripts fall through to os.environ — which is exactly what CI populates.
#
# Called by pipeline jobs:
#   test:smoke-dev             -> run-e2e.sh smoke       (dev VM)
#   test:e2e-int                -> run-e2e.sh e2e         (int VM)
#   test:smoke-prod             -> run-e2e.sh smoke       (prod VM)
#   test:smoke-prod-full-query  -> run-e2e.sh smoke-full  (prod VM)
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
# script exits non-zero on any test failure so the pipeline job goes red
