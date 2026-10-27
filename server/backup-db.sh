#!/bin/bash
set -euo pipefail

# this script intended to run periodically
# and should be supervised to detect exit 1
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
TODAY=${TIMESTAMP%%_*}  # YYYYMMDD prefix of TIMESTAMP
DAILY_NAME="${DB_NAME}_${TODAY}.dump"
HOURLY_NAME="${DB_NAME}_${TIMESTAMP}.dump"

have_daily=()
missing_daily=()
for remote in "${REMOTES[@]}"; do
	if rclone lsjson --stat "$remote/daily/$DAILY_NAME" 2>/dev/null | grep -q '"Size":[1-9]' >/dev/null; then
		have_daily+=("$remote")
	else
		missing_daily+=("$remote")
	fi
done

ALL_OK=1
if [ "${#have_daily[@]}" -gt 0 ] && [ "${#missing_daily[@]}" -gt 0 ]; then
	src="${have_daily[0]}"
	for dest in "${missing_daily[@]}"; do
		if rclone copyto "$src/daily/$DAILY_NAME" "$dest/daily/$DAILY_NAME"; then
			echo "$(date -u): Synced $DAILY_NAME $src -> $dest"
		else
			echo "$(date -u): Error: Failed to sync $DAILY_NAME to $dest" >&2
			ALL_OK=0
		fi
	done
fi

mkdir -p "$BACKUP_DIR" || { echo "$(date -u): Error: cannot create $BACKUP_DIR" >&2; exit 1; }

T_SUBDIRS=("hourly")
T_NAMES=("$HOURLY_NAME")
if [ "${#have_daily[@]}" -eq 0 ]; then
	echo "$(date -u): No daily exists for $TODAY; creating one" >&2
	T_SUBDIRS+=("daily")
	T_NAMES+=("$DAILY_NAME")
fi


RM_LOCAL=1
trap 'rc=$?; if [ "$RM_LOCAL" -eq 1 ] && [ -n "${HOURLY_NAME:-}" ]; then rm -f "$BACKUP_DIR/$HOURLY_NAME" "$BACKUP_DIR/$HOURLY_NAME.md5" || true; fi; exit $rc' EXIT

pg_dump -U postgres -h localhost -Fc -d "$DB_NAME" > "$BACKUP_DIR/$HOURLY_NAME"

DUMP_SIZE=$(stat -c%s "$BACKUP_DIR/$HOURLY_NAME" 2>/dev/null || echo 0)

if [ "$DUMP_SIZE" -lt 2048 ]; then
    echo "$(date -u): Error: dump too small ($DUMP_SIZE < 2048); DB likely empty, missing, or truncated" >&2
    exit 1
fi

if [ "$DUMP_SIZE" -gt "$MAX_BYTES" ]; then
    echo "$(date -u): Error: dump syze $DUMP_SIZE bytes exceeds limit $MAX_BYTES" >&2
    exit 1
fi

if ! pg_restore --list "$BACKUP_DIR/$HOURLY_NAME" > /dev/null 2>&1; then
    echo "$(date -u): Error: dump is not restorable" >&2
    exit 1
fi

LOCAL_MD5=$(md5sum "$BACKUP_DIR/$HOURLY_NAME" | awk '{print $1}')
printf '%s\n' "$LOCAL_MD5" > "$BACKUP_DIR/$HOURLY_NAME.md5"

RM_LOCAL=0 # only keep local backup if all uploads fail
for i in "${!T_SUBDIRS[@]}"; do
	subdir="${T_SUBDIRS[$i]}"
	name="${T_NAMES[$i]}"
	for remote in "${REMOTES[@]}"; do
		dest="$remote/$subdir"
		if ! rclone copyto "$BACKUP_DIR/$HOURLY_NAME" "$dest/$name"; then
			echo "$(date -u): Error - $dest upload failed for $name" >&2
			ALL_OK=0
			continue
		fi
		REMOTE_MD5=$(rclone hashsum md5 "$dest/$name" 2>/dev/null | awk '{print $1}' || true)
		if [ -n "$REMOTE_MD5" ] && [ "$REMOTE_MD5" = "$LOCAL_MD5" ]; then
			echo "$(date -u): $dest checksum OK for $name"
		else
			echo "$(date -u): Error - $dest checksum mismatch for $name" >&2
			ALL_OK=0
			continue
		fi
		if ! rclone copyto "$BACKUP_DIR/$HOURLY_NAME.md5" "$dest/$name.md5"; then
			echo "$(date -u): Error - $dest upload failed for $name.md5" >&2
		else
			echo "$(date -u): $name fully uploaded to $dest"
			RM_LOCAL=1
		fi
	done
done

if [ "$ALL_OK" -eq 0 ]; then
	echo "$(date -u): Warning - partial upload/sync failure" >&2
	echo "$( [ "$RM_LOCAL" -eq 1 ] && echo removing || echo keeping ) local backup"
	exit 1
fi

echo "$(date -u): All targets verified on all ${#REMOTES[@]} origins"
echo "$( [ "$RM_LOCAL" -eq 1 ] && echo removing || echo keeping ) local backup"
exit 0
