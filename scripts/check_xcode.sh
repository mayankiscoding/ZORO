#!/bin/bash
# Can this Mac build ZORO for an iPhone? Checks macOS, Xcode, the iOS SDK, XcodeGen, free disk,
# code-signing identities, the team ID and connected devices, then prints the next step.
#
#   scripts/check_xcode.sh
#
# Exit 0: ready to run scripts/build_ios.sh. Exit 1: something is missing (each problem is listed).
# Sources for the version table: https://developer.apple.com/xcode/system-requirements/ (2026-11-13).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_XCODE="26.0"      # first Xcode with the iOS 26 SDK (App Store Connect minimum since 2026-04-28)
MIN_FREE_GB=15        # our own estimate for DerivedData + archive + export of ZORO, not an Apple figure

problems=(); warnings=(); next=""
problem() { problems+=("$1"); [ -n "$next" ] || next="$2"; }
warn() { warnings+=("$1"); }
row() { printf '  %-22s %s\n' "$1" "$2"; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

echo "ZORO build check"
echo

# macOS and the newest Xcode it can run.
MACOS="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
row "macOS" "$MACOS ($(uname -m))"
if [ "$MACOS" = unknown ]; then
  problem "This is not macOS. iPhone apps can only be built on a Mac." "Use route C (cloud build) in docs/setup/install-on-iphone.md."
elif ver_ge "$MACOS" "26.6"; then
  row "Xcode this Mac runs" "Xcode 27.x (or Xcode 26.4.1-26.6)"
elif ver_ge "$MACOS" "26.2"; then
  row "Xcode this Mac runs" "Xcode 26.0-26.6 (Xcode 27 needs macOS 26.6)"
elif ver_ge "$MACOS" "15.6"; then
  row "Xcode this Mac runs" "Xcode 26.0-26.3 (iOS 26.2 SDK at most; newer Xcode needs macOS 26.2+)"
else
  row "Xcode this Mac runs" "none with the iOS 26 SDK (Xcode 26 needs macOS 15.6 or later)"
  problem "macOS $MACOS is too old for Xcode 26." "Update macOS (System Settings > General > Software Update), or use route C in docs/setup/install-on-iphone.md."
fi

# Xcode.
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
XCODE_VER=""
if [ -z "$DEV_DIR" ] || [[ "$DEV_DIR" == *CommandLineTools* ]] || ! xcodebuild -version >/dev/null 2>&1; then
  row "Xcode" "not installed (developer dir: ${DEV_DIR:-none})"
  problem "Xcode is not installed or not selected." \
    "Install the newest Xcode your macOS supports (line above): the Mac App Store only offers the newest Xcode; older ones are at developer.apple.com/download/all (free Apple ID). Open it once, then run: sudo xcode-select -s /Applications/Xcode.app"
else
  XCODE_VER="$(xcodebuild -version | awk '/^Xcode/{print $2}')"
  row "Xcode" "$XCODE_VER ($(xcodebuild -version | awk '/Build version/{print $3}')) at $DEV_DIR"
  if ! ver_ge "$XCODE_VER" "$MIN_XCODE"; then
    problem "Xcode $XCODE_VER is older than $MIN_XCODE (ZORO needs the iOS 26 SDK)." "Install Xcode $MIN_XCODE or later, then select it with sudo xcode-select -s <path to Xcode.app>."
  fi
  IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
  if [ -n "$IOS_SDK" ]; then
    row "iOS SDK" "$IOS_SDK"
  else
    row "iOS SDK" "missing"
    problem "The iOS platform is not installed in Xcode." "Run: xcodebuild -downloadPlatform iOS   (or Xcode > Settings > Components)"
  fi
  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    problem "Xcode has not finished its first launch." "Run: sudo xcodebuild -runFirstLaunch"
  fi
fi
row "Swift" "$(swift --version 2>/dev/null | head -n1 | sed 's/^.*Swift version /Swift /' || echo 'not found')"

# XcodeGen.
if command -v xcodegen >/dev/null 2>&1; then
  row "XcodeGen" "$(xcodegen --version 2>/dev/null | tail -n1)"
else
  row "XcodeGen" "not installed"
  problem "XcodeGen is not installed (it generates the Xcode projects from ios/project.yml)." "Install it: brew install xcodegen"
fi
[ -f "$ROOT/ios/project.yml" ] && row "ios/project.yml" "present" || { row "ios/project.yml" "missing"; problem "ios/project.yml does not exist yet." "Wait for the app targets to land in the repository, then run this check again."; }

# Free disk on the volume that holds the repository and on the one with the build folder.
free_gb() { df -k "$1" 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}'; }
BUILD_DIR="${ZORO_BUILD_DIR:-$HOME/Library/Caches/ZORO/ios-build}"
VOL="$BUILD_DIR"; while [ ! -d "$VOL" ]; do VOL="$(dirname "$VOL")"; done
FREE="$(free_gb "$VOL")"; FREE="${FREE:-0}"
row "Free disk" "${FREE} GB at $BUILD_DIR"
if [ "$FREE" -lt "$MIN_FREE_GB" ]; then
  if [ -z "$XCODE_VER" ]; then
    problem "Only ${FREE} GB free. Xcode itself needs much more (Apple lists the download size, not the installed size)." "Free disk space, or skip Xcode and use route C in docs/setup/install-on-iphone.md."
  else
    problem "Only ${FREE} GB free; a ZORO build needs about ${MIN_FREE_GB} GB (estimate)." "Free disk space (Xcode > Settings > Locations > Derived Data can be deleted), or set ZORO_BUILD_DIR to a bigger volume."
  fi
fi

# Signing.
IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEVID="$(grep -c '"Apple Development' <<<"$IDS" || true)"
DISTID="$(grep -c '"Apple Distribution' <<<"$IDS" || true)"
row "Signing identities" "${DEVID} Apple Development, ${DISTID} Apple Distribution"
[ "$DEVID" -gt 0 ] || warn "No Apple Development certificate yet. Xcode creates one when you add your Apple ID in Xcode > Settings > Accounts and build once."
if [ -n "${ZORO_TEAM_ID:-}" ]; then
  if [[ "$ZORO_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then row "ZORO_TEAM_ID" "set"; else problem "ZORO_TEAM_ID is set but is not a 10-character team ID." "Copy the team ID from Xcode > Settings > Accounts (or developer.apple.com/account > Membership details)."; fi
else
  row "ZORO_TEAM_ID" "not set"
  problem "ZORO_TEAM_ID is not set." "Find your team ID (Xcode > Settings > Accounts > your Apple ID > Team; a free account shows a Personal Team), then: export ZORO_TEAM_ID=<ID>"
fi

# Devices.
if [ -n "$XCODE_VER" ] && xcrun --find devicectl >/dev/null 2>&1; then
  TMPJ="$(mktemp "${TMPDIR:-/tmp}/zoro-devices.XXXXXX")"
  if xcrun devicectl list devices --json-output "$TMPJ" >/dev/null 2>&1; then
    DEVICES="$(/usr/bin/python3 -I - "$TMPJ" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
for dev in d.get("result", {}).get("devices", []):
    p, h, c = dev.get("deviceProperties", {}), dev.get("hardwareProperties", {}), dev.get("connectionProperties", {})
    print(f"{p.get('name','?')} | {h.get('platform','?')} {p.get('osVersionNumber','?')} | {c.get('pairingState','?')} | {c.get('tunnelState','?')}")
PY
)"
    if [ -n "$DEVICES" ]; then
      row "Devices" "name | OS | pairing | connection"
      while IFS= read -r l; do row "" "$l"; done <<<"$DEVICES"
    else
      row "Devices" "none"
      warn "No device found. Connect the iPhone with a cable, unlock it and tap Trust, then run: xcrun devicectl manage pair"
    fi
  else
    warn "xcrun devicectl list devices failed."
  fi
  rm -f "$TMPJ"
else
  row "Devices" "not checked (needs Xcode)"
fi

echo
for w in ${warnings[@]+"${warnings[@]}"}; do echo "note: $w"; done
if [ -z "$XCODE_VER" ] && [ "$FREE" -lt 40 ]; then
  next="With ${FREE} GB free, installing Xcode here is not realistic (our estimate: plan for 40 GB or more). Use the cloud build and a sideloading tool: docs/setup/install-on-iphone.md, route C."
fi
if [ "${#problems[@]}" -gt 0 ]; then
  for p in "${problems[@]}"; do echo "missing: $p"; done
  echo
  echo "NOT READY. Next step: $next"
  exit 1
fi
echo "READY. Next step: scripts/build_ios.sh"
