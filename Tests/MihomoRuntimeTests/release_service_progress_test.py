#!/usr/bin/env python3
"""Actual installed service lifecycle, PF denial, progress IPC and lock-failure handling.

Only mimo-vm; uses the saved proxy/allowlist, normal Release and ordinary jay HTTPS.
The root client exercises real XPC progress, not a fake service implementation.
"""
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from release_network_progress_test import offsets, events, LOGS
from release_tailnet_lifecycle_test import native, cleanup as restore_network
from upgrade_test import RUNTIME, STORAGE, FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent


def cleanup(root):
    hidden = Path('/Library/Application Support/Mimo/Mihomo/controller.service-test.sock')
    controller = hidden.with_name('controller.sock')
    marker = root / 'controller-moved'
    if marker.exists():
        if hidden.exists():
            if controller.exists(): hidden.unlink()
            else: hidden.rename(controller)
        marker.unlink()
    restore_network(root)


def watchdog(root, parent):
    deadline = time.monotonic() + 1800
    while not (root / 'cleanup-complete').exists() and time.monotonic() < deadline:
        try: os.kill(parent, 0)
        except ProcessLookupError: break
        time.sleep(.5)
    cleanup(root)


def main():
    assert sys.argv[1:] in ([], ["--focused"])
    focused = sys.argv[1:] == ["--focused"]
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    assert json.loads(native('status', '--json').stdout)['BackendState'] == 'Stopped'
    original = read_settings()
    assert json.loads(original['service.routing'])['mode'] == 'direct'
    assert not json.loads(original['service.settings'])['tailscaleProviderEnabled']
    assert json.loads(original['service.settings'])['allowlist']['addresses']
    manifest = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == manifest['helperSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-service-progress-', dir='/var/tmp'))
    (root / 'installed-release').touch()
    backup = root / 'private-backup'; backup.mkdir()
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup / name)
    (backup / 'credential.digest').write_text(command(BASE / 'acceptance-client', 'credential-digest').stdout.strip())
    with (root / 'watchdog.log').open('w') as log:
        guard = subprocess.Popen([sys.executable, __file__, '--watchdog', str(root), str(os.getpid())],
                                 stdout=log, stderr=log, start_new_session=True)
    checks, error = [], None
    print('Evidence:', root, flush=True)

    def record(name):
        checks.append(name); print('PASS:', name, flush=True)

    def client(*args):
        deadline = time.monotonic() + 20
        while True:
            result = command(BASE / 'acceptance-client', *args, timeout=70, check=False)
            if result.returncode == 0:
                return
            (root / 'client-error.txt').write_text(result.stdout + result.stderr)
            if time.monotonic() > deadline:
                raise RuntimeError('Core operation failed; private client-error.txt retained')
            time.sleep(.5)

    def state():
        return json.loads(command(BASE / 'installation-check', timeout=25).stdout)

    def active(mode):
        value = state()
        return value['phase'] == 'active' and value.get('effectiveMode') == mode and (RUNTIME / 'gate.state').read_text() == ('direct' if mode == 'direct' else 'active')

    def wait(predicate, label, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.3)
        raise RuntimeError('Timed out: ' + label)

    def https(allowed):
        result = command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail',
                         '--noproxy', '*', '--max-time', '5', '--head', 'https://1.1.1.1/', check=False)
        assert (result.returncode == 0) == allowed, 'Ordinary-user HTTPS differs from gate'

    def action(service, operation):
        result = command(BASE / 'service-progress-check', service, operation, timeout=50)
        return json.loads(result.stdout)

    def engine_pid():
        value = command('/bin/launchctl', 'print', 'system/com.example.exitipmonitor.mihomo').stdout
        return next(row.strip() for row in value.splitlines() if row.strip().startswith('pid = '))

    try:
        for mode in (('rule',) if focused else ('rule', 'global', 'direct')):
            client('mode', mode); wait(lambda: active(mode), mode + ' activation')
            https(True)
            for service in (('mihomo',) if focused else ('core', 'mihomo', 'profileHosting')):
                for operation in ('stop', 'start', 'restart'):
                    before = offsets(LOGS)
                    result = action(service, operation)
                    assert result['failure'] == '', result
                    rows = events(LOGS, before)
                    begins = [i for i, row in enumerate(rows) if row['event'] == 'mimo_service_change_begin'
                              and row['fields']['service'] == service and row['fields']['operation'] == operation]
                    assert begins, 'Missing service begin receipt'
                    if mode != 'direct':
                        assert result['progressBeforeReply'] == ['blocked'], result
                        assert result['finalPhase'] == 'blocked', result
                        assert rows[begins[0]]['fields']['closed'] == 'true'
                        closures = [row for row in rows[:begins[0]] if row['event'] == 'mimo_gate_closed']
                        assert closures and closures[-1]['fields']['confirmed'] == 'true'
                        record(mode + '-' + service + '-' + operation + '-confirmed-blocking-before-operation-and-reply')
                        if operation == 'stop':
                            assert state()['phase'] == 'blocked'
                            https(False)
                            record(mode + '-' + service + '-stopped-denies-real-HTTPS')
                    else:
                        assert result['progressBeforeReply'] == [], result
                    if operation != 'stop':
                        client('refresh'); wait(lambda: active(mode), mode + '-' + service + '-' + operation)
                        https(True)
                    elif mode == 'direct':
                        https(True)
                    if mode == 'direct': record('direct-' + service + '-' + operation + '-normal-IPv4-recovered')
            if mode == 'rule':
                controller = Path('/Library/Application Support/Mimo/Mihomo/controller.sock')
                hidden = controller.with_name('controller.service-test.sock')
                assert controller.exists() and not hidden.exists()
                pid = engine_pid()
                (root / 'controller-moved').touch()
                controller.rename(hidden)
                try:
                    result = action('mihomo', 'restart')
                    assert result['failure'] == '' and result['progressBeforeReply'] == ['blocked'], result
                    assert engine_pid() != pid
                    assert controller.exists()
                finally:
                    if hidden.exists():
                        if controller.exists(): hidden.unlink()
                        else: hidden.rename(controller)
                    (root / 'controller-moved').unlink()
                record('missing-controller-does-not-prevent-safe-engine-restart')
                client('refresh'); wait(lambda: active('rule'), 'controller recovery verification')
                https(True)
                # Actual kernel lock contention: the existing engine must not be
                # stopped/restarted if closing PF cannot acquire its transition lock.
                pid, flags, before = engine_pid(), FLAGS.read_bytes(), offsets(LOGS)
                with (RUNTIME / 'firewall.lock').open('a') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    try:
                        result = action('mihomo', 'restart')
                    finally:
                        fcntl.flock(lock, fcntl.LOCK_UN)
                assert result['failure'] == 'unavailable', result
                assert result['progressBeforeReply'] == ['unavailable'], result
                assert engine_pid() == pid and FLAGS.read_bytes() == flags
                rows = events(LOGS, before)
                assert any(row['event'] == 'mimo_service_change_aborted' for row in rows)
                assert not any(row['event'] == 'mimo_service_change_begin' for row in rows)
                record('failed-PF-closure-aborts-restart-without-changing-engine-or-intent')
                client('refresh'); wait(lambda: active('rule'), 'lock contention recovery')
                https(True); record('protected-verification-recovers-after-real-lock-contention')
        if focused:
            return
        # The Tailnet provider owns a separate route exception, not public proxy
        # authorization. Stop must remove that exception while public policy holds.
        native('up')
        def provider_running():
            result = command('/usr/bin/curl', '--silent', '--fail', '--noproxy', '*', '--max-time', '2',
                             'http://127.0.0.1:18766/provider.yaml', check=False)
            return result.returncode == 0 and 'type: direct' in result.stdout
        wait(provider_running, 'native Tailnet provider activation')
        time.sleep(3)
        for mode in ('rule', 'global', 'direct'):
            client('mode', mode); wait(lambda: active(mode), 'tailnet ' + mode)
            client('tailnet', 'stop')
            wait(lambda: not provider_running(), 'provider Stop')
            wait(lambda: active(mode), 'public policy after Tailnet Stop')
            https(True)
            rules = command('/sbin/pfctl', '-a', 'com.apple/000.mimo/native-transport', '-sr').stdout
            assert not re.search(r'on utun[0-9]+ .*100\.64\.0\.0/10', rules), 'Stopped provider left the inner-tailnet route exception'
            # Authenticated native control/DERP socket tuples intentionally remain
            # so Tailscale can stay connected and reconnect the provider.
            record(mode + '-tailnet-stop-clears-route-exception-with-public-policy-intact')
            for operation in ('start', 'restart'):
                if operation == 'restart': client('tailnet', 'stop')
                client('tailnet', 'start'); wait(provider_running, 'provider ' + operation)
                wait(lambda: active(mode), 'public policy after provider ' + operation)
                https(True)
                record(mode + '-tailnet-' + operation + '-restores-verified-native-provider')
    except BaseException as failure:
        error = type(failure).__name__ + ': ' + str(failure)
        raise
    finally:
        cleanup(root)
        guard.wait(timeout=10)
        (root / 'report.json').write_text(json.dumps(dict(success=error is None, passed=checks, error=error,
            helperSHA256=manifest['helperSHA256'], packageSHA256=manifest['packageSHA256'],
            scope=('Focused Rule/mihomo lifecycle, missing controller and PF-lock contention rerun on the final UI-fallback build. ' if focused else 'Full Rule/Global/Direct lifecycle and Tailnet matrix. ') + 'Installed normal Release in mimo-vm; real XPC, launchd and ordinary-user HTTPS. No physical GUI click ordering claimed.'), indent=2) + '\n')
        print('Evidence:', root, flush=True)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--watchdog': watchdog(Path(sys.argv[2]), int(sys.argv[3]))
    else: main()
