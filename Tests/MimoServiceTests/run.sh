#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$REPO/.build/service-tests}"
mkdir -p "$output"
export MIMO_LOG_DIRECTORY="$output/logs"
xcrun swiftc -swift-version 6 -parse-as-library -D MIMO_SERVICE_TEST \
    "$REPO"/Sources/MimoShared/*.swift "$REPO"/Sources/MimoCore/*.swift \
    "$REPO"/Sources/MimoService/*.swift "$REPO"/Tests/MimoServiceTests/*.swift \
    -o "$output/service-tests"
"$output/service-tests" "$output"
