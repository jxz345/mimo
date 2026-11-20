#!/bin/bash
# Installer contract checks only; launchctl is mocked and no installed files are touched.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
source "$REPO/Sources/ExitIPDaemon/daemon.sh"
fixture=$(mktemp -d)
trap '/bin/rm -rf "$fixture"' EXIT
service_plist > "$fixture/service.plist"
/usr/bin/plutil -lint "$fixture/service.plist" >/dev/null
[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$fixture/service.plist")" = "$EXECUTABLE" ]
[ "$(/usr/bin/plutil -extract RunAtLoad raw -o - "$fixture/service.plist")" = true ]
[ "$(/usr/bin/plutil -extract KeepAlive raw -o - "$fixture/service.plist")" = true ]
/usr/bin/python3 - "$fixture/service.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
assert p['MachServices'] == {'com.example.exitipmonitor.daemon': True, 'com.example.exitipmonitor.daemon.control': True}
assert 'UserName' not in p and 'LimitLoadToSessionType' not in p
assert len(p['ProgramArguments']) == 1
PY
for kind in engine supervisor; do
    service_plist "$kind" > "$fixture/$kind.plist"
    /usr/bin/plutil -lint "$fixture/$kind.plist" >/dev/null
done
for kind in boot health; do
    infrastructure_plist "$kind" > "$fixture/$kind.plist"
    /usr/bin/plutil -lint "$fixture/$kind.plist" >/dev/null
done
/usr/bin/python3 - "$fixture" "$PLIST" "$ENGINE_PLIST" "$SUPERVISOR_PLIST" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
for name, argument in [('engine', '--engine'), ('supervisor', '--supervisor')]:
    p = plistlib.loads((root / (name + '.plist')).read_bytes())
    assert p['ProgramArguments'][1:] == [argument]
    assert p['GroupName'] == '_mimo'
    assert p['KeepAlive'] is True and p['RunAtLoad'] is True
    assert ('MachServices' in p) == (name == 'supervisor')
assert all('/Application Support/' in p for p in sys.argv[2:4])
assert sys.argv[4].startswith('/Library/LaunchDaemons/')
for kind, argument in [('boot', '--boot'), ('health', '--check')]:
    p = plistlib.loads((root / (kind + '.plist')).read_bytes())
    assert p['ProgramArguments'] == ['/usr/bin/perl', '/Library/Application Support/Mimo/Guard/pf-guard.pl', argument]
    assert p['RunAtLoad'] is True and p['KeepAlive'] == {'SuccessfulExit': False}
    assert ('StartInterval' in p) == (kind == 'health')
    if kind == 'health': assert p['StartInterval'] == 10
PY
echo 'PASS: independent PF and health jobs start at boot without executing Mimo or mihomo; core/engine retain saved service intent'
/usr/bin/perl "$REPO/Tests/ExitIPDaemonTests/pf_guard_test.pl" "$REPO/Sources/ExitIPDaemon/pf-guard.pl"

(
    directory_query() { if [ "$2" = /Groups ]; then printf '_mimo 10000\nstaff 20\n'; fi; }
    runtime_group_id_available 10000 _mimo
    if runtime_group_id_available 10000 >/dev/null 2>&1; then exit 1; fi
    directory_query() { if [ "$2" = /Users ]; then echo 'unexpected-user PrimaryGroupID: 10000'; fi; }
    if runtime_group_id_available 10000 _mimo >/dev/null 2>&1; then exit 1; fi
    directory_query() { if [ "$2" = /Groups ]; then printf '_mimo 10000\nother-group 10000\n'; fi; }
    if runtime_group_id_available 10000 _mimo >/dev/null 2>&1; then exit 1; fi
    directory_query() { return 1; }
    if runtime_group_id_available 10000 _mimo >/dev/null 2>&1; then exit 1; fi
)
echo 'PASS: runtime group rejects primary-group users, duplicate group IDs and directory lookup failures'

run() {
    local count
    echo "$*" >> "$fixture/commands"
    if [ "$2" = bootout ]; then return 0; fi
    count=$(cat "$fixture/reads" 2>/dev/null || echo 0)
    echo "$((count + 1))" > "$fixture/reads"
    if [ "$count" -lt 3 ]; then return 0; fi
    echo "Could not find service \"$LABEL\" in domain for system"
    return 113
}
unload "$LABEL"
[ "$(cat "$fixture/reads")" = 4 ]
grep -q "bootout system/$LABEL" "$fixture/commands"
echo 'PASS: uninstall waits for launchd to confirm service removal'
run() { return 124; }
if unload "$LABEL" > /dev/null 2>&1; then echo 'FAIL: inspection timeout treated as absence'; exit 1; fi
run() { echo 'permission denied'; return 1; }
if unload "$LABEL" > /dev/null 2>&1; then echo 'FAIL: permission error treated as absence'; exit 1; fi
echo 'PASS: inspection failures cannot report successful removal'

ln -s "$fixture" "$fixture/link"
if secure_directory "$fixture/link" > /dev/null 2>&1; then echo 'FAIL: symlink accepted'; exit 1; fi
if [ "$(id -u)" != 0 ]; then
    if install_service > /dev/null 2>&1; then echo 'FAIL: unprivileged install accepted'; exit 1; fi
    if uninstall_service > /dev/null 2>&1; then echo 'FAIL: unprivileged removal accepted'; exit 1; fi
fi
echo 'PASS: installation requires administrator privileges and rejects symlinked executable directories'

# A failed replacement restores bytes and restarts only previously loaded services.
(
    stage="$fixture/rollback"; mkdir -p "$stage/backup"
    EXECUTABLE="$fixture/executable"; PLIST="$fixture/launch.plist"
    installed_files=("$EXECUTABLE" "$PLIST" "$fixture/new-file")
    echo old-binary > "$stage/backup/0"
    echo old-plist > "$stage/backup/1"
    echo replacement > "$EXECUTABLE"; echo replacement > "$PLIST"; touch "$fixture/new-file"
    old_loaded=1 supervisor_loaded=0 legacy_loaded=0 legacy_http_loaded=0 old_mode=global old_ipv4_policy=1
    LEGACY_CORE_PLIST="$PLIST" RUNTIME="$fixture/runtime"
    mkdir -p "$RUNTIME"
    touch "$RUNTIME/maintenance"
    unload() { echo "unload $1" >> "$fixture/rollback-commands"; }
    wait_mimo_workers() { :; }
    run() { echo "$*" >> "$fixture/rollback-commands"; }
    restore_installation
    [ "$(cat "$EXECUTABLE")" = old-binary ] && [ "$(cat "$PLIST")" = old-plist ]
    [ ! -e "$fixture/new-file" ]
    grep -q "bootstrap system $PLIST" "$fixture/rollback-commands"
    [ ! -e "$RUNTIME/maintenance" ]
    ! grep -q -- '--restore-direct-offline' "$fixture/rollback-commands"
    [ "$(wc -l < "$fixture/rollback-commands" | tr -d ' ')" = 6 ]
)
echo 'PASS: a failed protected upgrade restores the old files and service without implicitly restoring Direct'
