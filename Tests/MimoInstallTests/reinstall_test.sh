#!/bin/bash
# Real packaging/extraction into a temporary directory, with cleanup and launch substitutes.
# No real app process, service, /Applications entry or privileged command is touched.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
app="$fixture/root/Mimo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$fixture/Applications/Mimo.app"
# A standalone installer must not send new CLI commands to an older core.
if /bin/bash "$REPO/Sources/MimoDaemon/daemon.sh" install --app "$app" > "$fixture/mismatch" 2>&1; then
    echo 'FAIL: mismatched installer/app was accepted'; exit 1
fi
grep -q 'Installer and app versions do not match' "$fixture/mismatch"
echo 'PASS: mismatched downloaded installer stops before invoking the app'
cp /usr/bin/true "$app/Contents/MacOS/mimo-gui"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.mimo.reinstall</string>
<key>CFBundleExecutable</key><string>mimo-gui</string>
<key>CFBundleVersion</key><string>7</string>
</dict></plist>
EOF
cat > "$app/Contents/Resources/cleanup-installation.sh" <<'EOF'
#!/bin/bash
[ "$1" = --app ] || exit 2
[ -f "$2/preserve" ] || exit 3
echo cleanup >> "$TEST_ORDER"
[ "${TEST_CLEANUP_FAIL:-0}" = 0 ] || exit 1
EOF
cat > "$app/Contents/Resources/diagnose-launch.sh" <<'EOF'
#!/bin/bash
echo launch >> "$TEST_ORDER"
[ ! -e "$2/preserve" ] && [ -f "$2/Contents/MacOS/mimo-gui" ]
EOF
cat > "$app/Contents/Resources/setup.command" <<'EOF'
#!/bin/bash
echo setup >> "$TEST_ORDER"
[ "${TEST_SETUP_FAIL:-0}" = 0 ]
EOF
codesign --force --sign - --timestamp=none "$app" > "$fixture/sign" 2>&1
pkgbuild --root "$fixture/root" --identifier test.mimo.reinstall --version 1.0 \
    "$fixture/Mimo-1.0.pkg" > "$fixture/package" 2>&1
sha=$(shasum -a 256 "$fixture/Mimo-1.0.pkg" | awk '{print $1}')
cat > "$fixture/sudo" <<'EOF'
#!/bin/bash
[ "$1" = /bin/bash ] && [[ "$2" = */Contents/Resources/cleanup-installation.sh ]] || exit 2
echo authorize-cleanup >> "$TEST_ORDER"
exec "$@"
EOF
chmod +x "$fixture/sudo"
awk -v support="$REPO/Sources/MimoDiagnostics/command-support.sh" '
    /^# @COMMAND_SUPPORT@$/ { while ((getline line < support) > 0) print line; close(support); next }
    { print }
' "$REPO/Scripts/install-release.sh" | sed -e 's|@RELEASE_REPO@|test/repo|' -e 's|@VERSION@|1.0|' -e 's|@RELEASE_TAG@|v1.0-build.6|' \
    -e "s|@PKG_SHA256@|$sha|" -e "s|/usr/bin/sudo|$fixture/sudo|g" > "$fixture/install.sh"
export MIMO_LOG_DIRECTORY="$fixture/logs" MIMO_INSTALL_DIR="$fixture/Applications" TEST_ORDER="$fixture/order"
touch "$fixture/Applications/Mimo.app/preserve"
if TEST_CLEANUP_FAIL=1 /bin/bash "$fixture/install.sh" "$fixture/Mimo-1.0.pkg" > "$fixture/fail" 2>&1; then
    echo 'FAIL: installer ignored cleanup failure'; exit 1
fi
[ -f "$fixture/Applications/Mimo.app/preserve" ]
[ "$(cat "$TEST_ORDER")" = "$(printf 'authorize-cleanup\ncleanup')" ]
echo 'PASS: cleanup failure preserves the installed app and prevents launch'
: > "$TEST_ORDER"
/bin/bash "$fixture/install.sh" "$fixture/Mimo-1.0.pkg" > "$fixture/success" 2>&1 || { cat "$fixture/success"; exit 1; }
[ "$(cat "$TEST_ORDER")" = "$(printf 'authorize-cleanup\ncleanup\nsetup\nlaunch')" ]
echo 'PASS: verified package cleans, replaces, installs all services, then launches'
: > "$TEST_ORDER"
touch "$fixture/Applications/Mimo.app/preserve"
if TEST_SETUP_FAIL=1 /bin/bash "$fixture/install.sh" "$fixture/Mimo-1.0.pkg" > "$fixture/setup-fail" 2>&1; then
    echo 'FAIL: service setup failure reported successful installation'; exit 1
fi
[ "$(cat "$TEST_ORDER")" = "$(printf 'authorize-cleanup\ncleanup\nsetup')" ]
grep -q 'installation is incomplete' "$fixture/setup-fail"
echo 'PASS: failed service setup prevents a successful install or launch'

mkdir "$fixture/scripts"
cp "$REPO/Scripts/pkg/preinstall" "$fixture/scripts/"
cat > "$fixture/scripts/cleanup-installation.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_ORDER"
exit 17
EOF
status=0
/bin/bash "$fixture/scripts/preinstall" unused "$fixture/Applications" / || status=$?
[ "$status" = 17 ]
[ "$(cat "$TEST_ORDER")" = "$(printf '%s\n%s' --app "$fixture/Applications/Mimo.app")" ]
echo 'PASS: package preinstall uses its packaged helper and propagates cleanup failure'
