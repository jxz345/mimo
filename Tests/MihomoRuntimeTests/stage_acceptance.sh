#!/bin/bash
# Deliberately separate from release packaging; these executables refuse physical Macs.
set -euo pipefail
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    exit 2
fi
repo="$(cd "$(dirname "$0")/../.." && pwd)"
output="$1"
mkdir -p "$output"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
python3 - "$repo" "$manifest" <<'PY'
import hashlib, json, sys
from pathlib import Path
repo = Path(sys.argv[1])
paths = []
for directory in ('Sources/MimoShared', 'Sources/MimoCore', 'Sources/MimoService'):
    paths.extend((repo / directory).glob('*.swift'))
paths.extend(repo / ('Tests/MihomoRuntimeTests/' + name) for name in (
    'stage_acceptance.sh', 'acceptance_client.swift', 'installation_check.swift', 'installed_acceptance_test.py', 'saved_proxy_test.py', 'installed_boot_test.py', 'upgrade_test.py', 'packet_test.py'))
Path(sys.argv[2]).write_text(json.dumps({str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}, indent=2))
PY
xcrun swiftc -swift-version 6 -parse-as-library -O -D MIMO_DAEMON -D MIMO_VM_ACCEPTANCE \
    "$repo"/Sources/MimoShared/*.swift "$repo"/Sources/MimoCore/*.swift \
    "$repo"/Sources/MimoService/*.swift -o "$output/mimo-core-vm-acceptance"
xcrun swiftc -swift-version 6 -parse-as-library \
    "$repo"/Sources/MimoShared/*.swift "$repo/Sources/MimoService/SystemCredentials.swift" \
    "$repo/Tests/MihomoRuntimeTests/acceptance_client.swift" -o "$output/acceptance-client"
xcrun swiftc -swift-version 6 -parse-as-library "$repo"/Sources/MimoShared/*.swift \
    "$repo/Tests/MihomoRuntimeTests/installation_check.swift" -o "$output/installation-check"
for binary in mimo-core-vm-acceptance acceptance-client installation-check; do
    /usr/bin/codesign --force --sign - --timestamp=none "$output/$binary"
done
cp "$repo/Tests/MihomoRuntimeTests/installed_acceptance_test.py" "$output/"
cp "$repo/Tests/MihomoRuntimeTests/saved_proxy_test.py" "$output/"
cp "$repo/Tests/MihomoRuntimeTests/installed_boot_test.py" "$output/"
cp "$repo/Tests/MihomoRuntimeTests/upgrade_test.py" "$output/"
cp "$repo/Tests/MihomoRuntimeTests/packet_test.py" "$output/"
python3 - "$repo" "$manifest" "$output" <<'PY'
import hashlib, json, sys
from pathlib import Path
repo, manifest, output = map(Path, sys.argv[1:])
inputs = json.loads(manifest.read_text())
assert all(hashlib.sha256((repo / name).read_bytes()).hexdigest() == digest for name, digest in inputs.items()), 'Sources changed during acceptance build; rebuild before running it.'
result = {'scope': 'VM-only acceptance; not release qualification', 'inputs': inputs,
          'helperSHA256': hashlib.sha256((output / 'mimo-core-vm-acceptance').read_bytes()).hexdigest()}
(output / 'acceptance-build.json').write_text(json.dumps(result, indent=2) + '\n')
PY
echo "Staged VM-only installed-service acceptance tests. No release qualification granted."
