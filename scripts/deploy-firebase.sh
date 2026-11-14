#!/usr/bin/env bash
# Lab 9: build the static export and put it on Firebase Hosting.
#
# Two modes, chosen by GCP_API_MODE in .env:
#   aws      (default) the bundle calls the API on AWS (BACKEND_URL). The page is
#            on Google, the data still on AWS - the multicloud state of Lab 9.
#   cloudrun the bundle calls /api on its own origin; Firebase rewrites /api/**
#            to the Cloud Run service (firebase.cloudrun.json). One origin, no CORS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/frontend"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

PROJECT="${GCP_PROJECT_ID:-spry-yulia-2026}"
MODE="${GCP_API_MODE:-aws}"
command -v node >/dev/null 2>&1 || die "node is required"

if [[ "${MODE}" == "cloudrun" ]]; then
  API_URL=""                      # same origin: fetch("/api/v1/...")
  CONFIG="firebase.cloudrun.json"
else
  API_URL="${BACKEND_URL%/}"
  [[ "${API_URL}" == https://* ]] || die "BACKEND_URL (https://...) is not set in .env"
  CONFIG="firebase.json"
fi

if command -v pnpm >/dev/null 2>&1; then PM=(pnpm); else PM=(npx --yes pnpm@10); fi

log "building against ${API_URL:-the same origin (/api -> Cloud Run)}"
(cd "${APP}" && "${PM[@]}" install --frozen-lockfile)
rm -rf "${APP}/out"
(cd "${APP}" && NEXT_OUTPUT=export \
  NEXT_PUBLIC_API_URL="${API_URL}" \
  NEXT_PUBLIC_PARSER_URL="${PARSER_URL:-}" \
  "${PM[@]}" build)
[[ -f "${APP}/out/index.html" ]] || die "the export produced no out/index.html"

log "deploying to Firebase Hosting (project ${PROJECT}, ${CONFIG})"
(cd "${ROOT}" && npx --yes firebase-tools@latest deploy \
  --only hosting --project "${PROJECT}" --config "${CONFIG}")

echo
echo "  site  https://${PROJECT}.web.app"
[[ "${MODE}" == "aws" ]] && echo "  api   ${API_URL}  (add https://${PROJECT}.web.app to API_CORS_ORIGINS, then make deploy-backend)"
