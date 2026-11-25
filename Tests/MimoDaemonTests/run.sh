#!/bin/bash
# Runs the daemon script checks: syntax, installer, conflict handling and standalone cleanup tests.
# Usage: bash Tests/MimoDaemonTests/run.sh   (as a normal user; nothing here touches the Mac)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$DIR/../.." && pwd)
for script in "$REPO"/Sources/MimoDaemon/*.sh "$DIR"/*.sh; do
    /bin/bash -n "$script"
done
echo "PASS: bash -n on the daemon scripts and tests"
for test in daemon_test.sh engine_conflicts_test.sh; do
    echo "== $test"
    /bin/bash "$DIR/$test"
done
/usr/bin/perl "$DIR/manual_cleanup_test.pl"
echo "All daemon tests passed."
