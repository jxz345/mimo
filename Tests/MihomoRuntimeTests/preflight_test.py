#!/usr/bin/env python3
"""VM-only real installer rejection before mutation: bad hash and competing engine."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

from upgrade_test import APP, CORE, ENGINE, SUPERVISOR, FLAGS, HELPER, RUNTIME, read_settings


def run():
    def command(*args, check=True):
        return subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=40, check=check)

    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    assert not (RUNTIME / 'qualification.json').exists()
    original = read_settings()
    assert 'service.settings' not in original
    assert json.loads(original.get('service.routing', b'{}')).get('mode', 'direct') == 'direct'
    root = Path(tempfile.mkdtemp(prefix='mimo-preflight-test-', dir='/var/tmp'))
    passed, success, other = [], False, None
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (HELPER, RUNTIME / 'mihomo', FLAGS)}
    jobs = {label: command('/bin/launchctl', 'print', 'system/' + label).stdout for label in (CORE, ENGINE, SUPERVISOR)}

    def rejected(app, name, message):
        result = command('/usr/bin/env', 'SUDO_USER=jay', '/bin/bash', app / 'Contents/Resources/daemon.sh', 'install', '--non-interactive', check=False)
        (root / (name + '.log')).write_text(result.stdout + result.stderr)
        assert result.returncode != 0 and message in result.stdout + result.stderr
        assert read_settings() == original
        assert before == {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (HELPER, RUNTIME / 'mihomo', FLAGS)}
        assert (RUNTIME / 'gate.state').read_text() == 'direct'
        for label, previous in jobs.items():
            pid = next(line.strip() for line in previous.splitlines() if line.strip().startswith('pid = '))
            assert pid in command('/bin/launchctl', 'print', 'system/' + label).stdout
        passed.append(name)
        print('PASS:', name, flush=True)

    try:
        fixture = root / 'wrong-hash/Mimo.app'
        command('/usr/bin/ditto', APP, fixture)
        manifest = fixture / 'Contents/Resources/MihomoDependency.plist'
        value = plistlib.loads(manifest.read_bytes())
        value['architectures']['arm64']['binarySHA256'] = '0' * 64
        manifest.write_bytes(plistlib.dumps(value))
        command('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', fixture)
        rejected(fixture, 'wrong-engine-checksum-preserves-running-installation', 'checksum verification failed')
        competing = root / 'competing'
        competing.mkdir()
        command('/bin/cp', RUNTIME / 'mihomo', competing / 'mihomo')
        profile = competing / 'blocking.yaml'
        profile.write_text('mode: rule\nmixed-port: 0\nlog-level: silent\ntun:\n  enable: false\ndns:\n  enable: false\nrules:\n  - MATCH,REJECT\n')
        with (root / 'competing.log').open('w') as log:
            other = subprocess.Popen([str(competing / 'mihomo'), '-d', str(competing), '-f', str(profile)], stdout=log, stderr=log)
        time.sleep(0.5)
        assert other.poll() is None
        rejected(APP, 'competing-engine-preserves-running-installation', 'Another Clash/mihomo engine is running')
        success = True
    finally:
        if other is not None:
            other.terminate()
            other.wait(timeout=5)
        (root / 'report.json').write_text(json.dumps({'success': success, 'passed': passed}, indent=2))
        for path in root.iterdir():
            if path.is_file(): path.chmod(0o644)
        root.chmod(0o755)
        print('Evidence:', root, flush=True)


if __name__ == '__main__':
    run()
