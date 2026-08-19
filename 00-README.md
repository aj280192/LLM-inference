# Release Engineering Handbook — Python Streamlit AI App

End-to-end guide for building, testing, versioning, and releasing a Dockerized
Python (Streamlit) AI application in an enterprise setup with **GitLab 14.x
(self-managed, shell runners)**, **JFrog Artifactory + Xray**, and
**HashiCorp Vault**, deployed to shared VMs (dev / int / prod) via Docker Compose.

## Documents

| # | File | What it covers |
|---|------|----------------|
| 1 | [01-architecture.md](01-architecture.md) | JFrog repos, environments, secrets (Vault), shared-VM layout |
| 2 | [02-git-branching.md](02-git-branching.md) | Git from zero: branches, MRs, release branches, cherry-picks, conflicts |
| 3 | [03-versioning-and-releases.md](03-versioning-and-releases.md) | Conventional commits, semantic-release, tags, release bundles |
| 4 | [04-testing-strategy.md](04-testing-strategy.md) | Test pyramid, white-box vs black-box, AI evals, e2e/smoke, Playwright |
| 5 | [05-cicd-pipeline.md](05-cicd-pipeline.md) | The full pipeline step by step, JFrog-enforced scanning, rollback |
| 6 | [06-health-and-operations.md](06-health-and-operations.md) | Health endpoints, deploy/rollback scripts, failure points & fixes |

## The one-line summary

> **Build once → scan once → promote the same immutable image by digest through
> scratch → staging → stable, with tests gating every step and automatic
> rollback if health checks fail.**

## Core principles (recur throughout all docs)

1. **Build once, promote everywhere** — never rebuild an image between
   environments; promote the exact scanned digest.
2. **White-box tests before the image, black-box tests after deploy** — code
   tests run on source, Playwright tests hit a running URL.
3. **Machines decide versions** — conventional commits + semantic-release
   compute the version number and changelog; humans only approve MRs and click
   the prod gate.
4. **Fail loudly, recover automatically** — health checks gate every deploy;
   a deploy that never turns healthy rolls itself back.
5. **Parallel environments, never shared instances** — int mirrors prod in
   kind (same engine, same config shape) but never touches prod's DB,
   credentials, or data.
6. **No manual changes on environment VMs** — everything flows through the
   pipeline; break-glass fixes get backported to the repo the same day.
