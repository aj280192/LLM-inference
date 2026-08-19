# 1. Architecture: JFrog, Environments, Secrets, VMs

## 1.1 JFrog repository layout

### Docker repositories

| Repo | Purpose | Who writes |
|---|---|---|
| `docker-scratch-local` | Every CI build lands here | CI pipeline |
| `docker-staging-local` | Promoted after scan passes + release tagged | Promotion job |
| `docker-stable-local` | Promoted after int e2e + manual approval | Promotion job |

### Python repositories

| Repo | Purpose |
|---|---|
| `pypi-remote` | Proxy/cache of public PyPI |
| `pypi-local` | Internal libraries your teams publish |
| `pypi-virtual` | Wraps both — the only URL pip ever uses |

### The golden rule: build once, promote by digest

The image is built **one time**. Promotion (`jf rt docker-promote` /
`jf rt build-promote`) moves the **exact same immutable digest** between repos.
Never rebuild per environment — a rebuild is an unscanned, untested new
artifact.

**Build-info** is published alongside every image
(`jf rt build-publish`): it links the image to its pip dependencies, git SHA,
CI job, and Xray scan results — full traceability from CVE to commit.

## 1.2 Environments

One VM per environment (dev / int / prod), each hosting multiple team apps
under Docker Compose.

### Environment parity — what must match

| Priority | Item | Rule |
|---|---|---|
| Must be identical | Docker image | Same digest, promoted not rebuilt |
| Must be identical | Compose file *structure* | Same services/networks/healthchecks; only values differ |
| Must be identical | OS / Docker version | Same base VM config on int and prod |
| Must be identical | Deploy mechanism | Same pipeline scripts, same secrets flow |
| Same kind, separate instance | Database | Same engine + major version; **never** point int at prod DB |
| Same kind, separate instance | Vault secrets | Same server OK; separate paths (`.../int` vs `.../prod`), separate credentials |
| Same kind, separate instance | LLM / external APIs | Same provider+model; separate API key/project per env |
| Shared but tagged | Splunk / MLflow | Same instance acceptable; tag data per env (`index=app_int`) |
| Allowed to differ | Scale | Int VM can be smaller — testing correctness, not load |
| Allowed to differ | Data volume | Representative test data; never raw prod data on lower envs |

> **Int has access to the same *kinds* of systems as prod, but never to prod's
> actual instances or credentials.** Parallel infrastructure, not shared.

### Preventing environment drift

- One `docker-compose.yml` template in a deploy-config repo; per-env only an
  `.env` (from Vault) + small override for resource limits.
- **No manual changes on any environment VM.** Break-glass prod fixes during
  incidents get backported to the repo the same day.

## 1.3 Secrets: Vault → containers

### Chosen approach: Vault Agent on each VM

Since the VMs have direct network access to Vault, run **Vault Agent** as a
systemd service on each VM:

1. Agent authenticates to Vault via AppRole
2. Renders secrets to `/opt/apps/<app>/.env` (mode `600`, deploy user only)
3. Auto-renews and re-renders on rotation — **CI never touches secrets for
   deployment at all**
4. Compose references it via `env_file: .env` (never inline `environment:`
   blocks that show in `docker inspect`)

### CI jobs that DO need secrets (e.g. LLM key for evaluation tests)

Use GitLab's JWT auth to Vault. On **GitLab 14.x** the modern `id_tokens:`
syntax does not exist — use the legacy `CI_JOB_JWT` variable:

```bash
export VAULT_TOKEN=$(vault write -field=token \
  auth/jwt/login role=reportapp-ci jwt=$CI_JOB_JWT)
export LLM_API_KEY=$(vault kv get -field=api_key secret/reportapp/ci-eval)
```

Each project gets a Vault role bound to its GitLab project ID and protected
refs, so no static Vault token ever lives in GitLab CI variables.

### Secret hygiene rules

- `.env` owned by deploy user, `chmod 600`, never baked into the image
- Separate secret paths and credentials per environment
- CI-eval LLM key is rate-limited/low-cost and separate from prod's key
- Evolution path: Vault Agent (now) → app fetches from Vault directly at
  startup via `hvac` with short-lived AppRole creds (later, enables dynamic DB
  credentials and per-app audit)

## 1.4 Shared VM layout

Multiple apps per VM require isolation:

```
/opt/apps/
  reportapp/
    docker-compose.yml
    .env                 <- rendered by Vault Agent
    CURRENT_VERSION      <- rollback bookkeeping (see doc 6)
    PREVIOUS_VERSION
  otherapp/
    ...
```

- **Reverse proxy** (Traefik or nginx) container routes by hostname/path
- **Per-app Docker networks** so containers can't reach each other's DBs
- **Resource limits** in compose (`mem_limit`, `cpus`) so one app can't
  starve the VM
- **One GitLab shell runner per VM**, tagged `dev` / `int` / `prod`; deploy
  jobs pin to the right tag and therefore run directly on the target machine
  (no SSH needed)
- `resource_group:` per environment in GitLab so deploys never interleave

## 1.5 GitLab project setup

- App repo: source + tests + `.gitlab-ci.yml` + `ci/` scripts
- Deploy-config repo (or folder): compose templates per environment
- Shared CI template repo: common pipeline included by all team projects
  (`include: project:` — supported in 14.x) so fixes propagate everywhere
- **Settings → Repository → Protected branches**: protect `main` and
  `release/*` — MR-only, no direct pushes
- **Protected tags**: pattern `v*`, maintainers only
- Note: GitLab 14.x is EOL — flag the upgrade path to the instance owner;
  several workarounds in these docs (e.g. `CI_JOB_JWT`) disappear on 16/17.
