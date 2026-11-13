#!/bin/bash
# Build or test one ZORO Swift package on the macOS host.
#
#   scripts/swiftpm.sh <PackageName | repo-relative package dir> <build|test|run> [extra swift args...]
#
# - shares one compiler module cache across packages (saves ~180 MB per package)
# - lets at most two builds run at once (protects an 8 GB machine)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -lt 2 ]; then
  echo "usage: $0 <Package> <build|test> [swift args]" >&2
  exit 64
fi
if [ -f "$ROOT/ios/Packages/$1/Package.swift" ]; then
  PKG="$ROOT/ios/Packages/$1"
elif [ -f "$ROOT/$1/Package.swift" ]; then
  PKG="$ROOT/$1" # a package elsewhere in the repo, e.g. "macos"
else
  echo "no such package: $1" >&2
  exit 66
fi
CMD="$2"
shift 2

CACHE="$ROOT/.cache/swift-module-cache"
LOCKS="$ROOT/.cache/locks"
mkdir -p "$CACHE" "$LOCKS"

# Keep build products out of iCloud Drive. When the repository sits in a folder iCloud syncs
# (Desktop or Documents with "Desktop & Documents Folders" switched on), every build would upload
# thousands of object files. In that case, or when ZORO_SWIFT_SCRATCH is set, build elsewhere.
SCRATCH_ARGS=()
if [ -n "${ZORO_SWIFT_SCRATCH:-}" ]; then
  SCRATCH_ARGS=(--scratch-path "$ZORO_SWIFT_SCRATCH/$(basename "$PKG")")
elif [ "$(defaults read com.apple.finder FXICloudDriveDesktop 2>/dev/null)" = "1" ]; then
  case "$ROOT" in
    "$HOME/Desktop/"* | "$HOME/Documents/"*)
      SCRATCH_ARGS=(--scratch-path "$HOME/Library/Caches/zoro-swift-build/$(basename "$PKG")")
      ;;
  esac
fi

SWIFT=(swift "$CMD" --package-path "$PKG" ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"} -j 4 -Xswiftc -module-cache-path -Xswiftc "$CACHE" "$@")

# Try each slot without waiting; lockf exits 75 when the slot is taken.
for slot in 1 2; do
  lockf -s -t 0 "$LOCKS/slot$slot.lock" "${SWIFT[@]}"
  rc=$?
  if [ "$rc" -ne 75 ]; then
    exit "$rc"
  fi
done

# Both busy: wait (up to 30 min) on one of them.
exec lockf -s -t 1800 "$LOCKS/slot$(( ($$ % 2) + 1 )).lock" "${SWIFT[@]}"
