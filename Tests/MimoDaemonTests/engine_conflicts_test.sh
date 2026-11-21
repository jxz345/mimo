#!/bin/bash
# Function-level contracts. Every signal/launchctl call is mocked; VM integration is separate.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
source "$REPO/Sources/MimoDaemon/daemon.sh"
fixture=$(mktemp -d)
trap '/bin/rm -rf "$fixture"' EXIT
engine='/opt/Proxy App/mihomo'
reset_fixture() {
    rm -f "$fixture/stopped" "$fixture/changed" "$fixture/actions" "$fixture/asked"
    installation_interactive=1
}
engine_conflict_snapshot() {
    printf '1 0 /sbin/launchd\n200 0 %s\n201 0 %s\n' "$RUNTIME/mihomo" "$EXECUTABLE"
    [ -e "$fixture/stopped" ] || printf '500001 0 %s\n' "$engine"
}
engine_process_identity() {
    [ ! -e "$fixture/stopped" ] || return 1
    if [ -e "$fixture/changed" ]; then printf '0 Sat Nov 22 10:00:01 2026 %s\n' "$engine"
    else printf '0 Sat Nov 22 10:00:00 2026 %s\n' "$engine"; fi
}
confirm_engine_stop() { touch "$fixture/asked"; return 0; }
engine_job_rows() { echo "500001 0 homebrew.mxcl.mihomo"; }
run() {
    case "$*" in
        '/bin/launchctl disable system/homebrew.mxcl.mihomo') echo "$*" >> "$fixture/actions" ;;
        '/bin/launchctl print system/homebrew.mxcl.mihomo') echo 'pid = 500001' ;;
        '/bin/launchctl bootout system/homebrew.mxcl.mihomo'|'/bin/kill -TERM 500001')
            echo "$*" >> "$fixture/actions"; touch "$fixture/stopped" ;;
        *) echo "Unexpected command: $*" >&2; return 2 ;;
    esac
}
reset_fixture
check_engine_conflicts > "$fixture/approved.log" 2>&1
[ -f "$fixture/asked" ] && [ -f "$fixture/stopped" ]
[ "$(cat "$fixture/actions")" = $'/bin/launchctl disable system/homebrew.mxcl.mihomo\n/bin/launchctl bootout system/homebrew.mxcl.mihomo' ]
echo 'PASS: approval disables and unloads the exact live job; own Mimo processes are excluded'
(
    reset_fixture
    confirm_engine_stop() { return 1; }
    status=0; check_engine_conflicts > "$fixture/cancelled.log" 2>&1 || status=$?
    [ "$status" = 130 ] && [ ! -e "$fixture/actions" ]
    grep -q '\[MIMO_INSTALL_CANCELLED\]' "$fixture/cancelled.log"
)
echo 'PASS: cancel leaves every competing process untouched'
(
    reset_fixture; installation_interactive=0
    status=0; check_engine_conflicts > /dev/null 2>&1 || status=$?
    [ "$status" = 130 ] && [ ! -e "$fixture/asked" ] && [ ! -e "$fixture/actions" ]
)
echo 'PASS: noninteractive installs cannot silently stop another proxy'
(
    reset_fixture
    confirm_engine_stop() { touch "$fixture/changed"; }
    if check_engine_conflicts > /dev/null 2>&1; then exit 1; fi
    [ ! -e "$fixture/actions" ]
)
echo 'PASS: process replacement during confirmation invalidates consent'
(
    reset_fixture
    engine_job_target() { return 0; }
    check_engine_conflicts > /dev/null 2>&1
    [ "$(cat "$fixture/actions")" = '/bin/kill -TERM 500001' ]
)
echo 'PASS: a standalone engine receives only a scoped TERM signal'
(
    reset_fixture
    engine_conflict_snapshot() { return 1; }
    if check_engine_conflicts > /dev/null 2>&1; then exit 1; fi
    [ ! -e "$fixture/asked" ] && [ ! -e "$fixture/actions" ]
)
(
    reset_fixture
    engine_job_target() { return 2; }
    if check_engine_conflicts > /dev/null 2>&1; then exit 1; fi
    [ ! -e "$fixture/asked" ] && [ ! -e "$fixture/actions" ]
)
echo 'PASS: inspection failure aborts before asking or stopping'
(
    reset_fixture
    engine_conflict_snapshot() {
        echo '1 0 /sbin/launchd'
        if [ -e "$fixture/stopped" ]; then printf '500002 0 %s\n' "$engine"
        else printf '500001 0 %s\n' "$engine"; fi
    }
    if check_engine_conflicts > "$fixture/respawn.log" 2>&1; then exit 1; fi
    [ "$(wc -l < "$fixture/actions" | tr -d ' ')" = 2 ]
    grep -q 'still running or restarted' "$fixture/respawn.log"
)
echo 'PASS: a respawn fails verification without killing an unapproved replacement'
(
    engine_job_rows() { [ "$1" != gui/501 ] || echo "500001 0 homebrew.mxcl.mihomo"; }
    run() {
        case "$*" in
            '/bin/launchctl print gui/501/homebrew.mxcl.mihomo') echo 'pid = 500001' ;;
            *) return 2 ;;
        esac
    }
    [ "$(engine_job_target 500001 501)" = gui/501/homebrew.mxcl.mihomo ]
)
(
    [ "$(engine_job_target 500001 501)" = system/homebrew.mxcl.mihomo ]
)
echo 'PASS: per-user launch agents and system jobs with a non-root UserName are identified'
(
    run() {
        case "$*" in
            '/bin/launchctl print system/homebrew.mxcl.mihomo') echo 'pid = 500002' ;;
            *) return 2 ;;
        esac
    }
    if engine_job_target 500001 0 > /dev/null 2>&1; then exit 1; fi
)
echo 'PASS: a mismatched launchd PID is never unloaded'
(
    reset_fixture
    run() {
        case "$*" in
            '/bin/launchctl print system/homebrew.mxcl.mihomo') echo 'pid = 500001' ;;
            '/bin/launchctl disable system/homebrew.mxcl.mihomo') return 1 ;;
            *) echo "$*" >> "$fixture/actions"; return 2 ;;
        esac
    }
    if check_engine_conflicts > /dev/null 2>&1; then exit 1; fi
    [ ! -e "$fixture/actions" ] && [ ! -e "$fixture/stopped" ]
)
echo 'PASS: failure to disable a supervising job prevents an incomplete takeover'
