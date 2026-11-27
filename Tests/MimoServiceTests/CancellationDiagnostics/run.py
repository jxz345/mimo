#!/usr/bin/env python3
"""Test real monitor cancellation and daemon commits with isolated local storage.

No provider, daemon, firewall, DNS, Keychain, or VM calls are made. The client is
held until cancellation and snapshots the actual RuntimeLog inside onCancel.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / '.build') or output.exists():
        parser.error('Choose a new output directory under this repository .build')
    output.mkdir(parents=True, mode=0o700)
    sources = [p for folder in ('MimoShared', 'MimoCore', 'MimoService')
               for p in sorted((ROOT / 'Sources' / folder).glob('*.swift'))]
    for name in ('MonitoringEngine.swift', 'DaemonService.swift'):
        source = next(p for p in sources if p.name == name)
        (output / name).write_bytes(source.read_bytes())
    (output / 'source-identity.json').write_text(json.dumps({
        str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sources + [HERE / 'cases.swift']}, indent=2) + '\n')
    command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
               '-D', 'MIMO_SERVICE_TEST', *map(str, sources), str(HERE / 'cases.swift'),
               '-o', str(output / 'cancellation-diagnostics-tests')]
    compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    (output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
    if compiled.returncode:
        print((compiled.stdout + compiled.stderr)[-6000:])
        return compiled.returncode
    env = dict(os.environ, MIMO_LOG_DIRECTORY=str(output / 'logs'),
               MIMO_TEST_APP_GROUP='group.com.mimo.tests.' + uuid.uuid4().hex)
    tested = subprocess.run([str(output / 'cancellation-diagnostics-tests'), str(output)],
                            cwd=ROOT, env=env, capture_output=True, text=True, timeout=90)
    (output / 'test.log').write_text(tested.stdout + tested.stderr)
    print(tested.stdout + tested.stderr)
    return tested.returncode


if __name__ == '__main__':
    sys.exit(main())
