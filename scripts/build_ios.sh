#!/bin/bash
# Build ZORO for iPhone on a Mac with Xcode: generate the project, archive with automatic signing for
# your team, export an .ipa.
#
#   ZORO_TEAM_ID=<10-character team ID> scripts/build_ios.sh [development|ad-hoc|app-store]
#
# development (default) works with a free Apple ID (Personal Team) or a paid account;
# ad-hoc and app-store need a paid Apple Developer Program membership.
#
# Environment:
#   ZORO_TEAM_ID       required. Xcode > Settings > Accounts > your Apple ID > Team.
#   ZORO_IOS_SCHEME    scheme to build (default: "ZORO" when it exists, else the only app scheme).
#   ZORO_BUILD_DIR     output folder (default: ~/Library/Caches/ZORO/ios-build, outside iCloud Drive).
#   ZORO_BUILD_NUMBER  CFBundleVersion override (TestFlight needs a new number for each upload).
#   ZORO_SKIP_GENERATE=1  reuse the existing ios/*.xcodeproj instead of running XcodeGen.
#
# The signing account must be signed in to Xcode (Xcode > Settings > Accounts): xcodebuild uses it
# through -allowProvisioningUpdates. For a free account, connect and unlock the iPhone first so that
# Xcode can register it (-allowProvisioningDeviceRegistration).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo; echo "FAILED: $1" >&2; [ -n "${2:-}" ] && echo "Next step: $2" >&2; exit 1; }

METHOD="${1:-development}"
case "$METHOD" in
  development) EXPORT_PLIST="$ROOT/ios/release/ExportOptions-Development.plist" ;;
  ad-hoc) EXPORT_PLIST="$ROOT/ios/release/ExportOptions-AdHoc.plist" ;;
  app-store) EXPORT_PLIST="$ROOT/ios/release/ExportOptions-AppStore.plist" ;;
  -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
  *) die "unknown export method '$METHOD' (use development, ad-hoc or app-store)." "scripts/build_ios.sh development" ;;
esac

xcodebuild -version >/dev/null 2>&1 || die "Xcode is not installed or not selected (xcodebuild does not run)." \
  "Run scripts/check_xcode.sh to see what is missing, or use the cloud build (docs/setup/install-on-iphone.md, route C)."
TEAM="${ZORO_TEAM_ID:-}"
[ -n "$TEAM" ] || die "ZORO_TEAM_ID is not set." "export ZORO_TEAM_ID=<your team ID from Xcode > Settings > Accounts>, then run this again."
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "ZORO_TEAM_ID must be the 10-character team ID." "Copy it from Xcode > Settings > Accounts."
[ -f "$ROOT/ios/project.yml" ] || die "ios/project.yml does not exist yet." "Wait for the iPhone app target to land in the repository."

OUT="${ZORO_BUILD_DIR:-$HOME/Library/Caches/ZORO/ios-build}"
mkdir -p "$OUT" || die "cannot create $OUT" "Set ZORO_BUILD_DIR to a writable folder."
LOG="$OUT/build.log"
: > "$LOG"
run() { # label, command...
  local label="$1"; shift
  echo ">> $label"
  if ! "$@" >>"$LOG" 2>&1; then
    tail -n 40 "$LOG"
    hint=""
    grep -q "No Accounts\|No account for team" "$LOG" && hint="Add your Apple ID in Xcode > Settings > Accounts, then run this again."
    grep -q "requires a provisioning profile\|No profiles for" "$LOG" && hint="Open ios/*.xcodeproj in Xcode once, pick your team under Signing & Capabilities, connect the iPhone, then run this again."
    grep -q "Your team has no devices\|no devices" "$LOG" && hint="Connect and unlock the iPhone (tap Trust), run xcrun devicectl manage pair, then run this again."
    grep -qi "personal development team.*does not support" "$LOG" && hint="A free account cannot sign a capability the app uses; see the capability table in docs/setup/install-on-iphone.md."
    die "$label (full log: $LOG)" "${hint:-Read the log above; scripts/check_xcode.sh checks the usual causes.}"
  fi
}

if [ "${ZORO_SKIP_GENERATE:-0}" != 1 ]; then
  command -v xcodegen >/dev/null 2>&1 || die "XcodeGen is not installed." "brew install xcodegen"
  run "generate Xcode projects" "$ROOT/scripts/gen_xcode.sh"
fi

shopt -s nullglob
projects=("$ROOT"/ios/*.xcodeproj)
shopt -u nullglob
[ "${#projects[@]}" -eq 1 ] || die "expected one .xcodeproj in ios/, found ${#projects[@]}." "Run scripts/gen_xcode.sh and check its output."
PROJECT="${projects[0]}"

SCHEMES_JSON="$OUT/schemes.json"
xcodebuild -list -json -project "$PROJECT" >"$SCHEMES_JSON" 2>>"$LOG" || die "xcodebuild -list failed (log: $LOG)"
SCHEME="$(/usr/bin/python3 -I - "$SCHEMES_JSON" "${ZORO_IOS_SCHEME:-}" <<'PY'
import json, sys
schemes = json.load(open(sys.argv[1])).get("project", {}).get("schemes", [])
wanted = sys.argv[2]
if wanted:
    print(wanted if wanted in schemes else "")
elif "ZORO" in schemes:
    print("ZORO")
else:
    apps = [s for s in schemes if not s.endswith(("Tests", "Widgets", "-Package"))]
    print(apps[0] if len(apps) == 1 else "")
PY
)"
[ -n "$SCHEME" ] || die "cannot pick a scheme. Schemes in $(basename "$PROJECT"): $(/usr/bin/python3 -I -c 'import json,sys; print(", ".join(json.load(open(sys.argv[1]))["project"]["schemes"]))' "$SCHEMES_JSON")" \
  "export ZORO_IOS_SCHEME=<scheme>, then run this again."
echo "project: $(basename "$PROJECT"), scheme: $SCHEME, team: $TEAM, method: $METHOD"
echo "output:  $OUT"

ARCHIVE="$OUT/ZORO.xcarchive"
rm -rf "$ARCHIVE" "$OUT/export"
EXTRA=()
[ -n "${ZORO_BUILD_NUMBER:-}" ] && EXTRA+=("CURRENT_PROJECT_VERSION=$ZORO_BUILD_NUMBER")
run "archive (Release, generic iOS device, automatic signing)" \
  xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -derivedDataPath "$OUT/DerivedData" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic ${EXTRA[@]+"${EXTRA[@]}"}

OPTS="$OUT/ExportOptions.plist"
cp "$EXPORT_PLIST" "$OPTS"
plutil -replace teamID -string "$TEAM" "$OPTS" || die "cannot write $OPTS"
if xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" -exportOptionsPlist "$OPTS" \
     -allowProvisioningUpdates >>"$LOG" 2>&1; then
  IPA="$(ls "$OUT"/export/*.ipa 2>/dev/null | head -n1)"
  echo
  echo "BUILT: $IPA"
  case "$METHOD" in
    app-store) echo "Next step: upload it with Xcode's Organizer (Window > Organizer > Distribute App), or run the ios-build workflow's TestFlight job." ;;
    *) echo "Next step: scripts/install_ios.sh \"$IPA\"" ;;
  esac
else
  APP="$(ls -d "$ARCHIVE"/Products/Applications/*.app 2>/dev/null | head -n1)"
  tail -n 20 "$LOG"
  [ "$METHOD" = development ] && [ -n "$APP" ] || die "export failed (full log: $LOG)" "Check the signing errors above; scripts/check_xcode.sh lists the usual causes."
  echo
  echo "The archive is signed but the .ipa export failed (common with a free Personal Team)."
  echo "BUILT: $APP"
  echo "Next step: scripts/install_ios.sh \"$APP\""
fi
