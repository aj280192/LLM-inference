# syntax=docker/dockerfile:1
# =============================================================================
# Proxy + internal-Artifactory-aware Dockerfile.
#
# - Base image comes from the internal registry mirror (never docker.io direct)
# - pip uses the internal PyPI mirror; auth arrives as a BuildKit SECRET
#   (mounted only during that one RUN — never written to any image layer)
# - Proxy vars are build-args so they exist only at build time, not runtime
# =============================================================================
ARG DOCKER_REGISTRY=artifactory.internal.corp/docker-remote
FROM ${DOCKER_REGISTRY}/python:3.11-slim AS base

# Build-time proxy (passed by CI; empty defaults keep local builds working)
ARG http_proxy=""
ARG https_proxy=""
ARG no_proxy=""
ARG PIP_INDEX_URL=""
ARG PIP_TRUSTED_HOST=""

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
# The netrc secret provides Artifactory credentials to pip for this RUN only.
RUN --mount=type=secret,id=netrc,target=/root/.netrc \
    pip install --no-cache-dir \
        ${PIP_INDEX_URL:+--index-url "$PIP_INDEX_URL"} \
        ${PIP_TRUSTED_HOST:+--trusted-host "$PIP_TRUSTED_HOST"} \
        -r requirements.txt

COPY src/ ./src/
COPY prompts/ ./prompts/

# Non-root user — containers never run as root
RUN useradd --uid 10001 --no-create-home appuser
USER appuser

# IMPORTANT: no proxy ENV in the final image. If the app itself must reach the
# internet via proxy at runtime, pass HTTP(S)_PROXY through the env file from
# Vault instead — keeps proxy creds rotatable like any other secret.

EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')"

CMD ["python", "-m", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
