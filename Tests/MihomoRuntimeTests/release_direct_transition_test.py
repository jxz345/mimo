#!/usr/bin/env python3
"""Installed Release in mimo-vm: Direct exits protection without a fresh blocking step.

Real saved proxy, real allowlist rejection, PF, ordinary-user HTTPS and native VPN
changes. No injected notifications, substituted helper or simulated power events.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from release_network_progress_test import LOGS, offsets, events, DESTINATION
from release_tailnet_lifecycle_test import native, cleanup
from upgrade_test import STORAGE, FLAGS, HELPER, RUNTIME, read_settings

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    assert json.loads(native('status', '--json').stdout)['BackendState'] == 'Stopped'
    original = read_settings()
    assert json.loads(original['service.routing'])['mode'] == 'direct'
    assert not json.loads(original['service.settings'])['tailscaleProviderEnabled']
    approved = json.loads(original['service.settings'])['allowlist']['addresses']
    assert approved
    assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
    gateway = re.search(r'gateway: (\S+)', command('/sbin/route', '-n', 'get', 'default').stdout)[1]
    manifest = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == manifest['helperSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-direct-transition-', dir='/var/tmp'))
    (root / 'installed-release').touch()
    backup = root / 'private-backup'; backup.mkdir()
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup / name)
    (backup / 'credential.digest').write_text(command(BASE / 'acceptance-client', 'credential-digest').stdout.strip())
    with (root / 'watchdog.log').open('w') as log:
        guard = subprocess.Popen([sys.executable, BASE / 'release_tailnet_lifecycle_test.py', '--watchdog', str(root), str(os.getpid())],
                                 stdout=log, stderr=log, start_new_session=True)
    passed, error = [], None
    print('Evidence:', root, flush=True)

    def record(name):
        passed.append(name); print('PASS:', name, flush=True)

    def client(*args):
        result = command(BASE / 'acceptance-client', *args, timeout=70, check=False)
        if result.returncode:
            (root / 'client-error-private.txt').write_text(result.stdout + result.stderr)
            raise RuntimeError('Core operation failed; details retained privately')

    def state():
        return json.loads(command(BASE / 'installation-check', 'core-state', timeout=20).stdout)

    def wait(predicate, label, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = state()
            if predicate(value): return value
            time.sleep(.2)
        raise RuntimeError('Timed out: ' + label)

    def active(value, mode):
        route = value['routing']
        return route['phase'] == 'active' and route.get('effectiveMode') == mode

    def https():
        command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail',
                '--noproxy', '*', '--max-time', '10', '--head', 'https://one.one.one.one/')

    def no_close(baseline):
        rows = events(LOGS, baseline)
        assert not any(row['event'] in ('mimo_gate_closed', 'mimo_sleep_guard_closed', 'mimo_private_probe_ready', 'mimo_traffic_opened') for row in rows), 'Direct performed a protected closure or verification'
        assert (RUNTIME / 'gate.state').read_text() == 'direct'
        rules = command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout
        assert 'block return out quick inet6 all' in rules and 'block drop' not in rules
        return rows

    try:
        for mode in ('rule', 'global'):
            for blocked in (False, True):
                client('allow', *([] if blocked else approved))
                client('mode', mode)
                if blocked:
                    wait(lambda v: v['routing']['phase'] == 'blocked' and bool(v['routing'].get('blockingIP')), 'allowlist rejection')
                else:
                    wait(lambda v: active(v, mode), 'approved ' + mode)
                baseline = offsets(LOGS)
                client('mode', 'direct')
                wait(lambda v: active(v, 'direct'), 'Direct restoration')
                rows = no_close(baseline)
                supervisor = next(row['file'] for row in rows if row['event'] == 'mimo_direct_ipv4_released')
                ordered = [row['event'] for row in rows if row['file'] == supervisor]
                assert ordered.index('mimo_direct_ipv4_released') < ordered.index('mimo_direct_restored')
                record(mode + ('-blocked' if blocked else '-approved') + '-to-Direct-without-close-or-allowlist-verification')
                https()
                record(mode + ('-blocked' if blocked else '-approved') + '-to-Direct-restores-ordinary-HTTPS-and-keeps-IPv6-denied')
        # Keep the empty list for these events: informational Direct lookup must
        # never become an allowlist gate, even after an actual VPN reconnection.
        wait(lambda v: active(v, 'direct') and 'ready' in v['status'], 'Direct lookup settled')
        for add in (True, False):
            baseline = offsets(LOGS)
            if add:
                (root / 'test-route').touch()
                command('/sbin/route', '-n', 'add', '-host', DESTINATION, gateway)
            else:
                command('/sbin/route', '-n', 'delete', '-host', DESTINATION)
                (root / 'test-route').unlink()
            wait(lambda v: active(v, 'direct') and any(r['event'] == 'mimo_network_changed' for r in events(LOGS, baseline)), 'real route event')
            https(); no_close(baseline)
            record('Direct-route-' + ('add' if add else 'remove') + '-does-not-block-with-empty-allowlist')
        for enabled in (True, False):
            baseline = offsets(LOGS)
            native('up' if enabled else 'down')
            wait(lambda v: active(v, 'direct') and v['settings']['tailscaleProviderEnabled'] == enabled, 'native VPN/provider state')
            https(); no_close(baseline)
            record('Direct-native-VPN-' + ('connect' if enabled else 'disconnect') + '-does-not-block-with-empty-allowlist')
        client('refresh'); wait(lambda v: active(v, 'direct') and bool(v['routing'].get('observedIP')) and 'ready' in v['status'], 'Direct informational IP')
        https()
        record('Direct-informational-IP-lookup-works-with-empty-allowlist')
    except Exception as exc:
        # Do not export private command output or saved proxy/IP metadata.
        (root / 'failure-private.txt').write_text(repr(exc))
        error = type(exc).__name__ + ': details retained in private VM evidence'
    finally:
        cleanup(root)
        guard.wait(timeout=10)
        record('original-Direct-proxy-allowlist-password-service-intent-and-native-off-restored')
        (root / 'report.json').write_text(json.dumps(dict(success=error is None, passed=passed, error=error,
            packageSHA256=manifest['packageSHA256'], helperSHA256=manifest['helperSHA256'], guiSHA256=manifest['guiSHA256'],
            scope='Installed Release in mimo-vm; approved/rejected Rule/Global → Direct, real route changes and native VPN reconnect/disconnect, ordinary-user HTTPS and real PF. No physical sleep/login simulation or zero-interruption TCP claim.'), indent=2)+'\n')
    print('RESULT:', 'PASS' if error is None else 'FAIL', flush=True)
    return int(error is not None)


if __name__ == '__main__':
    sys.exit(main())
