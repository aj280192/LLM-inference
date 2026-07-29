# syntax=docker/dockerfile:1
# =============================================================================
# Multi-stage build:
#   Stage 1 "builder"  — has compilers/build tools, installs deps into a venv
#   Stage 2 "runtime"  — clean slim image; copies ONLY the venv + app code
#
# Result: no gcc/build tooling, no pip cache, and no trace of the netrc
# secret in the shipped image. Final image is typically 30-60% smaller.
#
# Both stages pull from the internal registry mirror (never docker.io direct).
# =============================================================================
ARG DOCKER_REGISTRY=artifactory.internal.corp/docker-remote

# ---------------------------------------------------------------------------
# Stage 1: builder
# ---------------------------------------------------------------------------
FROM ${DOCKER_REGISTRY}/python:3.11-slim AS builder

# Build-time proxy + internal pip mirror (build-args exist ONLY in this stage;
# nothing here reaches the runtime image)
ARG http_proxy=""
ARG https_proxy=""
ARG no_proxy=""
ARG PIP_INDEX_URL=""
ARG PIP_TRUSTED_HOST=""

ENV PIP_NO_CACHE_DIR=1

# Compilers/headers needed to build wheels with C extensions.
# These NEVER ship to production — they live only in this stage.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc \
    && rm -rf /var/lib/apt/lists/*

# Install everything into an isolated venv — this single directory is the
# only thing the runtime stage will copy across.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
# Artifactory pip credentials arrive as a BuildKit SECRET: mounted only for
# this RUN, never written to any layer of any stage.
RUN --mount=type=secret,id=netrc,target=/root/.netrc \
    pip install \
        ${PIP_INDEX_URL:+--index-url "$PIP_INDEX_URL"} \
        ${PIP_TRUSTED_HOST:+--trusted-host "$PIP_TRUSTED_HOST"} \
        -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: runtime — starts FRESH from the slim base
# ---------------------------------------------------------------------------
FROM ${DOCKER_REGISTRY}/python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# curl only for the container HEALTHCHECK; drop it if you healthcheck in python
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# The one COPY that makes multi-stage work: bring over ONLY the ready-made venv
COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY src/ ./src/
COPY prompts/ ./prompts/

# Non-root user — containers never run as root
RUN useradd --uid 10001 --no-create-home appuser
USER appuser

# NOTE: no proxy ENV baked into this image. If the app needs a runtime proxy
# to reach the LLM provider, pass HTTP(S)_PROXY via the Vault-rendered env
# file — that keeps proxy creds rotatable like any other secret.

EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD curl -sf http://127.0.0.1:8080/health || exit 1

CMD ["python", "-m", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
