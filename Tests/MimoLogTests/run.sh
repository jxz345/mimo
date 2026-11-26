#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$REPO/.build/log-tests}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
export MIMO_TEST_APP_GROUP="group.com.mimo.log-tests.$(/usr/bin/uuidgen)"
xcrun swiftc -swift-version 6 -parse-as-library \
    "$REPO"/Sources/MimoShared/*.swift "$REPO/Sources/MimoCore/RuntimeLog.swift" \
    "$REPO/Tests/MimoLogTests/log_test.swift" -o "$output/log-tests"
"$output/log-tests"
