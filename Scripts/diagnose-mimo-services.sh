#!/bin/bash
# Read-only snapshot for contradictory dashboard/launchd/controller reports.
# No profiles, proxy endpoints, tokens or entire process command lines are read.
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
if [ "$(/usr/bin/id -u)" != 0 ]; then
    echo 'Run with sudo: sudo bash diagnose-mimo-services.sh' >&2
    exit 1
fi
bounded() {
    /usr/bin/perl -e '$SIG{ALRM}=sub {die "Inspection timed out\n"}; alarm 5; exec @ARGV or die "$!\n"' -- "$@"
}
section() { printf '\n=== %s ===\n' "$1"; }
echo 'Mimo service snapshot. Read-only; no services or firewall rules are changed.'
section 'Mac and UTC time'
/bin/hostname
/bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
section 'Installed app identity'
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
    printf '%s: ' "$key"
    bounded /usr/libexec/PlistBuddy -c "Print :$key" /Applications/Mimo.app/Contents/Info.plist
done
section 'Mimo processes (PID, parent PID, UID, GID, executable)'
bounded /bin/ps -axo pid,ppid,uid,gid,comm | /usr/bin/awk '$0 ~ /mimo-core|mihomo/ || index($0, "/Mimo.app/Contents/MacOS/")'
for label in com.mimo.core com.mimo.supervisor com.mimo.mihomo; do
    section "$label"
    bounded /bin/launchctl print "system/$label" 2>&1 | /usr/bin/awk '
        NR == 1 || /state =|path =|program =|pid =|runs =|last exit|Could not find|Bad request|timed out/ {print}'
done
section 'Saved service intent'
bounded /bin/cat '/Library/Application Support/Mimo/Runtime/services.json'
section 'Gate marker'
bounded /bin/cat '/Library/Application Support/Mimo/Runtime/gate.state'
section 'Controller socket'
bounded /usr/bin/stat -f 'type=%HT owner=%Su group=%Sg mode=%Sp changed=%Sm' '/Library/Application Support/Mimo/Mihomo/controller.sock'
bounded /usr/bin/curl --silent --show-error --max-time 3 --unix-socket '/Library/Application Support/Mimo/Mihomo/controller.sock' http://localhost/version
section 'Proxy and DNS listeners'
bounded /usr/sbin/lsof -nP -iTCP:7890 -iTCP:1053 -iUDP:1053
for child in permission power-guard; do
    section "PF $child"
    bounded /sbin/pfctl -a "com.apple/000.mimo/$child" -sr
done
section 'PF parent policy shape'
bounded /sbin/pfctl -a com.apple/000.mimo -sr | /usr/bin/awk '/^anchor |^block |on lo0/'
section 'Protected resolver'
printf 'show State:/Network/Service/com.mimo.dns/DNS\n' | bounded /usr/sbin/scutil
section 'Finished'
echo 'Compare this snapshot with the dashboard on the Mac named above.'
