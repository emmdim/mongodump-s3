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
require_env "S3_OBJECT_KEY"

BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"
BACKUP_PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-}"
AWS_S3_FORCE_PATH_STYLE="${AWS_S3_FORCE_PATH_STYLE:-false}"
RESTORE_VERIFY_CHECKSUM="${RESTORE_VERIFY_CHECKSUM:-true}"
EXTRA_MONGORESTORE_ARGS="${EXTRA_MONGORESTORE_ARGS:-}"

if [[ -z "$BACKUP_PASSPHRASE" && -z "$BACKUP_PASSPHRASE_FILE" ]]; then
  fail "Set BACKUP_PASSPHRASE or BACKUP_PASSPHRASE_FILE"
fi

export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""
export AWS_S3_FORCE_PATH_STYLE

workdir="$(mktemp -d)"
encrypted_archive_path="${workdir}/restore.archive.gz.gpg"
checksum_path="${encrypted_archive_path}.sha256"
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

log "Starting restore (object_key=${S3_OBJECT_KEY})"

log "Downloading encrypted archive"
aws --endpoint-url "${SPACE_ENDPOINT}" \
  s3 cp "s3://${SPACE_NAME}/${S3_OBJECT_KEY}" "${encrypted_archive_path}" >/dev/null

if [[ "$RESTORE_VERIFY_CHECKSUM" == "true" ]]; then
  log "Downloading checksum"
  if aws --endpoint-url "${SPACE_ENDPOINT}" \
    s3 cp "s3://${SPACE_NAME}/${S3_OBJECT_KEY}.sha256" "${checksum_path}" >/dev/null; then
    expected_sha256="$(awk '{print $1}' "${checksum_path}")"
    actual_sha256="$(sha256sum "${encrypted_archive_path}" | awk '{print $1}')"
    if [[ "$expected_sha256" != "$actual_sha256" ]]; then
      fail "Checksum verification failed for ${S3_OBJECT_KEY}"
    fi
    log "Checksum verified (sha256=${actual_sha256})"
  else
    fail "Checksum sidecar not found for ${S3_OBJECT_KEY}; set RESTORE_VERIFY_CHECKSUM=false to bypass"
  fi
else
  log "Checksum verification disabled"
fi

read -r -a extra_restore_args <<<"${EXTRA_MONGORESTORE_ARGS}"

mongorestore_args=(
  --archive
  --gzip
  --uri "${MONGO_URI}"
)

if [[ ${#extra_restore_args[@]} -gt 0 ]]; then
  mongorestore_args+=("${extra_restore_args[@]}")
fi

log "Decrypting archive and running mongorestore"
if ! gpg --batch --yes --pinentry-mode loopback \
  --passphrase-file "${passphrase_file_path}" \
  --decrypt "${encrypted_archive_path}" \
  | mongorestore "${mongorestore_args[@]}"; then
  fail "Restore failed"
fi

log "Restore completed successfully"
