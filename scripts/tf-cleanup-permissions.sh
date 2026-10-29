#!/usr/bin/env bash
# Lab 7, Step 3: after Terraform created its two function URL permissions,
# remove the old statements CloudFormation left on the parser, so that the
# function's policy holds only what infra/ai.tf describes.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-spry}"
FUNCTION="${PROJECT_NAME}-agenda-parser"
KEEP=(SpryFunctionUrlPublic SpryFunctionUrlInvoke)
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

SIDS="$(aws lambda get-policy --function-name "${FUNCTION}" --query Policy --output text \
  | python3 -c 'import json,sys; print("\n".join(s["Sid"] for s in json.load(sys.stdin)["Statement"]))')"

for keep in "${KEEP[@]}"; do
  grep -qx "${keep}" <<<"${SIDS}" \
    || { echo "error: ${keep} is missing - apply the Terraform first" >&2; exit 1; }
done

while read -r sid; do
  [[ -z "${sid}" ]] && continue
  if printf '%s\n' "${KEEP[@]}" | grep -qx "${sid}"; then
    echo "keep    ${sid}"
  else
    aws lambda remove-permission --function-name "${FUNCTION}" --statement-id "${sid}"
    echo "removed ${sid}"
  fi
done <<<"${SIDS}"
