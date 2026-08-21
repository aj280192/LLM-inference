# 10. Pipeline Internals — How It Actually Works

Learning material: the machinery underneath the YAML. Read doc 5 for *what*
the pipeline does; read this for *how* each mechanism works.

## 10.1 The big picture

```
you push ──► GitLab server ──► parses .gitlab-ci.yml ──► creates PIPELINE
                                                             │
                                              (a DAG of JOBS in STAGES)
                                                             │
runners poll GitLab ◄────────────────────────────────────────┘
   │  "any jobs for my tags?"
   └─► claim job ─► clone repo ─► run script lines ─► report exit code
```

Two machines are involved in every job: the **GitLab server** (decides what
should run, stores results) and a **runner** (actually runs it). They never
talk directly to each other's internals — the runner *polls* the server
over HTTPS, which is why runners can sit inside your network/VMs without
any inbound access.

## 10.2 Pipeline creation — everything is decided up front

When a push/tag/MR event arrives, GitLab:

1. Reads `.gitlab-ci.yml` **at that commit** (so an old tag runs the old
   pipeline definition — pipelines are versioned with the code)
2. Evaluates `workflow: rules` → should a pipeline exist at all?
3. Evaluates every job's `rules:` **once, now** — using variables known at
   creation time (`CI_COMMIT_BRANCH`, `CI_COMMIT_TAG`,
   `CI_PIPELINE_SOURCE`, `changes:` against the diff). A job is either IN
   the pipeline or it doesn't exist. This is why "show a job only if the
   scan finds high CVEs" can't be done with rules — scan results don't
   exist yet at creation time (the workaround is child pipelines: a job
   *generates* a YAML file at runtime and triggers it as a new pipeline)
4. Builds the job graph and starts scheduling

Consequence worth internalizing: `rules` answer "does this job exist for
this event?", not "should this step run right now?". Runtime decisions
live in `script:` (like our promote job's grep for "pending approval").

## 10.3 Stages vs `needs:` — the execution order

Default model: stages are sequential barriers. Every job in `test` must
finish before any job in `build` starts.

`needs:` upgrades this to a **DAG** (directed acyclic graph): a job starts
the moment the specific jobs it names have finished, regardless of stage
barriers. In our pipeline:

```
build-image ──► publish-scratch ──► wait-for-scan ──► deploy-dev
     └────────────────────────────────────────────────────► (artifacts flow along edges)
```

`needs:` does double duty: it defines *when* a job may start AND *whose
artifacts it downloads* (see 10.6).

## 10.4 The shell executor — what "running a job" means

Our runners use the shell executor. When one claims a job it:

1. Creates/uses a build directory:
   `~gitlab-runner/builds/<runner>/<project>/`
2. Clones or fetches the repo at the pipeline's commit
   (shallow by default — `GIT_DEPTH: 0` overrides for full history)
3. Writes your `script:` lines into a generated bash script and runs it
   with **fail-fast semantics**: each line must exit 0; the first non-zero
   exit code stops the script and the job is FAILED with that code
4. Runs `after_script:` in a *separate* shell — always, pass or fail,
   with `CI_JOB_STATUS` set to `success`/`failed` (this is exactly how our
   smoke-prod auto-rollback hook works)
5. Uploads declared artifacts, reports the exit status to GitLab

Shell-executor implications you must respect:

- Jobs run **as the runner's OS user, directly on the host** — the same
  machine state persists between jobs. That's a feature for us (the prod
  runner IS the prod VM, `docker compose` acts on localhost, the
  `CURRENT_VERSION` files persist) and a hazard (leftover files, installed
  tools accumulate — the "works because of the runner" failure). Keep jobs
  self-contained; anything the job needs, it installs or it's documented
  as VM provisioning
- Exit codes are the whole protocol: `deploy.sh` ending in `exit 1` after
  a successful *rollback* is a deliberate use of this — the environment
  recovered, but the pipeline must show red so promotion stops

## 10.5 Variables — where values come from

Precedence (later overrides earlier): predefined → instance/group/project
CI variables → `variables:` in YAML → dotenv artifacts → `export` in script.

The ones this pipeline lives on:

| Variable | Set by | Used for |
|---|---|---|
| `CI_COMMIT_TAG` | GitLab, tag pipelines only | Version + routing jobs via rules |
| `CI_COMMIT_BRANCH` | GitLab, branch pipelines only | Routing main-only jobs |
| `CI_PIPELINE_IID` | GitLab, per-project counter | Unique rc versions |
| `CI_COMMIT_SHORT_SHA` | GitLab | Traceability in rc tags |
| `CI_JOB_JWT` | GitLab (14.x) | Vault authentication (10.8) |
| `CI_JOB_STATUS` | GitLab, in after_script | Rollback-on-failure hook |
| `RELEASE_TOKEN` | You, project CI variable | Bot's tag-push credential |

**Masked** variables are redacted in job logs; **protected** variables are
only injected into pipelines on protected branches/tags — which is why
`RELEASE_TOKEN` set as protected can't be exfiltrated by a job running on
someone's feature branch.

## 10.6 Artifacts and the dotenv trick — how $VERSION travels

Jobs run on potentially different machines with fresh checkouts — nothing
survives between jobs unless declared. **Artifacts** are files a job
uploads to the GitLab server; downstream jobs listed in `needs:` download
them automatically.

The special case we use everywhere:

```yaml
artifacts:
  reports:
    dotenv: build.env      # file contains: VERSION=1.5.0-rc.214-abc1234
```

A dotenv artifact isn't downloaded as a file — GitLab parses it and
**injects each line as an environment variable** into every job that
`needs:` this one. That is the entire mechanism by which the version
computed once in `build-image` appears as `$VERSION` in publish, deploy,
and promote jobs, without recomputation (recomputing would risk two jobs
disagreeing — one value, one source).

## 10.7 Environments, manual jobs, resource_group

- `environment: {name: prod}` links a job to a named environment: GitLab
  tracks "what's deployed where" in its UI, and **protected environments**
  restrict who may run jobs targeting it — that's the real access control
  on our `when: manual` gates. The button exists for everyone; only the
  allowed group can successfully press it.
- `when: manual` = the job is created in the pipeline but waits for a
  human click. With `allow_failure: false` (our promote-stable), the
  pipeline *blocks* at it — nothing after runs until pressed.
- `resource_group: prod` = a mutex on the GitLab server: across ALL
  pipelines of the project, at most one job holding that resource runs at
  a time. This is what makes two release pipelines physically unable to
  deploy to the same VM simultaneously.

## 10.8 How CI authenticates to Vault (CI_JOB_JWT)

No Vault password is stored anywhere. Instead:

1. For every job, GitLab mints a **JWT** — a signed token whose payload
   states: project ID, ref, whether the ref is protected, pipeline source
2. The job sends it to Vault:
   `vault write auth/jwt/login role=reportapp-ci jwt=$CI_JOB_JWT`
3. Vault verifies the signature against GitLab's public keys (fetched once
   from GitLab's OIDC discovery URL) — proving GitLab, not an attacker,
   minted it
4. Vault checks the payload against the role's **bound claims**
   (`project_id = 42`, `ref_protected = true`) and, if they match, returns
   a short-lived Vault token limited to that role's policy

Effect: only real jobs, of the right project, on protected refs, can read
the secrets — and the credential expires in minutes. A leaked job log
leaks nothing durable.

## 10.9 Docker mechanics the pipeline relies on

- An **image** is a stack of layers (tar archives) plus a **manifest**
  listing them; the manifest's SHA-256 is the **digest** — the true
  immutable identity. A **tag** is a mutable name pointing at a digest
  (exactly like a git branch vs a commit)
- `docker build` caches per layer: an unchanged Dockerfile line whose
  inputs are unchanged reuses the cached layer — why we order Dockerfiles
  as "copy lockfile → install deps → copy code" (code changes then reuse
  the expensive dependency layer), and why the first cold-start build is
  slow
- `docker push` uploads only layers the registry doesn't already have
- **Promotion** (`jf rt docker-promote`) is a server-side registry
  operation: Artifactory re-points/copies the manifest into another repo.
  No bits move through the runner, nothing is rebuilt — which is the
  physical reason "promote the same digest" is trustworthy
- `docker compose up -d` is **declarative**: it diffs desired state
  (compose file + IMAGE_REF) against running state and only recreates
  containers whose definition changed. Deploy and rollback are therefore
  the *same operation* with a different IMAGE_REF — one code path

## 10.10 One merge, traced end to end

```
1  git push (merge to main, commit H)
2  GitLab: workflow rules pass → pipeline #215 created:
     [lint, unit-test] → build-image → publish-scratch → wait-for-scan
     → deploy-dev → integration-test → release
3  build runner polls, claims lint + unit-test (parallel, same stage)
4  both exit 0 → build-image claimed:
     VERSION=0.0.0-rc.215-h1h2h3h; docker build (layer cache hits deps);
     writes build.env; uploads as dotenv artifact
5  publish-scratch: inherits VERSION via dotenv; docker push (new layers
     only); jf build-publish records the dependency graph (SBOM source)
6  wait-for-scan: polls until Xray finishes indexing
7  dev VM's runner claims deploy-dev (it has tag `dev`):
     resource_group dev acquired; deploy.sh: PREVIOUS_VERSION saved,
     compose up with new IMAGE_REF, polls /readyz → healthy → exit 0
8  integration-test on build runner (throwaway postgres service)
9  release job: full-depth fetch; parses commits since v1.4.0; computes
     1.5.0; tags; pushes tag with RELEASE_TOKEN
10 GitLab receives refs/tags/v1.5.0 → protected-tag check passes →
     NEW pipeline #216 created containing only the tag-rule jobs
     → promotion begins (doc 5, from promote-staging onward)
```

Every arrow in that trace is one of the mechanisms above: rules decided
which jobs exist, tags routed jobs to machines, dotenv moved the version,
exit codes gated progress, the mutex serialized the deploy, and the JWT
opened Vault. Nothing in the pipeline is magic — it's these seven or eight
small mechanisms composed.
