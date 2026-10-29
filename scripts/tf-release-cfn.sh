#!/usr/bin/env bash
# Lab 7, Step 3a: make CloudFormation let go of the parser's resources without
# deleting them. Redeploys infra/ai.yml (every resource now DeletionPolicy:
# Retain) with the stack's current parameters, checks the policies arrived,
# deletes the stack, and checks the resources are still there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-spry}"
STACK="${PROJECT_NAME}-ai"
FUNCTION="${PROJECT_NAME}-agenda-parser"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

aws cloudformation describe-stacks --stack-name "${STACK}" >/dev/null 2>&1 \
  || die "stack ${STACK} not found - nothing to release"
[[ -f "${ROOT}/infra/imports.tf" ]] \
  || die "run scripts/tf-adopt.sh first: it reads the IDs from the stack"

# Same parameters as now: only the deletion policies change.
# (A while-read loop, not mapfile: macOS ships bash 3.2.)
PARAMS=()
while IFS=$'\t' read -r key value; do
  [[ -n "${key}" ]] && PARAMS+=("${key}=${value}")
done < <(aws cloudformation describe-stacks --stack-name "${STACK}" \
  --query 'Stacks[0].Parameters[].[ParameterKey,ParameterValue]' --output text)

log "redeploying ${STACK} with DeletionPolicy: Retain"
aws cloudformation deploy \
  --stack-name "${STACK}" \
  --template-file "${ROOT}/infra/ai.yml" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --tags "PROJECT_NAME=${PROJECT_NAME}" \
  --parameter-overrides "${PARAMS[@]}"

RETAINED="$(aws cloudformation get-template --stack-name "${STACK}" \
  --query TemplateBody --output text | grep -c 'DeletionPolicy: Retain' || true)"
[[ "${RETAINED}" -ge 7 ]] \
  || die "the deployed template has ${RETAINED} Retain policies, expected 7 - NOT deleting the stack"
log "all 7 resources are marked Retain"

log "deleting the stack ${STACK} (its resources stay)"
aws cloudformation delete-stack --stack-name "${STACK}"
aws cloudformation wait stack-delete-complete --stack-name "${STACK}"

log "checking that the resources survived"
aws lambda get-function --function-name "${FUNCTION}" --query Configuration.FunctionName --output text
aws lambda get-function-url-config --function-name "${FUNCTION}" --query FunctionUrl --output text
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${FUNCTION}" \
  --query 'logGroups[0].logGroupName' --output text
aws budgets describe-budget --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget-name "${PROJECT_NAME}-monthly" --query Budget.BudgetName --output text

echo
echo "The stack is gone and the resources are not. Now: terraform -chdir=infra plan"
