#!/bin/sh
# ============================================================================
# entrypoint.sh — container startup: health sidecar + Streamlit app
#
# Starts the FastAPI health API in the background on port 8000, then execs
# Streamlit as PID 1 on port 8501. `exec` matters: it makes Streamlit the
# main process so docker stop / compose down deliver signals correctly.
# ============================================================================
set -e

uvicorn healthapi:app --host 0.0.0.0 --port 8000 &

exec streamlit run streamlit_app.py \
  --server.port 8501 \
  --server.address 0.0.0.0 \
  --server.headless true
