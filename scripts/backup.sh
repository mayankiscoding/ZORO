#!/bin/bash
# Encrypted backup: pg_dump | openssl AES-256-CBC (PBKDF2) + tar of the object directory.
#
#   ZORO_BACKUP_PASSPHRASE=... scripts/backup.sh [output-dir]
#
# The passphrase comes from the environment or an interactive prompt, never argv.
# The database comes from ZORO_DATABASE_URL (psql-style postgresql:// URL) or the
# local dev cluster. Output: zoro-db-<ts>.sql.enc and zoro-objects-<ts>.tar.enc.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
OUT="${1:-$ROOT/.local/backups}"
TS="$(date +%Y%m%d-%H%M%S)"
PGBIN="${PGBIN:-/opt/homebrew/bin}"
command -v openssl >/dev/null || { echo "openssl missing" >&2; exit 69; }
PGDUMP="$(command -v pg_dump || echo "$PGBIN/pg_dump")"
[ -x "$PGDUMP" ] || { echo "pg_dump missing: brew install postgresql@17" >&2; exit 69; }

if [ -z "${ZORO_BACKUP_PASSPHRASE:-}" ]; then
  [ -t 0 ] || { echo "set ZORO_BACKUP_PASSPHRASE or run interactively" >&2; exit 64; }
  read -r -s -p "Backup passphrase: " ZORO_BACKUP_PASSPHRASE; echo
  read -r -s -p "Repeat passphrase: " again; echo
  [ "$ZORO_BACKUP_PASSPHRASE" = "$again" ] || { echo "passphrases differ" >&2; exit 64; }
fi
export ZORO_BACKUP_PASSPHRASE

URL="${ZORO_DATABASE_URL:-$("$ROOT/scripts/dev_db.sh" url)}"
case "$URL" in
  sqlite*) echo "SQLite database: copy the file instead (no pg_dump)." >&2; exit 65 ;;
esac
PGURL="${URL/postgresql+psycopg:/postgresql:}"

umask 077
mkdir -p "$OUT"
"$PGDUMP" --no-owner --format=plain "$PGURL" \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:ZORO_BACKUP_PASSPHRASE \
      -out "$OUT/zoro-db-$TS.sql.enc"
echo "database  -> $OUT/zoro-db-$TS.sql.enc"

OBJ="${ZORO_OBJECT_DIR:-$ROOT/.local/objects}"
if [ -d "$OBJ" ]; then
  tar -C "$OBJ" -cf - . \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:ZORO_BACKUP_PASSPHRASE \
        -out "$OUT/zoro-objects-$TS.tar.enc"
  echo "objects   -> $OUT/zoro-objects-$TS.tar.enc"
else
  echo "object directory $OBJ not found; skipped (minio store: back up the bucket separately)"
fi
