#!/usr/bin/env bash
# The application road for the agenda parser (Lab 7, Step 4): build the image
# (Dockerfile stage `ai`), push it to ECR, and point the existing function at
# it. The function, its role, URL and budget are Terraform's (infra/ai.tf);
# this script creates nothing, it only ships code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ -f "${ENV_FILE}" ]]; then
  preset="$(export -p)"
  set -a
  # shellcheck disable=SC1091
  source "${ENV_FILE}"
  set +a
  eval "${preset}"
fi
for var in AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
  [[ -n "${!var:-}" ]] || unset "${var}"
done

PROJECT_NAME="${PROJECT_NAME:-spry}"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
FUNCTION="${PROJECT_NAME}-agenda-parser"
REPO="${FUNCTION}"

command -v docker >/dev/null || die "docker is required"
docker info >/dev/null 2>&1 || die "docker is not running - start Docker Desktop"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "no usable AWS credentials"
aws lambda get-function --function-name "${FUNCTION}" >/dev/null 2>&1 \
  || die "${FUNCTION} does not exist - the infrastructure comes from HCP Terraform (infra/)"

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
TAG="$(git -C "${ROOT}" rev-parse --short=12 HEAD 2>/dev/null || echo manual)-$(date -u +%H%M%S)"
IMAGE_URI="${REGISTRY}/${REPO}:${TAG}"

log "building ${IMAGE_URI}"
aws ecr get-login-password | docker login --username AWS --password-stdin "${REGISTRY}" >/dev/null
docker buildx build --platform linux/arm64 --target ai \
  --provenance=false --sbom=false --tag "${IMAGE_URI}" --push "${ROOT}/backend"

log "pointing ${FUNCTION} at the new image"
aws lambda update-function-code --function-name "${FUNCTION}" --image-uri "${IMAGE_URI}" >/dev/null
aws lambda wait function-updated-v2 --function-name "${FUNCTION}"

URL="$(aws lambda get-function-url-config --function-name "${FUNCTION}" --query FunctionUrl --output text)"
URL="${URL%/}"
KEY=PARSER_URL VALUE="${URL}" ENV_FILE="${ENV_FILE}" python3 - <<'PY'
import os, re
key, value, path = os.environ["KEY"], os.environ["VALUE"], os.environ["ENV_FILE"]
lines = open(path).read().splitlines() if os.path.exists(path) else []
for i, line in enumerate(lines):
    if re.match(rf"^{key}=", line):
        lines[i] = f"{key}={value}"
        break
else:
    lines.append(f"{key}={value}")
open(path, "w").write("\n".join(lines) + "\n")
PY

echo
echo "  parser   ${URL}"
echo "  image    ${IMAGE_URI}"
echo
echo "The model and every other setting live in infra/ (PARSER_MODEL -> parser_model)."
