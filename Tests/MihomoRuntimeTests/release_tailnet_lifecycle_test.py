#!/usr/bin/env python3
"""Installed Release only: native Tailscale down/up, provider Stop and real DNS changes.

All operations execute in mimo-vm. No helper substitution or synthetic notifications.
The initial native state must be Stopped; an independent worker restores it and Direct.
"""
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
from release_network_progress_test import offsets, events, LOGS, GUI_LOGS
from saved_proxy_test import restore
from upgrade_test import STORAGE, FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent
NATIVE = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'


def native(*args):
    return command('/usr/bin/sudo', '-n', '-u', 'jay', NATIVE, *args, timeout=45)


def cleanup(root):
    if (root / 'cleanup-complete').exists():
        return
    native('down')
    if (root / 'dns-backup.json').exists():
        dns = json.loads((root / 'dns-backup.json').read_text())
        command('/usr/sbin/networksetup', '-setdnsservers', dns['service'], *(dns['servers'] or ['Empty']))
    restore(root)


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
    modes = sys.argv[1:] or ['direct', 'rule', 'global']
    assert all(mode in ['direct', 'rule', 'global'] for mode in modes)
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    assert json.loads(native('status', '--json').stdout)['BackendState'] == 'Stopped'
    original = read_settings()
    assert json.loads(original['service.routing'])['mode'] == 'direct'
    assert not json.loads(original['service.settings'])['tailscaleProviderEnabled']
    manifest = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == manifest['helperSHA256']
    assert hashlib.sha256(Path('/Applications/Mimo.app/Contents/MacOS/mimo-gui').read_bytes()).hexdigest() == manifest['guiSHA256']
    assert command('/usr/bin/pgrep', '-x', 'mimo-gui').stdout.strip()
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-tailnet-lifecycle-', dir='/var/tmp'))
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
        return json.loads(command(BASE / 'installation-check', 'core-state', timeout=15).stdout)

    def client(*args):
        end = time.monotonic() + 20
        while True:
            result = command(BASE / 'acceptance-client', *args, timeout=70, check=False)
            if result.returncode == 0:
                return result
            (root / 'client-error-private.txt').write_text(result.stdout + result.stderr)
            # A native transition may have just committed a new settings revision.
            # Fetching a new state and retrying is valid only for that explicit conflict.
            if 'DaemonFailure.conflict' not in result.stderr or time.monotonic() >= end:
                failures = [name for name in ('conflict', 'unavailable', 'unauthorized', 'storage') if 'DaemonFailure.' + name in result.stderr]
                raise RuntimeError('Client ' + args[0] + ' failed: ' + (','.join(failures) or 'see private diagnostic'))
            time.sleep(.5)

    def wait(predicate, description, timeout=100):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.3)
        raise RuntimeError('Timed out: ' + description)

    def active(mode):
        r = state()['routing']
        return r['phase'] == 'active' and r.get('effectiveMode') == mode

    def provider(enabled):
        s = state()
        if s['settings']['tailscaleProviderEnabled'] != enabled:
            return False
        response = command('/usr/bin/curl', '--silent', '--fail', '--noproxy', '*', '--max-time', '2',
                           'http://127.0.0.1:18766/provider.yaml', check=False)
        return (response.returncode == 0 and 'type: direct' in response.stdout) if enabled else response.returncode != 0

    def gui_kind():
        rows = [r for r in events(GUI_LOGS, {}) if r['event'] == 'mimo_access_presentation_changed']
        rows.sort(key=lambda r: r.get('timestamp', ''))
        return rows[-1]['fields']['kind'] if rows else None

    def https():
        command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail', '--noproxy', '*',
                '--max-time', '8', '--head', 'https://1.1.1.1/')

    def set_native(enabled):
        baseline = offsets(LOGS)
        native('up' if enabled else 'down')
        wait(lambda: json.loads(native('status', '--json').stdout)['BackendState'] == ('Running' if enabled else 'Stopped'), 'native Tailscale state')
        wait(lambda: state()['routing'].get('tailnetExpected') == enabled, 'core observes native state')
        wait(lambda: provider(enabled), 'provider follows native state')
        if enabled:
            wait(lambda: any(r['event'] == 'mimo_tailnet_automatic_state_changed' and r['fields'].get('enabled') == 'true'
                             for r in events(LOGS, baseline)), 'automatic Start transaction completed')

    try:
        wait(lambda: provider(False) and state()['routing'].get('tailnetExpected') is False, 'initial off state')
        record('native-off-provider-off')
        for mode in modes:
            # A normal mode-selection test starts after the preceding VPN teardown
            # and its IP check finish, rather than selecting during those changes.
            wait(lambda: active(state()['routing']['configuration']['mode']) and 'ready' in state()['status'], 'previous network check settled')
            time.sleep(8)
            baseline = offsets(LOGS)
            client('mode', mode); wait(lambda: active(mode), mode + ' approval')
            time.sleep(8)
            if mode != 'direct':
                opened = [r for r in events(LOGS, baseline) if r['event'] == 'mimo_traffic_opened']
                assert len(opened) == 1, mode + ' performed redundant activation'
                wait(lambda: gui_kind() == 'verified', 'provider-off is not a warning')
                record(mode + '-single-activation-with-native-off-and-no-warning')
            set_native(True)
            wait(lambda: active(mode), 'public access after native connect')
            record(mode + '-native-connect-automatically-starts-real-provider')
            client('tailnet', 'stop')
            wait(lambda: provider(False), 'manual provider stop')
            wait(lambda: gui_kind() == 'tailnetWarning', 'GUI warns while native Tailscale is running')
            time.sleep(5)
            assert not state()['settings']['tailscaleProviderEnabled']
            https()
            record(mode + '-manual-stop-reports-failure-and-preserves-public-access')
            set_native(False)
            wait(lambda: active(mode), 'public access after native disconnect')
            set_native(True)
            wait(lambda: active(mode), 'public access after native reconnect')
            https()
            record(mode + '-reconnect-overrides-manual-stop')
            set_native(False)
            wait(lambda: active(mode), 'access after native off')
            wait(lambda: gui_kind() == ('direct' if mode == 'direct' else 'verified'), 'off state clears provider warning')
            record(mode + '-native-off-stops-provider-and-clears-warning')

        # A genuine user-facing DNS preference change must still close the gate.
        client('mode', 'global'); wait(lambda: active('global'), 'Global before DNS change')
        services = command('/usr/sbin/networksetup', '-listallnetworkservices').stdout.splitlines()[1:]
        assert 'Ethernet' in services
        old = command('/usr/sbin/networksetup', '-getdnsservers', 'Ethernet').stdout.strip().splitlines()
        old = [] if old and "There aren't any DNS Servers" in old[0] else old
        (root / 'dns-backup.json').write_text(json.dumps(dict(service='Ethernet', servers=old)))
        for servers, label in ((['1.1.1.1'], 'set'), (old or ['Empty'], 'restore')):
            baseline = offsets(LOGS)
            command('/usr/sbin/networksetup', '-setdnsservers', 'Ethernet', *servers)
            def reverified():
                rows = events(LOGS, baseline)
                return any(r['event'] == 'mimo_network_configuration_external' for r in rows) and any(r['event'] == 'mimo_traffic_opened' for r in rows) and active('global')
            wait(reverified, 'real DNS change closes and re-verifies')
            rows = events(LOGS, baseline)
            assert any(r['event'] == 'mimo_gate_closed' and r['fields'].get('confirmed') == 'true' for r in rows)
            (root / ('dns-' + label + '-events.json')).write_text(json.dumps(rows))
            record('real-external-DNS-' + label + '-still-blocks-and-verifies')
        (root / 'dns-backup.json').unlink()
    except Exception as exc:
        error = type(exc).__name__ + ': ' + str(exc)
    finally:
        cleanup(root); guard.wait(timeout=10)
        assert json.loads(native('status', '--json').stdout)['BackendState'] == 'Stopped'
        record('original-Direct-native-off-proxy-allowlist-password-and-services-restored')
        report = dict(success=error is None, passed=passed, error=error, **{k: manifest[k] for k in ('packageSHA256', 'helperSHA256', 'guiSHA256')},
                      scope='Installed normal Release in mimo-vm; actual native Tailscale connection changes, provider HTTP, GUI state logs, ordinary-user HTTPS and networksetup DNS changes. No simulated events, helper substitution or sleep claim.')
        (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print('RESULT:', 'PASS' if error is None else 'FAIL: ' + error, flush=True)
    return 0 if error is None else 1


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--watchdog':
        watchdog(Path(sys.argv[2]), int(sys.argv[3]))
    else:
        sys.exit(main())
