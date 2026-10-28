#!/usr/bin/env bash
# Tear the backend stack down: the Lambda function, its URL and the Aurora
# cluster. Idle, only Aurora's storage still bills - this stops that too.
#
# The database goes with it: the stack sets DeletionPolicy Delete. A function
# in a VPC leaves network interfaces behind that Lambda releases on its own
# schedule, so the delete can sit for a while on the security groups.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ -f "${ROOT}/.env" ]]; then
  # Variables already exported win over .env: `AWS_REGION=eu-central-1 make x`
  # must not be quietly reset to the region .env names.
  preset="$(export -p)"
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
  eval "${preset}"
fi

# A blank AWS_PROFILE is read as a profile literally named "", and blank keys
# short-circuit the credential chain - which is exactly what a .env full of
# empty placeholders hands us. Treat empty as absent.
for var in AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
  [[ -n "${!var:-}" ]] || unset "${var}"
done

PROJECT_NAME="${PROJECT_NAME:-spry}"
STACK_NAME="${STACK_NAME:-${PROJECT_NAME}-backend}"
ECR_REPOSITORY="${ECR_REPOSITORY:-${PROJECT_NAME}-backend}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

command -v aws >/dev/null 2>&1 || die "aws cli is required"
aws cloudformation describe-stacks --stack-name "${STACK_NAME}" >/dev/null 2>&1 \
  || die "stack ${STACK_NAME} does not exist in ${AWS_REGION}"

if [[ "${FORCE:-0}" != "1" ]]; then
  echo "This deletes stack ${STACK_NAME} in ${AWS_REGION}, including the"
  echo "${PROJECT_NAME}-db Aurora cluster and everything in it."
  read -r -p "Type the stack name to confirm: " reply
  [[ "${reply}" == "${STACK_NAME}" ]] || die "aborted"
fi

log "deleting ${STACK_NAME} (a few minutes)"
aws cloudformation delete-stack --stack-name "${STACK_NAME}"
aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}"

# Secrets Manager schedules deletions instead of doing them, and the name stays
# taken for the whole recovery window - which would block the next deploy.
SECRET_NAME="${PROJECT_NAME}/backend/database-url"
if aws secretsmanager describe-secret --secret-id "${SECRET_NAME}" >/dev/null 2>&1; then
  log "force-deleting the ${SECRET_NAME} secret so the name is free again"
  aws secretsmanager delete-secret --secret-id "${SECRET_NAME}" \
    --force-delete-without-recovery >/dev/null
fi

if [[ "${KEEP_IMAGES:-0}" != "1" ]]; then
  if aws ecr describe-repositories --repository-names "${ECR_REPOSITORY}" >/dev/null 2>&1; then
    log "deleting the ${ECR_REPOSITORY} ECR repository"
    aws ecr delete-repository --repository-name "${ECR_REPOSITORY}" --force >/dev/null
  fi
fi

log "done - nothing from this stack is still billing"
