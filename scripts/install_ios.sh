#!/bin/bash
# List connected iPhones and install a signed ZORO build with devicectl (Xcode 15 or later).
#
#   scripts/install_ios.sh --list
#   scripts/install_ios.sh [path/to/ZORO.ipa | path/to/ZORO.app] [--device <name|UDID|identifier>] [--launch]
#
# Without a path it installs the newest build from scripts/build_ios.sh (ZORO_BUILD_DIR, default
# ~/Library/Caches/ZORO/ios-build). Without --device it uses ZORO_DEVICE, or the only connected iPhone.
# An unsigned .ipa from the cloud build cannot be installed this way: use a sideloading tool
# (docs/setup/install-on-iphone.md, route C).
# Apple reference: https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line
set -uo pipefail
OUT="${ZORO_BUILD_DIR:-$HOME/Library/Caches/ZORO/ios-build}"

die() { echo; echo "FAILED: $1" >&2; [ -n "${2:-}" ] && echo "Next step: $2" >&2; exit 1; }

LIST=0; LAUNCH=0; DEVICE="${ZORO_DEVICE:-}"; ARTIFACT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    --launch) LAUNCH=1 ;;
    --device) shift; DEVICE="${1:-}"; [ -n "$DEVICE" ] || die "--device needs a name or identifier." "scripts/install_ios.sh --list" ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "unknown option $1" "scripts/install_ios.sh --help" ;;
    *) ARTIFACT="$1" ;;
  esac
  shift
done

xcrun --find devicectl >/dev/null 2>&1 || die "devicectl is not available (it ships with Xcode 15 and later)." \
  "Install Xcode (scripts/check_xcode.sh), or use a sideloading tool (docs/setup/install-on-iphone.md, route C)."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zoro-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# devicectl's terminal output is not stable; Apple recommends --json-output for scripts.
xcrun devicectl list devices --json-output "$WORK/devices.json" >"$WORK/list.log" 2>&1 || { cat "$WORK/list.log"; die "devicectl list devices failed."; }
/usr/bin/python3 -I - "$WORK/devices.json" >"$WORK/devices.tsv" <<'PY' || die "cannot read the device list."
import json, sys
d = json.load(open(sys.argv[1]))
for dev in d.get("result", {}).get("devices", []):
    p, h, c = dev.get("deviceProperties", {}), dev.get("hardwareProperties", {}), dev.get("connectionProperties", {})
    if h.get("platform") != "iOS":
        continue
    print("\t".join([p.get("name", "?"), dev.get("identifier", "?"), h.get("udid", "?"), p.get("osVersionNumber", "?"),
                     h.get("marketingName", h.get("productType", "?")), c.get("pairingState", "?"), c.get("tunnelState", "?")]))
PY

echo "iPhones and iPads known to this Mac:"
if [ -s "$WORK/devices.tsv" ]; then
  awk -F'\t' '{printf "  %-24s %-22s iOS %-8s pairing: %-10s connection: %s\n   id: %s\n", $1, $5, $4, $6, $7, $2}' "$WORK/devices.tsv"
else
  echo "  none"
fi
[ "$LIST" = 1 ] && exit 0
[ -s "$WORK/devices.tsv" ] || die "no iPhone found." "Connect the iPhone with a cable, unlock it, tap Trust, then run: xcrun devicectl manage pair"

if [ -z "$DEVICE" ]; then
  n="$(wc -l <"$WORK/devices.tsv" | tr -d ' ')"
  [ "$n" -eq 1 ] || die "$n devices are listed; choose one." "scripts/install_ios.sh --device \"<name or id>\""
  DEVICE="$(cut -f2 "$WORK/devices.tsv")"
  echo "using: $(cut -f1 "$WORK/devices.tsv")"
fi
if awk -F'\t' -v d="$DEVICE" '($1==d||$2==d||$3==d) && $6!="paired"{found=1} END{exit !found}' "$WORK/devices.tsv"; then
  die "the iPhone is not paired with this Mac." "Unlock it, then run: xcrun devicectl manage pair"
fi

# Pick the build.
if [ -z "$ARTIFACT" ]; then
  ARTIFACT="$(ls -t "$OUT"/export/*.ipa 2>/dev/null | head -n1)"
  [ -n "$ARTIFACT" ] || ARTIFACT="$(ls -d "$OUT"/ZORO.xcarchive/Products/Applications/*.app 2>/dev/null | head -n1)"
  [ -n "$ARTIFACT" ] || die "no build found in $OUT." "Run scripts/build_ios.sh first, or pass the path of a signed .ipa or .app."
fi
[ -e "$ARTIFACT" ] || die "not found: $ARTIFACT"
case "$ARTIFACT" in
  *.ipa)
    /usr/bin/unzip -q "$ARTIFACT" -d "$WORK/ipa" || die "cannot unzip $ARTIFACT"
    APP="$(ls -d "$WORK"/ipa/Payload/*.app 2>/dev/null | head -n1)"
    [ -n "$APP" ] || die "$ARTIFACT has no Payload/*.app inside." ;;
  *.app) APP="${ARTIFACT%/}" ;;
  *) die "expected a .ipa or .app, got $ARTIFACT" ;;
esac
[ -f "$APP/embedded.mobileprovision" ] || die "$(basename "$APP") has no provisioning profile: it is unsigned (for example the cloud build)." \
  "Sign and install it with Sideloadly, AltStore or SideStore (docs/setup/install-on-iphone.md, route C), or build it here with scripts/build_ios.sh."
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Info.plist" 2>/dev/null || echo '?')"

echo "installing $(basename "$APP") ($BUNDLE_ID) on $DEVICE ..."
xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1 | tee "$WORK/install.log"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  hint="Unlock the iPhone and try again."
  grep -qi "developer mode" "$WORK/install.log" && hint="On the iPhone: Settings > Privacy & Security > Developer Mode > On, restart, confirm, then try again."
  grep -qiE "provision|profile|not been explicitly trusted|ApplicationVerificationFailed" "$WORK/install.log" && \
    hint="The profile does not include this iPhone or has expired: run scripts/build_ios.sh again with the iPhone connected."
  die "install failed." "$hint"
fi

echo
echo "INSTALLED."
echo "On the iPhone, once: Settings > General > VPN & Device Management > your Apple ID > Trust."
echo "If iOS asks for it: Settings > Privacy & Security > Developer Mode > On (needs a restart)."
if [ "$LAUNCH" = 1 ] && [ "$BUNDLE_ID" != '?' ]; then
  xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || echo "Could not launch it; open ZORO from the Home Screen."
else
  echo "Next step: open ZORO on the iPhone and pair it with your server (scan the QR from the setup script)."
fi
