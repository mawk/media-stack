#!/usr/bin/env bash
# Backs up the live SQLite databases for services whose data isn't otherwise
# recoverable (Seerr's user/request DB, Jellyfin's library/user DB).
#
# Uses `sqlite3 .backup` (not cp) so a WAL checkpoint happens as part of the
# copy and we never grab a torn/inconsistent snapshot of a live db.
set -euo pipefail

STACK_DIR="/home/michaelr/media-stack"
BACKUP_ROOT="$STACK_DIR/backups"
KEEP_DAYS=14
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

declare -A DATABASES=(
  [seerr]="$STACK_DIR/data/config/seerr/db/db.sqlite3"
  [jellyfin]="$STACK_DIR/data/config/jellyfin/data/data/jellyfin.db"
)

for name in "${!DATABASES[@]}"; do
  src="${DATABASES[$name]}"
  dest_dir="$BACKUP_ROOT/$name"
  mkdir -p "$dest_dir"

  if [[ ! -f "$src" ]]; then
    echo "[$name] WARNING: source db not found at $src, skipping" >&2
    continue
  fi

  dest="$dest_dir/${name}-${TIMESTAMP}.sqlite3"
  sqlite3 "$src" ".backup '$dest'"
  gzip "$dest"
  echo "[$name] backed up to ${dest}.gz"

  find "$dest_dir" -name "${name}-*.sqlite3.gz" -mtime "+${KEEP_DAYS}" -delete
done
