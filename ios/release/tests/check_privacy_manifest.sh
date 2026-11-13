#!/bin/bash
# Fails when the Swift code uses a required-reason API category that the privacy manifest does not
# declare. Categories and API lists: Apple, NSPrivacyAccessedAPIType reference (retrieved 2026-11-13).
#
#   ios/release/tests/check_privacy_manifest.sh
#
# iOS manifest  <- every non-test Swift file except those in a Mac/ folder or starting with #if os(macOS)
# macOS manifest <- every non-test Swift file except those in an iOS/ folder or starting with #if os(iOS)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="$ROOT/ios/Packages"
[ -d "$SRC" ] || { echo "no ios/Packages folder"; exit 1; }

CATS=(UserDefaults FileTimestamp SystemBootTime DiskSpace ActiveKeyboards)
pattern() {
  case "$1" in
    UserDefaults) echo '\bUserDefaults\b' ;;
    FileTimestamp) echo 'FileAttributeKey|attributesOfItem|\[\.(creationDate|modificationDate)\]|creationDateKey|contentModificationDateKey|fileModificationDate|getattrlist|\b(f|l)?stat\(|fstatat\(' ;;
    SystemBootTime) echo 'systemUptime|mach_absolute_time' ;;
    DiskSpace) echo 'volume(Available|Total)Capacity|systemFreeSize|systemSize|\bf?statv?fs\(' ;;
    ActiveKeyboards) echo 'activeInputModes' ;;
  esac
}

files_for() { # ios|macos
  local skipdir skipif
  if [ "$1" = ios ]; then skipdir="/Mac/"; skipif='^#if os\(macOS\)'; else skipdir="/iOS/"; skipif='^#if os\(iOS\)'; fi
  find "$SRC" -name '*.swift' -not -path '*/Tests/*' -not -path '*/.build/*' -not -path '*/AppTargetTemplates/*' -print0 |
    while IFS= read -r -d '' f; do
      case "$f" in *"$skipdir"*) continue ;; esac
      head -n 5 "$f" | grep -Eq "$skipif" && continue
      printf '%s\0' "$f"
    done
}

rc=0
check() { # platform manifest
  local platform="$1" manifest="$2" cat used declared hits
  [ -f "$manifest" ] || { echo "FAIL $platform: manifest missing: $manifest"; rc=1; return; }
  for cat in "${CATS[@]}"; do
    hits="$(files_for "$platform" | xargs -0 grep -lE "$(pattern "$cat")" 2>/dev/null | sed "s#^$SRC/##" | head -5)"
    used=no; [ -n "$hits" ] && used=yes
    declared=no; grep -q "NSPrivacyAccessedAPICategory$cat<" "$manifest" && declared=yes
    if [ "$used" = yes ] && [ "$declared" = no ]; then
      echo "FAIL $platform: $cat used but not declared in $(basename "$manifest"):"; echo "$hits" | sed 's/^/       /'; rc=1
    elif [ "$used" = no ] && [ "$declared" = yes ]; then
      echo "WARN $platform: $cat declared but no use found (remove it unless the app target uses it)"
    elif [ "$used" = yes ]; then
      echo "ok   $platform: $cat used and declared ($(echo "$hits" | wc -l | tr -d ' ') file(s), e.g. $(echo "$hits" | head -1))"
    fi
  done
}
IOS_MANIFEST="${ZORO_IOS_MANIFEST:-$ROOT/ios/release/PrivacyInfo.xcprivacy}"
MAC_MANIFEST="${ZORO_MAC_MANIFEST:-$ROOT/ios/release/PrivacyInfo-macOS.xcprivacy}"
check ios "$IOS_MANIFEST"
check macos "$MAC_MANIFEST"
for m in "$IOS_MANIFEST" "$MAC_MANIFEST"; do
  plutil -lint "$m" >/dev/null || { echo "FAIL: $m is not a valid property list"; rc=1; }
  grep -q '<key>NSPrivacyTracking</key>' "$m" || { echo "FAIL: $m lacks NSPrivacyTracking"; rc=1; }
done
[ "$rc" -eq 0 ] && echo "privacy manifests: OK" || echo "privacy manifests: FAILED"
exit "$rc"
