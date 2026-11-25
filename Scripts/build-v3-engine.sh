#!/bin/bash
# Build only; never starts an engine or changes host network settings.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GO_BIN=${MIMO_GO:-go}
COMMIT=0455d0d28c4526937380505153e65a843d8612e8
VERSION=v1.19.34-mimo-v3.2
BUILD_ROOT=${MIMO_V3_BUILD_ROOT:-"$ROOT/.build/v3-engine-repro"}
export GOTOOLCHAIN=local CGO_ENABLED=0
if [[ $("$GO_BIN" version) != 'go version go1.26.11 '* ]]; then
    echo 'Use Go 1.26.11 (set MIMO_GO to its absolute path).' >&2
    exit 1
fi
if [[ -e "$BUILD_ROOT/source" || -e "$BUILD_ROOT/sing-tun" ]]; then
    echo 'Choose a fresh MIMO_V3_BUILD_ROOT; existing source is not overwritten.' >&2
    exit 1
fi
mkdir -p "$BUILD_ROOT"
BUILD_ROOT=$(cd "$BUILD_ROOT" && pwd)
git init --quiet "$BUILD_ROOT/source"
git -C "$BUILD_ROOT/source" remote add origin https://github.com/MetaCubeX/mihomo.git
git -C "$BUILD_ROOT/source" fetch --quiet --depth=1 origin "$COMMIT"
git -C "$BUILD_ROOT/source" checkout --quiet --detach "$COMMIT"
git -C "$BUILD_ROOT/source" apply --check "$ROOT/Patches/mihomo-1.19.34-v3.patch"
git -C "$BUILD_ROOT/source" apply "$ROOT/Patches/mihomo-1.19.34-v3.patch"
cd "$BUILD_ROOT/source"
"$GO_BIN" mod download -json github.com/metacubex/sing-tun@v0.4.29 > "$BUILD_ROOT/sing-tun-download.json"
DEP_DIR=$(python3 - "$BUILD_ROOT/sing-tun-download.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value['Sum'] == 'h1:KIULEuW0iFXxLegOgrW8orq5Sx4TCBBhwo6j8+CIFBs='
print(value['Dir'])
PY
)
cp -R "$DEP_DIR" "$BUILD_ROOT/sing-tun"
chmod -R u+w "$BUILD_ROOT/sing-tun"
git -C "$BUILD_ROOT/sing-tun" apply --check "$ROOT/Patches/sing-tun-0.4.29-no-ping.patch"
git -C "$BUILD_ROOT/sing-tun" apply "$ROOT/Patches/sing-tun-0.4.29-no-ping.patch"
"$GO_BIN" mod edit -replace=github.com/metacubex/sing-tun=../sing-tun
"$GO_BIN" test -tags with_gvisor ./tunnel ./config ./adapter/outbound
"$GO_BIN" test -tags with_gvisor ./constant -run '^TestNoPingStackRoundTrip$'
"$GO_BIN" test -tags with_gvisor ./listener/sing_tun -run '^TestMimoNativeRoute'
(
    cd "$BUILD_ROOT/sing-tun"
    "$GO_BIN" test -tags with_gvisor . -run '^TestBlockEcho'
)
"$GO_BIN" build -tags with_gvisor -trimpath \
    -ldflags "-X github.com/metacubex/mihomo/constant.Version=$VERSION -X github.com/metacubex/mihomo/constant.BuildTime=2026-11-25" \
    -o "$BUILD_ROOT/mihomo-v3.bin" .
shasum -a 256 "$BUILD_ROOT/mihomo-v3.bin"
echo 'Built the v3 engine. Compare its SHA256 with Configuration/MihomoDependency.plist before packaging.'
