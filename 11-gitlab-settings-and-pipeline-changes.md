# 11. GitLab Settings & Pipeline Changes — Complete Reference

This is the single source of truth for **every GitLab UI setting** this
project needs, plus the **exact pipeline changes** that go with them
(release-bot setup, no-direct-push-to-main flow, JFrog-enforced scanning).
Follow it top to bottom when setting up a new project, or use it to audit
an existing one.

---

## 1. Branch structure

Only two kinds of branches exist in this project:

- **`main`** — the only long-lived branch. Always deployable to dev.
- **`feature/*`** — short-lived, one per unit of work, deleted after merge.
- **`release/X.Y`** — created only if/when you need to stabilize a release
  in parallel with ongoing main development (see doc 2). Not needed at
  project start.

There is **no `dev` branch**. If migrating from a project that had one,
see the migration notes in the conversation history — delete it after
fast-forwarding/squashing its content into `main`.

---

## 2. Protected branches

**Settings → Repository → Protected branches**

### `main`

| Setting | Value | Why |
|---|---|---|
| Allowed to merge | **Developers + Maintainers** | Normal team workflow — anyone can get their MR merged after review |
| Allowed to push | **No one** | Nobody, at any role, pushes a commit directly. All changes to `main` go through an MR. This includes the release-bot — see section 5 for why that's fine |
| Allowed to force push | No | Never rewrite shared history |
| Require code owner approval | Optional — enable if you have a CODEOWNERS file | Extra review gate on sensitive paths |

> **Critical consequence of "Allowed to push: No one":** this blocks
> literally everyone, including Maintainers and any bot token, from
> `git push origin main` directly. There is no exception by role. This
> is why the release job (section 5) is specifically designed to never
> attempt a push to the `main` branch — only to tags.

### `release/*` (once you start using them)

| Setting | Value |
|---|---|
| Allowed to merge | Maintainers only (fixes go through careful review) |
| Allowed to push | No one |
| Allowed to force push | No |

---

## 3. Protected tags

**Settings → Repository → Protected tags**

| Setting | Value | Why |
|---|---|---|
| Tag pattern | `v*` | Matches all release tags (`v1.0.0`, `v1.4.1`, etc.) |
| Allowed to create | **Maintainers** | The release-bot holds Maintainer role (section 5), so it can create tags matching this pattern. Human Maintainers can also tag manually for hotfixes (doc 2) |

**Important distinction from branches:** protected *tags* and protected
*branches* are separate GitLab features governing separate git ref
namespaces (`refs/tags/*` vs `refs/heads/*`). Setting "Allowed to push: No
one" on the `main` branch has **zero effect** on tag pushes — that's
exactly the property this whole setup relies on.

On GitLab 14.x: protected tags only support role-based rules (Developer /
Maintainer / No one) — there is no "select this specific user" option for
tags. Any Maintainer, human or bot, satisfies the rule. This is a
tier/version limitation, not a misconfiguration.

---

## 4. Merge request settings

**Settings → Merge requests**

| Setting | Value | Why |
|---|---|---|
| Merge method | **Squash commits when merging** | Keeps `main` as one clean commit per MR |
| Squash commit message | **Use the merge request title** | This is critical — see section 6. Since individual commits inside a feature branch don't need to follow conventional-commit format, only the **MR title** does, because that title becomes the one commit that lands on `main` |
| Merge commit message | Default is fine (only relevant if you ever disable squash) |
| Delete source branch by default | Yes | Keeps the branch list clean; feature branches are meant to be deleted after merge |

---

## 5. The release-bot — full setup

### 5.1 Create the Project Access Token

**Settings → Access Tokens** (requires GitLab 14.5+ for Free tier; if
below that version or Free-tier-without-PAT-support, use a dedicated bot
*user* with a Personal Access Token instead — same end result, see note
at the bottom of this section).

| Field | Value |
|---|---|
| Name | `release-bot` |
| Role | **Maintainer** — required to satisfy the protected-tag rule in section 3 |
| Scopes | `write_repository` only — least privilege, no `api` scope needed |
| Expiration date | Required by GitLab. Set 6–12 months out; put a calendar reminder to rotate before it expires |

Click **Create project access token** — copy the value immediately, it is
shown once and cannot be retrieved again.

### 5.2 Store it as a CI/CD variable

**Settings → CI/CD → Variables → Add variable**

| Field | Value |
|---|---|
| Key | `RELEASE_TOKEN` |
| Value | (the token from 5.1) |
| Type | Variable |
| Environment scope | All (or restrict to match your protected refs) |
| Protect variable | **Yes** — only injected into pipelines running on protected branches/tags (i.e. `main`). A feature-branch pipeline cannot see this value even if someone copies the job into their branch |
| Mask variable | **Yes** — hides the value in job logs |

### 5.3 What the bot can and cannot do — the mental model

| Action | Governed by | Bot allowed? |
|---|---|---|
| Push a commit to `main` | Protected branch → Allowed to push | **No — blocked, by design (section 2)** |
| Push a tag matching `v*` | Protected tag → Allowed to create | **Yes** — bot is Maintainer |
| Merge an MR | Protected branch → Allowed to merge | Not applicable — the bot never opens/merges MRs |

The bot's entire job is: compute a version number, tag the existing
commit, push the tag. It never touches the `main` branch ref directly.

### 5.4 Alternative if Project Access Tokens are unavailable

Create a real (non-human) GitLab user account (e.g.
`release-bot@yourcompany.com`), add it to the project as **Maintainer**,
generate a **Personal Access Token** for that user with `write_repository`
scope, and use it identically as `RELEASE_TOKEN`. Note this consumes a
licensed seat if your instance is seat-limited — check with whoever
manages licensing first.

### 5.5 Verifying the bot's access works

Run this once after setup, from your own machine (not CI), to confirm
permissions before relying on it in a real pipeline:

```bash
git clone https://release-bot:<RELEASE_TOKEN>@gitlab.company.com/team/reportapp.git /tmp/bot-check
cd /tmp/bot-check

# tag push should succeed (protected tag rule allows Maintainers)
git tag v0.0.0-permission-check
git push origin v0.0.0-permission-check
git push origin --delete v0.0.0-permission-check

# branch push should FAIL (protected branch: allowed to push = no one)
echo test >> README.md
git commit -am "test: should be rejected"
git push origin main
# expect: ! [remote rejected] main -> main (protected branch hook declined)
```

If the tag push fails: check the bot's project role is actually Maintainer
(Members page) and that the protected-tag pattern matches. If the branch
push *succeeds* when you expected it to fail: your "Allowed to push"
setting on `main` isn't actually "No one" — re-check section 2.

---

## 6. Conventional commits enforcement

Because squash-merge uses the **MR title** as the commit message (section
4), enforcement focuses there, not on every commit inside a branch.

**Format**: `<type>: <description>`, types = `feat`, `fix`, `docs`,
`chore`, `refactor`, `test`, `perf`; breaking changes use `feat!:` or a
`BREAKING CHANGE:` footer.

**Enforcement layers:**

1. **Local pre-commit hook** (`pre-commit install`) — catches bad commit
   messages before they're even made; not strictly required if you only
   enforce at the MR title level, but good practice for interactive
   `cz commit` usage
2. **MR pipeline job** validating the MR title:

```yaml
commit-lint:
  stage: validate
  tags: [build]
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
  script:
    - pip install --quiet commitizen
    - echo "$CI_MERGE_REQUEST_TITLE" | cz check --message -
```

Start this with `allow_failure: true` for the first week or two on a new
project so the team learns the format from warnings rather than blocked
MRs, then remove `allow_failure` to make it a hard gate.

---

## 7. The release job — full rewrite (no push to `main`)

### 7.1 Why this changed

Default `semantic-release` behavior writes `CHANGELOG.md`, commits it to
`main`, then pushes that commit before tagging. With "Allowed to push: No
one" on `main`, that push is rejected. The fix: never commit to `main` at
all. Compute the version, tag the existing commit directly, push only the
tag, and put the changelog in a GitLab Release object instead of a repo
file.

### 7.2 Config change

```toml
# pyproject.toml
[tool.semantic_release]
tag_format = "v{version}"
branch = "main"
commit_version_number = false   # never create a version-bump commit
changelog_file = ""             # never write CHANGELOG.md into the repo
```

### 7.3 Pipeline job — before and after

**Before (breaks with "Allowed to push: No one"):**

```yaml
release:
  stage: release
  tags: [build]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  variables:
    GIT_DEPTH: 0
  script:
    - pip install --quiet python-semantic-release
    - git remote set-url origin "https://release-bot:${RELEASE_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
    - semantic-release version --push
    # internally: writes CHANGELOG.md, commits it, tries `git push origin main`
    #             --> REJECTED by protected branch rule
```

**After (works — tag only, changelog goes to GitLab Releases):**

```yaml
release:
  stage: release
  tags: [build]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  variables:
    GIT_DEPTH: 0     # full history required — semantic-release must see the last tag
  script:
    - pip install --quiet python-semantic-release python-gitlab
    - git remote set-url origin "https://release-bot:${RELEASE_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"

    # 1. Compute the next version WITHOUT committing or tagging yet
    - export NEXT_VERSION=$(semantic-release version --print)
    - |
      if [ -z "$NEXT_VERSION" ]; then
        echo "No release-worthy commits since last tag. Skipping."
        exit 0
      fi

    # 2. Generate changelog content to a file (not committed to the repo)
    - semantic-release changelog > release-notes.md

    # 3. Tag the CURRENT commit directly (no new commit created)
    - git tag -a "v${NEXT_VERSION}" -m "v${NEXT_VERSION}"

    # 4. Push ONLY the tag — this is allowed (protected tag rule = Maintainers)
    - git push origin "v${NEXT_VERSION}"

    # 5. Record the changelog as a GitLab Release, not a repo commit
    - |
      pip install --quiet release-cli 2>/dev/null || true
      release-cli create \
        --tag-name "v${NEXT_VERSION}" \
        --name "v${NEXT_VERSION}" \
        --description "$(cat release-notes.md)"
  artifacts:
    paths:
      - release-notes.md
```

> Exact `semantic-release` CLI flags (`--print`, `changelog` subcommand)
> vary by version — verify against `semantic-release --help` in your
> environment. The principle to preserve regardless of flag names:
> **compute → tag existing commit → push tag only → changelog goes to
> GitLab Release, never to a repo commit.**

### 7.4 What no longer needs to exist

- The `[skip ci]` marker on a release commit — there's no commit to mark,
  so no risk of the push re-triggering a pipeline
- Any logic worrying about "did the changelog commit succeed before the
  tag" — there's only one write operation now (the tag), not two

---

## 8. Scanning enforcement — JFrog policy, not a pipeline job

**No changes needed here if you followed doc 5** — this section is
included for completeness since it's part of the same pipeline.

Configured once in JFrog Xray (Watch + Security Policy on
`docker-scratch-local`), not in `.gitlab-ci.yml`:

| Severity | Policy action | Pipeline behavior |
|---|---|---|
| Critical | Block | `jf rt build-promote` fails non-zero — job red, release stops |
| High | Require approval | Promotion held server-side; job detects "pending approval" in the error, prints the JFrog approval URL, exits 1. After approval, **retry the job** (no rebuild) |
| Medium | Notify only | Promotion succeeds; warning recorded in the build's Xray report |

There is no standalone `scan-image` job — only a `wait-for-scan` job
(ensures Xray indexing finished) before `promote-staging` attempts the
promotion, which is where enforcement actually happens.

---

## 9. CI/CD variables — full list

**Settings → CI/CD → Variables**

| Key | Protected | Masked | Purpose |
|---|---|---|---|
| `RELEASE_TOKEN` | Yes | Yes | Release-bot's push access for tags (section 5) |
| `JFROG_URL` | No | No | Artifactory base URL (not secret) |
| Any Vault role names / addresses | No | No | Not secret by themselves — actual secrets come from Vault at runtime, never stored as static CI variables |

Deliberately **not** stored as CI variables: LLM API keys, DB passwords,
Splunk tokens — these come from Vault via `CI_JOB_JWT` auth (doc 1, doc
10.8) or, for deployment, are rendered by Vault Agent directly on the VM
and never pass through GitLab at all.

---

## 10. Protected environments

**Settings → CI/CD → Environments** (or configured via `environment:` in
YAML plus **Settings → CI/CD → Protected environments**)

| Environment | Who can deploy |
|---|---|
| `dev` | Anyone whose pipeline reaches the job (auto, no gate) |
| `int` | Anyone whose pipeline reaches the job (auto, no gate) |
| `prod-approval` | Restrict to your lead/approver group — this is the real access control behind the `promote-stable` manual button |
| `prod` | Same restricted group |

This is what makes `when: manual` meaningful — the button is visible to
everyone, but only members of the allowed group can successfully click it
and have the job execute.

---

## 11. One-time setup checklist (new project)

Run through in this order:

- [ ] Repo has only `main` (no `dev`)
- [ ] Protected branches: `main` — merge: Developers+Maintainers, push: No one
- [ ] Protected tags: `v*` — create: Maintainers
- [ ] Merge requests: squash enabled, squash message = MR title
- [ ] Project Access Token `release-bot` created (Maintainer, `write_repository`, expiry set)
- [ ] `RELEASE_TOKEN` CI/CD variable added (protected + masked)
- [ ] Bot access verified with the section 5.5 script (tag push succeeds, branch push rejected)
- [ ] `pyproject.toml` has `commit_version_number = false`, `changelog_file = ""`
- [ ] `release` job matches section 7.3 "After" version
- [ ] `commit-lint` job added (start with `allow_failure: true`)
- [ ] Baseline tag planted: `git tag -a v0.1.0 -m "baseline" && git push origin v0.1.0`
- [ ] Protected environments configured for `prod-approval` / `prod`
- [ ] JFrog Xray watch + policy configured on `docker-scratch-local` (section 8)
- [ ] First MR merged, watched end-to-end through dev deploy
- [ ] First release tag (`v0.2.0`) watched through to prod, supervised
