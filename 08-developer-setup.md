# 8. Developer Setup & Local Testing — New Joiner Guide

Welcome! This guide takes you from a fresh laptop to running the app,
making a change, testing it, and getting it merged. No prior knowledge of
our tooling is assumed. Follow it top to bottom — it takes about 30–45
minutes.

> **The one rule to remember:** you never build or push Docker images to
> JFrog yourself. You work locally, open a Merge Request, and the pipeline
> does the rest. Your JFrog account is read-only for Docker on purpose.

---

## Part A — One-time machine setup

### A.1 Install the basics

You need these installed (ask IT / your buddy if any are missing):

| Tool | Check it works with | Why you need it |
|---|---|---|
| Git | `git --version` | Version control |
| Python 3.11+ | `python3 --version` | The app is Python |
| VS Code | open it | Your editor |
| Docker Desktop / Engine | `docker --version` | Only for occasional container testing |
| Vault CLI | `vault --version` | Fetching dev secrets |

### A.2 Get the code

```bash
git clone https://gitlab.company.com/team/reportapp.git
cd reportapp
```

If this asks for credentials, set up a GitLab **Personal Access Token**:
GitLab → your avatar → *Preferences* → *Access Tokens* → create one with
`read_repository` + `write_repository` scope, and use it as your password
when git asks.

### A.3 Create a virtual environment

A virtual environment ("venv") is a private folder holding this project's
Python packages, so they don't clash with anything else on your machine.

```bash
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
```

Your prompt now shows `(.venv)`. **You must activate this every time you
open a new terminal for this project.** (VS Code will do it automatically
once configured — Part B.)

### A.4 Point pip at the company package server

We install Python packages through JFrog (our internal mirror), not public
PyPI directly. Create the file `~/.pip/pip.conf`
(Windows: `%APPDATA%\pip\pip.ini`):

```ini
[global]
index-url = https://jfrog.company.com/artifactory/api/pypi/pypi-virtual/simple
```

### A.5 Install the app in "editable" mode

```bash
pip install -e ".[dev]"
```

What this does, in plain words:

- Installs all the app's dependencies **plus** the developer tools
  (pytest, ruff, mypy)
- Installs the app itself as *editable*: when you change a file in
  `app/src/`, the change is live immediately — no reinstalling
- Makes `from app.src.llm import build_prompt` work in tests, exactly like
  it does in CI

### A.6 Install the commit hooks

```bash
pre-commit install
```

This makes git check your work *before* each commit: code style, and that
your commit message follows our required format (explained in Part D).
Better to be told at commit time than by a red pipeline 5 minutes later.

### A.7 Get local secrets

The app talks to a database and an LLM, so it needs credentials. You have
two options:

**Option 1 — Mock mode (start here, zero setup):**

```bash
cp .env.example .env
```

`.env.example` sets `LLM_PROVIDER=mock`, which makes the app return canned
fake responses. Perfect for working on UI and logic without touching any
real service.

**Option 2 — Real dev credentials (when you need real LLM behavior):**

```bash
vault login -method=oidc          # opens browser, log in with your SSO
vault kv get -format=json secret/reportapp/dev-local \
  | jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' > .env
```

These are *development* credentials — a rate-limited LLM key and a dev
database. You will never have access to int or prod credentials, and that's
by design.

> `.env` is in `.gitignore`. It must **never** be committed. If you ever
> accidentally commit a secret, tell your lead immediately — it needs
> rotating, and that's a normal thing to report, not a firing offense.

### A.8 Verify everything works

```bash
make test          # runs lint + type check + unit tests — should be all green
make dev           # starts the app; open http://localhost:8501 in a browser
```

If both work: setup done. If not: the error message + your buddy.

---

## Part B — VS Code setup

### B.1 Open the project

```bash
code .
```

VS Code will pop up "This workspace has recommended extensions" — click
**Install All**. That installs:

- **Python** (Microsoft) — language support, debugging, test integration
- **Ruff** — our linter/formatter, runs on save
- **GitLab Workflow** — see your MR's pipeline status inside the editor

### B.2 Select the interpreter

Bottom-right corner of VS Code shows a Python version. Click it and pick
**`.venv/bin/python`** (it usually says "Recommended"). This makes VS Code
use your project venv for everything — running, testing, autocomplete.

If it's already correct (the repo ships `.vscode/settings.json` that points
there), you'll see `('.venv': venv)` — done.

### B.3 What the committed settings give you automatically

The repo includes `.vscode/settings.json`, so without configuring anything:

- **Format on save** — Ruff formats your code every time you hit save.
  You will *never* fail the pipeline for code style
- **Testing sidebar** — the flask/beaker icon in the left bar lists every
  unit test. Click ▶ next to any test to run just that one; click the bug
  icon to run it under the debugger
- **Problems tab** — type errors and lint issues appear as you type, the
  same ones CI would flag

### B.4 Debugging the Streamlit app

`.vscode/launch.json` includes a "Streamlit: Debug" configuration. Press
**F5**, and the app starts under the debugger — set breakpoints in
`app/src/` by clicking left of a line number, interact with the app in the
browser, and execution pauses at your breakpoint with all variables
inspectable. This is *far* faster than print-statement debugging.

---

## Part C — How to test locally (the daily loop)

There are three ways to test, from fastest to slowest. You'll use the first
two constantly and the third rarely.

### C.1 Run the app and click around (~2 seconds per change)

```bash
make dev            # = streamlit run streamlit_app.py
```

Open http://localhost:8501. Now the magic: **edit any file and save** —
Streamlit detects it and offers "Rerun" (or reruns automatically). Your
edit-to-result loop is about 2 seconds. This is where you spend most of
your time when building UI or flows.

With mock mode (Option 1 secrets), the LLM answers instantly with fake
data — ideal for UI work.

### C.2 Run the tests (~seconds for one test, ~1 min for all)

While coding a specific function:

```bash
pytest tests/unit/test_utils.py -x        # one file, stop at first failure
pytest tests/unit -k "clean_prompt"        # only tests matching a name
```

Or click ▶ in the VS Code Testing sidebar — same thing, with a UI.

Before you push, run **exactly what the MR pipeline will run**:

```bash
make test
# = ruff check . && mypy app/ && pytest tests/unit tests/streamlit_apptest
```

If `make test` is green locally, your MR pipeline will be green. If it's
red locally, you just saved yourself a 5-minute wait and a red X next to
your name.

**When you add a feature, add a test for it in the same branch.** A rough
guide: new function in `app/src/` → new test in `tests/unit/`. Look at the
existing tests and copy their pattern — mocking the LLM/DB is already shown
in `tests/unit/test_llm.py`.

### C.3 Test inside the actual container (rare — only when relevant)

You only need this when you changed the `Dockerfile`, `entrypoint.sh`,
`healthapi.py`, or you're chasing a "works on my machine but not in dev"
mystery:

```bash
make docker-run
# = docker build -t reportapp:local . && docker run --rm -p 8501:8501 --env-file .env reportapp:local
```

Then check the app at http://localhost:8501 **and** the health endpoint:

```bash
curl http://localhost:8000/readyz
```

This image stays on your laptop. Never `docker push` it anywhere — you
can't (read-only permissions), and the pipeline builds the real one.

### C.4 What you do NOT test locally

- **Integration tests** (`tests/integration/`) need a Postgres service —
  CI spins one up automatically on merge. You *can* run them locally with
  `docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=test postgres:15` if
  you're working on DB code, but it's optional
- **Evaluation tests** (`tests/evaluation/`) cost real LLM tokens — CI runs
  them when prompt code changes. Don't run the full set locally
- **E2E/smoke tests** (`tests/e2e/`, `tests/smoke/`) run against deployed
  environments — nothing to run locally

---

## Part D — Making your first change, end to end

### D.1 Start a branch (never work on main)

```bash
git checkout main
git pull                                  # always start from the latest
git checkout -b feature/JIRA-123-my-first-change
```

### D.2 Code → test → repeat

Use the C.1/C.2 loop until it works and `make test` is green.

### D.3 Commit — the message format matters

Our commit messages follow a strict format because a robot reads them to
compute release version numbers (see doc 3):

```
feat: add export button to report page      <- new feature
fix: handle empty report list                <- bug fix
docs: update local setup guide               <- docs only
test: add tests for prompt builder           <- tests only
chore: bump ruff version                     <- maintenance
```

```bash
git add .
git commit -m "feat: add export button to report page"
```

If the format is wrong, the pre-commit hook rejects it and tells you why.
Unsure? Run `cz commit` instead — it asks you questions and builds the
message for you.

### D.4 Push and open a Merge Request

```bash
git push -u origin feature/JIRA-123-my-first-change
```

The push output contains a link — click it to open the MR in GitLab.
**Make the MR title follow the same format** (`feat: add export button…`)
— because we squash-merge, the MR title becomes the commit on main, and
that's what the release robot reads.

The MR pipeline runs (~3 min): commit format check, lint, type check, unit
tests. Green + one approval from a reviewer → click **Merge**.

### D.5 What happens after merge (you do nothing)

The pipeline builds a Docker image, scans it, pushes it to JFrog, and
deploys it to the **dev environment** automatically. A few minutes after
merging, open the dev URL and see your feature live. That's the whole
cycle — you never touched Docker, JFrog, or a server.

---

## Part E — Quick reference

```bash
# every new terminal
source .venv/bin/activate

# daily commands
make dev              # run the app locally (hot reload)
make test             # exactly what the MR pipeline checks
pytest tests/unit -x  # fast test loop while coding
make docker-run       # (rare) test the real container

# git flow
git checkout main && git pull && git checkout -b feature/x
git commit -m "feat: ..."      # strict format, hook enforces it
git push -u origin feature/x   # then open MR, title in same format
```

### When things go wrong

| Symptom | Likely cause |
|---|---|
| `ModuleNotFoundError: app` | venv not activated, or `pip install -e ".[dev]"` not run |
| `pip install` fails to find packages | `~/.pip/pip.conf` missing (A.4) |
| Commit rejected with message about format | Message doesn't start with `feat:`/`fix:`/etc — see D.3 |
| App starts but LLM calls fail | `.env` missing or stale — redo A.7 |
| Tests pass locally, MR pipeline red | You ran `pytest` but not full `make test` (lint/mypy failed) |
| VS Code doesn't find tests | Wrong interpreter selected — see B.2 |

And the universal rule: **stuck for more than 20 minutes → ask.** Every
person on the team was set up by this guide and got stuck somewhere; the
guide improves every time someone asks a question it didn't answer — so
when that happens, your first MR can be `docs: clarify setup step X`.
