#!/usr/bin/env bash
set -euo pipefail

echo "[entrypoint] applying migrations..."
alembic upgrade head

echo "[entrypoint] starting uvicorn..."
exec uvicorn app.main:app \
  --host 0.0.0.0 \
  --port "${PORT:-8000}" \
  --log-level "${LOG_LEVEL:-info}"
