# ChatApp CI/CD — Full Architecture & Runbook

```
                         ┌──────────────────────────────────────────────┐
                         │                 GITLAB                       │
                         │  app repo ──────────────┐                    │
                         │  releases repo (manifest)│  CI variables     │
                         └──────────┬───────────────┴────────┬──────────┘
                                    │ pipeline                │ AppRole creds
                                    ▼                         ▼
   ┌─────────────────────────  BUILD HOST  ─────────────────────────────┐
   │  gitlab-runner + docker + vault CLI + ssh                          │
   │  1. lint/test/eval        4. record release row -> releases repo   │
   │  2. docker build :SHA     5. ssh deploy@host deploy_local.sh       │
   │  3. push -> Artifactory        (passes image ref + vault version)  │
   └───────────────┬───────────────────────────────┬────────────────────┘
                   │ push :SHA                     │ ssh
                   ▼                               ▼
        ┌──────────────────┐          ┌────────  DEPLOY HOSTS  ────────┐
        │   ARTIFACTORY    │  pull    │ vault-agent (auto-auth token)  │
        │  chatapp:a3f9c2e │ ───────► │ deploy_local.sh:               │
        │  chatapp:b7d1e90 │          │  - read PINNED secret version  │
        │  (immutable tags)│          │  - render env on tmpfs (/run)  │
        └──────────────────┘          │  - blue/green swap via nginx   │
                   ▲                  │  - local state + history files │
                   │                  └──────────────┬─────────────────┘
        ┌──────────┴────────┐                        │ versioned reads
        │      VAULT        │ ◄──────────────────────┘
        │ secret/chatapp/*  │   KV v2, max-versions=30, 3 AppRoles
        └───────────────────┘
```

## Repository layout

```
.gitlab-ci.yml                  pipeline definition
Dockerfile                      pinned base, non-root, healthcheck
ci/
  deploy_from_buildhost.sh      orchestrates: vault-pin -> ssh -> manifest
  rollback_from_buildhost.sh    paired rollback (secret first, image second)
deploy/                          installed at /opt/chatapp/ on each deploy host
  deploy_local.sh               blue-green deploy, version-pinned env render
  nginx-upstream.conf.tpl       upstream swap template
vault/
  vault_setup.sh                policies + AppRoles (run once by admin)
  vault-agent.hcl               agent config for deploy hosts (token sink only)
scripts/
  rotate_secret.sh              the ONLY way to change secrets
  validate_prompts.py           prompt template CI check
eval/
  run_eval.py                   golden-set eval gate (local or live-target)
  golden_set.jsonl              fast MR subset (+ regressions appended)
```

## The tracking model (the part that makes rollback trivial)

**One append-only manifest per environment, stored in a git repo** —
`chatapp-releases/prod/manifest.csv`:

```
timestamp,image_tag,vault_version,git_sha,pipeline_url,deployer
2026-07-15T09:00:00Z,a3f9c2e,3,<sha>,<url>,alice
2026-07-20T14:30:00Z,a3f9c2e,4,SECRET-ROTATION,manual,bob      <- rotation = release event
2026-07-28T09:15:00Z,b7d1e90,5,<sha>,<url>,alice
2026-07-28T09:40:00Z,a3f9c2e,6,ROLLBACK,<url>,alice            <- rollback is also recorded
```

Rules that make this work:
1. **Every state change appends a row** — deploys, secret rotations, rollbacks.
   No exceptions. Rotation outside `rotate_secret.sh` is how you get the
   "image2 was recorded with v3 but actually ran with v4" trap.
2. **Rows are never edited or deleted.** Rollback appends a new row; it doesn't
   rewrite history. The git history of the manifest gives you a second audit
   layer for free (who, when, from which pipeline).
3. **The pair (image_tag, vault_version) is the unit of deployment.** Rollback
   restores both, secret first, image second.
4. Each deploy host also keeps local state (`/var/lib/chatapp/`): current
   image, current vault version, live slot, and its own deploy history — so
   even if GitLab/the manifest repo is down, you can inspect and manually
   redeploy from the host itself.

Vault versions are never destroyed (`max-versions=30`, no `kv destroy`), and
Artifactory keeps every `:SHA` image (set a retention policy of, say, last 30
images / 90 days — never auto-delete anything referenced in the manifest).

## Standard flows

### Deploy
1. Merge to `main` → pipeline: lint → unit tests → prompt validation → eval gate.
2. `build-and-push` builds `chatapp:<short-sha>` on the build host, pushes to
   Artifactory with OCI labels (commit, pipeline URL, timestamp baked in).
3. `deploy-staging` runs automatically; `staging-smoke-eval` hits the live
   staging URL with the smoke eval set.
4. `deploy-prod` is a **manual button** in the pipeline. It:
   - pins the current Vault secret version,
   - rolling-deploys host by host (blue-green on each host, so zero downtime),
   - commits a manifest row to the releases repo.

### Rollback (one click / one command)
- GitLab UI: play the `rollback-prod` job (optionally set `ROLLBACK_TO=<sha>`).
- Or from the build host: `bash ci/rollback_from_buildhost.sh prod [tag]`
- What it does: find target row → `vault kv rollback` to the paired secret
  version → force re-render on each host → redeploy the old image via the
  exact same `deploy_local.sh` → append a ROLLBACK row.

### Secret rotation
```
VAULT_ADMIN_ROLE_ID=... VAULT_ADMIN_SECRET_ID=... \
  bash scripts/rotate_secret.sh prod OPENAI_API_KEY=sk-new... 
```
Merges the new key into the existing secret (partial update safe), writes a
new Vault version, records a manifest row pairing it with the currently
deployed image, and redeploys that same image so the app picks it up.

## Vault design decisions (and why)

| Decision | Why |
|---|---|
| KV v2, `max-versions=30` | version history is what makes secret rollback possible |
| Agent used ONLY as a token sink (`/run/vault/token`) | agent templates always render "latest"; deploy needs a **pinned** version, so the deploy script reads `-version=N` itself |
| env file rendered to `/run` (tmpfs), mode 400 | secrets never touch persistent disk |
| 3 AppRoles: deploy-host (read), ci (read+rollback-write), secret-admin (write) | least privilege; a compromised deploy host cannot alter secrets; humans have no direct prod write path |
| CI token TTL 15m, revoked on job exit (`trap`) | leaked CI token is useless within minutes |
| No human `vault kv put` on prod paths | untracked writes are what break manifest/reality alignment |

## Things people usually miss (added or flagged here)

1. **The failed-mid-rollout state.** With multiple deploy hosts, a failure on
   host 2 of 3 leaves the fleet split. The deploy script aborts immediately;
   the fix is always "run rollback to converge" — never continue forward
   manually on remaining hosts.
2. **Health checks must be real.** `/health` should verify the app can reach
   its LLM provider and vector DB (a shallow "200 OK" lets a broken build pass
   the blue-green gate). Add a `/health/deep` used only during deploy swaps if
   provider checks are too expensive for the LB's frequent polling.
3. **Image provenance labels.** Every image carries `org.opencontainers.image.revision`
   and the pipeline URL. `docker inspect` on any running container tells you
   exactly which commit and pipeline produced it — no guessing during incidents.
4. **SBOM + vulnerability scanning** (trivy step in the build job). Currently
   non-blocking (`|| true`); make it blocking once you've triaged the baseline.
5. **Retention alignment.** Rollback only works if the target still exists.
   Align: Artifactory image retention ≥ Vault `max-versions` window ≥ how far
   back you'd realistically roll back (weeks, not days).
6. **DB / vector-store migrations.** Blue-green breaks if v(N+1) migrates the
   schema in a way v(N) can't read. Rule: migrations must be backwards-
   compatible one version back ("expand-migrate-contract" pattern), or
   rollback becomes impossible without a data restore.
7. **Streaming-aware nginx config.** `proxy_buffering off` + long read timeout
   or SSE token streaming breaks on deploys. Also drain connections: nginx
   reload is graceful, but give in-flight LLM generations time before killing
   the old container (add a `sleep 30` before `docker rm` if responses are long).
8. **Concurrency guard.** Add `resource_group: prod-deploy` to the deploy-prod
   and rollback jobs in `.gitlab-ci.yml` so two people can't deploy at once.
9. **Observability hooks.** Log a structured line on app startup with
   image tag + vault version (read them from the container labels/env); your
   log aggregator then shows exactly when each version served which requests.
10. **Prod continuous eval.** Schedule the smoke eval against *prod* nightly
    too — model providers change models under you; retrieval data drifts. A
    quality drop with no deploy is a real and common failure mode.
11. **Break-glass runbook.** If GitLab is down: ssh to a deploy host,
    `cat /var/lib/chatapp/host_deploy_history.csv`, pick the last good pair,
    and run `deploy_local.sh <image> <vault_version> prod` by hand. Everything
    needed for recovery deliberately exists on the host itself.
12. **When you outgrow this.** This whole design is a faithful manual
    implementation of what ArgoCD + External Secrets Operator give you on
    Kubernetes: desired (image, secret-version) declared in git, continuously
    reconciled, rolled back with `git revert`. When host count or team size
    grows, migrate the *model* (it maps 1:1), not just the scripts.

## First-time setup checklist

- [ ] Run `vault/vault_setup.sh` as Vault admin; distribute role_id/secret_id:
      deploy-host creds → `/etc/vault/agent/` on each host;
      ci + secret-admin creds → GitLab CI variables (masked, protected)
- [ ] Install on each deploy host: `deploy/deploy_local.sh` →
      `/opt/chatapp/deploy_local.sh` (root:root, 750) + sudoers line;
      `deploy/nginx-upstream.conf.tpl` → `/opt/chatapp/`;
      vault-agent systemd service with `vault/vault-agent.hcl`
- [ ] Create the `chatapp-releases` repo; give the CI ssh key push access
- [ ] Register a runner on the build host with tag `build-host`
- [ ] Set CI variables: ARTIFACTORY_*, VAULT_*, DEPLOY_HOSTS, STAGING_HOSTS,
      DEPLOY_SSH_KEY (type File)
- [ ] Artifactory: retention policy keeping ≥30 tagged images
- [ ] GitLab: pipeline schedule for nightly-full-eval; protect `main`;
      make `production` environment protected (approvers)

---

# ADDENDUM: Single POC-server setup (proxy + internal Artifactory + service account)

## Branch strategy: trunk-based

```
main (protected, MR-only, pipeline must pass)
  └── feature/* (short-lived; deleted on merge; squash-merge for linear history)
```

## Who runs where

| Pipeline trigger | What runs | Credentials available |
|---|---|---|
| Feature branch MR | lint, tests, eval gate, image build, **manual** deploy-poc button | UNPROTECTED vars only: POC-scoped Vault AppRole, limited Artifactory account |
| Merge to main | everything above + deploy main to POC + live smoke eval + rollback button | PROTECTED vars: full service-account creds, deploy SSH key |
| Nightly schedule | full eval set | protected vars |

Protected variables are the security boundary: a feature branch (which anyone
can push) physically cannot read the deploy SSH key or the main Vault creds,
because GitLab only injects protected variables on protected branches.

## Proxy rules — the three places it must be configured

1. **Job environment** (`variables:` in .gitlab-ci.yml) — pip, curl, git in jobs
2. **Docker daemon** on BOTH hosts (`/etc/systemd/system/docker.service.d/http-proxy.conf`)
   — docker pull/push. **Artifactory must be in NO_PROXY** so registry traffic
   goes direct; sending internal-registry traffic through the proxy is the #1
   corp misconfiguration (slow at best, auth-broken at worst).
3. **Docker build args** — so `pip install` INSIDE the build reaches the mirror.
   Proxy vars are build-args (build-time only), pip creds are a BuildKit
   `--secret` mount (never stored in any image layer — check with
   `docker history` to verify nothing leaked).

## Internal Artifactory usage

- **docker**: base images from `docker-remote` (proxying docker.io), app images
  pushed to `docker-local`. Login via service account (`docker login` with
  password-stdin — never on the command line, it lands in shell history/ps).
- **pip**: `PIP_INDEX_URL` points at the pypi-remote virtual repo; credentials
  via `~/.netrc` (mode 600) in jobs and a BuildKit secret in image builds.

## Runner as the service account

`scripts/setup_build_host.sh` does this end-to-end. The key line most people
miss: `gitlab-runner install --user svc-chatapp` — by default the runner runs
as its own `gitlab-runner` user which has none of your service account's
access. Also: `--locked=true` so no other GitLab project can execute code as
this privileged account, and shell-executor risk is mitigated by the
protected-variable boundary above.

## Setup order (checklist)

1. Vault admin runs `vault/vault_setup.sh` (now includes the `chatapp-poc-only`
   AppRole for feature branches). Distribute creds.
2. Root on build host: edit CONFIG block in `scripts/setup_build_host.sh`, run it.
   Copy the printed SSH public key.
3. Root on POC host: paste pubkey + Vault creds into `scripts/setup_poc_host.sh`
   CONFIG block, run it.
4. GitLab: create CI/CD variables per the header of `.gitlab-ci.yml`
   (mind the protected vs unprotected split!), protect `main`, enable
   squash-merge + delete-branch-on-merge, add nightly schedule.
5. Create the `chatapp-releases` repo, give the service account push access.
6. Push a feature branch, open an MR, watch lint→test→eval→build run, press
   play on `deploy-poc`, hit `http://<poc-host>:8080`.
