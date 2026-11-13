#!/bin/bash
# Tests ios/release/package_unsigned_ipa.sh on a synthetic archive (a tiny host binary standing in for
# the app and its widget extension). Needs only macOS, cc and codesign: no Xcode.
#
#   ios/release/tests/test_package_unsigned_ipa.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$HERE/../package_unsigned_ipa.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/zoro-ipa-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
ko() { echo "FAIL $1"; fail=$((fail + 1)); }

command -v cc >/dev/null || { echo "SKIP: no C compiler (xcode-select --install)"; exit 0; }
printf 'int main(void){return 0;}\n' > "$T/main.c"
cc -o "$T/bin" "$T/main.c" || { echo "cannot compile the stand-in binary"; exit 1; }

make_bundle() { # dir exe bundle-id
  mkdir -p "$1"
  cp "$T/bin" "$1/$2"
  cat > "$1/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$2</string>
<key>CFBundleIdentifier</key><string>$3</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
}

ARCH="$T/ZORO.xcarchive"
APP="$ARCH/Products/Applications/ZORO.app"
make_bundle "$APP" ZORO app.zoro.ios
make_bundle "$APP/PlugIns/ZOROWidgets.appex" ZOROWidgets app.zoro.ios.widgets

mkdir -p "$T/src"
cat > "$T/src/ZORO.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.developer.healthkit</key><true/>
<key>com.apple.security.application-groups</key><array><string>group.$(PRODUCT_BUNDLE_IDENTIFIER)</string></array>
<key>keychain-access-groups</key><array><string>$(AppIdentifierPrefix)app.zoro.ios</string></array>
<key>com.example.unresolved</key><string>$(NOT_A_SETTING)</string>
</dict></plist>
EOF
cat > "$T/src/Widgets.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key><array><string>group.app.zoro.ios</string></array>
</dict></plist>
EOF
cat > "$T/settings.json" <<EOF
[
 {"target": "ZORO", "buildSettings": {"WRAPPER_NAME": "ZORO.app", "CODE_SIGN_ENTITLEMENTS": "src/ZORO.entitlements",
   "SRCROOT": "$T", "PRODUCT_BUNDLE_IDENTIFIER": "app.zoro.ios"}},
 {"target": "ZOROWidgets", "buildSettings": {"WRAPPER_NAME": "ZOROWidgets.appex",
   "CODE_SIGN_ENTITLEMENTS": "$T/src/Widgets.entitlements", "SRCROOT": "$T"}},
 {"target": "ZoroKit", "buildSettings": {"WRAPPER_NAME": "ZoroKit.framework"}}
]
EOF

# 1. Packaging with entitlements.
if "$PKG" "$ARCH" "$T/out/ZORO-unsigned.ipa" "$T/settings.json" > "$T/log" 2>&1; then ok "packages with build settings"; else ko "packages with build settings"; cat "$T/log"; fi
[ -f "$T/out/ZORO-unsigned.ipa" ] && ok "ipa written" || ko "ipa written"
mkdir -p "$T/x" && (cd "$T/x" && unzip -q "$T/out/ZORO-unsigned.ipa")
[ -f "$T/x/Payload/ZORO.app/ZORO" ] && ok "Payload/ZORO.app layout" || ko "Payload/ZORO.app layout"
ENT="$(codesign -d --entitlements :- "$T/x/Payload/ZORO.app" 2>/dev/null)"
grep -q "group.app.zoro.ios" <<<"$ENT" && ok "app group expanded" || ko "app group expanded"
grep -q "com.apple.developer.healthkit" <<<"$ENT" && ok "healthkit kept" || ko "healthkit kept"
grep -q "keychain-access-groups" <<<"$ENT" && ko "team-bound keychain group dropped" || ok "team-bound keychain group dropped"
grep -q "com.example.unresolved" <<<"$ENT" && ko "unresolved variable dropped" || ok "unresolved variable dropped"
grep -q "unresolved build variable" "$T/log" && ok "warns about unresolved variable" || ko "warns about unresolved variable"
WENT="$(codesign -d --entitlements :- "$T/x/Payload/ZORO.app/PlugIns/ZOROWidgets.appex" 2>/dev/null)"
grep -q "group.app.zoro.ios" <<<"$WENT" && ok "extension signed with its entitlements" || ko "extension signed with its entitlements"
codesign --verify --deep --strict "$T/x/Payload/ZORO.app" 2>/dev/null && ok "deep signature verifies" || ko "deep signature verifies"

# 2. Without build settings: still packages, warns.
if "$PKG" "$ARCH" "$T/out2/plain.ipa" > "$T/log2" 2>&1 && grep -q "without entitlements" "$T/log2"; then ok "packages without settings and warns"; else ko "packages without settings and warns"; fi

# 3. Failure paths.
"$PKG" "$T/missing.xcarchive" "$T/out3.ipa" > "$T/log3" 2>&1 && ko "missing archive fails" || { grep -q "no Products/Applications" "$T/log3" && ok "missing archive fails clearly" || ko "missing archive fails clearly"; }
"$PKG" "$ARCH" "$T/out4.ipa" "$T/nope.json" > "$T/log4" 2>&1 && ko "missing settings fails" || ok "missing settings file fails"
"$PKG" > /dev/null 2>&1 && ko "no arguments fails" || ok "no arguments fails"

echo "package_unsigned_ipa: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
