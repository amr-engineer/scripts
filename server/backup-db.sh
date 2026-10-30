#!/bin/bash
set -euo pipefail
export TZ=UTC0
export AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED
export AWS_CLI_CONNECT_TIMEOUT=10
export AWS_CLI_READ_TIMEOUT=60

# Designed to backup PostgreSQL to S3-compatible

UPLOAD_TIMEOUT="1h"
BACKUP_DIR="/var/backups/pg"
DB_NAME="main"

# origins - change this :)
# left side to the colon are profiles from ~/.aws/config
REMOTES=(
	"r2:eu-backup"
	"r2:us-backup"
	"s3:sa-backup"
)

printf -v TIMESTAMP '%(%Y%m%d_%H%M%S)T' -1
FILE_NAME="${DB_NAME}_${TIMESTAMP}.dump"

log() { printf '%(%Y-%m-%dT%H:%M:%SZ)T %s\n' -1 "$*"; }
err() { printf '%(%Y-%m-%dT%H:%M:%SZ)T %s\n' -1 "$*" >&2; }

mkdir -p "$BACKUP_DIR" || { err "Error: cannot create $BACKUP_DIR"; exit 1; }

exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || { echo "Error: a backup task already running" >&2; exit 1; }

RM_LOCAL=1
trap 'rc=$?; if [ "$RM_LOCAL" -eq 1 ] && [ -n "${FILE_NAME:-}" ]; then rm -f "$BACKUP_DIR/$FILE_NAME" || true; fi; exit $rc' EXIT

pg_dump -U postgres -h localhost -Fc -d "$DB_NAME" > "$BACKUP_DIR/$FILE_NAME"

DUMP_SIZE=$(stat -c%s "$BACKUP_DIR/$FILE_NAME" 2>/dev/null || echo 0)

if [ "$DUMP_SIZE" -lt 2048 ]; then
	err "Error: dump too small ($DUMP_SIZE < 2048); DB likely empty, missing, or truncated"
	exit 1
fi

if ! pg_restore --list "$BACKUP_DIR/$FILE_NAME" > /dev/null 2>&1; then
	err "Error: dump is not restorable"
	exit 1
fi

OK_COUNT=0
for remote in "${REMOTES[@]}"; do
	PROFILE="${remote%%:*}"
	BUCKET="${remote#*:}"
	KEY="manual/${FILE_NAME}"

	log "Uploading to s3://${BUCKET}/${KEY} (profile: ${PROFILE})"

	if ! timeout --signal=TERM --kill-after=30s $UPLOAD_TIMEOUT \
		aws s3 cp "$BACKUP_DIR/$FILE_NAME" "s3://${BUCKET}/${KEY}" \
		--profile "$PROFILE" \
		--checksum-algorithm SHA256 \
		--no-progress; then
		err "Error: upload failed to s3://${BUCKET}/${KEY}"
		RM_LOCAL=0
		continue
	fi

	log "$FILE_NAME uploaded, SHA-256 verified by s3://${BUCKET}/${KEY}"
	OK_COUNT=$((OK_COUNT + 1))
done

if [ "$OK_COUNT" -ne "${#REMOTES[@]}" ]; then
	err "Warning: only $OK_COUNT/${#REMOTES[@]} remotes verified"
	err "Note: $( [ "$RM_LOCAL" -eq 1 ] && echo removing || echo keeping ) local backup"
	exit 1
fi

log "All targets verified on all ${#REMOTES[@]} remotes"
log "Note: $( [ "$RM_LOCAL" -eq 1 ] && echo removing || echo keeping ) local backup"
exit 0
