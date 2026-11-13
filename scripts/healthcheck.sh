#!/bin/bash
# GET /healthz and print the result. Exit 0 only when the server answers 200.
#   scripts/healthcheck.sh [base-url]      default http://127.0.0.1:8787
set -uo pipefail
BASE="${1:-${ZORO_HEALTH_URL:-http://127.0.0.1:8787}}"
body="$(curl -sS --max-time 5 -w '\n%{http_code}' "$BASE/healthz" 2>&1)" || { echo "unreachable: $BASE/healthz"; exit 2; }
code="${body##*$'\n'}"; text="${body%$'\n'*}"
echo "$text"
if [ "$code" = "200" ]; then echo "healthy (HTTP 200)"; exit 0; fi
echo "unhealthy (HTTP $code)"; exit 1
