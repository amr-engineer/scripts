#!/bin/bash
set -euo pipefail

# Designed to backup PostgreSQL under 4GiB

BACKUP_DIR="/var/backups/pg"
DB_NAME="main"
MAX_BYTES=$((4 * 1024 * 1024 * 1024))   # 4GiB (under S3 single-part limit)

# origins - change this :)
REMOTES=(
	"r2:eu-backup"
	"r2:us-backup"
	"s3:sa-backup"
)

TIMESTAMP=$(TZ=UTC date +%Y%m%d_%H%M%S)
FILE_NAME="${DB_NAME}_${TIMESTAMP}.dump"

mkdir -p "$BACKUP_DIR" || { echo "$(date -u): Error: cannot create $BACKUP_DIR" >&2; exit 1; }

exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || { echo "Error: a backup task already running" >&2; exit 1; }

RM_LOCAL=1
trap 'rc=$?; if [ "$RM_LOCAL" -eq 1 ] && [ -n "${FILE_NAME:-}" ]; then rm -f "$BACKUP_DIR/$FILE_NAME" "$BACKUP_DIR/$FILE_NAME.md5" || true; fi; exit $rc' EXIT

pg_dump -U postgres -h localhost -Fc -d "$DB_NAME" > "$BACKUP_DIR/$FILE_NAME"

DUMP_SIZE=$(stat -c%s "$BACKUP_DIR/$FILE_NAME" 2>/dev/null || echo 0)

if [ "$DUMP_SIZE" -lt 2048 ]; then
	echo "$(date -u): Error: dump too small ($DUMP_SIZE < 2048); DB likely empty, missing, or truncated" >&2
	exit 1
fi

if [ "$DUMP_SIZE" -gt "$MAX_BYTES" ]; then
	echo "$(date -u): Error: dump size $DUMP_SIZE bytes exceeds limit $MAX_BYTES" >&2
	exit 1
fi

if ! pg_restore --list "$BACKUP_DIR/$FILE_NAME" > /dev/null 2>&1; then
	echo "$(date -u): Error: dump is not restorable" >&2
	exit 1
fi

LOCAL_MD5=$(md5sum "$BACKUP_DIR/$FILE_NAME" | awk '{print $1}')
printf '%s\n' "$LOCAL_MD5" > "$BACKUP_DIR/$FILE_NAME.md5"

OK_COUNT=0
for remote in "${REMOTES[@]}"; do
	dest="$remote/manual"
	if ! rclone copyto "$BACKUP_DIR/$FILE_NAME" "$dest/$FILE_NAME"; then
		echo "$(date -u): Error: $dest upload failed for $FILE_NAME" >&2
		continue
	fi
	REMOTE_MD5=$(rclone hashsum md5 "$dest/$FILE_NAME" 2>/dev/null | awk '{print $1}' || true)
	if [ -z "$REMOTE_MD5" ] || [ "$REMOTE_MD5" != "$LOCAL_MD5" ]; then
		echo "$(date -u): Error: $dest checksum mismatch for $FILE_NAME" >&2
		continue
	fi
	if ! rclone copyto "$BACKUP_DIR/$FILE_NAME.md5" "$dest/$FILE_NAME.md5"; then
		echo "$(date -u): Error: $dest upload failed for $FILE_NAME.md5" >&2
		continue
	fi
	echo "$(date -u): $FILE_NAME fully uploaded to $dest"
	OK_COUNT=$((OK_COUNT + 1))
	RM_LOCAL=1
done

if [ "$OK_COUNT" -ne "${#REMOTES[@]}" ]; then
	echo "$(date -u): Warning - only $OK_COUNT/${#REMOTES[@]} remotes verified" >&2
	echo "$( [ "$RM_LOCAL" -eq 1 ] && echo removing || echo keeping ) local backup" >&2
	exit 1
fi

echo "$(date -u): All targets verified on all ${#REMOTES[@]} origins"
echo "$( [ "$RM_LOCAL" -eq 1 ] && echo removing || echo keeping ) local backup"
exit 0
