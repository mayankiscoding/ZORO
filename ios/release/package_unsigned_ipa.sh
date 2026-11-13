#!/bin/bash
# Package an unsigned ZORO archive as an .ipa that sideloading tools (Sideloadly, AltStore, SideStore)
# re-sign with the owner's own Apple ID.
#
#   ios/release/package_unsigned_ipa.sh <ZORO.xcarchive> <out.ipa> [build-settings.json]
#
# build-settings.json is the output of
#   xcodebuild -showBuildSettings -json -project … -scheme … -configuration Release -destination generic/platform=iOS
# When it is given, every app and extension bundle is ad-hoc signed ("codesign --sign -") with the
# entitlements file named by its target's CODE_SIGN_ENTITLEMENTS, with build variables expanded.
# Sideloading tools read the entitlements from that signature to decide which capabilities to ask
# Apple for (App Groups, HealthKit, HomeKit, …). Team-bound keys (application-identifier,
# team-identifier, keychain-access-groups) are dropped: the re-signing tool sets them for the owner's team.
# Without the JSON the bundles are ad-hoc signed without entitlements and a warning is printed.
#
# The archive must have been built with CODE_SIGNING_ALLOWED=NO (see .github/workflows/ios-build.yml).
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: $0 <archive.xcarchive> <out.ipa> [build-settings.json]"
ARCHIVE="$1"
OUT="$2"
SETTINGS="${3:-}"

command -v codesign >/dev/null || die "codesign not found (it ships with macOS)."
command -v python3 >/dev/null || die "python3 not found (install the Xcode Command Line Tools: xcode-select --install)."
[ -d "$ARCHIVE/Products/Applications" ] || die "$ARCHIVE has no Products/Applications folder. Did the archive step succeed?"

apps=("$ARCHIVE"/Products/Applications/*.app)
[ -d "${apps[0]}" ] || die "no .app inside $ARCHIVE/Products/Applications"
[ "${#apps[@]}" -eq 1 ] || die "expected one .app in the archive, found ${#apps[@]}"
APP="${apps[0]}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zoro-ipa.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload" "$WORK/ent"
cp -R "$APP" "$WORK/Payload/"
PAYLOAD_APP="$WORK/Payload/$(basename "$APP")"

# Write one entitlements plist per bundle name (e.g. ZORO.app, ZOROWidgets.appex) into $WORK/ent.
if [ -n "$SETTINGS" ]; then
  [ -f "$SETTINGS" ] || die "build settings file not found: $SETTINGS"
  python3 -I - "$SETTINGS" "$WORK/ent" <<'PY'
import json, os, plistlib, re, sys

settings_path, out_dir = sys.argv[1], sys.argv[2]
with open(settings_path, encoding="utf-8") as f:
    targets = json.load(f)

DROP = {"application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups",
        "com.apple.application-identifier", "get-task-allow"}
VAR = re.compile(r"\$\(([A-Za-z0-9_]+)(?::[^)]*)?\)|\$\{([A-Za-z0-9_]+)\}")

def expand(value: str, env: dict) -> str:
    for _ in range(10):
        new = VAR.sub(lambda m: str(env.get(m.group(1) or m.group(2), m.group(0))), value)
        if new == value:
            break
        value = new
    return value

def clean(obj, env, where):
    if isinstance(obj, dict):
        return {k: clean(v, env, f"{where}.{k}") for k, v in obj.items()}
    if isinstance(obj, list):
        out = []
        for i, v in enumerate(obj):
            c = clean(v, env, f"{where}[{i}]")
            if c is not None:
                out.append(c)
        return out
    if isinstance(obj, str):
        s = expand(obj, env)
        if "$(" in s or "${" in s:
            print(f"warning: dropping {where} = {obj!r}: unresolved build variable", file=sys.stderr)
            return None
        return s
    return obj

count = 0
for t in targets:
    env = t.get("buildSettings", {})
    wrapper = env.get("WRAPPER_NAME") or env.get("FULL_PRODUCT_NAME")
    ent = env.get("CODE_SIGN_ENTITLEMENTS", "")
    if not wrapper or not ent:
        continue
    path = ent if os.path.isabs(ent) else os.path.join(env.get("SRCROOT") or env.get("PROJECT_DIR", "."), ent)
    path = expand(path, env)
    if not os.path.isfile(path):
        print(f"warning: {t.get('target')}: entitlements file not found: {path}", file=sys.stderr)
        continue
    with open(path, "rb") as f:
        data = plistlib.load(f)
    data = {k: v for k, v in data.items() if k not in DROP}
    data = {k: v for k, v in clean(data, env, t.get("target", "?")).items() if v is not None}
    with open(os.path.join(out_dir, wrapper + ".plist"), "wb") as f:
        plistlib.dump(data, f)
    print(f"entitlements for {wrapper}: {', '.join(sorted(data)) or '(none)'}")
    count += 1
if count == 0:
    print("warning: no target in the build settings names an entitlements file", file=sys.stderr)
PY
else
  echo "warning: no build settings JSON given: bundles are signed without entitlements;" >&2
  echo "         capabilities such as App Groups, HealthKit and HomeKit will not be requested." >&2
fi

sign() { # bundle path
  local b="$1" name ent
  name="$(basename "$b")"
  ent="$WORK/ent/$name.plist"
  if [ -f "$ent" ]; then
    codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$ent" "$b"
  else
    codesign --force --sign - --timestamp=none "$b"
  fi
  echo "signed (ad hoc): $name"
}

# Innermost first: frameworks and dylibs, then extensions, then the app itself.
while IFS= read -r -d '' fw; do sign "$fw"; done < <(find "$PAYLOAD_APP" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
while IFS= read -r -d '' ex; do sign "$ex"; done < <(find "$PAYLOAD_APP" -depth \( -name '*.appex' -o -name '*.app' \) ! -path "$PAYLOAD_APP" -print0)
sign "$PAYLOAD_APP"
codesign --verify --deep --strict "$PAYLOAD_APP" || die "signature check failed for $PAYLOAD_APP"

mkdir -p "$(dirname "$OUT")"
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$WORK" && /usr/bin/zip -qry "$OUT_ABS" Payload)
echo "wrote $OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
echo "Next: download it from the workflow run and open it with Sideloadly, AltStore or SideStore"
echo "(docs/setup/install-on-iphone.md, route C)."
