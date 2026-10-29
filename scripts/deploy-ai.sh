#!/usr/bin/env bash
# Build the agenda parser image (Dockerfile `ai` stage), push it to ECR, deploy
# infra/ai.yml, and write PARSER_URL into .env for deploy-frontend.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${ROOT}/infra/ai.yml"
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
STACK_NAME="${PROJECT_NAME}-ai"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
PARSER_MODEL="${PARSER_MODEL:-anthropic.claude-opus-5-5}"
REPO="${PROJECT_NAME}-agenda-parser"

command -v docker >/dev/null || die "docker is required"
docker info >/dev/null 2>&1 || die "docker is not running - start Docker Desktop"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "no usable AWS credentials"

# Origins the browser calls the parser from: the site's domain, its
# cloudfront.net name, and localhost for Compose.
ORIGINS="http://localhost:3000"
[[ -n "${DOMAIN_NAME:-}" ]] && ORIGINS="${ORIGINS},https://${DOMAIN_NAME}"
SITE="$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-frontend" \
  --query "Stacks[0].Outputs[?OutputKey=='SiteUrl'].OutputValue" --output text 2>/dev/null || true)"
[[ -n "${SITE}" && "${SITE}" != "None" ]] && ORIGINS="${ORIGINS},${SITE%/}"
log "allowed origins: ${ORIGINS}"

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
if ! aws ecr describe-repositories --repository-names "${REPO}" >/dev/null 2>&1; then
  log "creating ECR repository ${REPO}"
  aws ecr create-repository --repository-name "${REPO}" \
    --tags "Key=PROJECT_NAME,Value=${PROJECT_NAME}" >/dev/null
fi
TAG="$(git -C "${ROOT}" rev-parse --short=12 HEAD 2>/dev/null || date -u +%Y%m%d%H%M%S)-$(date -u +%H%M%S)"
IMAGE_URI="${REGISTRY}/${REPO}:${TAG}"

log "building ${IMAGE_URI}"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}" >/dev/null
docker buildx build --platform linux/arm64 --target ai \
  --provenance=false --sbom=false --tag "${IMAGE_URI}" --push "${ROOT}/backend"

log "deploying ${STACK_NAME} with ${PARSER_MODEL}"
aws cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${TEMPLATE}" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --tags "PROJECT_NAME=${PROJECT_NAME}" \
  --parameter-overrides \
    "ProjectName=${PROJECT_NAME}" \
    "ImageUri=${IMAGE_URI}" \
    "ParserModel=${PARSER_MODEL}" \
    "AllowedOrigins=${ORIGINS}" \
    "BudgetEmail=${BUDGET_EMAIL:-}" \
  || { aws cloudformation describe-stack-events --stack-name "${STACK_NAME}" --max-items 20 \
         --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' \
         --output table >&2; exit 1; }

URL="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
  --query "Stacks[0].Outputs[?OutputKey=='ParserUrl'].OutputValue" --output text)"
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
echo "  model    ${PARSER_MODEL}"
echo "  logs     make logs-ai"
echo
echo "Next: make deploy-frontend (it compiles PARSER_URL into the site)."
