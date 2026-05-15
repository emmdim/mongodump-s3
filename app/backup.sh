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

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

first_line_or_unknown() {
  local output="$1"
  if [[ -n "$output" ]]; then
    printf '%s' "$output" | head -n 1
  else
    printf 'unknown'
  fi
}

require_env "MONGO_URI"
require_env "SPACE_NAME"
require_env "SPACE_ENDPOINT"
require_env "AWS_ACCESS_KEY_ID"
require_env "AWS_SECRET_ACCESS_KEY"

RETENTION="${RETENTION:-6}"
HOST_NAME="$(hostname -s)"
EXTRA_MONGODUMP_ARGS="${EXTRA_MONGODUMP_ARGS:-}"
AWS_S3_FORCE_PATH_STYLE="${AWS_S3_FORCE_PATH_STYLE:-false}"
MONGO_TLS_CA_FILE="${MONGO_TLS_CA_FILE:-}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"
BACKUP_PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-}"

if ! [[ "$RETENTION" =~ ^[0-9]+$ ]] || [[ "$RETENTION" -lt 1 ]]; then
  fail "RETENTION must be a positive integer"
fi

if [[ -z "$BACKUP_PASSPHRASE" && -z "$BACKUP_PASSPHRASE_FILE" ]]; then
  fail "Set BACKUP_PASSPHRASE or BACKUP_PASSPHRASE_FILE"
fi

SPACE_PREFIX="$(date -u +%Y/%m)"
BASE_PREFIX="backups/${SPACE_PREFIX}"

export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""
export AWS_S3_FORCE_PATH_STYLE

start_epoch="$(date -u +%s)"
created_at_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

encryption_mode="gpg-symmetric-aes256"
log "Starting backup (prefix=${BASE_PREFIX}, retention=${RETENTION}, encryption_mode=${encryption_mode})"

workdir="$(mktemp -d)"
archive_path="${workdir}/mongo.archive.gz"
encrypted_archive_path="${archive_path}.gpg"
checksum_path="${encrypted_archive_path}.sha256"
metadata_path="${encrypted_archive_path}.metadata.json"
passphrase_file_path="${BACKUP_PASSPHRASE_FILE}"

cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

if [[ -z "$passphrase_file_path" ]]; then
  passphrase_file_path="${workdir}/backup_passphrase.txt"
  umask 077
  printf '%s' "$BACKUP_PASSPHRASE" >"$passphrase_file_path"
  unset BACKUP_PASSPHRASE
else
  [[ -r "$passphrase_file_path" ]] || fail "BACKUP_PASSPHRASE_FILE is not readable: ${passphrase_file_path}"
fi

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

log "Encrypting archive"
if ! gpg --batch --yes --pinentry-mode loopback \
  --symmetric --cipher-algo AES256 \
  --passphrase-file "${passphrase_file_path}" \
  --output "${encrypted_archive_path}" \
  "${archive_path}"; then
  fail "gpg encryption failed"
fi
rm -f "${archive_path}"

sha256sum "${encrypted_archive_path}" > "${checksum_path}"
encrypted_sha256="$(awk '{print $1}' "${checksum_path}")"
encrypted_size_bytes="$(wc -c <"${encrypted_archive_path}" | tr -d ' ')"

stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
object_key="${BASE_PREFIX}/mongo-${stamp}.archive.gz.gpg"
checksum_key="${object_key}.sha256"
metadata_key="${BASE_PREFIX}/mongo-${stamp}.metadata.json"

mongodump_version="$(first_line_or_unknown "$(mongodump --version 2>/dev/null || true)")"
gpg_version="$(first_line_or_unknown "$(gpg --version 2>/dev/null || true)")"
current_epoch="$(date -u +%s)"
duration_seconds="$((current_epoch - start_epoch))"

cat >"${metadata_path}" <<JSON
{
  "schema_version": 1,
  "created_at_utc": "$(json_escape "${created_at_utc}")",
  "host_name": "$(json_escape "${HOST_NAME}")",
  "base_prefix": "$(json_escape "${BASE_PREFIX}")",
  "object_key": "$(json_escape "${object_key}")",
  "checksum_key": "$(json_escape "${checksum_key}")",
  "metadata_key": "$(json_escape "${metadata_key}")",
  "encryption_mode": "${encryption_mode}",
  "encrypted_size_bytes": ${encrypted_size_bytes},
  "encrypted_sha256": "${encrypted_sha256}",
  "duration_seconds": ${duration_seconds},
  "mongodump_version": "$(json_escape "${mongodump_version}")",
  "gpg_version": "$(json_escape "${gpg_version}")"
}
JSON

log "Backup artifact details: encryption_mode=${encryption_mode}, encrypted_size_bytes=${encrypted_size_bytes}, encrypted_sha256=${encrypted_sha256}, duration_seconds=${duration_seconds}"
log "Backup object keys: archive_key=${object_key}, checksum_key=${checksum_key}, metadata_key=${metadata_key}"

log "Uploading archive to Spaces"
aws --endpoint-url "${SPACE_ENDPOINT}" s3 cp "${encrypted_archive_path}" "s3://${SPACE_NAME}/${object_key}" >/dev/null

log "Uploading checksum to Spaces"
aws --endpoint-url "${SPACE_ENDPOINT}" s3 cp "${checksum_path}" "s3://${SPACE_NAME}/${checksum_key}" >/dev/null

log "Uploading metadata to Spaces"
aws --endpoint-url "${SPACE_ENDPOINT}" s3 cp "${metadata_path}" "s3://${SPACE_NAME}/${metadata_key}" >/dev/null

log "Reporting retention policy"
keys_raw="$(aws --endpoint-url "${SPACE_ENDPOINT}" s3api list-objects-v2 \
  --bucket "${SPACE_NAME}" \
  --prefix "${BASE_PREFIX}/mongo-" \
  --query 'Contents[].Key' \
  --output text)"

if [[ -z "$keys_raw" || "$keys_raw" == "None" ]]; then
  archive_count="0"
else
  archive_keys="$(printf '%s\n' "$keys_raw" | tr '\t' '\n' | grep -E '\.archive\.gz\.gpg$' || true)"
  archive_count="$(printf '%s\n' "$archive_keys" | grep -c . || true)"
fi

log "Retention report: found ${archive_count} archive(s), configured retention is ${RETENTION}, deletion disabled"

end_epoch="$(date -u +%s)"
total_duration_seconds="$((end_epoch - start_epoch))"
log "Backup completed successfully (duration_seconds=${total_duration_seconds})"
