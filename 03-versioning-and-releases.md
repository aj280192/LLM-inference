# 3. Versioning & Releases

## 3.1 Semantic versioning refresher

`MAJOR.MINOR.PATCH` → `1.4.2`

| Bump | When | Example |
|---|---|---|
| PATCH `1.4.2 → 1.4.3` | Bug fixes only | crash fix |
| MINOR `1.4.2 → 1.5.0` | New backward-compatible features | new export button |
| MAJOR `1.4.2 → 2.0.0` | Breaking changes | auth now required everywhere |

## 3.2 Conventional commits — strict message format

Every commit message starts with a type:

```
<type>: <short description>
```

| Prefix | Meaning | Version effect |
|---|---|---|
| `fix:` | Bug fix | **patch** bump |
| `feat:` | New feature | **minor** bump |
| `feat!:` / `fix!:` | Breaking change | **major** bump |
| `docs:` `chore:` `test:` `refactor:` | No user-facing change | no release |

Why strict? **A machine reads your history** and computes versions +
changelogs automatically.

### Enforcement (a convention nobody enforces decays in two weeks)

1. **Local**: `pre-commit` hook with commitizen — bad messages rejected at
   commit time; `cz commit` gives an interactive prompt for beginners
2. **CI**: MR job validates all commits
   (`cz check --rev-range origin/main..HEAD`)
3. **Squash setting — critical**: with squash merging (recommended — keeps
   main clean), the *squash commit message* is what lands on main. Configure
   GitLab to use the **MR title** as the squash message, then only MR titles
   need discipline (`feat: add pdf export`) — individual "wip" commits inside
   the branch don't matter. Optionally add an MR-title regex check in CI.

## 3.3 How semantic-release works, step by step

Current release: `v1.4.0`. Three MRs merge to main:

```
fix: correct timeout on large reports
feat: add pdf download
chore: update ci template
```

The `release` job runs `python-semantic-release`, which:

1. Finds the last tag → `v1.4.0`
2. Parses every commit message since that tag
3. Computes the bump: `fix` (patch) + `feat` (minor) → **highest wins** →
   minor → next version **1.5.0**; `chore` ignored
4. Writes the changelog automatically, grouped by type
5. Creates and pushes tag `v1.5.0`
6. The tag push **triggers the promotion pipeline**

If only `docs:`/`chore:` merged since the last tag → correctly concludes
"nothing shipped" → no release. No human decides numbers, writes changelogs,
or forgets to release.

### Config

```toml
# pyproject.toml
[tool.semantic_release]
tag_format = "v{version}"
branch = "main"
```

```yaml
# .gitlab-ci.yml (14.x)
release:
  stage: release
  only: [main]
  variables:
    GIT_DEPTH: 0                       # needs full history to see last tag
  script:
    - pip install python-semantic-release
    - git remote set-url origin "https://release-bot:${RELEASE_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
    - semantic-release version --push
```

`RELEASE_TOKEN` = GitLab project access token (write_repository scope) as a
masked/protected CI variable — the only thing in the pipeline with repo write
access.

### Hotfixes on release branches

Tag `v1.4.1` **manually** on `release/1.4` — hotfixes are rare and
deliberate. Automate later only if they become frequent.

## 3.4 Version numbers through the pipeline (hybrid scheme)

| Event | Python version (setuptools-scm) | Docker tag | Repo |
|---|---|---|---|
| Merge to main (pipeline 214) | `1.5.0.dev5+gdef5678` | `0.0.0-rc.214-def5678` | scratch |
| Tag `v1.5.0` created | `1.5.0` | `1.5.0` (re-tag of that exact digest — **no rebuild**) | staging → stable |
| Convenience | — | `1.5`, `stable` | stable only |

The rc suffix makes dev builds impossible to confuse with releases; every
build is uniquely identifiable via `CI_PIPELINE_IID` + short SHA.

`setuptools-scm` derives the Python package version from the git tag — no
version string in code, ever:

```toml
[build-system]
requires = ["setuptools>=64", "setuptools-scm>=8"]
[tool.setuptools_scm]
```

### Alternatives considered

| Scheme | Pros | Cons |
|---|---|---|
| Manual tags + setuptools-scm | Zero tooling, version = git reality | Humans forget to release |
| **Conventional commits + semantic-release (chosen)** | Fully automatic, free changelog | Needs commit discipline (solved via squash + MR titles) |
| CalVer / `1.4.${CI_PIPELINE_IID}` | Dead simple | No semantic meaning |

If commit hygiene is loose at first: start with manual tags + setuptools-scm,
add semantic-release once conventions stick.

## 3.5 What a "release bundle" is

Not just the code — a **versioned, immutable set of artifacts**:

1. **Docker image** (by digest, in JFrog) — the primary artifact
2. **Build-info** — links image → pip deps → git SHA → CI job → scan results
3. **Compose/deploy manifest** pinned to the exact tag/digest
4. **Changelog + git tag**
5. Optionally a **GitLab Release** object tying it together

### Packaging options

| Option | When |
|---|---|
| **JFrog Release Bundle (Distribution)** — `jf release-bundle-create`, signed, atomic promotion | If your license includes Distribution — the enterprise-clean answer |
| **Build-info as release unit (chosen default)** — `build-publish` + `build-promote` + GitLab Release via `release-cli` | Works on any license, zero extra cost |
| Tarball (`docker save` + compose + install script in a generic repo) | Only for air-gapped delivery; otherwise skip |

Inside the image: build a **wheel** in the builder stage
(`python -m build`), install it into the runtime stage. Never `COPY . .` raw
source into prod images — a wheel enforces packaging metadata and can also be
published to `pypi-local` if other teams consume your code.
