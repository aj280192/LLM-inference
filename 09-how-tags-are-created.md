# 9. How a Tag Is Created — In Detail

## 9.1 What a tag technically is

Git stores everything in the hidden `.git/` folder. A tag is literally a
tiny file:

```
.git/refs/tags/v1.5.0     <- contains one line: the commit ID it points to
```

That's it. `git tag v1.5.0` writes that file. Nothing about your code
changes — you've added a permanent, named pointer to one commit.

Two kinds exist:

| Kind | Command | What's stored |
|---|---|---|
| Lightweight | `git tag v1.5.0` | Just the pointer |
| **Annotated** (use this) | `git tag -a v1.5.0 -m "release 1.5.0"` | Pointer + author + date + message, as a real git object |

Annotated tags are preferred for releases because they record *who* tagged
*when* — audit information you want.

Tags are **not pushed automatically**. `git push` sends branches;
tags need an explicit push:

```bash
git push origin v1.5.0        # push one tag
```

The moment the tag arrives at the GitLab server is the moment that matters —
see 9.4.

## 9.2 Manual tag creation (hotfixes, baseline)

```bash
git checkout release/1.4          # be on the commit you want to mark
git pull
git tag -a v1.4.1 -m "hotfix: empty report crash"
git push origin v1.4.1
```

Used for: the one-time baseline tag before enabling automation
(`v0.1.0`), and hotfix tags on release branches.

**Protected tags** (GitLab: Settings → Repository → Protected tags, pattern
`v*`) mean only Maintainers — and the release bot — can push tags matching
`v*`. Anyone else's `git push origin v9.9.9` is rejected by the server.
This is what stops an accidental or malicious tag from triggering a
release pipeline.

## 9.3 Automated tag creation — semantic-release, step by step

The `release` job on main runs `semantic-release version --push`. Here is
exactly what happens inside, in order:

**Step 0 — prerequisites the job config provides**

- `GIT_DEPTH: 0` → the runner clones *full* history. By default GitLab
  clones shallow (last ~20 commits) to be fast, but semantic-release must
  see the last tag, which may be hundreds of commits back.
- The remote URL is rewritten to embed credentials:
  `https://release-bot:${RELEASE_TOKEN}@gitlab.../reportapp.git`
  — because the runner's default clone credentials are **read-only**
  (a short-lived job token), and this job must *push* a tag back.

**Step 1 — find the last release tag**

```
git tag --list        (internally: sorted, filtered by tag_format "v{version}")
→ latest match: v1.4.0 at commit E
```

If no tag exists at all (cold start), it falls back to the configured
initial version — which is why we plant a baseline tag manually first, so
it never parses your entire pre-pipeline history.

**Step 2 — collect commits since that tag**

```
git log v1.4.0..HEAD --format=...
```

`v1.4.0..HEAD` means "every commit reachable from the current main that is
NOT reachable from v1.4.0" — i.e., everything merged since the last
release. Because we squash-merge, this list is clean: one commit per MR,
each with a conventional title.

**Step 3 — parse each commit message**

Each message is matched against the conventional-commit grammar:

```
^(?P<type>feat|fix|docs|chore|refactor|test|perf)(?P<scope>\(.+\))?(?P<breaking>!)?: (?P<subject>.+)
```

Plus a scan of the commit body for a `BREAKING CHANGE:` footer. Commits
that don't match are ignored (another reason the commit-lint MR job
matters — unparseable messages silently contribute nothing to the version).

**Step 4 — compute the bump**

```
any breaking?        → major
else any feat?       → minor
else any fix/perf?   → patch
else                 → no release, job exits doing nothing
```

Highest wins. `v1.4.0` + one `feat` + one `fix` → **1.5.0**.

**Step 5 — write files (before tagging)**

- `CHANGELOG.md` gets a new section generated from the parsed subjects,
  grouped by type
- If configured, the version is stamped into files — with setuptools-scm we
  skip this (the tag itself *is* the version source), keeping the release
  commit minimal or nonexistent

**Step 6 — commit (if files changed), tag, push**

```
git commit -m "chore(release): 1.5.0 [skip ci]"    # only if CHANGELOG updated
git tag -a v1.5.0 -m "1.5.0"
git push origin main --follow-tags
```

Note `[skip ci]` on the release commit — without it, pushing that commit
to main would trigger *another* full main pipeline (build, deploy-dev)
for a changelog-only change, and in the worst case an infinite loop of
release jobs. `[skip ci]` in a commit message tells GitLab to create no
pipeline for that push. The **tag** push, however, is a separate ref and
DOES create a pipeline — deliberately.

## 9.4 What happens server-side when the tag arrives

1. GitLab receives the ref `refs/tags/v1.5.0`
2. Protected-tag check: is the pusher (the bot, via RELEASE_TOKEN) allowed
   to create `v*` tags? Yes → accepted
3. GitLab reads `.gitlab-ci.yml` **at that tag's commit** and evaluates
   pipeline creation:
   - `workflow: rules` → `$CI_COMMIT_TAG` is set → pipeline allowed
   - Every job's `rules:` are evaluated **now, once** (not at runtime):
     jobs with `if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/` are included;
     jobs with `if: $CI_COMMIT_BRANCH == "main"` are excluded (a tag
     pipeline has `CI_COMMIT_TAG` set and `CI_COMMIT_BRANCH` unset)
4. Result: a **tag pipeline** containing only
   promote-staging → deploy-int → e2e-int → promote-stable → deploy-prod →
   smoke-prod (+ manual rollback jobs)
5. In every job of that pipeline, the predefined variable
   `CI_COMMIT_TAG=v1.5.0` is available — which is where
   `export VERSION=${CI_COMMIT_TAG#v}` gets `1.5.0`
   (`#v` is bash for "strip leading `v`").

So the tag is simultaneously three things: a permanent pointer in git
history, the version number of record (via setuptools-scm and
`CI_COMMIT_TAG`), and **the trigger event** that starts promotion. One
artifact of information driving all three is what keeps them from ever
disagreeing.

## 9.5 The two tag flows side by side

```
AUTOMATED (main releases)                MANUAL (hotfix on release branch)
─────────────────────────                ────────────────────────────────
merge MRs with feat:/fix: titles         git checkout release/1.4
release job on main:                     git cherry-pick <fix>
  parse commits since last tag           git tag -a v1.4.1 -m "..."
  compute 1.5.0                          git push origin v1.4.1
  tag v1.5.0, push
        │                                        │
        └────────────► GitLab receives tag ◄─────┘
                              │
                    tag pipeline (same one, either way):
                    promote → int → e2e → [manual] → prod
```
