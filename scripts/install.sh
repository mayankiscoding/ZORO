#!/bin/bash
# First-time setup. Checks prerequisites, never installs global software itself.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
missing=0

need() { # name, command-to-test, install hint
  if command -v "$2" >/dev/null 2>&1 || [ -x "/opt/homebrew/bin/$2" ]; then
    echo "ok       $1"
  else
    echo "MISSING  $1  ->  $3"; missing=1
  fi
}
optional() {
  if command -v "$2" >/dev/null 2>&1; then echo "ok       $1 (optional)"; else echo "absent   $1 (optional)  ->  $3"; fi
}

echo "Prerequisites"
need "uv" uv "brew install uv"
need "Python 3.12" python3.12 "uv python install 3.12   (or: brew install python@3.12)"
need "PostgreSQL 17 (initdb)" initdb "brew install postgresql@17"
need "pgvector" psql "brew install pgvector   (checked via psql presence only)"
need "openssl" openssl "brew install openssl"
optional "redis-server" redis-server "brew install redis"
optional "Swift toolchain" swift "install Xcode command line tools: xcode-select --install"
optional "xcodegen" xcodegen "brew install xcodegen"
optional "docker" docker "https://docs.docker.com/desktop/setup/install/mac-install/"

if [ -f /opt/homebrew/share/postgresql@17/extension/vector.control ] || \
   ls /opt/homebrew/share/postgresql@17/extension/vector.control >/dev/null 2>&1 || \
   ls /opt/homebrew/opt/pgvector >/dev/null 2>&1; then
  echo "ok       pgvector files found"
else
  echo "MISSING  pgvector extension files  ->  brew install pgvector"; missing=1
fi

if [ "$missing" -ne 0 ]; then
  echo; echo "Install the missing items above, then run scripts/install.sh again."; exit 1
fi

if [ ! -d "$ROOT/backend/.venv" ]; then
  echo "Creating backend/.venv with uv sync"
  (cd "$ROOT/backend" && uv sync) || { echo "uv sync failed" >&2; exit 1; }
else
  echo "ok       backend/.venv exists (left untouched)"
fi

if [ ! -f "$ROOT/.env" ]; then
  [ -f "$ROOT/.env.example" ] || { echo ".env.example missing" >&2; exit 1; }
  SECRET="$(openssl rand -hex 32)"
  DATA="$(openssl rand -base64 32)"
  umask 077
  # Values are substituted without being printed. '|' cannot occur in hex or base64.
  sed -e "s|^ZORO_SECRET_KEY=.*|ZORO_SECRET_KEY=$SECRET|" \
      -e "s|^ZORO_DATA_KEY=.*|ZORO_DATA_KEY=$DATA|" \
      -e "s|^ZORO_POSTGRES_PASSWORD=.*|ZORO_POSTGRES_PASSWORD=$(openssl rand -hex 24)|" \
      -e "s|^ZORO_MINIO_ACCESS_KEY=.*|ZORO_MINIO_ACCESS_KEY=zoro|" \
      -e "s|^ZORO_MINIO_SECRET_KEY=.*|ZORO_MINIO_SECRET_KEY=$(openssl rand -hex 24)|" \
      "$ROOT/.env.example" > "$ROOT/.env"
  chmod 600 "$ROOT/.env"
  echo "Created .env with freshly generated secrets (ZORO_SECRET_KEY, ZORO_DATA_KEY, Compose passwords) (values not shown)"
else
  echo "ok       .env exists (left untouched)"
fi

cat <<'NEXT'

Next steps
  1. Add provider keys to .env (optional; missing keys only disable that integration).
  2. scripts/dev_up.sh        start local PostgreSQL, init the schema, serve on 127.0.0.1:8787
  3. scripts/healthcheck.sh   confirm the server answers
  4. scripts/test_all.sh      run every available check
NEXT
