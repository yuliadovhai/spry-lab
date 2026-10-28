#!/usr/bin/env bash
# Put a custom domain, with HTTPS, on the deployed frontend's CloudFront
# distribution. Only the frontend gets a custom domain - the API stays on its
# Lambda function URL - and it is assigned here, separately from
# `make deploy-frontend`, which never touches the domain settings.
#
#   scripts/domain-frontend.sh cert     request + DNS-validate an ACM certificate
#   scripts/domain-frontend.sh domain   the above, then attach it to the distribution
#
# Both are idempotent: an existing certificate for the domain is reused rather
# than re-requested, and re-running after DNS is in place just re-checks.
set -euo pipefail

MODE="${1:-domain}"
case "${MODE}" in
  cert | domain) ;;
  *) echo "usage: $0 [cert|domain]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
TEMPLATE="${ROOT}/infra/frontend.yaml"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ -f "${ENV_FILE}" ]]; then
  # Variables already exported win over .env: `AWS_REGION=eu-central-1 make x`
  # must not be quietly reset to the region .env names.
  preset="$(export -p)"
  set -a
  # shellcheck disable=SC1091
  source "${ENV_FILE}"
  set +a
  eval "${preset}"
fi

# A blank AWS_PROFILE is read as a profile literally named "", and blank keys
# short-circuit the credential chain. Treat empty as absent.
for var in AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
  [[ -n "${!var:-}" ]] || unset "${var}"
done

PROJECT_NAME="${PROJECT_NAME:-spry}"
STACK_NAME="${FRONTEND_STACK_NAME:-${PROJECT_NAME}-frontend}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
# CloudFront only takes certificates from us-east-1, whatever the stack region.
ACM_REGION=us-east-1

# `make domain DOMAIN=app.example.com` wins over whatever .env remembers.
DOMAIN="${DOMAIN:-${DOMAIN_NAME:-}}"
DOMAIN="${DOMAIN%.}"
[[ -n "${DOMAIN}" ]] || die "no domain - run: make ${MODE} DOMAIN=app.example.com"

for tool in aws python3; do
  command -v "${tool}" >/dev/null 2>&1 || die "${tool} is required but not installed"
done
aws sts get-caller-identity >/dev/null 2>&1 \
  || die "no usable AWS credentials - set AWS_PROFILE or the AWS_* keys in .env"

# --- helpers ----------------------------------------------------------------

# Rewrite one KEY=VALUE in .env, leaving every other line - credentials very
# much included - exactly as it was.
env_set() {
  KEY="$1" VALUE="$2" ENV_FILE="${ENV_FILE}" python3 - <<'PY'
import os, re

key, value, path = os.environ["KEY"], os.environ["VALUE"], os.environ["ENV_FILE"]
lines = open(path).read().splitlines() if os.path.exists(path) else []
pattern = re.compile(rf"^{re.escape(key)}=")

for i, line in enumerate(lines):
    if pattern.match(line):
        lines[i] = f"{key}={value}"
        break
else:
    lines.append(f"{key}={value}")

open(path, "w").write("\n".join(lines) + "\n")
PY
  log "wrote ${1} to .env"
}

# The zone for app.example.com is example.com: walk the labels and keep the
# longest public zone that the domain actually sits under.
find_hosted_zone() {
  DOMAIN="${DOMAIN}" python3 - <<'PY'
import json, os, subprocess

domain = os.environ["DOMAIN"]
out = subprocess.run(
    ["aws", "route53", "list-hosted-zones", "--output", "json"],
    capture_output=True, text=True,
)
if out.returncode != 0:
    raise SystemExit(0)

best = None
for zone in json.loads(out.stdout).get("HostedZones", []):
    if zone.get("Config", {}).get("PrivateZone"):
        continue
    name = zone["Name"].rstrip(".")
    if domain == name or domain.endswith("." + name):
        if best is None or len(name) > len(best[1]):
            best = (zone["Id"].split("/")[-1], name)

if best:
    print(best[0], best[1])
PY
}

stack_output() {
  aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text 2>/dev/null || true
}

# --- hosted zone ------------------------------------------------------------

ZONE_ID=""
ZONE_NAME=""
read -r ZONE_ID ZONE_NAME <<<"$(find_hosted_zone)" || true

if [[ -n "${ZONE_ID}" ]]; then
  log "${DOMAIN} sits in the Route 53 zone ${ZONE_NAME} (${ZONE_ID})"
else
  warn "no Route 53 zone covers ${DOMAIN} - you will add DNS records by hand"
fi

# --- certificate ------------------------------------------------------------

CERT_ARN="$(aws acm list-certificates --region "${ACM_REGION}" \
  --certificate-statuses PENDING_VALIDATION ISSUED \
  --query "CertificateSummaryList[?DomainName=='${DOMAIN}']|[0].CertificateArn" \
  --output text 2>/dev/null || true)"

if [[ -z "${CERT_ARN}" || "${CERT_ARN}" == "None" ]]; then
  log "requesting an ACM certificate for ${DOMAIN} in ${ACM_REGION}"
  CERT_ARN="$(aws acm request-certificate --region "${ACM_REGION}" \
    --domain-name "${DOMAIN}" \
    --validation-method DNS \
    --key-algorithm RSA_2048 \
    --tags "Key=PROJECT_NAME,Value=${PROJECT_NAME}" \
    --query CertificateArn --output text)"
else
  log "reusing the certificate already issued for ${DOMAIN}"
fi

CERT_STATUS="$(aws acm describe-certificate --region "${ACM_REGION}" --certificate-arn "${CERT_ARN}" \
  --query Certificate.Status --output text)"

if [[ "${CERT_STATUS}" != "ISSUED" ]]; then
  # ACM takes a moment to publish the record it wants to see.
  RECORD=""
  for _ in $(seq 1 12); do
    RECORD="$(aws acm describe-certificate --region "${ACM_REGION}" --certificate-arn "${CERT_ARN}" \
      --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Type,Value]" \
      --output text 2>/dev/null || true)"
    [[ -n "${RECORD}" && "${RECORD}" != *"None"* ]] && break
    sleep 5
  done
  [[ -n "${RECORD}" && "${RECORD}" != *"None"* ]] \
    || die "ACM did not publish a validation record for ${DOMAIN}"

  read -r RECORD_NAME RECORD_TYPE RECORD_VALUE <<<"${RECORD}"

  if [[ -n "${ZONE_ID}" ]]; then
    log "adding the validation record to Route 53"
    CHANGE_FILE="$(mktemp)"
    trap 'rm -f "${CHANGE_FILE}"' EXIT
    cat >"${CHANGE_FILE}" <<JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{
  "Name":"${RECORD_NAME}","Type":"${RECORD_TYPE}","TTL":300,
  "ResourceRecords":[{"Value":"${RECORD_VALUE}"}]}}]}
JSON
    aws route53 change-resource-record-sets \
      --hosted-zone-id "${ZONE_ID}" \
      --change-batch "file://${CHANGE_FILE}" >/dev/null
  else
    echo
    echo "  Add this record wherever ${DOMAIN} is hosted, then leave this running:"
    echo
    echo "    name   ${RECORD_NAME}"
    echo "    type   ${RECORD_TYPE}"
    echo "    value  ${RECORD_VALUE}"
    echo
  fi

  log "waiting for ACM to validate ${DOMAIN} (minutes, once DNS propagates)"
  for _ in $(seq 1 120); do
    CERT_STATUS="$(aws acm describe-certificate --region "${ACM_REGION}" --certificate-arn "${CERT_ARN}" \
      --query Certificate.Status --output text)"
    case "${CERT_STATUS}" in
      ISSUED) break ;;
      PENDING_VALIDATION) printf '.' ; sleep 15 ;;
      *) echo; die "certificate ended up ${CERT_STATUS} - see ACM in the console" ;;
    esac
  done
  echo
fi

[[ "${CERT_STATUS}" == "ISSUED" ]] \
  || die "gave up waiting - DNS is probably not published yet, re-run when it is"

log "certificate issued"
# Only the domain is remembered. The zone and the certificate are looked up
# again on every run, so neither needs to live in .env.
env_set DOMAIN_NAME "${DOMAIN}"

if [[ "${MODE}" == "cert" ]]; then
  echo
  echo "Certificate ready. Attach it with: make domain"
  exit 0
fi

# --- attach -----------------------------------------------------------------

# Only the domain parameters change; every other parameter keeps the stack's
# current value, and the site itself is not rebuilt.
aws cloudformation describe-stacks --stack-name "${STACK_NAME}" >/dev/null 2>&1 \
  || die "stack ${STACK_NAME} does not exist yet - run make deploy-frontend first"

log "attaching ${DOMAIN} to the distribution (CloudFront takes a few minutes)"
if ! aws cloudformation deploy \
  --stack-name "${STACK_NAME}" \
  --template-file "${TEMPLATE}" \
  --parameter-overrides \
    "DomainName=${DOMAIN}" \
    "AcmCertificateArn=${CERT_ARN}" \
    "HostedZoneId=${ZONE_ID}" \
  --no-fail-on-empty-changeset \
  --tags "PROJECT_NAME=${PROJECT_NAME}"; then
  warn "deploy failed - most recent failure reasons:"
  aws cloudformation describe-stack-events --stack-name "${STACK_NAME}" \
    --max-items 40 \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`||ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
    --output table >&2 || true
  exit 1
fi

TARGET="$(stack_output DistributionDomainName)"

if [[ -z "${ZONE_ID}" ]]; then
  echo
  if [[ "${DOMAIN}" == *.*.* ]]; then
    echo "  Last step - point ${DOMAIN} at CloudFront:"
    echo
    echo "    name   ${DOMAIN}"
    echo "    type   CNAME"
    echo "    value  ${TARGET}"
  else
    echo "  Last step - point ${DOMAIN} at ${TARGET}."
    warn "${DOMAIN} is a zone apex, which cannot be a CNAME. Either move the"
    warn "zone to Route 53 and re-run, or use your provider's ALIAS/ANAME record."
  fi
  echo
fi

echo "  https://${DOMAIN} - the cloudfront.net name keeps working too"
echo
echo "Let the API accept the new origin:"
echo
echo "  API_CORS_ORIGINS=https://${DOMAIN}   in .env, then: make deploy-backend"
