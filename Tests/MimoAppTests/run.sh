#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$(mktemp -d)}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
export MIMO_TEST_APP_GROUP="group.com.mimo.tests.$(/usr/bin/uuidgen)"
export MIMO_LOG_DIRECTORY="$output/logs"
xcrun swiftc -swift-version 6 -parse-as-library -D MIMO_TEST_HOST \
    "$REPO"/Sources/MimoShared/*.swift "$REPO"/Sources/MimoCore/*.swift "$REPO"/Sources/MimoApp/*.swift \
    "$REPO"/Tests/MimoAppTests/*.swift -o "$output/credential-tests"
"$output/credential-tests" "$output"
