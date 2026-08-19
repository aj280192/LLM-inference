# 2. Git & Branching — From Zero

## 2.1 The basics

- A **commit** is a snapshot of the project with a unique ID (`abc1234`).
  History is a chain of commits.
- A **branch** is a *movable label* pointing at a commit. Creating a branch
  copies nothing — it plants a second label that can then move independently.
- A **tag** is a *frozen* label — `v1.4.0` points at one commit forever.
  Tags mark releases.
- **GitLab** hosts the shared copy. You `git push` to send commits up,
  `git pull` to fetch others' work.
- A **Merge Request (MR)** = "please review my branch and merge it into main,"
  with review UI and automatic pipelines.

Run `git log --oneline --graph --all` often — it draws the branch diagram in
your terminal.

## 2.2 The branching model: main + feature + release

### `main` — the integration branch
- Always the latest development state; usually *ahead* of prod
- Protected: MR-only, pipeline must pass
- Every merge → builds an rc image → auto-deploys to dev

### `feature/*` — short-lived work branches
- Branched from main, merged back via MR within days (not weeks)
- Naming: `feature/JIRA-123-add-splunk-export`
- Deleted after merge

### `release/X.Y` — stabilization branches
- Cut from main when releasing; isolates the release from ongoing feature work
- Accepts **only bug fixes** after cutting — never new features
- Release tags (`v1.4.0`, `v1.4.1`) are created on this branch
- Lives as long as that version is supported in prod, then deleted
- If you release straight from main's HEAD anyway, skip the branch and just
  tag main — only cut `release/X.Y` when main has moved on or you support
  parallel versions

## 2.3 Daily workflow

```bash
# start work
git checkout main && git pull
git checkout -b feature/add-pdf-export

# do work
git add .
git commit -m "feat: add pdf export button"
git push -u origin feature/add-pdf-export
# -> open MR in GitLab, get review, merge
```

## 2.4 Cutting a release — exact steps

Team decides everything up to commit E becomes release 1.4.0:

```bash
git checkout main && git pull
git checkout -b release/1.4       # plants the label at main's current commit
git push -u origin release/1.4
```

```
main:         A --- B --- C --- D --- E
release/1.4:                          ↑ (same commit, new label)
```

Test on int; when good, tag:

```bash
git checkout release/1.4
git tag v1.4.0
git push origin v1.4.0            # tag push triggers the promotion pipeline
```

## 2.5 Hotfix when main has moved ahead

Prod runs 1.4.0. Main now contains unfinished 1.5 features (F, G). A prod bug
appears. **You cannot release main** — it would ship half-done work.

```
main:         A --- B --- C --- D --- E --- F --- G
release/1.4:                          E
```

**Step 1 — fix on main first ("upstream first"):**

```bash
git checkout main && git pull
git checkout -b fix/crash-on-empty-report
# fix, commit as: "fix: handle empty report list"
# MR -> main -> merged as commit H
```

Why main first? If you fixed only the release branch and forgot to copy it
over, version 1.5 would ship with the bug reintroduced. Fixing main first
makes forgetting impossible.

**Step 2 — cherry-pick onto the release branch** (copies just that one
commit's changes):

```bash
git checkout release/1.4 && git pull
git cherry-pick <commit-id-of-H>
git push
```

GitLab shortcut: every merged MR has a **Cherry-pick button** — select
`release/1.4` as target.

```
main:         A --- B --- C --- D --- E --- F --- G --- H
release/1.4:                          E --- H'
```

H' = same fix, different ID. F and G (unfinished 1.5 work) stayed out.

**Step 3 — release the patch:**

```bash
git checkout release/1.4
git tag v1.4.1
git push origin v1.4.1
```

## 2.6 Merge conflicts

A conflict = two branches changed **the same lines of the same file**. Git
can't pick a winner, so it stops and asks a human. Nothing is broken.

### Resolving locally

```bash
git checkout feature/my-branch
git pull origin main              # merge main in; git reports CONFLICT
```

Open the file; git marked the disputed spot:

```
<<<<<<< HEAD
REPORT_TIMEOUT = 10          <- your version
=======
REPORT_TIMEOUT = 60          <- main's version
>>>>>>> main
```

Edit the file to the final desired content (yours, theirs, or a new
combination — e.g. `45`), **delete all marker lines**, then:

```bash
git add config.py
git commit                        # accept the pre-filled merge message
git push
```

### Other ways
- **GitLab UI**: "Resolve conflicts" button on the MR — side-by-side with
  Use ours / Use theirs; fine for one-liners
- **VS Code**: highlights each conflict with *Accept Current / Incoming /
  Both* buttons

### Conflicts during cherry-pick

Same resolution, different continue command:

```bash
git cherry-pick <id>              # CONFLICT
# fix the file, then:
git add <file>
git cherry-pick --continue
```

**Safety net (nothing is ever lost):**

```bash
git merge --abort                 # or: git cherry-pick --abort
```

### Avoiding most conflicts
1. Keep feature branches short-lived (days)
2. `git pull origin main` into your branch every day or two
3. Don't reformat whole files inside a feature branch
4. Coordinate when two people must edit the same file the same week

**After resolving any conflict, run the tests before pushing** — a resolution
can be syntactically fine but logically wrong.

## 2.7 Cheat sheet

| Situation | Command |
|---|---|
| Start new work | `git checkout main && git pull && git checkout -b feature/x` |
| Share your branch | `git push -u origin feature/x` |
| Cut a release | `git checkout -b release/1.4 main && git push -u origin release/1.4` |
| Mark the release | `git tag v1.4.0 && git push origin v1.4.0` |
| Copy a fix to release | `git checkout release/1.4 && git cherry-pick <commit-id>` |
| See where you are | `git status` / `git log --oneline --graph --all` |
| Escape a bad merge | `git merge --abort` |

## 2.8 Pitfall to enforce

Release branches that live too long become a second main — teams start
merging features into them "because prod needs it sooner." Enforce:
**release branches accept only fixes.**
