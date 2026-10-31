#!/bin/sh

SSH_OPTS="-i key.pem"
HOST="user@ip"
USE_ST=0
ACTION=ssh
SRC="."
DEST="~/"

for arg in "$@"; do
  case "$arg" in
    agent)  SSH_OPTS="$SSH_OPTS -A" ;;
    st)     USE_ST=1 ;;
    push)   ACTION=push ;;
    push=*) ACTION=push; SRC="${arg#push=}" ;;
    to=*)   DEST="${arg#to=}" ;;
  esac
done

if [ "$ACTION" = push ]; then
  if [ ! -e "$SRC" ]; then
    echo "no such file or directory: $SRC" >&2
    exit 1
  fi

  if [ -d "$SRC" ]; then
    tar -cf - -C "$SRC" . \
      | ssh $SSH_OPTS "$HOST" "mkdir -p $DEST && tar -xf - -C $DEST"
  else
    tar -cf - -C "$(dirname "$SRC")" "$(basename "$SRC")" \
      | ssh $SSH_OPTS "$HOST" "mkdir -p $DEST && tar -xf - -C $DEST"
  fi
  exit 0
fi

if [ "$USE_ST" -eq 1 ]; then
  exec st -e ssh $SSH_OPTS "$HOST"
else
  exec ssh $SSH_OPTS "$HOST"
fi
