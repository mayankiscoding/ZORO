#!/bin/bash
# Generate the Xcode projects from ios/project.yml and macos/project.yml.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. Install it with: brew install xcodegen" >&2
  echo "Opening the projects also requires Xcode (https://developer.apple.com/xcode/)." >&2
  exit 69
fi
rc=0
for d in ios macos; do
  if [ -f "$ROOT/$d/project.yml" ]; then
    echo ">> xcodegen $d"
    (cd "$ROOT/$d" && xcodegen generate --spec project.yml) || rc=1
  else
    echo "skip: $d/project.yml not found"
  fi
done
exit $rc
