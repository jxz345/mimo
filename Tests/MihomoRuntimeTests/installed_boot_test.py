#!/usr/bin/env python3
"""One real VM reboot with saved, verified Global configuration.

Uses the separate VM-only acceptance helper, never qualification.json. A fixed
root-owned boot worker verifies fresh startup without the GUI and restores the
production helper, original Direct settings, service intent and empty credential.
Capture starts in the launchd boot worker, so it cannot observe earlier boot.
Any observed traffic before the confirmed guard prevents a full-boot pass.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback

from installed_acceptance_test import command, stop_jobs, start_jobs, replace_helper, restore
from upgrade_test import RUNTIME, STORAGE, FLAGS, HELPER, read_settings

WORK = Path('/Library/Application Support/Mimo/InstalledBootAcceptance')
JOB = 'com.mimo.installed-boot-acceptance'
PLIST = Path('/Library/LaunchDaemons') / (JOB + '.plist')


def boot_id():
    return command('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid').stdout.strip()


def client(*arguments):
    return json.loads(command(WORK / 'acceptance-client', *arguments, timeout=50).stdout)


def wait_for(predicate, root, name, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = client('state')
            (root / 'last-state.json').write_text(json.dumps(value, indent=2))
            if predicate(value.get('routing', {})):
                return value['routing']
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        time.sleep(0.5)
    raise RuntimeError(name + ' timed out')


def watcher(root):
    with (root / 'watchdog.log').open('a') as log:
        return subprocess.Popen([sys.executable, WORK / 'installed_acceptance_test.py', '--watchdog', root, str(os.getpid())],
                                stdout=log, stderr=log, start_new_session=True)


def prepare(configuration):
    assert not WORK.exists() and not PLIST.exists(), 'An earlier boot test must be cleaned up first'
    original = read_settings()
    routing = json.loads(original.get('service.routing', b'{}'))
    assert 'service.settings' not in original and not routing.get('proxy') and routing.get('mode', 'direct') == 'direct'
    assert all(json.loads(FLAGS.read_bytes()).get(k) for k in ('core', 'engine', 'profile'))
    base = Path(__file__).resolve().parent
    command(base / 'acceptance-client', 'require-empty-credential')
    build = json.loads((base / 'acceptance-build.json').read_text())
    assert build['helperSHA256'] == hashlib.sha256((base / 'mimo-core-vm-acceptance').read_bytes()).hexdigest()
    root = Path(tempfile.mkdtemp(prefix='mimo-installed-boot-', dir='/var/tmp'))
    backup = root / 'private-backup'
    backup.mkdir(mode=0o700)
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup / name)
    (root / 'credentials.json').write_bytes(configuration.read_bytes())
    (root / 'credentials.json').chmod(0o600)
    configuration.unlink()
    WORK.mkdir(mode=0o700)
    for name in ('installed_boot_test.py', 'installed_acceptance_test.py', 'upgrade_test.py', 'packet_test.py',
                 'acceptance-client', 'installation-check'):
        shutil.copyfile(base / name, WORK / name)
        (WORK / name).chmod(0o700)
    guard = watcher(root)
    armed = False
    try:
        stop_jobs()
        replace_helper(base / 'mimo-core-vm-acceptance')
        start_jobs()
        wait_for(lambda s: s.get('effectiveMode') == 'direct', root, 'initial Direct')
        client('initialize')
        client('proxy', root / 'credentials.json')
        client('mode', 'global')
        state = wait_for(lambda s: s.get('phase') == 'blocked' and bool(s.get('blockingIP')), root, 'blocked exit observation')
        address = state['blockingIP']['address']
        client('allow', address)
        wait_for(lambda s: s.get('phase') == 'active' and s.get('effectiveMode') == 'global', root, 'verified Global')
        context = {'previousBoot': boot_id(), 'allowedIP': address, 'helperSHA256': build['helperSHA256'],
                   'driverSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   'logs': {str(p): p.stat().st_size for p in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl')}}
        (root / 'context.json').write_text(json.dumps(context, indent=2))
        (root / 'acceptance-build.json').write_text(json.dumps(build, indent=2))
        PLIST.write_bytes(plistlib.dumps({'Label': JOB, 'ProgramArguments': ['/usr/bin/python3', str(WORK / 'installed_boot_test.py'),
            '--boot-worker', str(root)], 'RunAtLoad': True, 'StandardOutPath': str(root / 'boot-worker.log'),
            'StandardErrorPath': str(root / 'boot-worker.log')}))
        PLIST.chmod(0o644)
        print('PASS: verified-Global-saved-before-reboot', flush=True)
        print('Evidence:', root, flush=True)
        # The boot job now owns recovery. The preparation watchdog must not
        # restore Direct when this SSH process disappears during shutdown.
        guard.terminate()
        guard.wait(timeout=5)
        command('/sbin/shutdown', '-r', 'now')
        armed = True
    finally:
        if not armed:
            restore(root)
            if guard.poll() is None:
                guard.wait(timeout=5)
            PLIST.unlink(missing_ok=True)
            shutil.rmtree(WORK)


def boot_worker(root):
    context = json.loads((root / 'context.json').read_text())
    assert context['driverSHA256'] == hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    assert boot_id() != context['previousBoot'], 'Boot worker must run after an actual reboot'
    completed = ['verified-Global-saved-before-reboot']
    errors = []
    capture = probe = None
    guard = watcher(root)
    success = False
    packet_summary = None
    def record(name):
        completed.append(name)
        print('PASS:', name, flush=True)
    try:
        assert command('/usr/bin/pgrep', '-x', 'mimo-gui', check=False).returncode == 1
        record('protected-startup-without-GUI')
        fixture = json.loads((root / 'credentials.json').read_text())
        with (root / 'capture.log').open('w') as stream:
            capture = subprocess.Popen(['/usr/sbin/tcpdump', '-n', '-U', '-i', 'pktap,en0', '-w', str(root / 'installed.pcap'),
                'tcp and (dst host 1.1.1.1 or dst host ' + fixture['bind'] + ')'], stdout=stream, stderr=stream)
        (root / 'capture.pid').write_text(str(capture.pid))
        time.sleep(0.3)
        assert capture.poll() is None and 'listening on' in (root / 'capture.log').read_text()
        account = pwd.getpwnam('jay')
        def ordinary_user():
            os.setgroups([]); os.setgid(account.pw_gid); os.setuid(account.pw_uid)
        control = subprocess.Popen([sys.executable, '-c', 'import socket,sys;s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=5);s.close()',
            fixture['bind'], str(fixture['port'])], preexec_fn=ordinary_user)
        assert control.wait(timeout=7) == 0
        probe = subprocess.Popen([sys.executable, '-c', 'import socket,time\nfor _ in range(240):\n try:\n  s=socket.create_connection(("1.1.1.1",443),timeout=.2);s.close()\n except OSError: pass\n time.sleep(.1)'], preexec_fn=ordinary_user)
        state = wait_for(lambda s: s.get('phase') == 'active' and s.get('effectiveMode') == 'global'
            and (RUNTIME / 'gate.state').read_text() == 'active', root, 'fresh Global after boot')
        assert state['observedIP']['address'] == context['allowedIP'], 'Active exit differs from the saved allowlist'
        record('saved-Global-restores-after-fresh-allowlisted-check')
        assert json.loads((RUNTIME / 'pf-reference.json').read_text())['boot'] == boot_id()
        assert 'IPv6: Off' in command('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
        record('current-boot-firewall-reference-and-IPv6-denial')
        records = []
        for path in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl'):
            if str(path) in context['logs']:
                continue
            with path.open('rb') as stream:
                for line in stream:
                    try: records.append(json.loads(line))
                    except ValueError: pass
        events = [r['event'] for r in records]
        assert events.index('mimo_private_probe_ready') < events.index('mimo_traffic_opened')
        (root / 'startup-events.json').write_text(json.dumps(records, indent=2))
        record('startup-log-confirms-private-verification-before-opening')
        probe.terminate(); probe.wait(timeout=5)
        capture.send_signal(signal.SIGINT); capture.wait(timeout=5)
        capture = None
        (root / 'capture.pid').unlink()
        text = command('/usr/sbin/tcpdump', '-nn', '-k', 'NP', '-Q', 'pid=' + str(control.pid), '-r', root / 'installed.pcap').stdout
        assert text.strip(), 'Ordinary LAN positive control is missing from the capture'
        record('boot-capture-positive-control-confirms-ordinary-attribution')
        text = command('/usr/sbin/tcpdump', '-tt', '-nn', '-k', 'NP', '-Q', 'pid=' + str(probe.pid), '-r', root / 'installed.pcap').stdout
        boundary = min(float(r['fields']['closedAt']) for r in records if r['event'] == 'mimo_startup_guard_closed')
        packets = [line for line in text.splitlines() if line.strip()]
        before = [line for line in packets if float(line.split()[0]) < boundary]
        after = [line for line in packets if float(line.split()[0]) >= boundary]
        packet_summary = {'guardClosedAt': boundary, 'ordinaryPacketsBeforeGuard': len(before),
                          'ordinaryPacketsAfterGuard': len(after), 'protectedIntervalPassed': not after}
        (root / 'boot-packet-summary.json').write_text(json.dumps(packet_summary, indent=2))
        assert not after, 'Ordinary boot probe escaped after the startup guard was confirmed'
        record('ordinary-boot-probe-has-no-direct-uplink-after-confirmed-guard')
        if before:
            errors.append('Ordinary packets preceded the startup guard; first-packet boot protection remains unqualified.')
        assert not (RUNTIME / 'qualification.json').exists()
        assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == context['helperSHA256']
        record('VM-only-helper-and-no-qualification-manifest-confirmed')
        success = True
    except BaseException as error:
        errors.append(type(error).__name__ + ': ' + str(error))
        (root / 'failure.txt').write_text(traceback.format_exc())
    finally:
        for process in (probe, capture):
            if process is not None and process.poll() is None:
                process.terminate(); process.wait(timeout=5)
        try:
            restore(root)
            guard.wait(timeout=5)
            record('production-helper-original-Direct-and-empty-credential-restored')
        except BaseException as error:
            errors.append('Restoration: ' + str(error))
        PLIST.unlink(missing_ok=True)
        (root / 'report.json').write_text(json.dumps({'success': success and not errors, 'passed': completed, 'errors': errors,
            'helperSHA256': context['helperSHA256'], 'driverSHA256': context['driverSHA256'],
            'packetSummary': packet_summary,
            'scope': 'VM-only saved Global startup; pre-guard exposure is reported separately and prevents a full-boot pass. No sleep/wake qualification.'}, indent=2))
        if (root / 'cleanup-complete').exists():
            shutil.rmtree(WORK)
        print('Evidence:', root, flush=True)
        command('/bin/launchctl', 'bootout', 'system/' + JOB, check=False)


if __name__ == '__main__':
    assert os.geteuid() == 0 and command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    assert not (RUNTIME / 'qualification.json').exists()
    os.umask(0o077)
    if len(sys.argv) == 3 and sys.argv[1] == '--boot-worker':
        boot_worker(Path(sys.argv[2]))
    elif len(sys.argv) == 2:
        prepare(Path(sys.argv[1]))
    else:
        sys.exit('Usage: installed_boot_test.py PRIVATE_FIXTURE_JSON')
