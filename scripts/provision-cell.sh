#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly TERRAFORM_DIR="${REPO_ROOT}/terraform"
readonly AUDIT_DIR="${REPO_ROOT}/audit"

APPLY=false
CURRENT_ACTION="startup"
FINAL_STATUS="failed"
ACTOR_ARN="unknown"
PLAN_SHA256="not-created"

usage() {
  cat <<'USAGE'
Usage:
  CUSTOMER_ID=customer-001 \
  AWS_REGION=eu-central-1 \
  TIER=enterprise \
  TF_STATE_BUCKET=acme-platform-terraform-state-ACCOUNT_ID \
  TF_LOCK_TABLE=acme-platform-terraform-locks \
  ./scripts/provision-cell.sh [--apply]

Required environment variables:
  CUSTOMER_ID       Opaque customer identifier; never a real customer name
  AWS_REGION        AWS Region for the cell
  TIER              standard, enterprise, or regulated
  TF_STATE_BUCKET   Pre-created encrypted S3 backend bucket
  TF_LOCK_TABLE     Pre-created DynamoDB lock table

Optional environment variables:
  CELL_ID            Cell/environment name (default: cell-01)
  AUDIT_S3_URI       S3 prefix to receive the JSONL audit log
  TF_STATE_KMS_KEY_ID KMS key used by the state backend

The default mode creates a plan only. --apply applies that exact saved plan.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

: "${CUSTOMER_ID:?CUSTOMER_ID is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${TIER:?TIER is required}"
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET is required}"
: "${TF_LOCK_TABLE:?TF_LOCK_TABLE is required}"

readonly CELL_ID="${CELL_ID:-cell-01}"

audit_event() {
  local action="$1"
  local result="$2"
  local exit_code="${3:-0}"

  printf '{"timestamp":"%s","actor":"%s","action":"%s","result":"%s","exit_code":%s,"cell_id":"%s","customer_id":"%s","region":"%s","tier":"%s","git_commit":"%s","plan_sha256":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${ACTOR_ARN}" \
    "${action}" \
    "${result}" \
    "${exit_code}" \
    "${CELL_ID}" \
    "${CUSTOMER_ID}" \
    "${AWS_REGION}" \
    "${TIER}" \
    "${GIT_COMMIT}" \
    "${PLAN_SHA256}" |
    tee -a "${AUDIT_FILE}" >&2
}

upload_audit_log() {
  [[ -n "${AUDIT_S3_URI:-}" ]] || return 0

  local destination="${AUDIT_S3_URI%/}/${CELL_ID}/$(basename "${AUDIT_FILE}")"
  local aws_args=(s3 cp "${AUDIT_FILE}" "${destination}" --only-show-errors)

  if [[ -n "${TF_STATE_KMS_KEY_ID:-}" ]]; then
    aws_args+=(--sse aws:kms --sse-kms-key-id "${TF_STATE_KMS_KEY_ID}")
  else
    aws_args+=(--sse AES256)
  fi

  aws "${aws_args[@]}" || printf 'Warning: failed to upload audit log to %s\n' "${destination}" >&2
}

on_exit() {
  local exit_code=$?

  if [[ "${FINAL_STATUS}" != "success" ]]; then
    audit_event "${CURRENT_ACTION}" "failed" "${exit_code}"
  fi

  upload_audit_log
  exit "${exit_code}"
}

if [[ ! "${CUSTOMER_ID}" =~ ^[a-z0-9][a-z0-9-]{2,31}$ ]]; then
  printf 'CUSTOMER_ID must be an opaque lowercase slug between 3 and 32 characters.\n' >&2
  exit 64
fi

if [[ ! "${CELL_ID}" =~ ^[a-z0-9][a-z0-9-]{2,31}$ ]]; then
  printf 'CELL_ID must be a lowercase slug between 3 and 32 characters.\n' >&2
  exit 64
fi

if [[ ! "${AWS_REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]]; then
  printf 'AWS_REGION must use a valid AWS Region name format.\n' >&2
  exit 64
fi

case "${TIER}" in
  standard | enterprise) ;;
  regulated)
    case "${AWS_REGION}" in
      eu-central-1 | eu-west-1 | eu-west-3 | eu-north-1 | eu-south-1 | eu-south-2) ;;
      *)
        printf 'Regulated cells must use an approved EU Region.\n' >&2
        exit 64
        ;;
    esac
    ;;
  *)
    printf 'TIER must be standard, enterprise, or regulated.\n' >&2
    exit 64
    ;;
esac

for command_name in aws terraform git sha256sum; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command is missing: %s\n' "${command_name}" >&2
    exit 69
  fi
done

# Derive file paths only after CELL_ID and all other logged input is validated.
# This prevents path traversal and keeps every audit line valid JSON.
readonly GIT_COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || printf 'not-a-git-checkout')"
readonly STARTED_AT="$(date -u +%Y%m%dT%H%M%SZ)"
readonly PLAN_DIR="${REPO_ROOT}/.plans"
readonly AUDIT_FILE="${AUDIT_DIR}/provision-${CELL_ID}-${STARTED_AT}.jsonl"
readonly PLAN_FILE="${PLAN_DIR}/${CELL_ID}.tfplan"

mkdir -p "${AUDIT_DIR}" "${PLAN_DIR}"
chmod 700 "${AUDIT_DIR}" "${PLAN_DIR}"
touch "${AUDIT_FILE}"
chmod 600 "${AUDIT_FILE}"
trap on_exit EXIT

CURRENT_ACTION="identify-actor"
ACTOR_ARN="$(aws sts get-caller-identity --query Arn --output text)"
audit_event "${CURRENT_ACTION}" "succeeded"

CURRENT_ACTION="format-check"
terraform -chdir="${TERRAFORM_DIR}" fmt -check -recursive
audit_event "${CURRENT_ACTION}" "succeeded"

CURRENT_ACTION="init"
init_args=(
  -input=false
  -reconfigure
  "-backend-config=bucket=${TF_STATE_BUCKET}"
  "-backend-config=key=cells/${CELL_ID}/terraform.tfstate"
  "-backend-config=region=${AWS_REGION}"
  "-backend-config=encrypt=true"
  "-backend-config=use_lockfile=true"
  "-backend-config=dynamodb_table=${TF_LOCK_TABLE}"
)

if [[ -n "${TF_STATE_KMS_KEY_ID:-}" ]]; then
  init_args+=("-backend-config=kms_key_id=${TF_STATE_KMS_KEY_ID}")
fi

terraform -chdir="${TERRAFORM_DIR}" init "${init_args[@]}"
audit_event "${CURRENT_ACTION}" "succeeded"

CURRENT_ACTION="validate"
terraform -chdir="${TERRAFORM_DIR}" validate
audit_event "${CURRENT_ACTION}" "succeeded"

CURRENT_ACTION="plan"
terraform -chdir="${TERRAFORM_DIR}" plan \
  -input=false \
  -lock-timeout=5m \
  -out="${PLAN_FILE}" \
  -var="customer_id=${CUSTOMER_ID}" \
  -var="environment=${CELL_ID}" \
  -var="aws_region=${AWS_REGION}" \
  -var="tier=${TIER}"

PLAN_SHA256="$(sha256sum "${PLAN_FILE}" | awk '{print $1}')"
audit_event "${CURRENT_ACTION}" "succeeded"

if [[ "${APPLY}" == "true" ]]; then
  CURRENT_ACTION="apply"
  # Applying a saved plan is non-interactive and guarantees that the reviewed
  # plan, rather than a newly calculated plan, is executed.
  terraform -chdir="${TERRAFORM_DIR}" apply \
    -input=false \
    -lock-timeout=5m \
    "${PLAN_FILE}"
  audit_event "${CURRENT_ACTION}" "succeeded"
else
  printf 'Plan created at %s. Re-run with --apply to execute it.\n' "${PLAN_FILE}"
fi

CURRENT_ACTION="complete"
FINAL_STATUS="success"
audit_event "${CURRENT_ACTION}" "succeeded"
