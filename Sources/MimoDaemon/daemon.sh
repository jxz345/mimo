#!/bin/bash
# Install Mimo's supervisor and its independently supervised core/engine jobs.
# install: administrator-only; uninstall/remove: remove runtime and login items, retain configuration/credentials/logs.
# The root-owned copy permits only the fixed uninstall command through the removal grant.
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LABEL=com.mimo.core
SUPERVISOR=com.mimo.supervisor
ENGINE=com.mimo.mihomo
LEGACY=com.example.exitipmonitor.tailscale-verge
DIR='/Library/Application Support/Mimo'
EXECUTABLE=/Library/PrivilegedHelperTools/mimo-core
LEGACY_EXECUTABLE="/Library/PrivilegedHelperTools/$LABEL"
MANAGER="/Library/PrivilegedHelperTools/mimo-manage"
OLD_MANAGER=/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage
OLD_GRANT=/etc/sudoers.d/exitipmonitor-service
LEGACY_BRIDGE_MARKER='/Library/Application Support/ExitIPMonitor/needs-removal-bridge'
JOBS="$DIR/LaunchDaemons"
RUNTIME="$DIR/Runtime"
PROFILES='/Library/Application Support/Mimo/Mihomo'
APP_IDENTITY='/Library/Application Support/Mimo/app.cdhash'
LOGIN_APP=/Library/PrivilegedHelperTools/MimoUninstaller.app
PLIST="$JOBS/$LABEL.plist"
ENGINE_PLIST="$JOBS/$ENGINE.plist"
SUPERVISOR_PLIST="/Library/LaunchDaemons/$SUPERVISOR.plist"
LEGACY_CORE_PLIST="/Library/LaunchDaemons/$LABEL.plist"
GRANT=/etc/sudoers.d/mimo-service
GUARD='/Library/Application Support/Mimo/Guard'
GUARD_SCRIPT="$GUARD/pf-guard.pl"
BOOT_GUARD=com.mimo.pf-boot
INFRASTRUCTURE=com.mimo.infrastructure
BOOT_PLIST="/Library/LaunchDaemons/$BOOT_GUARD.plist"
HEALTH_PLIST="/Library/LaunchDaemons/$INFRASTRUCTURE.plist"
BOOT_RULES=/etc/pf.anchors/com.mimo.boot
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/command-support.sh" ]; then
    source "$SCRIPT_DIR/command-support.sh"
elif [ -f "$SCRIPT_DIR/../MimoDiagnostics/command-support.sh" ]; then
    source "$SCRIPT_DIR/../MimoDiagnostics/command-support.sh"
else
    source "$DIR/command-support.sh"
fi
run() { bounded_command 20 "$1" "$@"; }
require_root() { [ "$(/usr/bin/id -u)" = 0 ] || { echo 'Administrator authentication is required.' >&2; return 1; }; }

# Never install executable code through a symlink or into a user-writable directory.
secure_directory() {
    local path=$1 mode=${2:-0755}
    [ ! -L "$path" ] || { echo "Refusing symlink: $path" >&2; return 1; }
    if [ -e "$path" ]; then
        [ -d "$path" ] && [ "$(/usr/bin/stat -f %u "$path")" = 0 ] || return 1
    else
        /bin/mkdir "$path" || return 1
    fi
    /usr/sbin/chown root:wheel "$path" && /bin/chmod "$mode" "$path"
}

service_plist() {
    local kind=${1:-core} label=$LABEL argument="" group="" mach=""
    case "$kind" in
        core) mach="<key>MachServices</key><dict><key>$LABEL</key><true/><key>$LABEL.control</key><true/></dict>" ;;
        supervisor)
            label=$SUPERVISOR argument='<string>--supervisor</string>'
            group='<key>GroupName</key><string>_mimo</string>'
            mach="<key>MachServices</key><dict><key>$SUPERVISOR</key><true/><key>$SUPERVISOR.control</key><true/></dict>" ;;
        engine) label=$ENGINE argument='<string>--engine</string>'; group='<key>GroupName</key><string>_mimo</string>' ;;
        *) return 2 ;;
    esac
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$EXECUTABLE</string>$argument</array>
$group
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>ExitTimeOut</key><integer>10</integer>
<key>ProcessType</key><string>Background</string>
$mach
<key>StandardOutPath</key><string>/Library/Logs/Mimo/$kind.log</string>
<key>StandardErrorPath</key><string>/Library/Logs/Mimo/$kind.log</string>
</dict></plist>
PLIST
}

infrastructure_plist() {
    local kind=$1 label argument interval=""
    case "$kind" in
        boot) label=$BOOT_GUARD argument=--boot ;;
        health) label=$INFRASTRUCTURE argument=--check interval='<key>StartInterval</key><integer>10</integer>' ;;
        *) return 2 ;;
    esac
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/usr/bin/perl</string><string>$GUARD_SCRIPT</string><string>$argument</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>10</integer>
<key>ExitTimeOut</key><integer>10</integer>
$interval
<key>StandardOutPath</key><string>/Library/Logs/Mimo/infrastructure.log</string>
<key>StandardErrorPath</key><string>/Library/Logs/Mimo/infrastructure.log</string>
</dict></plist>
PLIST
}

# Homebrew remains owned/run by the installing account. Never execute its mutable
# binary as root: copy first, verify the sealed manifest's hash, then execute the copy.
dependency_source() {
    local architecture=$(/usr/bin/uname -m) prefix
    case "$architecture" in arm64) prefix=/opt/homebrew ;; *) echo 'Mimo requires an Apple silicon Mac.' >&2; return 1 ;; esac
    expected_hash=$(/usr/bin/plutil -extract "architectures.$architecture.binarySHA256" raw -o - "$SCRIPT_DIR/MihomoDependency.plist") || return 1
    [[ "$expected_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
    dependency="$prefix/opt/mihomo@1.19.34/bin/mihomo"
    [ -f "$dependency" ] || {
        echo "Setup incomplete: run '$SCRIPT_DIR/setup.command' as the installing account to install Homebrew and the pinned mihomo dependency." >&2
        return 1
    }
}

ensure_runtime_group() {
    local record gid attribute value
    if record=$(/usr/bin/dscl . -read /Groups/_mimo 2>/dev/null); then
        # An existing populated group is not a private process identity.
        /usr/bin/dscl -plist . -read /Groups/_mimo > "$stage/group.plist" || return 1
        /usr/bin/plutil -lint "$stage/group.plist" >/dev/null || return 1
        for attribute in GroupMembership GroupMembers NestedGroups; do
            value=$(/usr/bin/plutil -extract "dsAttrTypeStandard:$attribute" json -o - "$stage/group.plist" 2>/dev/null) || value='[]'
            if [ "$value" != '[]' ]; then
                echo 'The _mimo group has members; repair its private identity before installation.' >&2
                return 1
            fi
        done
        gid=$(/usr/bin/plutil -extract 'dsAttrTypeStandard:PrimaryGroupID.0' raw -o - "$stage/group.plist") || return 1
        [[ "$gid" =~ ^[0-9]+$ ]] && [ "$gid" -ge 10000 ] || return 1
        runtime_group_id_available "$gid" _mimo || return 1
        return 0
    fi
    for ((gid=10000; gid<20000; gid++)); do
        runtime_group_id_available "$gid" || continue
        /usr/sbin/dseditgroup -o create -i "$gid" -r 'Mimo private runtime' _mimo
        return $?
    done
    echo 'No private runtime group identifier was available.' >&2
    return 1
}

runtime_group_id_available() {
    local gid="$1" expected="${2:-}" record name value matched=0
    # Search the directory search node as well as local records: a primary-group
    # user need not appear in the group's explicit membership attributes.
    record=$(directory_query -search /Users PrimaryGroupID "$gid") || return 1
    [ -z "$record" ] || { echo 'The runtime group identifier is used by an account.' >&2; return 1; }
    record=$(directory_query -list /Groups PrimaryGroupID) || return 1
    while read -r name value; do
        [ -z "$name" ] && continue
        [ "${value##* }" = "$gid" ] || continue
        [ "$value" = "$gid" ] || return 1
        matched=$((matched + 1))
        [ -n "$expected" ] && [ "$name" = "$expected" ] || {
            echo 'The runtime group identifier is shared by another group.' >&2
            return 1
        }
    done <<< "$record"
    [ -z "$expected" ] || [ "$matched" = 1 ]
}

directory_query() { /usr/bin/dscl /Search "$@"; }

check_engine_conflicts() {
    local table pid command
    table=$(run /bin/ps -axo pid=,comm=) || return 1
    while read -r pid command; do
        case "$command" in
            "$RUNTIME/mihomo"|"$EXECUTABLE") ;;
            */mihomo|*/clash|*/clash-meta|*/verge-mihomo|*/clash-verge-service)
                echo "Another Clash/mihomo engine is running (PID $pid). Stop it explicitly before installing Mimo services." >&2
                return 1 ;;
        esac
    done <<< "$table"
}

job_state() {
    local output result=0
    output=$(run /bin/launchctl print "system/$1" 2>&1) || result=$?
    [ "$result" != 0 ] || return 0
    if [ "$result" = 113 ] && [[ "$output" == *'Could not find service'* ]]; then return 1; fi
    echo "Could not inspect system/$1: $output" >&2
    return 2
}

ensure_loaded() {
    local label=$1 plist=$2 state=0
    job_state "$label" || state=$?
    [ "$state" != 0 ] || return 0
    [ "$state" = 1 ] || return 1
    run /bin/launchctl bootstrap system "$plist" && return 0
    # A concurrently starting supervisor may have registered the same job.
    job_state "$label"
}

unload() {
    local label=$1 state=0 ticks=0
    job_state "$label" || state=$?
    [ "$state" != 1 ] || return 0
    [ "$state" = 0 ] || return 1
    run /bin/launchctl bootout "system/$label" || return 1
    while [ "$ticks" -lt 100 ]; do
        state=0; job_state "$label" || state=$?
        [ "$state" != 1 ] || return 0
        [ "$state" = 0 ] || return 1
        /bin/sleep 0.2; ticks=$((ticks + 1))
    done
    echo "Service did not unload: $label" >&2
    return 1
}

# launchctl bootout removes the registration before the last process/child has
# necessarily exited. Wait for those owners to release PF/settings locks before
# offline recovery or replacing their executable and startup files.
wait_mimo_workers() {
    local table pid command found started=$SECONDS
    while [ "$((SECONDS - started))" -lt 45 ]; do
        table=$(bounded_command 5 inspect-mimo-workers /bin/ps -axo pid=,command=) || return 1
        [ -n "$table" ] || return 1
        found=0
        while read -r pid command; do
            case "$command" in
                "$EXECUTABLE"|"$EXECUTABLE "*|"$RUNTIME/mihomo"|"$RUNTIME/mihomo "*|"/usr/bin/perl $GUARD_SCRIPT "*|"/usr/bin/perl5."*" $GUARD_SCRIPT "*) found=1 ;;
            esac
        done <<< "$table"
        [ "$found" = 1 ] || return 0
        /bin/sleep 0.2
    done
    echo 'Mimo workers did not exit; runtime files and recovery data were retained.' >&2
    return 1
}

# Both operations use the same atomic PID lock. An interrupted install leaves its
# backup under Service; ordinary failures restore the previous executable and launch job.
service_lock() {
    [ ! -L "$DIR/Service" ] || return 1
    [ ! -e "$DIR/Service" ] || [ "$(/usr/bin/stat -f %u "$DIR/Service")" = 0 ] || return 1
    /usr/bin/install -d -o root -g wheel -m 0700 "$DIR/Service" || return 1
    /usr/bin/shlock -p $$ -f "$DIR/Service/install.lock" || { echo 'Another service operation is active.' >&2; return 1; }
}

wait_legacy_workers() {
    local table pid command found ticks=0
    while [ "$ticks" -lt 100 ]; do
        table=$(run /bin/ps -axo pid=,command=) || return 1
        [ -n "$table" ] || return 1
        found=0
        while read -r pid command; do
            case "$command" in
                "/bin/bash $DIR/tailscale-verge.sh monitor"*|"/bin/bash $DIR/tailscale-verge.sh http"*) found=1 ;;
            esac
        done <<< "$table"
        [ "$found" = 1 ] || return 0
        /bin/sleep 0.2; ticks=$((ticks + 1))
    done
    echo 'Legacy provider workers did not exit; service replacement stopped.' >&2
    return 1
}

restore_installation() {
    local path result=0 index=0
    unload "$INFRASTRUCTURE" && unload "$BOOT_GUARD" && unload "$LABEL" && unload "$ENGINE" && unload "$SUPERVISOR" || return 1
    wait_mimo_workers || return 1
    if [ "${guard_was_installed:-0}" = 0 ] && [ -f "$GUARD_SCRIPT" ]; then
        run /usr/bin/perl "$GUARD_SCRIPT" --remove || return 1
        /bin/rm -f "$GUARD/boot.id" "$GUARD/health.json" || return 1
    fi
    for path in "${installed_files[@]}"; do
        if [ -f "$stage/backup/$index" ]; then
            /bin/cp -p "$stage/backup/$index" "$path" || result=1
        else
            /bin/rm -f "$path" || result=1
        fi
        index=$((index + 1))
    done
    if [ "${login_installed:-0}" = 1 ]; then /bin/rm -rf "$LOGIN_APP" || result=1; fi
    if [ "${login_backup:-0}" = 1 ]; then /bin/mv "$stage/login-backup.app" "$LOGIN_APP" || result=1; fi
    [ "$result" = 0 ] || return 1
    # Protected upgrades retain the closed gate. A former Direct/legacy install
    # is restored before restarting its old processes.
    if [ "$old_ipv4_policy" = 0 ]; then
        if [ "$old_mode" = direct ]; then run "$stage/new" --uninstall-runtime || return 1
        else run "$stage/new" --restore-ipv6-preferences || return 1; fi
    elif [ "$old_mode" = direct ]; then run "$stage/new" --restore-direct-offline || return 1; fi
    /bin/rm -f "$RUNTIME/maintenance" || return 1
    if [ "$supervisor_loaded" = 1 ]; then
        run /bin/launchctl bootstrap system "$SUPERVISOR_PLIST" || return 1
    elif [ "$old_loaded" = 1 ]; then
        run /bin/launchctl bootstrap system "$LEGACY_CORE_PLIST" || return 1
    fi
    if [ "${boot_loaded:-0}" = 1 ]; then ensure_loaded "$BOOT_GUARD" "$BOOT_PLIST" || return 1; fi
    if [ "${health_loaded:-0}" = 1 ]; then ensure_loaded "$INFRASTRUCTURE" "$HEALTH_PLIST" || return 1; fi
    if [ "$legacy_loaded" = 1 ]; then run /bin/launchctl bootstrap system "/Library/LaunchDaemons/$LEGACY.plist" || return 1; fi
    if [ "$legacy_http_loaded" = 1 ]; then run /bin/launchctl bootstrap system "/Library/LaunchDaemons/$LEGACY-http.plist" || return 1; fi
}

finish_installation() {
    local result=$1
    if [ "$result" != 0 ] && [ "$mutation_started" = 1 ]; then
        if restore_installation; then
            echo 'Service installation failed; previous files and loaded services were restored.' >&2
        else
            echo "Service installation failed; recovery files were retained in $stage. Repair installation before continuing." >&2
            /bin/rm -f "$DIR/Service/install.lock"
            return
        fi
    fi
    [ -z "$stage" ] || /bin/rm -rf "$stage"
    /bin/rm -f "$DIR/Service/install.lock"
}

install_service() (
    require_root || return 1
    local binary="$SCRIPT_DIR/../MacOS/mimo-core" app stage="" owner=${SUDO_USER:-} path state
    local mutation_started=0 old_loaded=0 supervisor_loaded=0 legacy_loaded=0 legacy_http_loaded=0 old_mode=direct old_ipv4_policy=0 index=0
    local boot_loaded=0 health_loaded=0 guard_was_installed=0
    local login_installed=0 login_backup=0
    local legacy_removal_bridge=0
    local dependency expected_hash actual_hash manager_mode
    local installed_files=("$EXECUTABLE" "$PLIST" "$ENGINE_PLIST" "$SUPERVISOR_PLIST" "$LEGACY_CORE_PLIST" "$MANAGER" "$DIR/command-support.sh" "$DIR/cleanup-installation.sh" "$DIR/installed-app" "$GRANT" "$RUNTIME/mihomo" "$RUNTIME/engine.sha256" "$RUNTIME/blocking.yaml" "$LEGACY_EXECUTABLE" "$PROFILES/blocking.yaml")
    installed_files+=("$APP_IDENTITY" "$OLD_MANAGER" "$OLD_GRANT")
    installed_files+=("$GUARD_SCRIPT" "$BOOT_PLIST" "$HEALTH_PLIST" "$BOOT_RULES" /etc/pf.conf "$GUARD/blocking.pf")
    for path in "$LABEL" "$ENGINE" "$SUPERVISOR" "$BOOT_GUARD" "$INFRASTRUCTURE"; do installed_files+=("$GUARD/$path.plist"); done
    [ -x "$binary" ] || { echo 'Install from a built Mimo.app bundle.' >&2; return 1; }
    app=$(cd "$SCRIPT_DIR/../.." && pwd -P) || return 1
    run /usr/bin/codesign --verify --deep --strict "$app" || return 1
    run /usr/bin/codesign --verify --strict "$binary" || return 1
    dependency_source || return 1
    if [ -e "$LEGACY_BRIDGE_MARKER" ]; then
        [ ! -L "$LEGACY_BRIDGE_MARKER" ] && [ -f "$LEGACY_BRIDGE_MARKER" ] &&
            [ "$(/usr/bin/stat -f %u "$LEGACY_BRIDGE_MARKER")" = 0 ] &&
            [ "$(/usr/bin/stat -f %Lp "$LEGACY_BRIDGE_MARKER")" = 600 ] || return 1
        legacy_removal_bridge=1
    fi
    if [ -e "$OLD_MANAGER" ]; then
        [ ! -L "$OLD_MANAGER" ] && [ "$(/usr/bin/stat -f %u "$OLD_MANAGER")" = 0 ] || return 1
        manager_mode=$(/usr/bin/stat -f %Lp "$OLD_MANAGER") || return 1
        [ "$((8#$manager_mode & 022))" = 0 ] || return 1
        legacy_removal_bridge=1
        if ! /usr/bin/grep -Fq '# Mimo legacy uninstall bridge' "$OLD_MANAGER"; then
            actual_hash=$(/usr/bin/shasum -a 256 "$dependency") || return 1
            [ "${actual_hash%% *}" = "$expected_hash" ] || return 1
            bounded_command 90 migrate-old-installation "$OLD_MANAGER" uninstall || return 1
            secure_directory '/Library/Application Support/ExitIPMonitor' 0700 || return 1
            [ ! -L "$LEGACY_BRIDGE_MARKER" ] || return 1
            /usr/bin/install -o root -g wheel -m 0600 /dev/null "$LEGACY_BRIDGE_MARKER" || return 1
        fi
    fi
    for path in com.example.exitipmonitor.daemon com.example.exitipmonitor.supervisor com.example.exitipmonitor.mihomo; do
        state=0; job_state "$path" || state=$?
        if [ "$state" != 1 ] || [ -e "/Library/LaunchDaemons/$path.plist" ]; then
            echo 'Old Mimo services remain without a working removal manager. Repair the old installation before updating.' >&2
            return 1
        fi
    done
    check_engine_conflicts || return 1
    secure_directory /Library/PrivilegedHelperTools && secure_directory /Library/LaunchDaemons &&
        secure_directory /etc/sudoers.d && secure_directory "$DIR" && secure_directory "$JOBS" &&
        secure_directory "$RUNTIME" 0700 && secure_directory /Library/Logs/Mimo &&
        secure_directory "$PROFILES" 0700 &&
        secure_directory "$GUARD" 0700 && secure_directory /etc/pf.anchors || return 1
    service_lock || return 1
    trap 'finish_installation $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for path in "${installed_files[@]}"; do
        [ ! -L "$path" ] || { echo "Refusing symlink: $path" >&2; return 1; }
        [ ! -e "$path" ] || { [ -f "$path" ] && [ "$(/usr/bin/stat -f %u "$path")" = 0 ]; } || return 1
    done
    stage=$(/usr/bin/mktemp -d "$DIR/Service/install.XXXXXXXX") || return 1
    /bin/mkdir "$stage/backup" || return 1
    for path in "${installed_files[@]}"; do
        [ ! -f "$path" ] || /bin/cp -p "$path" "$stage/backup/$index" || return 1
        index=$((index + 1))
    done
    /usr/bin/install -o root -g wheel -m 0755 "$binary" "$stage/new" || return 1
    # Preserve a sealed, root-owned GUI copy solely for per-user login removal.
    # It still works after Finder removes the public bundle, and never runs as root.
    /usr/bin/ditto --noextattr --norsrc --noacl "$app" "$stage/login.app" || return 1
    /usr/sbin/chown -RP root:wheel "$stage/login.app" || return 1
    /bin/chmod -R go-w "$stage/login.app" || return 1
    run /usr/bin/codesign --verify --deep --strict "$stage/login.app" || return 1
    /usr/bin/install -o root -g wheel -m 0755 "$dependency" "$stage/mihomo" || return 1
    actual_hash=$(/usr/bin/shasum -a 256 "$stage/mihomo") || return 1
    [ "${actual_hash%% *}" = "$expected_hash" ] || { echo 'Pinned mihomo checksum verification failed; existing services are unchanged.' >&2; return 1; }
    run "$stage/mihomo" -v | /usr/bin/grep -q 'Mihomo Meta v1.19.34 ' || return 1
    run "$stage/new" --migrate-legacy-names || return 1
    printf '%s\n' "$expected_hash" > "$stage/engine.sha256" || return 1
    for path in core engine supervisor; do
        service_plist "$path" > "$stage/$path.plist" || return 1
        /usr/bin/plutil -lint "$stage/$path.plist" || return 1
    done
    for path in boot health; do
        infrastructure_plist "$path" > "$stage/$path.plist" || return 1
        /usr/bin/plutil -lint "$stage/$path.plist" || return 1
    done
    [ ! -f "$GUARD_SCRIPT" ] || guard_was_installed=1
    /usr/bin/perl -c "$SCRIPT_DIR/pf-guard.pl" || return 1
    run "$stage/new" --print-startup-firewall > "$stage/blocking.pf" || return 1
    run /sbin/pfctl -n -a com.apple/000.mimo -f "$stage/blocking.pf" || return 1
    old_mode=$(run "$stage/new" --installation-mode) || return 1
    case "$old_mode" in direct|rule|global) ;; *) return 1 ;; esac
    for path in "$LABEL" "$SUPERVISOR" "$LEGACY" "$LEGACY-http" "$BOOT_GUARD" "$INFRASTRUCTURE"; do
        state=0; job_state "$path" || state=$?
        [ "$state" != 2 ] || return 1
        if [ "$state" = 0 ]; then
            case "$path" in "$LABEL") old_loaded=1 ;; "$SUPERVISOR") supervisor_loaded=1 ;; "$LEGACY") legacy_loaded=1 ;; "$BOOT_GUARD") boot_loaded=1 ;; "$INFRASTRUCTURE") health_loaded=1 ;; *) legacy_http_loaded=1 ;; esac
        fi
    done
    if [ -f "/Library/LaunchDaemons/$LEGACY.plist" ]; then /usr/bin/touch "$DIR/legacy-provider-enabled" || return 1; fi
    ensure_runtime_group || return 1
    if [ -f "$RUNTIME/ipv6-original.plist" ]; then old_ipv4_policy=1; fi
    mutation_started=1
    run "$stage/new" --begin-maintenance || return 1
    unload "$INFRASTRUCTURE" && unload "$BOOT_GUARD" && unload "$LEGACY-http" && unload "$LEGACY" && unload "$LABEL" && unload "$ENGINE" && unload "$SUPERVISOR" || return 1
    wait_mimo_workers || return 1
    wait_legacy_workers || return 1
    /usr/bin/install -o root -g wheel -m 0755 "$stage/new" "$EXECUTABLE" || return 1
    # Pin only the verified app selected during this administrator-approved
    # installation. Updates replace this pin atomically with the helper/jobs;
    # rollback restores it, and no ordinary user can rewrite it.
    /usr/bin/codesign -d --verbose=4 "$app" 2> "$stage/app-signature" || return 1
    /usr/bin/awk -F= '/^CDHash=/{print $2}' "$stage/app-signature" > "$stage/app.cdhash" || return 1
    [ "$(/usr/bin/wc -c < "$stage/app.cdhash" | /usr/bin/tr -d ' ')" = 41 ] || return 1
    /usr/bin/grep -Eq '^[0-9a-f]{40}$' "$stage/app.cdhash" || return 1
    /usr/bin/grep -Eq '^CodeDirectory .*flags=.*runtime' "$stage/app-signature" || return 1
    /usr/bin/codesign -d --verbose=4 "$stage/login.app" 2> "$stage/login-signature" || return 1
    /usr/bin/awk -F= '/^CDHash=/{print $2}' "$stage/login-signature" > "$stage/login.cdhash" || return 1
    /usr/bin/cmp -s "$stage/app.cdhash" "$stage/login.cdhash" || return 1
    [ ! -L "$LOGIN_APP" ] || return 1
    if [ -e "$LOGIN_APP" ]; then
        [ -d "$LOGIN_APP" ] && [ "$(/usr/bin/stat -f %u "$LOGIN_APP")" = 0 ] || return 1
        /bin/mv "$LOGIN_APP" "$stage/login-backup.app" || return 1
        login_backup=1
    fi
    /bin/mv "$stage/login.app" "$LOGIN_APP" || return 1
    login_installed=1
    /usr/bin/install -o root -g wheel -m 0600 "$stage/app.cdhash" "$APP_IDENTITY" || return 1
    user_name_operation migrate || return 1
    /usr/bin/install -o root -g wheel -m 0755 "$stage/mihomo" "$RUNTIME/mihomo" || return 1
    /usr/bin/install -o root -g wheel -m 0600 "$stage/engine.sha256" "$RUNTIME/engine.sha256" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$stage/core.plist" "$PLIST" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$stage/engine.plist" "$ENGINE_PLIST" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$stage/supervisor.plist" "$SUPERVISOR_PLIST" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$SCRIPT_DIR/pf-guard.pl" "$GUARD_SCRIPT" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$stage/boot.plist" "$BOOT_PLIST" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$stage/health.plist" "$HEALTH_PLIST" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$stage/blocking.pf" "$BOOT_RULES" || return 1
    /usr/bin/install -o root -g wheel -m 0600 "$stage/blocking.pf" "$GUARD/blocking.pf" || return 1
    /usr/bin/install -o root -g wheel -m 0600 "$stage/boot.plist" "$GUARD/$BOOT_GUARD.plist" || return 1
    /usr/bin/install -o root -g wheel -m 0600 "$stage/health.plist" "$GUARD/$INFRASTRUCTURE.plist" || return 1
    /usr/bin/install -o root -g wheel -m 0600 "$stage/supervisor.plist" "$GUARD/$SUPERVISOR.plist" || return 1
    /usr/bin/install -o root -g wheel -m 0600 "$stage/core.plist" "$GUARD/$LABEL.plist" || return 1
    /usr/bin/install -o root -g wheel -m 0600 "$stage/engine.plist" "$GUARD/$ENGINE.plist" || return 1
    run /usr/bin/perl "$GUARD_SCRIPT" --configure || return 1
    run /usr/bin/perl "$GUARD_SCRIPT" --boot || return 1
    /bin/rm -f "$LEGACY_CORE_PLIST" || return 1
    /usr/bin/install -o root -g wheel -m 0755 "${BASH_SOURCE[0]}" "$MANAGER" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$SCRIPT_DIR/command-support.sh" "$DIR/command-support.sh" || return 1
    /usr/bin/install -o root -g wheel -m 0644 "$SCRIPT_DIR/cleanup-installation.sh" "$DIR/cleanup-installation.sh" || return 1
    printf '%s\n' "$app" > "$DIR/installed-app" || return 1
    /bin/chmod 0600 "$DIR/installed-app" || return 1
    run "$EXECUTABLE" --install-right || return 1
    run "$EXECUTABLE" --prepare-runtime || return 1
    # A narrowly scoped, root-owned uninstaller preserves passwordless Homebrew removal.
    if [ -z "$owner" ] || [ "$owner" = root ]; then owner=$(/usr/bin/stat -f %Su /dev/console); fi
    if [[ "$owner" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$owner" != root ] && [ "$owner" != loginwindow ]; then
        printf '%s ALL=(root) NOPASSWD: %s uninstall\n' "$owner" "$MANAGER" > "$stage/grant" || return 1
        /usr/sbin/visudo -cf "$stage/grant" && /usr/bin/install -o root -g wheel -m 0440 "$stage/grant" "$GRANT" || return 1
        if [ "$legacy_removal_bridge" = 1 ]; then
            # Only direct upgrades need this alias: Homebrew may still hold its
            # old cached uninstall command. Fresh installs never create it.
            printf '%s\n' '#!/bin/bash' '# Mimo legacy uninstall bridge' '[ "$#" = 1 ] && [ "$1" = uninstall ] || exit 2' 'exec /Library/PrivilegedHelperTools/mimo-manage uninstall' > "$stage/legacy-bridge" || return 1
            /usr/bin/install -o root -g wheel -m 0755 "$stage/legacy-bridge" "$OLD_MANAGER" || return 1
            printf '%s ALL=(root) NOPASSWD: %s uninstall\n' "$owner" "$OLD_MANAGER" > "$stage/legacy-grant" || return 1
            /usr/sbin/visudo -cf "$stage/legacy-grant" && /usr/bin/install -o root -g wheel -m 0440 "$stage/legacy-grant" "$OLD_GRANT" || return 1
        fi
    fi
    /bin/rm -f "$RUNTIME/maintenance" || return 1
    run /bin/launchctl enable "system/$BOOT_GUARD" || return 1
    run /bin/launchctl enable "system/$INFRASTRUCTURE" || return 1
    run /bin/launchctl bootstrap system "$BOOT_PLIST" || return 1
    run /bin/launchctl enable "system/$SUPERVISOR" || return 1
    run /bin/launchctl bootstrap system "$SUPERVISOR_PLIST" || return 1
    bounded_command 60 check-services "$EXECUTABLE" --check-installation || return 1
    # The supervisor may already have registered the health job during its first
    # watchdog iteration. Never bootstrap the same job twice.
    ensure_loaded "$INFRASTRUCTURE" "$HEALTH_PLIST" || return 1
    run "$EXECUTABLE" --finish-name-migration || return 1
    /bin/rm -f "$LEGACY_EXECUTABLE" || return 1
    # Generated profiles from older builds may contain secrets. Regenerate via
    # stdin/socket delivery; remove obsolete copies only after the new jobs pass.
    /bin/rm -f "$RUNTIME/candidate.yaml" "$RUNTIME/config.yaml" "$RUNTIME/reload.json" "$RUNTIME/blocking.yaml" "$RUNTIME/controller.sock" || return 1
    mutation_started=0
    /bin/rm -f "/Library/LaunchDaemons/$LEGACY.plist" "/Library/LaunchDaemons/$LEGACY-http.plist" "/etc/sudoers.d/mimo-tailscale-verge" "$DIR/tailscale-verge.sh" || return 1
    echo 'Mimo supervisor, core and pinned mihomo installed. Saved mode and service stop preferences are retained. Rule and Global require a fresh verified exit on the saved allowlist.'
)

user_name_operation() {
    local operation=$1 app=$LOGIN_APP records name uid home signature actual expected
    [ -x "$app/Contents/MacOS/mimo-gui" ] && [ ! -L "$app" ] && [ "$(/usr/bin/stat -f %u "$app")" = 0 ] || {
        echo 'The private login-item removal copy is missing. Repair Mimo installation, then retry uninstall.' >&2
        return 1
    }
    run /usr/bin/codesign --verify --deep --strict "$app" || return 1
    signature=$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1) || return 1
    actual=$(/usr/bin/awk -F= '/^CDHash=/{print $2}' <<< "$signature") || return 1
    IFS= read -r expected < "$APP_IDENTITY" || return 1
    [[ "$expected" =~ ^[0-9a-f]{40}$ ]] && [ "$actual" = "$expected" ] || return 1
    records=$(directory_query -list /Users UniqueID) || return 1
    while read -r name uid; do
        [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 500 ] && [ "$uid" -ne 65534 ] || continue
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
        home=$(directory_query -read "/Users/$name" NFSHomeDirectory) || return 1
        home=${home#NFSHomeDirectory: }
        # Only real home directories; never execute the app as root or a service account.
        case "$home" in /*) ;; *) return 1 ;; esac
        [ -d "$home" ] && [ "$(/usr/bin/stat -f %u "$home")" = "$uid" ] || {
            echo "Home directory unavailable for $name; mount it before removing this account's login item." >&2
            return 1
        }
        # asuser selects that account's bootstrap namespace; sudo drops all root
        # privileges before executing the sealed, root-owned removal copy.
        run /bin/launchctl asuser "$uid" /usr/bin/sudo -n -H -u "$name" -- "$app/Contents/Helpers/MimoLegacyLoginCleanup.app/Contents/MacOS/mimo-gui" --unregister-login-item || return 1
        run /bin/launchctl asuser "$uid" /usr/bin/sudo -n -H -u "$name" -- "$app/Contents/MacOS/mimo-gui" --migrate-user-names || return 1
        if [ "$operation" = uninstall ]; then
            run /bin/launchctl asuser "$uid" /usr/bin/sudo -n -H -u "$name" -- "$app/Contents/MacOS/mimo-gui" --unregister-login-item || return 1
        fi
    done <<< "$records"
}

remove_runtime_group() (
    local groups record gid attribute value
    groups=$(/usr/bin/dscl . -list /Groups) || return 1
    /usr/bin/grep -Fxq _mimo <<< "$groups" || return 0
    record=$(/usr/bin/mktemp "$DIR/Service/remove-group.XXXXXXXX") || return 1
    trap '/bin/rm -f "$record"' EXIT
    /usr/bin/dscl -plist . -read /Groups/_mimo > "$record" || return 1
    for attribute in GroupMembership GroupMembers NestedGroups; do
        value=$(/usr/bin/plutil -extract "dsAttrTypeStandard:$attribute" json -o - "$record" 2>/dev/null) || value='[]'
        [ "$value" = '[]' ] || { echo 'Refusing to remove _mimo: the private group now has members.' >&2; return 1; }
    done
    gid=$(/usr/bin/plutil -extract 'dsAttrTypeStandard:PrimaryGroupID.0' raw -o - "$record") || return 1
    [[ "$gid" =~ ^[0-9]+$ ]] && [ "$gid" -ge 10000 ] || return 1
    runtime_group_id_available "$gid" _mimo || return 1
    /usr/sbin/dseditgroup -o delete _mimo
)

remove_runtime_files() {
    local path
    # These roots contain generated runtime material, not user profile sources.
    # Refuse substituted roots, and never traverse symlinks when deleting children.
    for path in "$RUNTIME" "$PROFILES" "$GUARD" "$DIR/Service" "$JOBS" "$DIR/TailscaleVerge" "$LOGIN_APP"; do
        [ ! -L "$path" ] || return 1
        [ ! -e "$path" ] || { [ -d "$path" ] && [ "$(/usr/bin/stat -f %u "$path")" = 0 ]; } || return 1
    done
    for path in "$RUNTIME"/* "$RUNTIME"/.[!.]* "$RUNTIME"/..?*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        [ "$path" = "$RUNTIME/services.json" ] || /bin/rm -rf "$path" || return 1
    done
    /bin/rm -rf "$PROFILES" "$GUARD" "$JOBS" "$DIR/TailscaleVerge" || return 1
    for path in "$DIR/Service"/install.*; do
        # Keep the active install.lock until the exit trap releases it.
        [ -d "$path" ] && [ ! -L "$path" ] || continue
        /bin/rm -rf "$path" || return 1
    done
    /bin/rm -f "$DIR/Service/instance.lock" "$DIR/legacy-provider-enabled"
}

uninstall_service() (
    require_root || return 1
    local app
    service_lock || return 1
    trap '/bin/rm -f "$DIR/Service/install.lock"' EXIT
    if [ -f "$DIR/installed-app" ]; then
        IFS= read -r app < "$DIR/installed-app"
        case "$app" in /*/Mimo.app|/*/ExitIPMonitor.app) ;; *) return 1 ;; esac
        source "$DIR/cleanup-installation.sh"
        cleanup_app=$app cleanup_uid=0 cleanup_translocations="" cleanup_matches=()
        cleanup_stop_app || return 1
        user_name_operation uninstall || return 1
    fi
    if [ -x "$EXECUTABLE" ] && [ -f "$SUPERVISOR_PLIST" ]; then run "$EXECUTABLE" --begin-maintenance || return 1; fi
    # Stop the independent repair job before removing the services it protects.
    unload "$INFRASTRUCTURE" && unload "$BOOT_GUARD" && unload "$LABEL" && unload "$ENGINE" && unload "$SUPERVISOR" && unload "$LEGACY-http" && unload "$LEGACY" || return 1
    wait_mimo_workers || return 1
    if [ -x "$EXECUTABLE" ] && [ -f "$SUPERVISOR_PLIST" ]; then run "$EXECUTABLE" --uninstall-runtime || return 1; fi
    if [ -f "$GUARD_SCRIPT" ]; then run /usr/bin/perl "$GUARD_SCRIPT" --remove || return 1; fi
    wait_legacy_workers || return 1
    if [ -n "${app:-}" ]; then
        cleanup_find_processes || return 1
        [ "${#cleanup_matches[@]}" = 0 ] || { echo 'App restarted during removal. Quit it and retry.' >&2; return 1; }
    fi
    if [ -x "$EXECUTABLE" ]; then run "$EXECUTABLE" --remove-right || return 1; fi
    remove_runtime_group || return 1
    /bin/rm -f "$PLIST" "$ENGINE_PLIST" "$SUPERVISOR_PLIST" "$LEGACY_CORE_PLIST" "$EXECUTABLE" "$LEGACY_EXECUTABLE" "$RUNTIME/maintenance" "$RUNTIME/mihomo" "$RUNTIME/engine.sha256" "/Library/LaunchDaemons/$LEGACY.plist" "/Library/LaunchDaemons/$LEGACY-http.plist" || return 1
    # Runtime profiles can contain proxy/probe credentials. Retain their source
    # settings in machine storage/Keychain, never stale generated copies.
    /bin/rm -f "$RUNTIME/candidate.yaml" "$RUNTIME/blocking.yaml" "$RUNTIME/reload.json" "$RUNTIME/controller.sock" "$RUNTIME/guard.pf" "$RUNTIME/native-transport.pf" "$PROFILES/blocking.yaml" "$PROFILES/controller.sock" || return 1
    /bin/rm -f "$DIR/TailscaleVerge/provider.yaml" "$DIR/TailscaleVerge/state" "$DIR/tailscale-verge.sh" || return 1
    /bin/rm -f "$BOOT_PLIST" "$HEALTH_PLIST" "$BOOT_RULES" "$GUARD_SCRIPT" "$GUARD/blocking.pf" "$GUARD/boot.id" "$GUARD/health.json" "$RUNTIME/guard.expected" || return 1
    for app in "$LABEL" "$ENGINE" "$SUPERVISOR" "$BOOT_GUARD" "$INFRASTRUCTURE"; do /bin/rm -f "$GUARD/$app.plist" || return 1; done
    remove_runtime_files || return 1
    # Keep the manager and its fixed removal grant until every cleanup step succeeds.
    /bin/rm -rf "$LOGIN_APP" "$APP_IDENTITY" "$DIR/installed-app" "$DIR/command-support.sh" "$DIR/cleanup-installation.sh" "$DIR/names-migrated.v1" "$GRANT" "/etc/sudoers.d/mimo-tailscale-verge" "$MANAGER" "$OLD_MANAGER" "$OLD_GRANT" || return 1
    echo 'Mimo services, firewall guard, login items, private group and runtime files removed; Direct networking restored. Settings, credentials, Homebrew and logs were retained.'
)

main() {
    [ "$#" = 1 ] || return 2
    case "$1" in
        install) install_service ;;
        remove|uninstall) uninstall_service ;;
        status) /bin/launchctl print "system/$SUPERVISOR" ;;
        *) echo 'Usage: daemon.sh install | status | uninstall' >&2; return 2 ;;
    esac
}
if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then main "$@"; fi
