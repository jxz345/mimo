#!/usr/bin/env python3
"""Provide a bounded, real service outage for observing the installed VM GUI."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from saved_proxy_test import restore
from upgrade_test import CORE, SUPERVISOR, HELPER, STORAGE, FLAGS, read_settings

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0 and command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    assert json.loads(read_settings()['service.routing'])['mode'] == 'direct'
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-release-ui-outage-', dir='/var/tmp'))
    (root / 'installed-release').touch()
    backup = root / 'private-backup'; backup.mkdir()
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup / name)
    (backup / 'credential.digest').write_text(command(BASE / 'acceptance-client', 'credential-digest').stdout.strip())
    with (root / 'watchdog.log').open('w') as log:
        guard = subprocess.Popen([sys.executable, BASE / 'saved_proxy_test.py', '--watchdog', root, str(os.getpid())],
                                 stdout=log, stderr=log, start_new_session=True)
    checks = []
    error = None
    print('Evidence:', root, flush=True)
    try:
        command(BASE / 'acceptance-client', 'mode', 'global', timeout=65)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            state = json.loads(command(BASE / 'installation-check').stdout)
            if state['phase'] == 'active' and state['effectiveMode'] == 'global': break
            time.sleep(.5)
        else: raise RuntimeError('Saved Global did not become ready')
        checks.append('saved-Global-baseline-ready')
        print('READY: Global baseline; waiting for GUI observation and proceed marker', flush=True)
        deadline = time.monotonic() + 90
        while not (root / 'proceed').exists():
            assert time.monotonic() < deadline, 'GUI baseline observation timed out'
            time.sleep(.2)
        command(HELPER, '--begin-maintenance')
        for label in (CORE, SUPERVISOR):
            command('/bin/launchctl', 'bootout', 'system/' + label)
        print('OBSERVE: core and supervisor unavailable for 35 seconds', flush=True)
        result = command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail', '--noproxy', '*',
                         '--max-time', '5', '--head', 'https://1.1.1.1/', check=False)
        assert result.returncode != 0
        checks.append('ordinary-user-HTTPS-denied-during-service-outage')
        time.sleep(30)
    except Exception as exc:
        error = str(exc)
    finally:
        restore(root)
        guard.wait(timeout=8)
        checks.append('original-Direct-configuration-password-and-service-intent-restored')
        (root / 'report.json').write_text(json.dumps(dict(success=error is None, passed=checks, error=error,
            packageSHA256=build['packageSHA256'], helperSHA256=build['helperSHA256'],
            scope='Actual normal-Release service outage in mimo-vm; GUI observations recorded separately'), indent=2) + '\n')
        print('RESULT:', 'PASS' if error is None else 'FAIL', flush=True)
    return 0 if error is None else 1


if __name__ == '__main__':
    sys.exit(main())
