#!/bin/bash
# Run every check that is possible on this machine and print a summary table.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="$ROOT/.cache/test_all"; mkdir -p "$LOGDIR"
# uv is usually installed by Homebrew or the official installer; a minimal PATH may miss both.
command -v uv >/dev/null 2>&1 || export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
names=(); results=(); fail=0

run() { # label, command...
  local label="$1"; shift
  local log="$LOGDIR/$(echo "$label" | tr -c 'A-Za-z0-9\n' '_').log"
  echo ">> $label"
  if "$@" >"$log" 2>&1; then results+=("PASS"); else results+=("FAIL"); fail=1; tail -n 15 "$log"; echo "   (full log: $log)"; fi
  names+=("$label")
}

if [ -d "$ROOT/backend/.venv" ] && command -v uv >/dev/null 2>&1; then
  run "backend pytest" bash -c "cd '$ROOT/backend' && uv run --no-sync pytest -q"
  run "backend ruff"   bash -c "cd '$ROOT/backend' && uv run --no-sync ruff check ."
  run "backend format" bash -c "cd '$ROOT/backend' && uv run --no-sync ruff format --check ."
  run "backend mypy"   bash -c "cd '$ROOT/backend' && uv run --no-sync mypy app"
  # PostgreSQL + pgvector: the whole suite (one schema per test) when the local cluster is running.
  if "$ROOT/scripts/dev_db.sh" status >/dev/null 2>&1; then
    PGURL="${ZORO_TEST_DATABASE_URL:-$("$ROOT/scripts/dev_db.sh" url)}"
    run "backend pytest (PostgreSQL)" bash -c "cd '$ROOT/backend' && PYTHONPATH=. ZORO_TEST_DATABASE_URL='$PGURL' uv run --no-sync pytest -q -p tests.integration.platform.pg_everywhere"
  else
    names+=("backend pytest (PostgreSQL)"); results+=("SKIP (scripts/dev_db.sh start)")
  fi
else
  names+=("backend (pytest, ruff, mypy)"); results+=("SKIP (no backend/.venv or uv)")
fi

if [ -d "$ROOT/ios/Packages" ]; then
  for dir in "$ROOT"/ios/Packages/*/; do
    [ -f "${dir}Package.swift" ] || continue
    pkg="$(basename "$dir")"
    run "swift $pkg" "$ROOT/scripts/swiftpm.sh" "$pkg" test
  done
else
  names+=("swift packages"); results+=("SKIP (ios/Packages missing)")
fi

names+=("xcodebuild (iOS/macOS apps)"); results+=("SKIP (Xcode not installed)")
names+=("docker compose health");       results+=("SKIP (Docker not installed)")

echo; echo "Summary"; echo "-------"
for i in "${!names[@]}"; do printf '%-34s %s\n' "${names[$i]}" "${results[$i]}"; done
if [ "$fail" -ne 0 ]; then echo; echo "RESULT: FAILED"; exit 1; fi
echo; echo "RESULT: all executed checks passed"
