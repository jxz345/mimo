#!/usr/bin/env python3
"""Exercise Direct IP retention through real installed-service repairs in mimo-vm."""
import fcntl
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
from release_network_progress_test import LOGS, events, offsets
from saved_proxy_test import restore
from upgrade_test import SUPERVISOR, STORAGE, FLAGS, HELPER, RUNTIME, read_settings

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    assert json.loads(read_settings()['service.routing'])['mode'] == 'direct'
    manifest = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == manifest['helperSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-direct-observation-', dir='/var/tmp'))
    (root / 'installed-release').touch()
    backup = root / 'private-backup'; backup.mkdir()
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup / name)
    (backup / 'credential.digest').write_text(command(BASE / 'acceptance-client', 'credential-digest').stdout.strip())
    with (root / 'watchdog.log').open('w') as log:
        guard = subprocess.Popen([sys.executable, BASE / 'saved_proxy_test.py', '--watchdog', root, str(os.getpid())],
                                 stdout=log, stderr=log, start_new_session=True)
    passed, failures = [], []
    print('Evidence:', root, flush=True)

    def state():
        return json.loads(command(BASE / 'installation-check', 'core-state', timeout=25).stdout)

    def wait(predicate, description, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = state()
                if predicate(value):
                    return value
            except (subprocess.SubprocessError, ValueError):
                pass
            time.sleep(.2)
        raise RuntimeError('Timed out waiting for ' + description)

    def healthy(value):
        routing = value['routing']
        health = routing.get('infrastructure', {})
        return routing.get('effectiveMode') == 'direct' and routing['phase'] == 'active' \
            and health.get('pf') == 'healthy' and health.get('launchd') == 'healthy'

    def record(name):
        passed.append(name); print('PASS:', name, flush=True)

    try:
        for scenario in sys.argv[1:] or ['pf', 'anchor', 'supervisor', 'firewall-busy', 'reinstall']:
            command(BASE / 'acceptance-client', 'refresh')
            before = wait(lambda v: healthy(v) and bool(v['routing'].get('observedIP')) and 'ready' in v['status'], 'fresh Direct IP')
            baseline = offsets(LOGS)
            if scenario == 'pf':
                command('/sbin/pfctl', '-d')
            elif scenario == 'anchor':
                command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-F', 'rules')
            elif scenario == 'supervisor':
                command('/bin/launchctl', 'kickstart', '-k', 'system/' + SUPERVISOR)
            elif scenario == 'firewall-busy':
                # A real competing root process holds the same kernel lock as
                # an installer/firewall transition. It releases automatically;
                # no status, event or gate file is fabricated.
                with (RUNTIME / 'firewall.lock').open('a+b') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    time.sleep(26)
            elif scenario == 'reinstall':
                with (root / 'reinstall.log').open('w') as log:
                    subprocess.run(['/usr/bin/env', 'SUDO_USER=jay', '/bin/bash',
                                    '/Applications/Mimo.app/Contents/Resources/daemon.sh', 'install'],
                                   stdout=log, stderr=log, check=True, timeout=180)
            else:
                raise ValueError('Unknown scenario')
            # Observe several actual infrastructure sweeps; an early healthy
            # reply can predate repair, which was the original missing-IP race.
            samples = []
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline:
                try:
                    samples.append(state())
                except (subprocess.SubprocessError, ValueError):
                    pass
                time.sleep(.25)
            after = wait(healthy, scenario + ' recovery')
            samples.append(after)
            (root / (scenario + '-states.json')).write_text(json.dumps(samples))
            rows = events(LOGS, baseline)
            (root / (scenario + '-events.json')).write_text(json.dumps(rows))
            if scenario == 'firewall-busy':
                assert any(v['event'] == 'mimo_infrastructure_check_failed' for v in rows)
                record('real-firewall-lock-contention-triggers-infrastructure-failure')
            record(scenario + '-real-repair-restores-healthy-Direct')
            observation = after['routing'].get('observedIP')
            if not observation:
                failures.append(scenario + '-healthy-Direct-lost-observed-IP')
                print('FAIL:', failures[-1], flush=True)
            else:
                record(scenario + '-Direct-IP-visible-after-recovery')
                if scenario == 'reinstall':
                    assert observation['checkedAt'] > before['routing']['observedIP']['checkedAt']
                    record('reinstall-records-fresh-startup-IP-without-manual-refresh')
            command('/usr/bin/sudo', '-n', '-H', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail',
                    '--noproxy', '*', '--max-time', '15', '--head', 'https://one.one.one.one/')
            record(scenario + '-ordinary-user-HTTPS-remains-available')
    except Exception as exc:
        failures.append(type(exc).__name__ + ': ' + str(exc))
    finally:
        restore(root)
        guard.wait(timeout=10)
        record('original-Direct-proxy-allowlist-password-and-service-intent-restored')
        (root / 'report.json').write_text(json.dumps(dict(success=not failures, passed=passed, failures=failures,
            packageSHA256=manifest['packageSHA256'], helperSHA256=manifest['helperSHA256'],
            scope='Installed Release in mimo-vm. Real PF disable/anchor loss, supervisor restart, competing kernel firewall lock and bundled service reinstall. No injected status or mocked network.'), indent=2) + '\n')
    print('RESULT:', 'PASS' if not failures else 'FAIL', flush=True)
    return int(bool(failures))


if __name__ == '__main__':
    sys.exit(main())
