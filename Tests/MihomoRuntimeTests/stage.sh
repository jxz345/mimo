#!/bin/bash
# Build an unprivileged test bundle for copying into an isolated arm64 macOS VM.
set -euo pipefail
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 MIHOMO_BINARY OUTPUT_DIRECTORY" >&2
    exit 2
fi
repo="$(cd "$(dirname "$0")/../.." && pwd)"
candidate="$1"
output="$2"
expected=a55a9073f9b7b1fa596a82c034d2dae3407ec34732102b6e42c5513ce3033f34
actual="$(/usr/bin/shasum -a 256 "$candidate")"
if [ "${actual%% *}" != "$expected" ]; then
    echo 'Expected the pinned arm64 mihomo v1.19.34 candidate; checksum differs.' >&2
    exit 1
fi
mkdir -p "$output"
xcrun swiftc -swift-version 6 -parse-as-library \
    "$repo"/Sources/ExitIPShared/*.swift \
    "$repo"/Sources/ExitIPService/MimoLookupSession.swift \
    "$repo"/Tests/MihomoRuntimeTests/render.swift \
    -o "$output/render-profiles"
cp "$candidate" "$output/mihomo"
cp "$repo/Tests/MihomoRuntimeTests/runtime_test.py" "$output/runtime_test.py"
cp "$repo/Tests/MihomoRuntimeTests/firewall_test.py" "$output/firewall_test.py"
cp "$repo/Tests/MihomoRuntimeTests/installation_test.py" "$output/installation_test.py"
cp "$repo/Tests/MihomoRuntimeTests/upgrade_test.py" "$output/upgrade_test.py"
cp "$repo/Tests/MihomoRuntimeTests/boot_test.py" "$output/boot_test.py"
cp "$repo/Tests/MihomoRuntimeTests/network_test.py" "$output/network_test.py"
cp "$repo/Tests/MihomoRuntimeTests/sleep_test.py" "$output/sleep_test.py"
cp "$repo/Tests/MihomoRuntimeTests/preflight_test.py" "$output/preflight_test.py"
cp "$repo/Tests/MihomoRuntimeTests/packet_test.py" "$output/packet_test.py"
cp "$repo/Tests/MihomoRuntimeTests/relay_test.py" "$output/relay_test.py"
cp "$repo/Tests/MihomoRuntimeTests/brew_state.py" "$output/brew_state.py"
cp "$repo/Tests/MihomoRuntimeTests/brew_command.py" "$output/brew_command.py"
xcrun swiftc -swift-version 6 -parse-as-library "$repo"/Sources/ExitIPShared/*.swift \
    "$repo/Tests/MihomoRuntimeTests/installation_check.swift" -o "$output/installation-check"
xcrun swiftc -swift-version 6 -parse-as-library -D EXIT_IP_SERVICE_TEST \
    "$repo"/Sources/ExitIPShared/*.swift "$repo"/Sources/ExitIPCore/*.swift \
    "$repo"/Sources/ExitIPService/*.swift \
    "$repo/Tests/MihomoRuntimeTests/native_transport_check.swift" -o "$output/native-transport-check"
"$output/render-profiles" closed-policy "$output/closed.pf"
echo "Staged unprivileged integration tests in $output"
