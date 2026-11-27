#!/bin/bash
# Installer contract checks only; launchctl is mocked and no installed files are touched.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
source "$REPO/Sources/MimoDaemon/daemon.sh"
fixture=$(mktemp -d)
trap '/bin/rm -rf "$fixture"' EXIT
service_plist > "$fixture/service.plist"
/usr/bin/plutil -lint "$fixture/service.plist" >/dev/null
[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$fixture/service.plist")" = "$HEARTBEAT_EXECUTABLE" ]
[ "$(/usr/bin/plutil -extract RunAtLoad raw -o - "$fixture/service.plist")" = true ]
[ "$(/usr/bin/plutil -extract KeepAlive raw -o - "$fixture/service.plist")" = true ]
/usr/bin/python3 - "$fixture/service.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
assert p['MachServices'] == {'com.mimo.core.heartbeat': True}
assert 'UserName' not in p and 'LimitLoadToSessionType' not in p
assert p['ProgramArguments'][1:] == ['--heartbeat']
PY
for kind in engine supervisor; do
    service_plist "$kind" > "$fixture/$kind.plist"
    /usr/bin/plutil -lint "$fixture/$kind.plist" >/dev/null
done
if declare -F infrastructure_plist >/dev/null; then
    echo 'FAIL: boot/health work must use the existing supervisor, without another launch job'
    exit 1
fi
/usr/bin/python3 - "$fixture" "$PLIST" "$ENGINE_PLIST" "$SUPERVISOR_PLIST" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
for name, argument in [('engine', '--engine'), ('supervisor', '--supervisor')]:
    p = plistlib.loads((root / (name + '.plist')).read_bytes())
    assert p['ProgramArguments'][1:] == [argument]
    assert p['GroupName'] == '_mimo'
    assert p['KeepAlive'] is True and p['RunAtLoad'] is True
    assert ('MachServices' in p) == (name == 'supervisor')
assert all(p.startswith('/Library/LaunchDaemons/') for p in sys.argv[2:5])
for filename, executable in [('service', 'mimo-core-heartbeat'), ('supervisor', 'mimo-core-supervisor'), ('engine', 'mihomo')]:
    p = plistlib.loads((root / (filename + '.plist')).read_bytes())
    assert pathlib.Path(p['ProgramArguments'][0]).name == executable
    assert '/Mimo/LaunchHelpers/' in p['ProgramArguments'][0]
p = plistlib.loads((root / 'supervisor.plist').read_bytes())
assert p['MachServices'] == {'com.mimo.supervisor': True, 'com.mimo.supervisor.control': True, 'com.mimo.core': True, 'com.mimo.core.control': True}
assert p['ExitTimeOut'] >= 30  # drain the bounded guard child on service removal
assert 'StartInterval' not in p  # existing supervisor owns scheduling
PY
echo 'PASS: existing supervisor owns boot and health; no additional launch job'
(
    # Execute the installer's real startup phase with launchctl mocked. A
    # completed Stop receipt remains until verification succeeds, so a peer
    # watchdog must not be relied on to start the missing heartbeat here.
    touch "$fixture/deactivated"
    heartbeat_loaded=0
    install_stage() { :; }
    run() {
        [ -e "$fixture/deactivated" ] || return 1
        if [ "$2" = bootstrap ] && [ "$4" = "$PLIST" ]; then heartbeat_loaded=1; fi
        return 0
    }
    job_state() { [ "$1" = "$LABEL" ] && [ "$heartbeat_loaded" = 1 ]; }
    startup=$(/usr/bin/python3 - "$REPO/Sources/MimoDaemon/daemon.sh" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
print(s[s.index('    install_stage starting_services'):s.index('    install_stage verifying_services')])
PY
)
    eval "$startup"
    if [ "$heartbeat_loaded" != 1 ]; then
        echo 'FAIL: activation must start heartbeat before health verification while retaining its Stop receipt'
        exit 1
    fi
    [ -e "$fixture/deactivated" ]
)
echo 'PASS: activation starts heartbeat before verification without weakening the deactivation fence'
/usr/bin/perl "$REPO/Tests/MimoDaemonTests/network_release_test.pl"
/usr/bin/perl "$REPO/Tests/MimoDaemonTests/pf_guard_test.pl" "$REPO/Sources/MimoDaemon/pf-guard.pl"

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

/bin/bash "$REPO/Tests/MimoDaemonTests/engine_conflicts_test.sh"
