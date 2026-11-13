#!/bin/bash
# Restore files made by scripts/backup.sh.
#
#   ZORO_BACKUP_PASSPHRASE=... scripts/restore.sh <zoro-db-*.sql.enc> [zoro-objects-*.tar.enc]
#
# Loads into the database named by ZORO_DATABASE_URL (or the local dev cluster). Refuses
# to restore into a non-empty database unless ZORO_RESTORE_FORCE=1.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
PGBIN="${PGBIN:-/opt/homebrew/bin}"
[ $# -ge 1 ] || { echo "usage: $0 <db.sql.enc> [objects.tar.enc]" >&2; exit 64; }
DBFILE="$1"; OBJFILE="${2:-}"
[ -f "$DBFILE" ] || { echo "not found: $DBFILE" >&2; exit 66; }
PSQL="$(command -v psql || echo "$PGBIN/psql")"

if [ -z "${ZORO_BACKUP_PASSPHRASE:-}" ]; then
  [ -t 0 ] || { echo "set ZORO_BACKUP_PASSPHRASE or run interactively" >&2; exit 64; }
  read -r -s -p "Backup passphrase: " ZORO_BACKUP_PASSPHRASE; echo
fi
export ZORO_BACKUP_PASSPHRASE

URL="${ZORO_DATABASE_URL:-$("$ROOT/scripts/dev_db.sh" url)}"
PGURL="${URL/postgresql+psycopg:/postgresql:}"

tables="$("$PSQL" "$PGURL" -qtA -c "select count(*) from information_schema.tables where table_schema='public'")"
if [ "$tables" != "0" ] && [ "${ZORO_RESTORE_FORCE:-0}" != "1" ]; then
  echo "target database has $tables tables; set ZORO_RESTORE_FORCE=1 to restore anyway" >&2; exit 65
fi

openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:ZORO_BACKUP_PASSPHRASE -in "$DBFILE" \
  | "$PSQL" "$PGURL" -v ON_ERROR_STOP=1 -q >/dev/null
echo "database restored"

if [ -n "$OBJFILE" ]; then
  [ -f "$OBJFILE" ] || { echo "not found: $OBJFILE" >&2; exit 66; }
  OBJ="${ZORO_OBJECT_DIR:-$ROOT/.local/objects}"
  mkdir -p "$OBJ"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:ZORO_BACKUP_PASSPHRASE -in "$OBJFILE" \
    | tar -C "$OBJ" -xf -
  echo "objects restored to $OBJ"
fi
