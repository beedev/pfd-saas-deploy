#!/bin/bash
# pfd-saas monthly database backup (macOS LaunchAgent; needs only Docker).
#
# Shell-only counterpart of scripts/backup-vaspar-pfd.mjs for Macs that have
# no repo checkout and no Node on the host: runs pg_dump INSIDE the container
# and streams the custom-format dump out to ~/pfd-backups. Keeps the newest
# KEEP files. Installed by setup-mac.sh; runs on the 1st of each month at
# 03:00 (launchd runs it at next wake if the Mac was asleep).
#
# Env (from ~/pfd-watchdog/watchdog.env, written by setup-mac.sh):
#   CONTAINER (default pfd-saas)   BACKUP_DIR (default ~/pfd-backups)   KEEP (default 12)

set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:$PATH"

CONTAINER="${CONTAINER:-pfd-saas}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/pfd-backups}"
KEEP="${KEEP:-12}"
ENV_FILE="${ENV_FILE:-$HOME/pfd-watchdog/watchdog.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
mkdir -p "$BACKUP_DIR"
OUT="$BACKUP_DIR/${CONTAINER}-db-backup-$(date +%d%m%Y).dump"
TMP="$OUT.partial"

# Write to a .partial first so a failed dump never looks like a good backup.
if docker exec "$CONTAINER" sh -c \
     'PGPASSWORD="$(cat /data/.secrets/postgres_password)" pg_dump -Fc -h 127.0.0.1 -U pfd_saas -d pfd_saas' \
     > "$TMP" && [ -s "$TMP" ]; then
  mv "$TMP" "$OUT"
  echo "$(ts) backup OK → $OUT ($(du -h "$OUT" | cut -f1))"
else
  rm -f "$TMP"
  echo "$(ts) backup FAILED for container $CONTAINER" >&2
  exit 1
fi

# Retention: newest $KEEP dumps for this container.
ls -1t "$BACKUP_DIR"/"${CONTAINER}"-db-backup-*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "$old" && echo "$(ts) pruned $old"
done
