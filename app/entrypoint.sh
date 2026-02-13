#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

CRON_SCHEDULE="${CRON_SCHEDULE:-}"
TZ="${TZ:-Etc/UTC}"
RUN_ON_START="${RUN_ON_START:-false}"

if [[ -z "$CRON_SCHEDULE" ]]; then
  log "ERROR: CRON_SCHEDULE is required"
  exit 1
fi

cron_file="/etc/cron.d/mongo-backup"
log_file="/var/log/cron.log"

log "Configuring cron (TZ=${TZ}, schedule=${CRON_SCHEDULE})"

cat >"${cron_file}" <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=${TZ}
TZ=${TZ}
${CRON_SCHEDULE} root /app/backup.sh >>${log_file} 2>&1
CRON

chmod 0644 "${cron_file}"
touch "${log_file}"

if [[ "$RUN_ON_START" == "true" ]]; then
  log "RUN_ON_START=true, running backup immediately"
  /app/backup.sh >>"${log_file}" 2>&1 || {
    log "Initial backup failed"
    exit 1
  }
fi

log "Starting cron"
cron

log "Tailing cron logs"
tail -F "${log_file}"
