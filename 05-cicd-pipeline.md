# 5. The CI/CD Pipeline, Step by Step

## 5.0 One-line flow

```
MR -> white-box tests (source) -> merge -> build + publish (scratch)
   -> deploy dev -> auto-tag release -> [tag pipeline] promote staging
   -> deploy int -> black-box e2e -> [manual] promote stable
   -> [manual] deploy prod -> smoke (auto-rollback on fail)
```

One image, built once, promoted by digest. Scanning is enforced **by JFrog at
promotion time**, not by a pipeline scan job (see 5.6).

## 5.1 Runner topology (shell executors)

| Runner tag | Lives | Runs |
|---|---|---|
| `build` | Dedicated build box (docker, jf CLI, python) | lint, tests, build, publish, promote, release |
| `dev` / `int` / `prod` | On that environment's VM | deploy + rollback jobs (compose on localhost — no SSH) |

`resource_group:` per environment prevents interleaved deploys.

## 5.2 Stages

```yaml
stages:
  - validate          # commit-lint (MR only)
  - test              # white-box: unit + AppTest + integration
  - evaluate          # white-box: AI evals (gated — see doc 4)
  - build
  - publish           # push scratch + wait-for-scan
  - deploy-dev
  - release           # semantic-release tags -> triggers tag pipeline
  - promote-staging   # tag pipeline from here down
  - deploy-int
  - e2e-int
  - promote-stable    # manual
  - deploy-prod       # manual
  - smoke-prod
```

## 5.3 MR pipeline (feature branches)

```yaml
commit-lint:
  stage: validate
  tags: [build]
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
  script:
    - cz check --rev-range origin/main..HEAD

lint:
  stage: test
  tags: [build]
  script:
    - pip install --quiet ruff mypy bandit
    - ruff check .
    - mypy app/
    - bandit -r app/ -ll

unit-test:
  stage: test
  tags: [build]
  script:
    - pip install -e ".[dev]"
    - pytest tests/unit tests/streamlit_apptest -m "not integration" \
        --junitxml=report.xml --cov=app
  artifacts:
    when: always
    reports: { junit: report.xml }
```

## 5.4 Main pipeline: build → publish → deploy dev

```yaml
build-image:
  stage: build
  tags: [build]
  script:
    - export VERSION=${CI_COMMIT_TAG:-0.0.0-rc.$CI_PIPELINE_IID-$CI_COMMIT_SHORT_SHA}
    - echo "VERSION=$VERSION" > build.env
    - docker build --build-arg APP_VERSION=$VERSION \
        -t $DOCKER_REGISTRY/$SCRATCH_REPO/$IMAGE_NAME:$VERSION .
    - jf rt build-collect-env reportapp-build $CI_PIPELINE_ID
    - jf rt build-add-git reportapp-build $CI_PIPELINE_ID
  artifacts:
    reports: { dotenv: build.env }     # exposes $VERSION downstream

publish-scratch:
  stage: publish
  tags: [build]
  needs: [build-image]
  script:
    - docker push $DOCKER_REGISTRY/$SCRATCH_REPO/$IMAGE_NAME:$VERSION
    - jf rt build-publish reportapp-build $CI_PIPELINE_ID

# Xray scanning is ASYNC after push — wait for it to finish before any
# promotion can be attempted. This job does NOT enforce severity.
wait-for-scan:
  stage: publish
  tags: [build]
  needs: [publish-scratch]
  script:
    - jf rt build-scan reportapp-build $CI_PIPELINE_ID --fail=false --vuln

deploy-dev:
  stage: deploy-dev
  tags: [dev]
  needs: [wait-for-scan]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  environment: { name: dev }
  script:
    - export IMAGE="$DOCKER_REGISTRY/$SCRATCH_REPO/$IMAGE_NAME:$VERSION"
    - ./ci/deploy.sh dev "$IMAGE" "$VERSION"
```

`deploy.sh` records the previously running version, deploys, polls `/readyz`,
and auto-rolls-back if the app never turns healthy (doc 6).

## 5.5 Release job → tag pipeline

```yaml
release:
  stage: release
  tags: [build]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  variables: { GIT_DEPTH: 0 }
  script:
    - pip install --quiet python-semantic-release
    - git remote set-url origin "https://release-bot:${RELEASE_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
    - semantic-release version --push
```

The pushed tag (e.g. `v1.5.0`) starts a **new pipeline** where
`$CI_COMMIT_TAG` matches `/^v\d+\.\d+\.\d+$/` — the promotion pipeline.

## 5.6 Scanning enforcement: JFrog policy at promotion

Configured once in Xray (Watch on `docker-scratch-local` + Security Policy),
**not** in CI YAML:

| Severity | Policy action | Pipeline behavior |
|---|---|---|
| Critical | Block | `build-promote` fails non-zero → job red → release stops |
| High | Require approval (Release Bundle v2) | Promote is held server-side; job detects it, prints the approval URL, exits 1; approver approves in JFrog → **retry the job** (cheap — nothing rebuilds) |
| Medium | Notify | Promotion succeeds; warning lives in the build's Xray report |

This is governance, so it belongs in JFrog: security can change thresholds
without touching CI. Exceptions ("ship now, patch in 7 days") are Xray
ignore-rules with an expiry date and approver — never disable scanning.

> **Check with your JFrog admin:** Release Bundle v2 approval is a
> Distribution feature not on all license tiers. If unavailable, the fallback
> is a conditionally-generated manual approval job via child pipelines
> (GitLab 14.x can't otherwise show a job based on runtime scan output).

```yaml
promote-staging:
  stage: promote-staging
  tags: [build]
  needs: [wait-for-scan]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
  script:
    - export VERSION=${CI_COMMIT_TAG#v}
    - |
      if ! jf rt build-promote reportapp-build $CI_PIPELINE_ID $STAGING_REPO --copy=true 2> promote-error.log; then
        if grep -qi "pending approval" promote-error.log; then
          echo "High-severity CVE - promotion pending approval in JFrog:"
          echo "  $JFROG_URL/ui/bundles/${IMAGE_NAME}/${VERSION}"
          exit 1     # approve in JFrog, then Retry this job
        fi
        cat promote-error.log; exit 1   # critical CVE or real error
      fi
    - jf rt docker-promote $IMAGE_NAME $SCRATCH_REPO $STAGING_REPO \
        --source-tag=$SRC_TAG --target-tag=$VERSION --copy=true
```

Promotion notes: promote by **digest** (never mutable tag), make target repos
immutable, make the job idempotent (same digest already there → succeed;
different digest under same tag → hard fail loudly).

## 5.7 Int: deploy + black-box e2e

```yaml
deploy-int:
  stage: deploy-int
  tags: [int]
  needs: [promote-staging]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
  environment: { name: int }
  script:
    - export VERSION=${CI_COMMIT_TAG#v}
    - ./ci/deploy.sh int "$DOCKER_REGISTRY/$STAGING_REPO/$IMAGE_NAME:$VERSION" "$VERSION"

e2e-int:
  stage: e2e-int
  tags: [int]
  needs: [deploy-int]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
  variables: { BASE_URL: "http://localhost:8501" }
  script:
    - ./ci/run-e2e.sh e2e        # throwaway Playwright container (doc 4)
  artifacts:
    when: always
    reports: { junit: tests/report.xml }
```

## 5.8 Prod: manual gates, smoke, auto-rollback

```yaml
promote-stable:
  stage: promote-stable
  tags: [build]
  needs: [e2e-int]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
      when: manual
  environment: { name: prod-approval }   # protected env = only leads can click
  script:
    - export VERSION=${CI_COMMIT_TAG#v}
    - jf rt docker-promote $IMAGE_NAME $STAGING_REPO $STABLE_REPO \
        --source-tag=$VERSION --target-tag=$VERSION --copy=true
    - jf rt docker-promote $IMAGE_NAME $STAGING_REPO $STABLE_REPO \
        --source-tag=$VERSION --target-tag=stable --copy=true

deploy-prod:
  stage: deploy-prod
  tags: [prod]
  needs: [promote-stable]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
      when: manual
  environment: { name: prod }
  script:
    - export VERSION=${CI_COMMIT_TAG#v}
    - ./ci/deploy.sh prod "$DOCKER_REGISTRY/$STABLE_REPO/$IMAGE_NAME:$VERSION" "$VERSION"

smoke-prod:
  stage: smoke-prod
  tags: [prod]
  needs: [deploy-prod]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
  variables: { BASE_URL: "https://reportapp.company.com" }
  script:
    - ./ci/run-e2e.sh smoke              # login-only
  after_script:
    - |
      if [ "$CI_JOB_STATUS" == "failed" ]; then
        echo "Smoke failed - rolling back prod"
        ./ci/rollback.sh prod
      fi

smoke-prod-full-query:
  stage: smoke-prod
  tags: [prod]
  needs: [smoke-prod]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
  allow_failure: true                    # LLM hiccup never blocks a release
  script:
    - ./ci/run-e2e.sh smoke-full
```

## 5.9 Manual rollback buttons (always available on tag pipelines)

```yaml
rollback-prod:
  stage: deploy-prod
  tags: [prod]
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'
      when: manual
  environment: { name: prod }
  script:
    - ./ci/rollback.sh prod
# (identical rollback-int job on the int VM)
```

For "it looked healthy but broke 20 minutes later." Same script as the
automatic path — **exactly one rollback code path.**

## 5.10 Full working files

The complete `.gitlab-ci.yml`, `ci/deploy.sh`, `ci/rollback.sh`,
`ci/run-e2e.sh`, and `docker-compose.example.yml` were generated earlier in
this project — deploy/rollback internals are documented in doc 6.
