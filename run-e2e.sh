#!/usr/bin/env bash
# ============================================================================
# ci/run-e2e.sh <suite>
#
# Runs Playwright tests from a throwaway Docker container against a live
# BASE_URL. Never bundled into the app image — this is a separate,
# disposable client, same as a real user's browser hitting the deployed app.
#
# Usage:
#   BASE_URL=http://localhost:8501 ./ci/run-e2e.sh smoke        # login-only
#   BASE_URL=http://localhost:8501 ./ci/run-e2e.sh e2e          # full flow
#   BASE_URL=https://reportapp.company.com ./ci/run-e2e.sh smoke-full
#
# Called from (job name -> suite):
#   test:smoke-dev            -> smoke       (runs on the dev VM runner)
#   test:e2e-int               -> e2e         (runs on the int VM runner)
#   test:smoke-prod            -> smoke       (runs on the prod VM runner)
#   test:smoke-prod-full-query -> smoke-full  (runs on the prod VM runner,
#                                               allow_failure: true)
# ============================================================================
set -euo pipefail

SUITE="${1:?usage: run-e2e.sh <e2e|smoke|smoke-full>}"
BASE_URL="${BASE_URL:?BASE_URL must be set}"
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright/python:v1.47.0-jammy"

case "$SUITE" in
  e2e)         TEST_PATH="tests/e2e" ;;
  smoke)       TEST_PATH="tests/smoke/test_login.py" ;;
  smoke-full)  TEST_PATH="tests/smoke/test_full_query.py" ;;
  *) echo "Unknown suite: $SUITE"; exit 1 ;;
esac

echo "[run-e2e] suite=$SUITE base_url=$BASE_URL"

docker run --rm \
  --memory=512m --cpus=0.5 \
  -v "$(pwd)/tests:/tests" \
  -w /tests \
  -e BASE_URL="$BASE_URL" \
  "$PLAYWRIGHT_IMAGE" \
  bash -c "pip install --quiet pytest pytest-playwright && \
           pytest $TEST_PATH --base-url=\"\$BASE_URL\" \
             --junitxml=/tests/${SUITE}-report.xml"
