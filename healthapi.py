"""Health API sidecar — runs alongside Streamlit in the same container.

Streamlit owns its own web server and cannot expose custom routes, so this
tiny FastAPI app on a second port (8000) answers the questions machines ask:

  GET /healthz  -> liveness:  is the process running at all?
  GET /readyz   -> readiness: can the app actually serve users?
                   (secrets loaded, DB reachable, LLM endpoint reachable)
  GET /version  -> the exact version baked into this image at build time
                   (APP_VERSION via SETUPTOOLS_SCM_PRETEND_VERSION)

Consumed by:
  - docker compose healthcheck (every 30s)
  - ci/deploy.sh   (post-deploy wait-for-healthy loop, rollback trigger)
  - ci/rollback.sh (post-rollback verification)

Design rules:
  - LLM check is CONNECTIVITY only — never a real completion (cost/quota)
  - hard timeouts everywhere — a hanging health check is worse than a fast fail
  - do NOT expose port 8000 through the reverse proxy: the /readyz body
    reveals internal architecture; only VM-local callers need it
"""

import os
from importlib.metadata import PackageNotFoundError, version

import httpx
import psycopg2
from fastapi import FastAPI, Response

app = FastAPI()

REQUIRED_ENV = ["DB_URL", "LLM_API_KEY", "LLM_BASE_URL"]


@app.get("/healthz")
def healthz() -> dict:
    """Liveness: the process is up. Checks nothing else."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz(response: Response) -> dict:
    """Readiness: dependency checks, each independent, each time-boxed."""
    checks: dict[str, str] = {}

    # 1. secrets present? (cheap existence check, not validity)
    checks["secrets"] = (
        "ok" if all(os.environ.get(k) for k in REQUIRED_ENV) else "fail"
    )

    # 2. database reachable?
    try:
        conn = psycopg2.connect(os.environ["DB_URL"], connect_timeout=3)
        conn.close()
        checks["db"] = "ok"
    except Exception:
        checks["db"] = "fail"

    # 3. LLM endpoint reachable? (connectivity only — no paid completion)
    try:
        httpx.get(os.environ["LLM_BASE_URL"], timeout=3)
        checks["llm"] = "ok"
    except Exception:
        checks["llm"] = "fail"

    healthy = all(v == "ok" for v in checks.values())
    response.status_code = 200 if healthy else 503
    return {"status": "ok" if healthy else "fail", "checks": checks}


@app.get("/version")
def app_version() -> dict:
    """The exact version baked in at build time — lets anyone verify the
    running app matches its Docker tag / JFrog label."""
    try:
        return {"version": version("reportapp")}
    except PackageNotFoundError:
        return {"version": "unknown"}
