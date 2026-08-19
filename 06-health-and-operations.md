# 6. Health, Deploy/Rollback Mechanics & Failure Catalogue

## 6.1 Health endpoints

A health endpoint is a URL machines call to ask "are you alive and able to
work?" — `200` = healthy, `503` = broken. Callers: Docker healthchecks,
deploy.sh, smoke tests, monitoring.

### Two levels

- **Liveness** `/healthz` — "is the process running?" Checks nothing else.
- **Readiness** `/readyz` — "can I serve users?" Checks dependencies and
  returns *which* check failed:

```json
{"status": "fail", "checks": {"db": "ok", "secrets": "ok", "llm": "timeout"}}
```

That body is gold during incidents: "the app is fine, the LLM provider is
down" instead of "the app is down."

### The Streamlit problem

Streamlit owns its web server and doesn't allow custom routes. Its built-in
`/_stcore/health` is liveness-only. Solution: a **tiny FastAPI sidecar in the
same container** on a second port:

```python
# healthapi.py
import os
from fastapi import FastAPI, Response
import psycopg2, httpx

app = FastAPI()

@app.get("/healthz")
def healthz():
    return {"status": "ok"}

@app.get("/readyz")
def readyz(response: Response):
    checks = {}
    checks["secrets"] = "ok" if os.environ.get("DB_URL") and os.environ.get("LLM_API_KEY") else "fail"
    try:
        psycopg2.connect(os.environ["DB_URL"], connect_timeout=3).close()
        checks["db"] = "ok"
    except Exception:
        checks["db"] = "fail"
    try:
        httpx.get(os.environ["LLM_BASE_URL"], timeout=3)   # connectivity only
        checks["llm"] = "ok"
    except Exception:
        checks["llm"] = "fail"
    healthy = all(v == "ok" for v in checks.values())
    response.status_code = 200 if healthy else 503
    return {"status": "ok" if healthy else "fail", "checks": checks}
```

```bash
#!/bin/sh
# entrypoint.sh — both processes in one container
uvicorn healthapi:app --host 0.0.0.0 --port 8000 &
exec streamlit run streamlit_app.py --server.port 8501 --server.address 0.0.0.0
```

Design rules:
1. LLM check = **connectivity, not a real completion** (a paid prompt every
   30s burns quota)
2. **Timeouts on everything** — a hanging health check is worse than a fast
   failure
3. **Don't expose port 8000 through the reverse proxy** — the readiness body
   reveals internal architecture; only VM-local callers need it

### Compose wiring

```yaml
services:
  reportapp:
    image: ${IMAGE_REF}
    env_file: [.env]                    # rendered by Vault Agent
    ports: ["${APP_PORT:-8501}:8501"]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/readyz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 40s                 # boot grace period
    mem_limit: 1g
    cpus: 1.0
    restart: unless-stopped
```

## 6.2 deploy.sh — deploy with automatic rollback

Runs **on** the target VM (shell runner). Logic:

1. **Sanity checks**: `.env` exists (is Vault Agent alive?), warn if stale
2. **Record current version** → `PREVIOUS_VERSION` file (rollback memory —
   plain text files, no extra infra)
3. Deploy: `IMAGE_REF=$IMAGE docker compose --env-file .env up -d --pull always`
4. **Poll `/readyz` up to 90s**
5. Healthy → write `CURRENT_VERSION`, exit 0
6. Never healthy → **redeploy the previous version automatically**, dump
   container logs, and **exit 1 anyway** — the pipeline for the broken
   version must go red so it can't be promoted further, even though prod
   recovered

Edge cases handled: first-ever deploy (no previous → fail with logs, no
rollback target), rollback target *also* unhealthy (CRITICAL log + full
logs + escalate).

## 6.3 rollback.sh — manual rollback

Same health-poll logic, callable as a manual pipeline job any time
("looked healthy, broke 20 minutes later"):

- Reads `PREVIOUS_VERSION`, asks for typed confirmation of the version
- Picks the source repo by environment (prod→stable, int→staging, dev→scratch)
- On success, **swaps** CURRENT/PREVIOUS so you can roll *forward* again
- Also invoked automatically by `smoke-prod`'s `after_script` on failure

One script, three callers → **exactly one rollback code path** to maintain
and trust.

## 6.4 Failure catalogue — what breaks and the fix

### Test stage
| Failure | Fix |
|---|---|
| Flaky tests (the #1 killer) | Mock all network, `pytest-randomly`, quarantine+fix weekly; never normalize retry-until-green |
| Passes locally, fails CI | Same base image for tests as Docker builder stage; committed lockfile |

### Build stage
| Failure | Fix |
|---|---|
| Transitive dep broke overnight | Pinned lockfile, always — loose `>=` versions make every build a gamble |
| JFrog remote slow/down | `retry: 2` on job; verify remote-repo caching enabled |
| Image bloat | Multi-stage Dockerfile, `.dockerignore` (don't ship `.git`), scratch-repo retention policy |
| Runner disk full | Cron `docker system prune -af --filter "until=168h"` + disk alerting |

### Scan (JFrog-enforced at promotion)
| Failure | Fix |
|---|---|
| New CVE blocks unrelated hotfix | Documented exception path: Xray ignore-rules with expiry + approver ("ship now, patch in 7 days"); never disable scanning |
| Base image constantly vulnerable | `python:3.11-slim`, weekly scheduled rebuilds so base patches flow in, pin base by digest |

### Publish/promote
| Failure | Fix |
|---|---|
| Tag already exists / overwrite | Immutable repos; idempotent promote (same digest → succeed, different digest → hard fail) |
| Race between pipelines | Promote by **digest**; `resource_group:` serializes per environment |
| JFrog token expired org-wide | Scoped tokens, rotation calendar, alert specifically on 401s |

### Deploy
| Failure | Fix |
|---|---|
| Vault sealed / token expired / path changed | Pre-check step: `vault kv get` every required key **before** touching the container; Vault Agent auto-renew removes most expiry issues |
| App crashes on boot | healthcheck + deploy.sh auto-rollback (previous image kept on the VM — instant, no registry pull) |
| Half-applied DB migration | Migrations as explicit pipeline step; **expand/contract** pattern (add column → deploy → remove old column next release); tested DB restore path |
| Shared-VM collisions | Per-app networks, fixed unique ports behind the proxy, resource limits, `resource_group` |
| Runner/SSH connectivity rot | Keys in Vault; nightly canary job that just connects and exits |

### E2E/smoke
| Failure | Fix |
|---|---|
| Flaky browser tests (LLM slow today) | Playwright auto-wait with generous timeouts on LLM steps; `retry: 1`; prod full-query non-blocking |
| Service account locked out | Exempt from expiry rotation (documented), IP-allowlist, alert auth failures distinctly from app failures |

### Cross-cutting / process
| Failure | Fix |
|---|---|
| Pipeline drift across projects | Shared CI template repo; projects include + override variables only |
| "Works because of the runner" | Explicit tool versions; runner stays vanilla; document every install |
| Failures nobody notices | Pipeline notifications to a team channel; red main = stop-the-line, fixing it outranks features |
| GitLab 14.x itself | EOL — flag the upgrade; `CI_JOB_JWT` and other workarounds disappear on 16/17 |

### The meta-fix

For every failure, ask three questions: **how fast do we detect it**
(alerting, fail-fast pre-checks), **how clearly does it explain itself**
(errors that name the problem, not a stack trace), **how fast can we recover**
(rollback, retry, exception process). A pipeline that fails loudly, clearly,
and reversibly beats one that rarely fails but strands you when it does.
