#!/usr/bin/env python3
"""Real route changes, saved proxy and installed GUI in mimo-vm only.

No mock routing, injected notifications, new approved IPs or helper replacement.
Private logs/settings stay in the VM; exported results contain check names only.
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
from saved_proxy_test import restore
from upgrade_test import RUNTIME, STORAGE, FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent
LOGS = Path('/Library/Logs/ExitIPMonitor')
GUI_LOGS = Path('/Users/jay/Library/Application Support/ExitIPMonitor/Logs')
DESTINATION = '198.51.100.254'


def offsets(directory):
    return {p: p.stat().st_size for p in directory.glob('runtime-*.jsonl')}


def events(directory, baseline):
    rows = []
    for path in sorted(directory.glob('runtime-*.jsonl')):
        with path.open('rb') as stream:
            stream.seek(baseline.get(path, 0))
            for line in stream:
                try:
                    value = json.loads(line)
                    value['file'] = path.name
                    rows.append(value)
                except ValueError:
                    pass
    return rows


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = read_settings()
    assert json.loads(original['service.routing'])['mode'] == 'direct'
    approved = json.loads(original['service.settings'])['allowlist']['addresses']
    assert approved and command('/usr/bin/pgrep', '-x', 'mimo-gui').stdout.strip()
    assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
    gateway = re.search(r'gateway: (\S+)', command('/sbin/route', '-n', 'get', 'default').stdout)[1]
    manifest = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == manifest['helperSHA256']
    assert hashlib.sha256(Path('/Applications/Mimo.app/Contents/MacOS/mimo-gui').read_bytes()).hexdigest() == manifest['guiSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-network-progress-', dir='/var/tmp'))
    (root / 'installed-release').touch()
    backup = root / 'private-backup'; backup.mkdir()
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup / name)
    (backup / 'credential.digest').write_text(command(BASE / 'acceptance-client', 'credential-digest').stdout.strip())
    with (root / 'watchdog.log').open('w') as log:
        guard = subprocess.Popen([sys.executable, BASE / 'saved_proxy_test.py', '--watchdog', root, str(os.getpid())],
                                 stdout=log, stderr=log, start_new_session=True)
    passed = []
    error = None
    print('Evidence:', root, flush=True)

    def record(name):
        passed.append(name)
        print('PASS:', name, flush=True)

    def client(*args):
        return command(BASE / 'acceptance-client', *args, timeout=70)

    def state():
        return json.loads(command(BASE / 'installation-check', timeout=25).stdout)

    def wait(predicate, timeout=100, description='current installed routing/UI state'):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.15)
        raise RuntimeError('Timed out waiting for ' + description)

    def active(mode):
        value = state()
        return value['phase'] == 'active' and value.get('effectiveMode') == mode

    def gui_rows(baseline):
        return [v['fields'] for v in events(GUI_LOGS, baseline) if v['event'] == 'mimo_access_presentation_changed']

    def route(add):
        if add:
            (root / 'test-route').touch()
            command('/sbin/route', '-n', 'add', '-host', DESTINATION, gateway)
        else:
            command('/sbin/route', '-n', 'delete', '-host', DESTINATION)
            (root / 'test-route').unlink()

    def https(allowed):
        result = command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail',
                         '--noproxy', '*', '--max-time', '6', '--head', 'https://1.1.1.1/', check=False)
        assert (result.returncode == 0) == allowed, 'Ordinary-user HTTPS result differs from the gate'

    try:
        for mode in ('rule', 'global'):
            client('mode', mode)
            wait(lambda: active(mode))
            record(mode + '-saved-proxy-approved')
            for add in (True, False):
                baseline, gui_baseline = offsets(LOGS), offsets(GUI_LOGS)
                route(add)

                def completed():
                    rows = events(LOGS, baseline)
                    return any(v['event'] == 'mimo_network_changed' and v['fields'].get('source') == 'route' for v in rows) \
                        and any(v['event'] == 'mimo_traffic_opened' for v in rows) and active(mode)

                wait(completed)
                rows = events(LOGS, baseline)
                supervisor = next(v['file'] for v in rows if v['event'] == 'mimo_network_changed' and v['fields'].get('source') == 'route')
                ordered = [v for v in rows if v['file'] == supervisor]
                probe = next(i for i, v in enumerate(ordered) if v['event'] == 'mimo_private_probe_ready')
                opened = next(i for i, v in enumerate(ordered) if v['event'] == 'mimo_traffic_opened')
                assert any(v['event'] == 'mimo_gate_closed' and v['fields'].get('confirmed') == 'true' for v in ordered[:probe])
                assert probe < opened
                wait(lambda: any(v.get('validating') == 'true' and v.get('blocked') == 'true' for v in gui_rows(gui_baseline))
                     and any(v.get('kind') == 'checking' and v.get('validating') == 'false' and v.get('blocked') == 'true' for v in gui_rows(gui_baseline))
                     and any(v.get('kind') in ('verified', 'tailnetWarning') and v.get('blocked') == 'false' for v in gui_rows(gui_baseline)))
                label = mode + ('-route-added' if add else '-route-removed')
                record(label + '-confirmed-block-before-probe-before-reopen')
                record(label + '-installed-GUI-published-blocked-validation-check-and-approval')
                (root / (label + '-events.json')).write_text(json.dumps(rows))
            https(True)
            record(mode + '-ordinary-user-HTTPS-after-approval')
            for addresses, label in (([], 'empty-allowlist'), (['192.0.2.254'], 'wrong-allowlist')):
                client('allow', *addresses)

                def rejected():
                    value = state()
                    return value['phase'] == 'blocked' and bool(value.get('blockingIP')) and (RUNTIME / 'gate.state').read_text() == 'blocked'

                wait(rejected)
                https(False)
                record(mode + '-' + label + '-retains-rejected-IP-and-denies-ordinary-HTTPS')
            client('allow', *approved)
            wait(lambda: active(mode))
            record(mode + '-original-allowlist-recovers')
        client('mode', 'direct')
        wait(lambda: active('direct'))
        # Switching mode itself starts a Direct lookup. Wait for that real
        # lookup to finish so the new route produces a new icon transition;
        # the icon correctly emits no duplicate event if already checking.
        def direct_settled():
            current = json.loads(command(BASE / 'installation-check', 'core-state').stdout)
            rows = gui_rows({})
            return 'ready' in current['status'] and rows and rows[-1].get('kind') == 'direct'

        wait(direct_settled, description='Direct lookup to settle before changing its route')
        baseline, gui_baseline = offsets(LOGS), offsets(GUI_LOGS)
        route(True)
        wait(lambda: any(v['event'] == 'mimo_network_changed' for v in events(LOGS, baseline)), description='Direct route notification')
        wait(lambda: any(v.get('direct') == 'true' and v.get('kind') == 'checking' for v in gui_rows(gui_baseline)), description='Direct checking icon transition')
        assert (RUNTIME / 'gate.state').read_text() == 'direct'
        assert not any(v.get('blocked') == 'true' for v in gui_rows(gui_baseline))
        https(True)
        route(False)
        record('Direct-network-change-checks-IP-without-protected-blocking')
    except Exception as exc:
        error = str(exc)
    finally:
        restore(root)
        guard.wait(timeout=10)
        record('original-Direct-proxy-allowlist-password-and-service-intent-restored')
        (root / 'report.json').write_text(json.dumps(dict(success=error is None, passed=passed, error=error,
            packageSHA256=manifest['packageSHA256'], helperSHA256=manifest['helperSHA256'],
            scope='Installed normal Release in mimo-vm; real kernel route changes, saved proxy, allowlist rejection, ordinary-user HTTPS and GUI presentation logs. No packet-level zero-delay claim; no sleep or login simulation.'), indent=2) + '\n')
        print('RESULT:', 'PASS' if error is None else 'FAIL: ' + error, flush=True)
    return 0 if error is None else 1


if __name__ == '__main__':
    sys.exit(main())
