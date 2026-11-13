#!/bin/bash
# Start the local database, initialise the schema, serve the API on 127.0.0.1:8787.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
# uv is usually installed by Homebrew or the official installer; a minimal PATH may miss both.
command -v uv >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || { echo "uv not found: install it (https://docs.astral.sh/uv/)" >&2; exit 1; }

if [ -f .env ]; then set -a; . ./.env; set +a; fi

"$ROOT/scripts/dev_db.sh" start || { echo "database failed to start" >&2; exit 1; }
if [ -z "${ZORO_DATABASE_URL:-}" ]; then
  ZORO_DATABASE_URL="$("$ROOT/scripts/dev_db.sh" url)"
fi
export ZORO_DATABASE_URL

cd "$ROOT/backend" || exit 1
if ! uv run --no-sync python -m app.cli init-db; then
  echo "warning: 'python -m app.cli init-db' failed or is not available yet; continuing" >&2
fi
exec uv run --no-sync uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8787
