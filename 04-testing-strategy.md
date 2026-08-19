# 4. Testing Strategy for a Streamlit AI App

## 4.1 What a test is

A small program that runs part of your app and checks the result — written
once, repeated by the machine in seconds on every change. In the pipeline,
**tests are the gate**: no merge and no promotion without green.

## 4.2 The pyramid

```
        /  E2E / Smoke \       few, slow, real browser vs deployed app
       /  Integration   \      some, medium, real DB (throwaway)
      /  Unit + AppTest   \    many, fast, mocked, every MR
```

Write lots of cheap unit tests, fewer integration tests, very few e2e tests.

## 4.3 The critical split: white-box vs black-box

| | White-box | Black-box |
|---|---|---|
| Imports `app.src`? | **Yes** | Never |
| Needs | Source checkout + `pip install -e ".[dev]"` | Only a URL of a running deployment |
| Types | unit, integration, evaluation | e2e, smoke |
| Runs | `build` runner, **before** the image exists | Playwright container, **after** deploy |
| Pipeline stage | `test` / `evaluate` | `e2e-int` / `smoke-prod` |

**Rule of thumb:** a test starting with `from app.src import ...` is
white-box → `test`/`evaluate` stage. A test starting with `page.goto(...)` is
black-box → runs against a deployed environment.

Folder layout:

```
tests/
  unit/               white-box, everything mocked
  streamlit_apptest/  white-box, Streamlit AppTest
  integration/        white-box, real throwaway DB
  evaluation/         white-box, real/sandbox LLM, golden dataset
  e2e/                black-box, full flows vs int
  smoke/              black-box, minimal checks vs prod
```

Make `app.src` importable with a `pyproject.toml` and `pip install -e ".[dev]"`
— identical behavior in CI, on laptops, and in the Docker builder stage.

## 4.4 Unit tests (pytest)

**Design prerequisite — the most important habit:** keep the Streamlit file
thin. Business logic (prompt building, transforms, parsing LLM responses)
lives in plain modules that tests can import; `streamlit_app.py` just calls
them.

```python
# tests/unit/test_utils.py
from app.utils import clean_prompt

def test_strips_whitespace():
    assert clean_prompt("  hello  ") == "hello"

def test_truncates_long_input():
    assert clean_prompt("x" * 5000) == "x" * 2000
```

## 4.5 Mocking external services

Unit tests must never call the real LLM/DB/Splunk — slow, costly, needs
secrets, non-deterministic. Use a fake:

```python
from unittest.mock import Mock
from app.llm import summarize

def test_summarize_strips_response():
    fake = Mock()
    fake.complete.return_value = Mock(text="  A summary.  ")
    assert summarize(fake, "long article") == "A summary."
    fake.complete.assert_called_once()
```

Design consequence: pass clients *into* functions (dependency injection) so
fakes are easy to inject.

## 4.6 Streamlit AppTest — headless UI tests

Catches what unit tests can't: missing widgets, session_state breakage, app
crashing on startup. Fast enough for every MR.

```python
from streamlit.testing.v1 import AppTest

def test_app_renders_and_responds(monkeypatch):
    monkeypatch.setattr("app.llm.summarize", lambda c, t: "fake summary")
    at = AppTest.from_file("streamlit_app.py").run()
    at.text_input[0].set_value("some article").run()
    at.button[0].click().run()
    assert "fake summary" in at.markdown[-1].value
    assert not at.exception
```

## 4.7 Integration tests — real throwaway DB

```yaml
integration-test:
  stage: test
  tags: [build]
  services:
    - postgres:15
  variables:
    DATABASE_URL: "postgresql://test:test@postgres/testdb"
  script:
    - pip install -e ".[dev]"
    - pytest tests/integration -m integration
```

Separate with `@pytest.mark.integration` so unit runs stay fast.

## 4.8 AI evaluation tests — regression testing for prompts

LLM output is non-deterministic; never assert exact strings. Instead:

1. **Contract tests** — assert shape: valid JSON with keys x,y; under 500
   chars; never empty
2. **Golden dataset evals** — 20–50 inputs with expected properties; score
   via exact-match / keyword presence / LLM-as-judge. Without this,
   "I improved the prompt" is a guess
3. **Guardrail tests** — adversarial inputs (prompt injection, huge/empty
   input, non-English) must fail gracefully, never crash or leak the system
   prompt
4. **Track in MLflow** — prompt version, model, scores per release

Gated separately (own `evaluate` stage) because evals are slow and burn real
tokens:

```yaml
evaluation-test:
  stage: evaluate
  tags: [build]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'   # every release
    - changes:                                       # or when prompts change
        - app/src/prompts/**
        - app/src/llm/**
  script:
    - export VAULT_TOKEN=$(vault write -field=token auth/jwt/login role=reportapp-ci jwt=$CI_JOB_JWT)
    - export LLM_API_KEY=$(vault kv get -field=api_key secret/reportapp/ci-eval)
    - pip install -e ".[dev]"
    - pytest tests/evaluation --junitxml=eval-report.xml
```

Separate stage also gives clear failure attribution: red at `test` = code
bug; red at `evaluate` = output-quality regression — often different owners.

## 4.9 E2E with Playwright — black-box, separate image

**Never bundle Playwright into the app image**: ~1GB of browsers, more CVE
surface, not a runtime dependency, different release cadence. Playwright is
just an automated browser — a *client* like a user's Chrome. It needs only
HTTP access to a URL, which is exactly why it verifies the real deployed
artifact from the outside.

With shell runners, run the official image as a throwaway container:

```bash
# ci/run-e2e.sh
docker run --rm --memory=512m --cpus=0.5 \
  -v "$(pwd)/tests:/tests" -w /tests \
  mcr.microsoft.com/playwright/python:v1.47.0-jammy \
  pytest "$1" --base-url="$BASE_URL" --junitxml=/tests/report.xml
```

- Image tag pins Playwright + browser versions — update deliberately
- Resource limits stop the test container starving the app on the same VM
- Cleaner alternative for prod: run smoke from a separate small "qa"/build
  runner with HTTPS access to the prod hostname, so the prod VM only ever
  runs the app itself
- Test code lives in the app repo (versioned with the code it tests); pin
  the Playwright pip version to match the image tag

## 4.10 E2E on int vs smoke on prod

**Full e2e belongs on int, not prod**, because prod tests: create real data
(junk in DB, fake Splunk events, paid LLM calls), can cause real side
effects, are too late (image already deployed), and fight real SSO/rate
limits/alerting.

**Int** (full flow, blocking): service account logs in → submits real query →
LLM responds → result renders → optionally verify int-DB row.

**Prod** (after every deploy):

1. **Login-only smoke (blocking, auto-rollback on fail)** — covers DNS, TLS,
   proxy routing, container up, SSO wiring, session handling, UI renders past
   auth. Exactly the things that break *at deployment time*.
2. **One full query (non-blocking, `allow_failure: true`)** — synthetic
   monitoring; alerts but never rolls back a healthy deploy on a transient
   LLM provider hiccup.

### Service-account hygiene for the prod query

- Recognizable name (`svc-e2e-reportapp`); exclude from analytics and
  "active users" metrics
- Least privilege — normal user role, never admin
- Prod credential in Vault under the prod path; different credential from int
- Cleanup: test deletes its own conversation, or a periodic job removes
  `svc-e2e` rows older than N days
- Tag its Splunk/MLflow events so ops dashboards can filter it out
- MFA/captcha: exempt only this account, only from the runner's IP —
  never weaken auth globally
- If the smoke query fails, that should alert — real users are likely
  failing too

## 4.11 Static checks (cheapest, run first)

| Tool | Catches |
|---|---|
| ruff | Lint errors, style |
| mypy | Type errors |
| bandit | Security mistakes in code (hardcoded secrets, unsafe calls) |
| pip-audit | Known-CVE dependencies (complements Xray) |

## 4.12 What runs when

| Trigger | Runs |
|---|---|
| Feature MR | commit-lint, ruff/mypy/bandit, unit + AppTest |
| Merge to main | + integration, build/scan/publish, deploy-dev |
| Release tag | + evaluation, deploy-int, full e2e, smoke after prod |
| Nightly schedule | evals + full e2e (catch provider drift without slowing MRs) |

Track **coverage** (`pytest --cov`) — don't chase 100%, but 0% on the
prompt-building module is a red flag.

### Starting from zero, in order
1. Make the Streamlit file thin; move logic into modules
2. 10–15 unit tests with mocked LLM/DB
3. A couple of AppTest smoke tests
4. Wire pytest into the MR pipeline (nothing merges without green)
5. Then integration → e2e → evals, each once the previous is habit

### Flaky tests — the #1 pipeline killer
Mock all network in unit tests, use `pytest-randomly`, quarantine
known-flaky tests with a marker and fix them weekly. Never let
retry-until-green become culture.
