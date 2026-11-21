#!/usr/bin/env python3
"""Real installed-app signature checks for admin/standard accounts in mimo-vm.

The exact Release GUI's read-only diagnostic uses the same control endpoints as
its dashboard. No test helper is granted the GUI's signature or an admin right.
This does not substitute for physical dashboard interaction.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from upgrade_test import STORAGE, FLAGS, HELPER

BASE = Path(__file__).resolve().parent
APP = Path('/Applications/Mimo.app')
GUI = APP / 'Contents/MacOS/mimo-gui'
IDENTITY = Path('/Library/Application Support/Mimo/app.cdhash')


def cleanup(root):
    marker = root / 'standard-account'
    if not marker.exists():
        return
    user = marker.read_text()
    assert user == '_mimoaccept_' + root.name.rsplit('-', 1)[-1]
    account = '/Users/' + user
    if command('/usr/bin/dscl', '.', '-read', account, check=False).returncode == 0:
        command('/usr/bin/dscl', '.', '-delete', account)
    assert command('/usr/bin/dscl', '.', '-read', account, check=False).returncode != 0
    marker.unlink()


def watchdog(root, parent):
    deadline = time.monotonic() + 600
    while not (root / 'cleanup-complete').exists() and time.monotonic() < deadline:
        try:
            os.kill(parent, 0)
        except ProcessLookupError:
            break
        time.sleep(.5)
    cleanup(root)


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-password-free-', dir='/var/tmp'))
    manifest = json.loads((BASE / 'release-build.json').read_text())
    checks, error = [], None
    print('Evidence:', root, flush=True)

    def record(name):
        checks.append(name)
        print('PASS:', name, flush=True)

    def state():
        return json.loads(command(BASE / 'installation-check', 'core-state').stdout)

    def invoke(user, executable, *args, check=True):
        return command('/usr/bin/sudo', '-n', '-H', '-u', user, executable, *args, check=check, timeout=45)

    original = state()
    assert original['routing']['effectiveMode'] == 'direct'
    flags = FLAGS.read_bytes()
    secret = command(BASE / 'acceptance-client', 'credential-digest').stdout.strip()
    with (root / 'watchdog.log').open('w') as log:
        guard = subprocess.Popen([sys.executable, __file__, '--watchdog', str(root), str(os.getpid())],
                                 stdout=log, stderr=log, start_new_session=True)
    try:
        assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == manifest['helperSHA256']
        assert hashlib.sha256(GUI.read_bytes()).hexdigest() == manifest['guiSHA256']
        command('/usr/bin/codesign', '--verify', '--deep', '--strict', APP)
        signature = command('/usr/bin/codesign', '-d', '--verbose=4', APP).stderr
        assert 'runtime' in signature
        cdhash = re.search(r'^CDHash=([0-9a-f]{40})$', signature, re.M)[1]
        assert IDENTITY.read_text().strip() == cdhash
        assert IDENTITY.stat().st_uid == 0 and IDENTITY.stat().st_mode & 0o777 == 0o600
        record('exact-Release-app-hardened-and-root-owned-identity-pinned')
        standard = '_mimoaccept_' + root.name.rsplit('-', 1)[-1]
        account = '/Users/' + standard
        assert command('/usr/bin/dscl', '.', '-read', account, check=False).returncode != 0
        (root / 'standard-account').write_text(standard)
        command('/usr/bin/dscl', '.', '-create', account)
        used = {entry.pw_uid for entry in pwd.getpwall()}
        uid = next(value for value in range(600, 1000) if value not in used)
        for key, value in [('UniqueID', str(uid)), ('PrimaryGroupID', '20'), ('UserShell', '/usr/bin/false'),
                           ('NFSHomeDirectory', '/var/empty'), ('IsHidden', '1'), ('AuthenticationAuthority', ';DisabledUser;')]:
            command('/usr/bin/dscl', '.', '-create', account, key, value)
        assert 'admin' not in command('/usr/bin/id', '-Gn', standard).stdout.split()
        for user in ('jay', 'mimotest', standard):
            label = 'standard' if user == standard else user
            for attempt in range(2):
                result = invoke(user, GUI, '--check-service-access')
                assert result.stdout.startswith('PASS: installed-app controls and private profile access;')
            record(label + '-installed-app-endpoints-profile-and-relaunch-without-authorization')
            # An unrelated program with the same bundle identifier still fails.
            rejected = invoke(user, BASE / 'installation-check', 'installed-app-control')
            assert rejected.stdout.splitlines() == ['signature-rejected', 'signature-rejected']
            record(label + '-same-identifier-different-code-rejected-by-both-endpoints')
            rejected = invoke(user, BASE / 'installation-check', 'core', 'stop', check=False)
            assert rejected.returncode != 0 and 'unauthorized' in (rejected.stdout + rejected.stderr).lower()
            record(label + '-public-endpoint-still-denies-service-mutation')
        final = state()
        assert final['settings'] == original['settings'] and final['revision'] == original['revision']
        assert final['routing']['configuration'] == original['routing']['configuration']
        assert flags == FLAGS.read_bytes()
        assert secret == command(BASE / 'acceptance-client', 'credential-digest').stdout.strip()
        record('shared-settings-service-intent-and-private-credential-unchanged')
        record('trusted-app-cannot-send-root-only-approval-or-network-invalidation')
    except BaseException as failure:
        error = type(failure).__name__
        raise
    finally:
        cleanup(root)
        (root / 'cleanup-complete').touch()
        guard.wait(timeout=5)
        record('temporary-standard-account-removed')
        (root / 'report.json').write_text(json.dumps(dict(success=error is None, passed=checks, error=error,
            helperSHA256=manifest['helperSHA256'], packageSHA256=manifest['packageSHA256'],
            scope='Exact installed Release GUI read-only access diagnostic, two administrators and a real standard UID. Fresh process each time, no Authorization Services form. Root-only commands and unrelated clients denied. No physical dashboard interaction claimed.'), indent=2) + '\n')


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--watchdog':
        watchdog(Path(sys.argv[2]), int(sys.argv[3]))
    else:
        main()
