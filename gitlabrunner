# Streamlit App — Complete GitLab CI/CD Setup Guide

**Context:** Self-managed GitLab, no runner set up yet, custom internal Docker/pip proxy,
a separate internal registry (Nexus/Artifactory/Harbor), stage + prod environments,
prod deployed to two legacy hosts behind an F5 load balancer, self-hosted Vault for
application secrets (accessed via the `vault` CLI, no CI-to-Vault authentication).

---

## Table of Contents
1. The big picture
2. Branching & environment model
3. GitLab Runner setup (full config)
4. Registry & pip proxy configuration
5. Dockerfile (multi-stage, production-grade)
6. How your code actually gets into the Docker image
7. Service account for host deployment (and matching UID)
8. Application secrets via Vault CLI (no CI-Vault auth)
9. Deploying to two hosts behind F5 — zero-downtime rolling deploy
10. Full `.gitlab-ci.yml`
11. Playwright E2E tests
12. Rollback
13. Reusing this pipeline across other projects (CI/CD Components)
14. Suggested rollout order

---

## 1. The big picture

```
feature/* branch ──MR──▶ main ──auto──▶ build+scan image ──auto──▶ deploy STAGE ──auto E2E──▶ manual gate ──▶ deploy PROD (host1 → host2)
      │                                                                                                              │
   MR pipeline:                                                                                                rollback job
   lint + unit tests                                                                                          (redeploy last-good tag)
   (no image push)
```

Key ideas baked into this design:
- **Trunk-based branching** (which you already use): short-lived `feature/*` branches merged into `main` via Merge Requests. `main` is always deployable.
- **One pipeline, environment-aware jobs.** GitLab's `environment:` keyword + `rules:` control what runs where — you don't need separate pipelines per environment.
- **Immutable images.** Build once, tag with the Git commit SHA, promote *the same image* from stage to prod. Never rebuild for prod.
- **Automated E2E gate, then a human gate.** Playwright runs automatically against stage; only if that passes does the manual "deploy to prod" button even become usable.
- **Secrets never touch GitLab.** Everything the app needs at runtime (Splunk, LLM, DB, LDAP, MLflow) is fetched from Vault directly on the host, via the `vault` CLI — the pipeline only ever holds build/deploy-mechanics credentials.

---

## 2. Branching & environment model (explained fully, since you're new to this)

| Git action | Pipeline behaviour |
|---|---|
| Push to `feature/xyz`, open MR | **MR pipeline**: lint, unit tests only. No build/push/deploy — this is your safety net before merge. |
| Merge to `main` | **Main pipeline**: build image → tag `sha-<short-sha>` → push to registry → security scan → **auto-deploy to stage** → **auto-run Playwright against stage** |
| Manual trigger (button click) on a green `main` pipeline | **Deploy to prod**: deploys the *same* image to host1 → health check → host2 → health check |
| Need to undo prod | **Manual rollback job**: re-deploys the previous known-good tag, no rebuild |

GitLab concepts you'll use:
- **`.gitlab-ci.yml`** — the pipeline definition, lives in your repo root.
- **Stages** — ordered phases (`test`, `build`, `scan`, `deploy-stage`, `e2e-stage`, `deploy-prod`). Jobs in the same stage run in parallel; stages run sequentially.
- **`rules:`** — conditions for when a job runs (e.g. only on `main`).
- **`environment:`** — tells GitLab "this job deploys to X"; gives you a deployment history dashboard and lets you protect it.
- **Protected environments** — restrict *who* can trigger deploys to `production` (Settings → CI/CD → Protected environments). Works on Free/Core tier with `when: manual` + role-restricted protection — enough for a 2-host setup.
- **CI/CD variables** — encrypted config stored in GitLab (Settings → CI/CD → Variables), injected as env vars into jobs. Mark them **Protected** and **Masked**.

---

## 3. GitLab Runner setup (complete config)

**Register the runner** (GitLab UI → project or group → Settings → CI/CD → Runners → New project/group runner → copy the `glrt-...` token):
```bash
sudo gitlab-runner register \
  --url https://gitlab.yourcompany.internal \
  --token glrt-xxxxxxxxxxxxxxxxxxxxxxxx \
  --executor docker \
  --docker-image docker:24-cli
```

**Proxy config for the runner service itself** (separate from what job containers see):
```bash
sudo mkdir -p /etc/systemd/system/gitlab-runner.service.d
cat <<EOF | sudo tee /etc/systemd/system/gitlab-runner.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://proxy.yourcompany.internal:3128"
Environment="HTTPS_PROXY=http://proxy.yourcompany.internal:3128"
Environment="NO_PROXY=gitlab.yourcompany.internal,registry.yourcompany.internal,localhost,127.0.0.1"
EOF
sudo systemctl daemon-reload && sudo systemctl restart gitlab-runner
```

**Complete `/etc/gitlab-runner/config.toml`:**
```toml
concurrent = 2
check_interval = 3
shutdown_timeout = 30

[session_server]
  session_timeout = 1800

[[runners]]
  name = "build-host-docker-runner"
  url = "https://gitlab.yourcompany.internal"
  id = 1
  token = "glrt-xxxxxxxxxxxxxxxxxxxxxxxx"
  token_obtained_at = 2026-07-23T00:00:00Z
  token_expires_at = 0001-01-01T00:00:00Z
  executor = "docker"
  tags = ["docker", "deploy"]
  run_untagged = false
  environment = [
    "HTTP_PROXY=http://proxy.yourcompany.internal:3128",
    "HTTPS_PROXY=http://proxy.yourcompany.internal:3128",
    "NO_PROXY=gitlab.yourcompany.internal,registry.yourcompany.internal,localhost,127.0.0.1"
  ]

  [runners.custom_build_dir]

  [runners.cache]
    [runners.cache.s3]
    [runners.cache.gcs]
    [runners.cache.azure]

  [runners.docker]
    image = "docker:24-cli"
    privileged = true
    tls_verify = false
    disable_entrypoint_overwrite = false
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/cache", "/certs/client"]
    shm_size = 0
    pull_policy = ["if-not-present"]
    network_mtu = 0
```

Notes:
- `concurrent = 2` caps parallel jobs across all projects using this runner — raise only after confirming the build host handles simultaneous Docker builds comfortably.
- `tags = ["docker", "deploy"]` + `run_untagged = false` means a job only lands here if its `.gitlab-ci.yml` explicitly requests `tags: [docker]` — this is how you control which projects use this runner if you extend it later (see §13).
- `privileged = true` is required for Docker-in-Docker builds. If your security team objects, the alternative is **kaniko**, which builds images without a privileged Docker daemon.
- `pull_policy = ["if-not-present"]` avoids re-pulling the dind service image on every job.

You only need **one runner**. Deploying to host2 happens via SSH *from within a job on this same runner* — no second runner needed.

---

## 4. Registry & pip proxy configuration

**CI/CD Variables to create** (Settings → CI/CD → Variables — this is now the *complete* list, since app secrets live in Vault, not here):

| Variable | Protected | Masked | Notes |
|---|---|---|---|
| `REGISTRY_HOST` | ✔ | | e.g. `registry.yourcompany.internal` |
| `REGISTRY_USER` / `REGISTRY_PASSWORD` | ✔ | ✔ | service account, not personal |
| `PIP_INDEX_URL` | ✔ | | your internal PyPI proxy |
| `SSH_PRIVATE_KEY` | ✔ | ✔ | type = **File**, for `svc-streamlit-deploy` |
| `DEPLOY_HOST1` / `DEPLOY_HOST2` | ✔ | | hostnames/IPs |
| `F5_API_USER` / `F5_API_PASSWORD` | ✔ | ✔ | only if using the iControl REST route (§9) |

Registry login in a job:
```yaml
before_script:
  - echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin
```

Pip, pointed at your internal index at build time:
```dockerfile
ARG PIP_INDEX_URL
RUN pip config set global.index-url ${PIP_INDEX_URL}
```

---

## 5. Dockerfile (multi-stage, production-grade)

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=python:3.12-slim
FROM ${BASE_IMAGE} AS builder

ARG PIP_INDEX_URL
ENV PIP_INDEX_URL=${PIP_INDEX_URL} \
    PIP_NO_CACHE_DIR=1

WORKDIR /app
COPY requirements.txt .
RUN pip install --user -r requirements.txt

FROM ${BASE_IMAGE}
RUN useradd --uid 5000 --create-home --shell /bin/bash appuser
WORKDIR /app

COPY --from=builder /root/.local /home/appuser/.local
COPY . .
RUN chown -R appuser:appuser /app

USER appuser
ENV PATH=/home/appuser/.local/bin:$PATH \
    PYTHONUNBUFFERED=1

EXPOSE 8501
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl --fail http://localhost:8501/_stcore/health || exit 1

ENTRYPOINT ["streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0"]
```

Why each piece matters:
- **Multi-stage build**: keeps `pip`/build tooling out of the final image — smaller, fewer CVEs.
- **`ARG BASE_IMAGE`**: lets you swap the base image per project/build without editing the Dockerfile (see §13 for making this dynamic via CI/CD component inputs).
- **Non-root `appuser`, fixed `--uid 5000`**: don't run as root; the fixed UID matches the host's `svc-streamlit-deploy` account (§7), so file ownership lines up across the host/container boundary.
- **`HEALTHCHECK`**: Streamlit exposes `/_stcore/health` — lets Docker and your deploy script know the app is actually ready, not just that the process started.
- **Pinned base image tag**: reproducible builds. Even better in prod: pin the digest (`python:3.12-slim@sha256:...`).

`.dockerignore`:
```
.git
__pycache__
*.pyc
.venv
tests/
```

---

## 6. How your code actually gets into the Docker image

Worth understanding end-to-end, since it explains why the pipeline is shaped the way it is:

1. **Before any job script runs, GitLab Runner automatically checks out your repository** into the job's working directory — this is built-in behaviour (`GIT_STRATEGY`), not something you write. By the time `build_image`'s `script:` executes, the current directory already holds your repo at the exact commit that triggered the pipeline.
2. **`docker build .` sends that directory (the "build context") to the Docker daemon.** The `.` tells Docker "package up everything in the current directory and hand it to the build." Your `.dockerignore` trims what's actually sent.
3. **Inside the Dockerfile, `COPY . .` is the moment your source code becomes part of the image** — copied from the build context into the image's filesystem layer. Once built, the code is frozen in that image forever, which is exactly why immutable, SHA-tagged images work as a promotion strategy: `streamlit-app:sha-a1b2c3d` is a permanent, unchangeable snapshot of your code at that commit. Promoting it to prod doesn't rebuild or re-copy anything.
4. Note there are **two different `COPY` operations** in the multi-stage Dockerfile above, for different reasons: `COPY --from=builder /root/.local ...` copies **installed pip packages** from the builder stage; `COPY . .` in the final stage copies **your actual source code** — that's the one that answers this question directly.

---

## 7. Service account for host deployment (and matching UID)

Two different "users" are in play — don't conflate them, but do align their UIDs:

- **`appuser` inside the container** — stays as-is; not running the app as root inside the container.
- **The SSH/deploy account on the host** — a dedicated service account, `svc-streamlit-deploy`, instead of a personal or generic login:
  - Password login disabled; only the CI's public key in `authorized_keys`
  - Member of the `docker` group (or sudo scoped narrowly to docker commands) — no broader access
  - Owns `/opt/streamlit-app/` and the Vault-fetched secrets directory

```bash
# on host1 / host2
sudo useradd --system --uid 5000 --create-home --shell /usr/sbin/nologin svc-streamlit-deploy
```
Matches the Dockerfile's `--uid 5000` for `appuser`, so any mounted volume (secrets, logs) has consistent ownership across the host/container boundary.

Deploy script's SSH target:
```bash
ssh -o StrictHostKeyChecking=accept-new svc-streamlit-deploy@"$HOST" bash -s <<'EOF'
  ...
EOF
```
`SSH_PRIVATE_KEY` in GitLab holds the key for this service account only.

---

## 8. Application secrets via Vault CLI (no CI-Vault authentication)

**Decision:** GitLab CI/CD variables hold only build/deploy-mechanics credentials (§4 table). Everything the *application* needs at runtime — Splunk, LLM, DB, LDAP, MLflow — comes from Vault, fetched directly on host1/host2 using the `vault` CLI. The pipeline never authenticates to Vault or sees these values.

**One-time setup per host** (provisioned manually or via config management — never through GitLab):
```bash
sudo mkdir -p /etc/vault-cli
echo "<role-id>"   | sudo tee /etc/vault-cli/role-id   > /dev/null
echo "<secret-id>" | sudo tee /etc/vault-cli/secret-id > /dev/null
sudo chmod 600 /etc/vault-cli/role-id /etc/vault-cli/secret-id
sudo chown svc-streamlit-deploy:svc-streamlit-deploy /etc/vault-cli/*
```

**`/opt/streamlit-app/fetch-secrets.sh`** (run as `svc-streamlit-deploy`):
```bash
#!/usr/bin/env bash
set -euo pipefail

export VAULT_ADDR="https://vault.yourcompany.internal:8200"
SECRET_PATH="secret/streamlit"
OUT_DIR="/opt/streamlit-app/secrets"

ROLE_ID=$(cat /etc/vault-cli/role-id)
SECRET_ID=$(cat /etc/vault-cli/secret-id)

VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$ROLE_ID" secret_id="$SECRET_ID")
export VAULT_TOKEN

mkdir -p "$OUT_DIR"
for key in splunk_api_key llm_api_key database_url db_user db_password \
           ldap_url ldap_bind_dn ldap_bind_password ldap_base_dn \
           mlflow_endpoint_url mlflow_user mlflow_password; do
  vault kv get -field="$key" "$SECRET_PATH" > "$OUT_DIR/$key"
  chmod 600 "$OUT_DIR/$key"
done

vault token revoke -self   # least privilege — don't leave a live token lying around
```

**Two hooks for this script:**
1. **Called from `deploy.sh`, right before `docker run`** — guarantees every deploy uses the latest secret values.
2. **Run on a `systemd` timer independent of deploys** — gives you rotation without needing a redeploy:
```ini
# /etc/systemd/system/vault-secret-refresh.timer
[Timer]
OnBootSec=5min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
```
```ini
# /etc/systemd/system/vault-secret-refresh.service
[Service]
Type=oneshot
User=svc-streamlit-deploy
ExecStart=/opt/streamlit-app/fetch-secrets.sh
```

**Container mount and app code:**
```bash
docker run -d --name streamlit-app --restart unless-stopped \
  -p 8501:8501 \
  -v /opt/streamlit-app/secrets:/run/secrets:ro \
  "$IMAGE"
```
```python
def read_secret(name):
    with open(f"/run/secrets/{name}") as f:
        return f.read().strip()

db_password = read_secret("db_password")
ldap_bind_password = read_secret("ldap_bind_password")
```

**Why this beats plain env vars:** `docker inspect` only shows the mount path, not secret contents — reading a value requires filesystem access to `/opt/streamlit-app/secrets/*`, lockable to `600` owned by UID 5000 only. It doesn't protect against someone with root on the host (nothing but a full secrets manager with runtime injection fully solves that) — but it's the right level of rigor for a two-host setup.

**Why Vault over plain GitLab variables at all:** GitLab CI/CD variables have **no version history** — editing one silently discards the old value, no diff, no rollback. Vault's KV v2 engine versions every write natively (`vault kv get -version=3 ...`, `vault kv rollback ...`).

**Vault outage behaviour:** already-fetched files on disk are untouched — a Vault outage blocks *new* fetches (so a stale secret keeps being used until Vault is reachable again), not your already-running app. If a crash restarts the container, Docker brings back the same container with the same mount reading the same on-disk files — no Vault call needed at restart. Run Vault itself in **HA mode** (3+ Raft nodes, auto-unseal) so a single node outage doesn't block your refresh timer or deploys.

---

## 9. Deploying to two hosts behind F5 — zero-downtime rolling deploy

Two options, ranked:

**Option A — health-check-driven (simplest, no F5 API access needed).**
If your F5 pool monitor already checks something like `GET /_stcore/health` on each member, a naive rolling restart works: F5's monitor pulls a restarting host out of rotation automatically once its container goes down, and adds it back once the new one passes health checks. Downside: a small window (monitor interval + failed-check threshold) where F5 might still route to a restarting host.

**Option B — explicitly disable the pool member first (recommended for production).**
Use F5's iControl REST API to disable the pool member *before* touching that host, redeploy, health-check locally, then re-enable:
```bash
curl -sk -u "$F5_API_USER:$F5_API_PASSWORD" -X PATCH \
  "https://f5.yourcompany.internal/mgmt/tm/ltm/pool/~Common~streamlit_pool/members/~Common~${DEPLOY_HOST1}:8501" \
  -H "Content-Type: application/json" -d '{"session":"user-disabled"}'
# ...deploy, health-check...
curl -sk -u "$F5_API_USER:$F5_API_PASSWORD" -X PATCH \
  "https://f5.yourcompany.internal/mgmt/tm/ltm/pool/~Common~streamlit_pool/members/~Common~${DEPLOY_HOST1}:8501" \
  -H "Content-Type: application/json" -d '{"session":"user-enabled"}'
```
Start with Option A, layer in Option B once stable — it's a deploy-script change, not a pipeline redesign.

**`deploy.sh`:**
```bash
#!/usr/bin/env bash
set -euo pipefail
HOST=$1
IMAGE=$2

ssh -o StrictHostKeyChecking=accept-new svc-streamlit-deploy@"$HOST" bash -s <<EOF
  set -e
  echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin
  /opt/streamlit-app/fetch-secrets.sh
  docker pull "$IMAGE"
  docker stop streamlit-app || true
  docker rm streamlit-app || true
  docker run -d --name streamlit-app --restart unless-stopped \
    -p 8501:8501 \
    -v /opt/streamlit-app/secrets:/run/secrets:ro \
    "$IMAGE"
  for i in {1..10}; do
    STATUS=\$(docker inspect --format='{{.State.Health.Status}}' streamlit-app)
    [ "\$STATUS" = "healthy" ] && exit 0
    sleep 3
  done
  echo "Container failed health check" && exit 1
EOF
```

---

## 10. Full `.gitlab-ci.yml`

```yaml
stages:
  - test
  - build
  - scan
  - deploy-stage
  - e2e-stage
  - deploy-prod

variables:
  IMAGE_BASE: "$REGISTRY_HOST/streamlit-app"
  SHA_TAG: "sha-$CI_COMMIT_SHORT_SHA"

# ---------- MR pipeline: lint + unit tests, every feature branch ----------
lint_test:
  stage: test
  image: python:3.12-slim
  tags: [docker]
  before_script:
    - pip config set global.index-url "$PIP_INDEX_URL"
    - pip install -r requirements.txt -r requirements-dev.txt
  script:
    - flake8 .
    - pytest --maxfail=1 --disable-warnings

# ---------- Build & push, only on main ----------
build_image:
  stage: build
  image: docker:24-cli
  services: [docker:24-dind]
  tags: [docker]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  before_script:
    - echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin
  script:
    - docker build --build-arg PIP_INDEX_URL="$PIP_INDEX_URL" -t "$IMAGE_BASE:$SHA_TAG" .
    - docker push "$IMAGE_BASE:$SHA_TAG"

# ---------- Container scan (Trivy) ----------
scan_image:
  stage: scan
  image: aquasec/trivy:latest
  tags: [docker]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  script:
    - trivy image --exit-code 1 --severity CRITICAL,HIGH "$IMAGE_BASE:$SHA_TAG"

# ---------- Auto-deploy to stage ----------
deploy_stage:
  stage: deploy-stage
  image: alpine:3.20
  tags: [docker, deploy]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  environment:
    name: stage
    url: https://stage-streamlit.yourcompany.internal
  before_script:
    - apk add --no-cache openssh-client
    - eval "$(ssh-agent -s)"
    - echo "$SSH_PRIVATE_KEY" | ssh-add -
  script:
    - ./deploy.sh "$DEPLOY_HOST1_STAGE" "$IMAGE_BASE:$SHA_TAG"

# ---------- Playwright against the real stage deployment ----------
e2e_stage:
  stage: e2e-stage
  image: mcr.microsoft.com/playwright:v1.47.0-jammy
  tags: [docker]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  needs: ["deploy_stage"]
  variables:
    BASE_URL: "https://stage-streamlit.yourcompany.internal"
    npm_config_registry: "$NPM_REGISTRY_URL"
  before_script:
    - npm ci
  script:
    - npx playwright test --reporter=line
  artifacts:
    when: always
    paths:
      - playwright-report/
    expire_in: 7 days

# ---------- Manual, gated deploy to prod: host1 then host2 ----------
deploy_prod_host1:
  stage: deploy-prod
  image: alpine:3.20
  tags: [docker, deploy]
  needs: ["e2e_stage"]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: manual
  environment:
    name: production
    url: https://streamlit.yourcompany.internal
  before_script:
    - apk add --no-cache openssh-client
    - eval "$(ssh-agent -s)"
    - echo "$SSH_PRIVATE_KEY" | ssh-add -
  script:
    - ./deploy.sh "$DEPLOY_HOST1" "$IMAGE_BASE:$SHA_TAG"

deploy_prod_host2:
  stage: deploy-prod
  image: alpine:3.20
  tags: [docker, deploy]
  needs: ["deploy_prod_host1"]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: manual
  environment:
    name: production
  before_script:
    - apk add --no-cache openssh-client
    - eval "$(ssh-agent -s)"
    - echo "$SSH_PRIVATE_KEY" | ssh-add -
  script:
    - ./deploy.sh "$DEPLOY_HOST2" "$IMAGE_BASE:$SHA_TAG"

# ---------- Rollback ----------
rollback_prod:
  stage: deploy-prod
  image: alpine:3.20
  tags: [docker, deploy]
  when: manual
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  environment:
    name: production
  before_script:
    - apk add --no-cache openssh-client
    - eval "$(ssh-agent -s)"
    - echo "$SSH_PRIVATE_KEY" | ssh-add -
  script:
    - ./deploy.sh "$DEPLOY_HOST1" "$IMAGE_BASE:$ROLLBACK_TAG"
    - ./deploy.sh "$DEPLOY_HOST2" "$IMAGE_BASE:$ROLLBACK_TAG"
```

Notes:
- `deploy_prod_host2` needs `deploy_prod_host1` to succeed first — you never redeploy both hosts simultaneously, so the LB always has a healthy backend.
- Both prod jobs are `when: manual` and require `e2e_stage` to have passed (`needs:`) — so even a human clicking the button can't bypass the automated Playwright gate.
- Set `ROLLBACK_TAG` as a manual pipeline variable (Run pipeline → variables) when triggering `rollback_prod`, using the last known-good `sha-xxxxxxx` from the registry or Environments deployment history.
- `environment:` blocks give you a full deploy history dashboard under **Operate → Environments** for free.

---

## 11. Playwright E2E tests

Placement: **after** `deploy_stage`, running against the real stage URL — not an ephemeral pre-deploy container. Playwright drives a real browser against a real app, and your app depends on DB, MLflow, Splunk, LDAP, and an LLM endpoint; replicating all of that in a throwaway CI container for little benefit isn't worth it. Cheap feedback (lint, unit tests) already happens earlier on every MR — Playwright is the heavier, later gate specifically because it needs a real, fully-wired environment.

`e2e_stage` runs the full suite against stage; `deploy_prod_host1` has `needs: ["e2e_stage"]` — GitLab won't allow the manual prod job to run unless `e2e_stage` passed. That's your automated quality gate sitting in front of the human approval gate.

If your Playwright config needs the internal npm proxy, set `npm_config_registry` (or commit a project `.npmrc`) the same way `PIP_INDEX_URL` is used for pip.

---

## 12. Rollback

Already included in §10 as `rollback_prod` — it re-runs `deploy.sh` with a previous tag instead of rebuilding. Because images are immutable and SHA-tagged, rollback is just "run the old image again," never a rebuild.

---

## 13. Reusing this pipeline across other projects (CI/CD Components)

Once you have a second project that needs the same build/scan/deploy shape, don't copy-paste `.gitlab-ci.yml`. Use GitLab **CI/CD Components** — versioned, parameterized, reusable pipeline units (Free tier, self-managed supported).

**1. Create a components project**, e.g. `platform/ci-components`:
```
platform/ci-components/
├── templates/
│   └── build-deploy.yml
└── .gitlab-ci.yml   # only used to test the component itself
```

```yaml
# templates/build-deploy.yml
spec:
  inputs:
    image_name:
      type: string
    base_image:
      type: string
      default: "python:3.12-slim"
    dockerfile_path:
      type: string
      default: "Dockerfile"
    vault_secret_path:
      type: string
    deploy_host1:
      type: string
    deploy_host2:
      type: string
---
build_image:
  stage: build
  image: docker:24-cli
  services: [docker:24-dind]
  tags: [docker]
  script:
    - docker build
        --build-arg BASE_IMAGE="$[[ inputs.base_image ]]"
        --build-arg PIP_INDEX_URL="$PIP_INDEX_URL"
        -f "$[[ inputs.dockerfile_path ]]"
        -t "$REGISTRY_HOST/$[[ inputs.image_name ]]:$CI_COMMIT_SHORT_SHA" .
    - docker push "$REGISTRY_HOST/$[[ inputs.image_name ]]:$CI_COMMIT_SHORT_SHA"
# ...scan_image, deploy_stage, e2e_stage, deploy_prod_host1/2, rollback_prod jobs
# go here too, copied from §10, parameterized with inputs where needed
```

Tag/release it (`v1.0.0`) so it's versioned — a fix to the shared deploy logic later means bumping the version, not re-pasting YAML everywhere.

**2. A project consumes it:**
```yaml
include:
  - component: gitlab.yourcompany.internal/platform/ci-components/build-deploy@v1.0.0
    inputs:
      image_name: streamlit-app
      base_image: "python:3.12-slim"
      vault_secret_path: "secret/streamlit"
      deploy_host1: "$DEPLOY_HOST1"
      deploy_host2: "$DEPLOY_HOST2"

# only this part differs per project
lint_test:
  stage: test
  image: python:3.12-slim
  tags: [docker]
  script:
    - flake8 .
    - pytest --maxfail=1 --disable-warnings
```

**Rules for what goes where:**
- **Structural/non-secret values** (base image, Dockerfile path, Vault secret path string) → pass as component `inputs` — safe, since inputs appear in GitLab's expanded pipeline view.
- **Actual secrets** (`REGISTRY_PASSWORD`, `SSH_PRIVATE_KEY`, `F5_API_PASSWORD`) → stay as each project's own masked/protected CI/CD variables, referenced by name inside the component's script — never pass a secret as an input.

**Sharing the runner itself across projects:** a runner isn't tied to one project. Assign it as a **project runner to multiple projects**, or register it as a **group runner** (available to every project in the group automatically), or an **instance runner** (available instance-wide — only if you trust every project on it). Caution: this runner's host holds the SSH key to your deploy hosts and runs `privileged: true` Docker builds — keep it scoped to project/group runner, not instance-wide, and only extend it to projects you'd trust with that access. Raise `concurrent` in `config.toml` only after confirming the host handles parallel builds.

---

## 14. Suggested rollout order

1. Install & register the runner on the build host (§3); confirm it picks up a trivial `echo hello` job.
2. Add `lint_test` only — get MR pipelines green.
3. Add `build_image` + registry push; confirm images land in Nexus/Artifactory/Harbor.
4. Add `scan_image` (Trivy) — non-blocking at first (remove `--exit-code 1`) until existing CVEs are triaged.
5. Add `deploy_stage`; wire up SSH keys; test end-to-end against stage.
6. Set up `svc-streamlit-deploy` on both hosts with matching UID; switch the deploy SSH user to it.
7. Provision Vault AppRole credentials per host, write `fetch-secrets.sh`, wire the systemd timer, confirm secrets render correctly before pointing the app at them.
8. Add `e2e_stage` (Playwright against stage); confirm it passes before wiring the `needs:` gate.
9. Add the two prod jobs as `when: manual` with `needs: ["e2e_stage"]`; protect the `production` environment.
10. Add the F5 API disable/enable step (§9 Option B) for true zero-downtime, once stable on the simpler health-check-driven approach.
11. Add `rollback_prod`.
12. Once a second project needs the same shape, extract §10 into a CI/CD Component (§13) rather than copy-pasting.
