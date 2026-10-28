#!/bin/bash
set -euo pipefail
export TZ=UTC0

# Designed to backup PostgreSQL under 4GiB to S3-compatible

BACKUP_DIR="/var/backups/pg"
DB_NAME="main"
MAX_BYTES=$((4 * 1024 * 1024 * 1024))   # 4GiB (under S3 single-part limit)

# origins - change this :)
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
trap 'rc=$?; if [ "$RM_LOCAL" -eq 1 ] && [ -n "${FILE_NAME:-}" ]; then rm -f "$BACKUP_DIR/$FILE_NAME" "$BACKUP_DIR/$FILE_NAME.md5" || true; fi; exit $rc' EXIT

pg_dump -U postgres -h localhost -Fc -d "$DB_NAME" > "$BACKUP_DIR/$FILE_NAME"

DUMP_SIZE=$(stat -c%s "$BACKUP_DIR/$FILE_NAME" 2>/dev/null || echo 0)

if [ "$DUMP_SIZE" -lt 2048 ]; then
	err "Error: dump too small ($DUMP_SIZE < 2048); DB likely empty, missing, or truncated"
	exit 1
fi

if [ "$DUMP_SIZE" -gt "$MAX_BYTES" ]; then
	err "Error: dump size $DUMP_SIZE bytes exceeds limit $MAX_BYTES"
	exit 1
fi

if ! pg_restore --list "$BACKUP_DIR/$FILE_NAME" > /dev/null 2>&1; then
	err "Error: dump is not restorable"
	exit 1
fi

LOCAL_MD5=$(md5sum "$BACKUP_DIR/$FILE_NAME" | awk '{print $1}')
printf '%s\n' "$LOCAL_MD5" > "$BACKUP_DIR/$FILE_NAME.md5"

OK_COUNT=0
RM_LOCAL=0
for remote in "${REMOTES[@]}"; do
	dest="$remote/manual"
	if ! rclone copyto "$BACKUP_DIR/$FILE_NAME" "$dest/$FILE_NAME" --s3-upload-cutoff=5G; then
		err "Error: $dest upload failed for $FILE_NAME"
		continue
	fi
	REMOTE_MD5=$(rclone hashsum md5 "$dest/$FILE_NAME" 2>/dev/null | awk '{print $1}' || true)
	if [ -z "$REMOTE_MD5" ] || [ "$REMOTE_MD5" != "$LOCAL_MD5" ]; then
		err "Error: $dest checksum mismatch for $FILE_NAME"
		continue
	fi
	if ! rclone copyto "$BACKUP_DIR/$FILE_NAME.md5" "$dest/$FILE_NAME.md5"; then
		err "Error: $dest upload failed for $FILE_NAME.md5"
		continue
	fi
	log "$FILE_NAME fully uploaded to $dest"
	OK_COUNT=$((OK_COUNT + 1))
	RM_LOCAL=1
done

if [ "$OK_COUNT" -ne "${#REMOTES[@]}" ]; then
	err "Warning: only $OK_COUNT/${#REMOTES[@]} remotes verified"
	err "Note: $( [ "$RM_LOCAL" -eq 1 ] && echo removing || echo keeping ) local backup"
	exit 1
fi

log "All targets verified on all ${#REMOTES[@]} origins"
log "Note: $( [ "$RM_LOCAL" -eq 1 ] && echo removing || echo keeping ) local backup"
exit 0
