#!/usr/bin/env python3
"""Real local-account XPC Start without any Authorization Services credential."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from release_tailnet_lifecycle_test import native, cleanup as restore_network
from upgrade_test import STORAGE, FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent


def cleanup(root):
    marker = root / 'standard-account'
    if marker.exists():
        account = marker.read_text()
        assert account == '_mimoaccept_' + root.name.rsplit('-', 1)[-1]
        path = '/Users/' + account
        if command('/usr/bin/dscl', '.', '-read', path, check=False).returncode == 0:
            command('/usr/bin/dscl', '.', '-delete', path)
        assert command('/usr/bin/dscl', '.', '-read', path, check=False).returncode != 0
        marker.unlink()
    restore_network(root)


def watchdog(root, parent):
    deadline = time.monotonic() + 1200
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
    assert json.loads(native('status', '--json').stdout)['BackendState'] == 'Stopped'
    original = read_settings()
    assert json.loads(original['service.routing'])['mode'] == 'direct'
    assert not json.loads(original['service.settings'])['tailscaleProviderEnabled']
    manifest = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == manifest['helperSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-tailnet-start-', dir='/var/tmp'))
    (root / 'installed-release').touch()
    backup = root / 'private-backup'; backup.mkdir()
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup / name)
    (backup / 'credential.digest').write_text(command(BASE / 'acceptance-client', 'credential-digest').stdout.strip())
    with (root / 'watchdog.log').open('w') as log:
        guard = subprocess.Popen([sys.executable, __file__, '--watchdog', str(root), str(os.getpid())],
                                 stdout=log, stderr=log, start_new_session=True)
    passed, error = [], None
    print('Evidence:', root, flush=True)

    def record(name):
        passed.append(name); print('PASS:', name, flush=True)

    def state():
        return json.loads(command(BASE / 'installation-check', 'core-state').stdout)

    def wait(predicate, label):
        end = time.monotonic() + 100
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.3)
        raise RuntimeError('Timed out: ' + label)

    def admin(*args):
        end = time.monotonic() + 15
        while True:
            result = command(BASE / 'acceptance-client', *args, timeout=70, check=False)
            if result.returncode == 0:
                return
            (root / 'admin-client-error.txt').write_text(result.stdout + result.stderr)
            if 'DaemonFailure.conflict' not in result.stderr or time.monotonic() >= end:
                raise RuntimeError('Administrator setup failed; see private diagnostic')
            time.sleep(.5)

    def unprivileged(user, action):
        # The child receives its real UID, no external authorization form and no
        # inherited GUI authorization. The new endpoint itself must permit Start.
        return command('/usr/bin/sudo', '-n', '-H', '-u', user, BASE / 'installation-check', action).stdout.strip()

    def provider_ready():
        if not state()['settings']['tailscaleProviderEnabled']:
            return False
        result = command('/usr/bin/curl', '--silent', '--fail', '--noproxy', '*', '--max-time', '2',
                         'http://127.0.0.1:18766/provider.yaml', check=False)
        return result.returncode == 0 and 'type: direct' in result.stdout

    try:
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
        native('up')
        wait(provider_ready, 'automatic provider startup')
        original_config = state()['routing']['configuration']
        for user in ('jay', 'mimotest', standard):
            label = 'standard' if user == standard else user
            admin('tailnet', 'stop')
            wait(lambda: not state()['settings']['tailscaleProviderEnabled'], 'manual Stop before local Start')
            before = state()
            wait(lambda: unprivileged(user, 'tailnet-start') == 'provider-enabled', 'local Start without authorization')
            wait(provider_ready, 'real provider serves verified native interface')
            after = state()
            settings = dict(after['settings']); settings['tailscaleProviderEnabled'] = False
            assert settings == before['settings']
            assert after['routing']['configuration'] == original_config
            record(label + '-starts-system-provider-without-authorization-or-other-setting-changes')
            revision = after['revision']
            assert unprivileged(user, 'tailnet-start') == 'provider-enabled'
            assert state()['revision'] == revision
            record(label + '-repeated-Start-is-idempotent')
            assert unprivileged(user, 'tailnet-start-with-settings') == 'failure:invalidRequest'
            assert unprivileged(user, 'tailnet-stop-without-authorization') == 'failure:unauthorized'
            assert state()['revision'] == revision
            record(label + '-Start-rejects-settings-payload-and-does-not-grant-general-administration')

        admin('mode', 'rule')
        wait(lambda: state()['routing'].get('effectiveMode') == 'rule', 'saved Rule approval')
        admin('allow')
        wait(lambda: state()['routing']['phase'] == 'blocked' and bool(state()['routing'].get('blockingIP')), 'empty allowlist blocks Rule')
        admin('tailnet', 'stop')
        wait(lambda: unprivileged(standard, 'tailnet-start') == 'provider-enabled', 'standard Start while Rule blocked')
        wait(provider_ready, 'provider running while public traffic remains blocked')
        current = state()
        assert current['routing']['phase'] == 'blocked'
        assert not current['settings']['allowlist']['addresses']
        denied = command('/usr/bin/sudo', '-n', '-H', '-u', standard, '/usr/bin/curl', '--silent', '--fail',
                         '--noproxy', '*', '--max-time', '6', '--head', 'https://1.1.1.1/', check=False)
        assert denied.returncode != 0
        record('standard-Start-cannot-open-public-traffic-with-an-empty-allowlist')
    except Exception as exc:
        error = type(exc).__name__ + ': ' + str(exc)
    finally:
        cleanup(root); guard.wait(timeout=10)
        assert json.loads(native('status', '--json').stdout)['BackendState'] == 'Stopped'
        record('temporary-standard-account-removed-and-original-Direct-native-off-settings-restored')
        (root / 'report.json').write_text(json.dumps(dict(success=error is None, passed=passed, error=error,
            **{k: manifest[k] for k in ('packageSHA256', 'helperSHA256', 'guiSHA256')},
            scope='Installed normal Release in mimo-vm. Actual XPC processes under two admin UIDs and a temporary standard UID, with no authorization form, real provider HTTP and ordinary-user HTTPS. Not a GUI fast-user-switching test.'), indent=2) + '\n')
        print('RESULT:', 'PASS' if error is None else 'FAIL: ' + error, flush=True)
    return 0 if error is None else 1


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--watchdog':
        watchdog(Path(sys.argv[2]), int(sys.argv[3]))
    else:
        sys.exit(main())
