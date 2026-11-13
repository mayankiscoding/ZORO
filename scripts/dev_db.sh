#!/bin/bash
# Project-local PostgreSQL 17 (+pgvector) for development and `pytest -m postgres`.
#
#   scripts/dev_db.sh start|stop|status|psql|reset|url
#
# Cluster lives in .local/pg (port 54329, unix socket in .local/pg/sock, trust auth
# for localhost only). Idempotent: start on a running cluster is a no-op.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGBIN="${PGBIN:-/opt/homebrew/bin}"
BASE="$ROOT/.local/pg"
DATA="$BASE/data"
SOCK="$BASE/sock"
LOG="$BASE/postgres.log"
export LC_ALL="en_US.UTF-8"
PORT="${ZORO_DEV_DB_PORT:-54329}"
DB="zoro"
DBUSER="zoro"

for tool in initdb pg_ctl psql; do
  if [ ! -x "$PGBIN/$tool" ]; then
    echo "missing $PGBIN/$tool. Install: brew install postgresql@17 pgvector" >&2
    exit 69
  fi
done

is_running() { "$PGBIN/pg_ctl" -D "$DATA" status >/dev/null 2>&1; }

init_cluster() {
  [ -f "$DATA/PG_VERSION" ] && return 0
  mkdir -p "$DATA" "$SOCK"
  chmod 700 "$DATA"
  "$PGBIN/initdb" -D "$DATA" -U "$DBUSER" --auth=trust --encoding=UTF8 --locale=C >/dev/null
  {
    echo "listen_addresses = '127.0.0.1'"
    echo "port = $PORT"
    echo "unix_socket_directories = '$SOCK'"
    echo "unix_socket_permissions = 0700"
    echo "fsync = on"
    echo "log_min_messages = warning"
  } >> "$DATA/postgresql.conf"
  # Trust only for this machine: unix socket (owner-only dir) and loopback.
  cat > "$DATA/pg_hba.conf" <<HBA
local   all   all                 trust
host    all   all   127.0.0.1/32  trust
host    all   all   ::1/128       trust
HBA
}

ensure_db() {
  export PGOPTIONS="-c client_min_messages=warning"
  local psql=("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U "$DBUSER" -v ON_ERROR_STOP=1 -qtA)
  if [ "$("${psql[@]}" -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$DB'")" != "1" ]; then
    "${psql[@]}" -d postgres -c "CREATE DATABASE $DB"
  fi
  "${psql[@]}" -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS vector"
}

do_start() {
  init_cluster
  mkdir -p "$SOCK"
  if is_running; then
    echo "already running on 127.0.0.1:$PORT"
  else
    "$PGBIN/pg_ctl" -D "$DATA" -l "$LOG" -w -t 30 start >/dev/null
    echo "started on 127.0.0.1:$PORT"
  fi
  ensure_db
}

case "${1:-}" in
  start) do_start ;;
  stop)
    if is_running; then "$PGBIN/pg_ctl" -D "$DATA" -m fast -w stop >/dev/null; echo "stopped"; else echo "not running"; fi ;;
  status)
    if is_running; then echo "running on 127.0.0.1:$PORT (data: $DATA)"; else echo "stopped"; exit 3; fi ;;
  psql)
    shift
    exec "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U "$DBUSER" -d "$DB" "$@" ;;
  reset)
    if is_running; then "$PGBIN/pg_ctl" -D "$DATA" -m fast -w stop >/dev/null; fi
    rm -rf "$BASE"
    do_start
    echo "reset complete (all local data erased)" ;;
  url) echo "postgresql+psycopg://$DBUSER@127.0.0.1:$PORT/$DB" ;;
  *) echo "usage: $0 start|stop|status|psql|reset|url" >&2; exit 64 ;;
esac
