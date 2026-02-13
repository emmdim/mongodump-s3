#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "Missing required env var: ${name}"
  fi
}

require_env "MONGO_URI"
require_env "SPACE_NAME"
require_env "SPACE_ENDPOINT"
require_env "AWS_ACCESS_KEY_ID"
require_env "AWS_SECRET_ACCESS_KEY"

RETENTION="${RETENTION:-6}"
HOST_TAG="${HOST_TAG:-$(hostname -s)}"
EXTRA_MONGODUMP_ARGS="${EXTRA_MONGODUMP_ARGS:-}"
AWS_S3_FORCE_PATH_STYLE="${AWS_S3_FORCE_PATH_STYLE:-false}"
MONGO_TLS_CA_FILE="${MONGO_TLS_CA_FILE:-}"

if ! [[ "$RETENTION" =~ ^[0-9]+$ ]] || [[ "$RETENTION" -lt 1 ]]; then
  fail "RETENTION must be a positive integer"
fi

SPACE_PREFIX="$(date -u +%Y-%m)"
BASE_PREFIX="${HOST_TAG}/${SPACE_PREFIX}"

export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""
export AWS_S3_FORCE_PATH_STYLE

log "Starting backup (prefix=${BASE_PREFIX}, retention=${RETENTION})"

workdir="$(mktemp -d)"
archive_path="${workdir}/mongo.archive.gz"
checksum_path="${workdir}/mongo.archive.gz.sha256"

cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

read -r -a extra_args <<<"${EXTRA_MONGODUMP_ARGS}"

mongodump_args=(
  --uri "${MONGO_URI}"
  --archive="${archive_path}"
  --gzip
)

if [[ -n "$MONGO_TLS_CA_FILE" ]]; then
  if [[ ! -f "$MONGO_TLS_CA_FILE" ]]; then
    fail "MONGO_TLS_CA_FILE does not exist: ${MONGO_TLS_CA_FILE}"
  fi
  mongodump_args+=(--tls --tlsCAFile "${MONGO_TLS_CA_FILE}")
fi

if [[ ${#extra_args[@]} -gt 0 ]]; then
  mongodump_args+=("${extra_args[@]}")
fi

log "Running mongodump"
if ! mongodump "${mongodump_args[@]}"; then
  fail "mongodump failed"
fi

sha256sum "${archive_path}" > "${checksum_path}"

stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
object_key="${BASE_PREFIX}/mongo-${stamp}.archive.gz"
checksum_key="${object_key}.sha256"

log "Uploading archive to Spaces"
aws --endpoint-url "${SPACE_ENDPOINT}" s3 cp "${archive_path}" "s3://${SPACE_NAME}/${object_key}" >/dev/null

log "Uploading checksum to Spaces"
aws --endpoint-url "${SPACE_ENDPOINT}" s3 cp "${checksum_path}" "s3://${SPACE_NAME}/${checksum_key}" >/dev/null

log "Applying retention policy"
keys_raw="$(aws --endpoint-url "${SPACE_ENDPOINT}" s3api list-objects-v2 \
  --bucket "${SPACE_NAME}" \
  --prefix "${BASE_PREFIX}/mongo-" \
  --query 'Contents[].Key' \
  --output text)"

if [[ -z "$keys_raw" || "$keys_raw" == "None" ]]; then
  log "No objects found for retention"
  exit 0
fi

archive_keys="$(printf '%s\n' "$keys_raw" | tr '\t' '\n' | grep -E '\.archive\.gz$' || true)"

if [[ -z "$archive_keys" ]]; then
  log "No archive objects found for retention"
  exit 0
fi

sorted="$(printf '%s\n' "$archive_keys" | sort -r)"

remove="$(printf '%s\n' "$sorted" | tail -n +"$((RETENTION + 1))" || true)"

if [[ -z "$remove" ]]; then
  log "Retention OK: keeping ${RETENTION} newest backup(s)"
  exit 0
fi

log "Deleting old backups"
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  log "Deleting ${key}"
  aws --endpoint-url "${SPACE_ENDPOINT}" s3api delete-object \
    --bucket "${SPACE_NAME}" \
    --key "${key}" >/dev/null || fail "Failed to delete ${key}"
  sha_key="${key}.sha256"
  log "Deleting ${sha_key}"
  aws --endpoint-url "${SPACE_ENDPOINT}" s3api delete-object \
    --bucket "${SPACE_NAME}" \
    --key "${sha_key}" >/dev/null || fail "Failed to delete ${sha_key}"

  # Small delay to avoid API bursts
  sleep 0.2
done <<<"${remove}"

log "Backup completed"
