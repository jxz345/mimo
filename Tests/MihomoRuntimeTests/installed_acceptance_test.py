#!/usr/bin/env python3
"""Exercise installed core/supervisor APIs in the unconfigured Apple VM.

The separately compiled helper bypasses ONLY the release-qualification check and
refuses a physical Mac. Real authorization, Keychain, profile validation, private
IP verification, PF, and generation fencing remain in effect. No qualification
manifest is written. An independent watchdog restores the production helper,
original state and service intent, and removes the fixture credential.
"""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from upgrade_test import CORE, SUPERVISOR, ENGINE, RUNTIME, STORAGE, FLAGS, HELPER, read_settings, atomic_write
from packet_test import WORKER


def command(*arguments, timeout=45, check=True):
    return subprocess.run([str(a) for a in arguments], capture_output=True, text=True, timeout=timeout, check=check)


def stop_jobs():
    for label in (SUPERVISOR, CORE, ENGINE):
        command('/bin/launchctl', 'bootout', 'system/' + label, check=False)
        deadline = time.monotonic() + 20
        while command('/bin/launchctl', 'print', 'system/' + label, check=False).returncode == 0:
            if time.monotonic() >= deadline:
                raise RuntimeError('launchd did not finish removing ' + label)
            time.sleep(0.2)


def start_jobs():
    command('/bin/launchctl', 'bootstrap', 'system', '/Library/LaunchDaemons/' + SUPERVISOR + '.plist')


def replace_helper(source):
    temporary = HELPER.with_name('.mimo-acceptance-restore')
    shutil.copyfile(source, temporary)
    os.chown(temporary, 0, 0)
    temporary.chmod(0o755)
    os.replace(temporary, HELPER)


def restore(root):
    # Atomic replacement makes retry by the independent watchdog safe.
    if (root / 'test-route').exists():
        command('/sbin/route', '-n', 'delete', '-host', '198.51.100.254', check=False)
        (root / 'test-route').unlink()
    capture_pid = root / 'capture.pid'
    if capture_pid.exists():
        pid = int(capture_pid.read_text())
        value = command('/bin/ps', '-p', pid, '-o', 'command=', check=False).stdout
        if value.startswith('/usr/sbin/tcpdump ') and str(root / 'installed.pcap') in value:
            os.kill(pid, signal.SIGINT)
        capture_pid.unlink()
    stopped = root / 'stopped-core.pid'
    if stopped.exists():
        pid = int(stopped.read_text())
        current = command('/bin/launchctl', 'print', 'system/' + CORE, check=False).stdout
        if ('pid = ' + str(pid) + '\n') in current:
            os.kill(pid, signal.SIGCONT)
        stopped.unlink()
    stop_jobs()
    base = Path(__file__).resolve().parent
    command(base / 'acceptance-client', 'clear-fixture-credential', root / 'credentials.json')
    backup = root / 'private-backup'
    replace_helper(backup / 'mimo-core')
    atomic_write(STORAGE, (backup / 'state.plist').read_bytes())
    atomic_write(FLAGS, (backup / 'services.json').read_bytes())
    for name in ('candidate.yaml', 'reload.json'):
        (RUNTIME / name).unlink(missing_ok=True)
    start_jobs()
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        if (RUNTIME / 'gate.state').read_text() == 'direct':
            assert hashlib.sha256(HELPER.read_bytes()).digest() == hashlib.sha256((backup / 'mimo-core').read_bytes()).digest()
            assert read_settings().get('service.settings') is None
            assert 'IPv6: Off' in command('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
            command(base / 'acceptance-client', 'require-empty-credential')
            (root / 'cleanup-complete').touch()
            (root / 'credentials.json').unlink()
            return
        time.sleep(0.25)
    raise RuntimeError('Production Direct restoration did not complete')


def watchdog(root, parent):
    deadline = time.monotonic() + 1200
    while not (root / 'cleanup-complete').exists():
        try:
            os.kill(parent, 0)
        except ProcessLookupError:
            break
        if time.monotonic() >= deadline:
            os.kill(parent, signal.SIGTERM)
            # Give the parent's finally block time to finish launchd removal.
            # Do not race a second restoration against its atomic replacements.
            grace = time.monotonic() + 45
            while time.monotonic() < grace and not (root / 'cleanup-complete').exists():
                try:
                    os.kill(parent, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.25)
            break
        time.sleep(0.25)
    else:
        return
    if not (root / 'cleanup-complete').exists():
        restore(root)


def run(configuration):
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = read_settings()
    routing = json.loads(original.get('service.routing', b'{}'))
    assert 'service.settings' not in original and not routing.get('proxy') and routing.get('mode', 'direct') == 'direct'
    assert not (RUNTIME / 'qualification.json').exists()
    assert all(json.loads(FLAGS.read_bytes()).get(k) for k in ('core', 'engine', 'profile'))
    base = Path(__file__).resolve().parent
    command(base / 'acceptance-client', 'require-empty-credential')
    assert 'VM-only acceptance runtime' in command(base / 'mimo-core-vm-acceptance', '--vm-acceptance-status').stdout
    build = json.loads((base / 'acceptance-build.json').read_text())
    assert build['helperSHA256'] == hashlib.sha256((base / 'mimo-core-vm-acceptance').read_bytes()).hexdigest()
    assert build['inputs']['Tests/MihomoRuntimeTests/installed_acceptance_test.py'] == hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    root = Path(tempfile.mkdtemp(prefix='mimo-installed-test-', dir='/var/tmp'))
    (root / 'acceptance-build.json').write_text(json.dumps(build, indent=2))
    backup = root / 'private-backup'
    backup.mkdir(mode=0o700)
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup / name)
    credentials = root / 'credentials.json'
    credentials.write_bytes(configuration.read_bytes())
    credentials.chmod(0o600)
    configuration.unlink()
    peer = json.loads(credentials.read_text()).get('peer')
    completed, worker, capture, watcher = [], None, None, None
    capture_phases = []
    engine_processes = set()
    success = False

    def record(name):
        completed.append(name)
        print('PASS:', name, flush=True)

    def client(*args):
        result = command(base / 'acceptance-client', *args)
        return json.loads(result.stdout)

    def wait_for(predicate, name, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = client('state')
                (root / 'last-state.json').write_text(json.dumps(value, indent=2))
                if predicate(value.get('routing', {})):
                    (root / (name + '.json')).write_text(json.dumps(value, indent=2))
                    record(name)
                    return value['routing']
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                pass
            time.sleep(0.5)
        raise RuntimeError(name + ' timed out; see last-state.json')

    def active(mode):
        return lambda s: s.get('phase') == 'active' and s.get('effectiveMode') == mode and (RUNTIME / 'gate.state').read_text() == ('direct' if mode == 'direct' else 'active')

    def blocked(s):
        return s.get('phase') == 'blocked' and not s.get('effectiveMode') and (RUNTIME / 'gate.state').read_text() == 'blocked'

    def request(operation, key='default', **values):
        worker.stdin.write(json.dumps(dict(operation=operation, key=key, **values)) + '\n')
        worker.stdin.flush()
        return json.loads(worker.stdout.readline())['ok']

    def ordinary(*args):
        return command('/usr/bin/sudo', '-n', '-u', 'jay', *args, check=False)

    @contextmanager
    def packets(name, expression, empty=True):
        subjects = {worker.pid}
        job = command('/bin/launchctl', 'print', 'system/' + ENGINE, check=False).stdout
        engine_processes.update(int(line.strip()[6:]) for line in job.splitlines() if line.strip().startswith('pid = '))
        subjects.update(engine_processes)
        started = time.time()
        try:
            yield subjects
        finally:
            time.sleep(0.2)
            capture_phases.append(dict(name=name, expression=expression, empty=empty, started=started,
                                       ended=time.time(), subjects=sorted(subjects)))
            (root / 'capture-phases.json').write_text(json.dumps(capture_phases, indent=2))

    def inspect_packets():
        nonlocal capture
        capture.send_signal(signal.SIGINT)
        capture.wait(timeout=5)
        capture = None
        (root / 'capture.pid').unlink()
        for phase in capture_phases:
            text = command('/usr/sbin/tcpdump', '-tt', '-nn', '-k', 'NP', '-r', root / 'installed.pcap', phase['expression']).stdout
            selected = [line for line in text.splitlines() if line and
                        phase['started'] <= float(line.split()[0]) <= phase['ended'] and
                        any(re.search(r':' + str(pid) + r'[,)]', line) for pid in phase['subjects'])]
            (root / (phase['name'] + '.subject-packets.txt')).write_text('\n'.join(selected))
            if phase['empty'] is not None:
                assert (not selected) if phase['empty'] else bool(selected), phase['name'] + ' did not meet the packet expectation'
        record('installed-captures-confirm-no-unapproved-uplink-traffic')

    def check_blocked(name):
        with packets(name, 'dst host 1.1.1.1 or dst host 198.51.100.70'):
            assert not request('open', key=name, host='1.1.1.1', port=443)
            assert not request('open', key=name + '-mixed', host='198.51.100.70', mixed=True)
        record(name)

    def check_active(mode):
        with packets(mode + '-echo', 'dst host 198.51.100.70 or dst host 2001:db8::70'):
            for udp in (False, True):
                assert request('open', key=mode + str(udp), host='198.51.100.70', udp=udp)
            assert not request('open', key=mode + 'ipv6', host='2001:db8::70')
        with packets(mode + '-https', 'tcp dst port 443 or udp dst port 53', empty=True if mode == 'global' else None) as subjects:
            response = subprocess.Popen(['/usr/bin/curl', '--silent', '--show-error', '--fail', '--noproxy', '*',
                '--max-time', '15', '--head', 'https://github.com/robots.txt'], stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, preexec_fn=identity)
            subjects.add(response.pid)
            output, _ = response.communicate(timeout=20)
            (root / (mode + '-https.txt')).write_text(output)
            assert response.returncode == 0
        assert 'inet6 ' not in command('/sbin/ifconfig', 'utun239').stdout
        record(mode + '-installed-IPv4-TCP-UDP-DNS-HTTPS-and-IPv6-denial')

    def core_hang():
        value = command('/bin/launchctl', 'print', 'system/' + CORE).stdout
        pid = int(next(line.strip()[6:] for line in value.splitlines() if line.strip().startswith('pid = ')))
        marker = root / 'stopped-core.pid'
        marker.write_text(str(pid))
        os.kill(pid, signal.SIGSTOP)
        started = time.monotonic()
        deadline = started + 15
        try:
            while time.monotonic() < deadline:
                state = json.loads(command(base / 'installation-check', timeout=12).stdout)
                if blocked(state):
                    (root / 'core-hang.json').write_text(json.dumps({'routing': state, 'seconds': time.monotonic() - started}, indent=2))
                    record('unresponsive-core-closes-protected-traffic')
                    check_blocked('unresponsive-core-denies-new-traffic')
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError('Core hang did not close the gate')
        finally:
            os.kill(pid, signal.SIGCONT)
            marker.unlink()
        client('refresh')
        wait_for(active('global'), 'Global-reverifies-after-core-resumes')

    def service_cycle(service):
        state = json.loads(command(base / 'installation-check', service, 'stop').stdout)
        assert blocked(state)
        record(service + '-Stop-retains-Global-and-blocks')
        check_blocked(service + '-Stop-denies-ordinary-traffic')
        command(base / 'installation-check', service, 'start')
        if service != 'core':
            client('refresh')
        wait_for(active('global'), service + '-Start-reverifies-before-Global')

    def runtime_failure(kind):
        logs = Path('/Library/Logs/ExitIPMonitor')
        offsets = {p: p.stat().st_size for p in logs.glob('runtime-*.jsonl')}
        label = CORE if kind == 'core-crash' else ENGINE
        def recent_records():
            records = []
            for path in logs.glob('runtime-*.jsonl'):
                with path.open('rb') as stream:
                    stream.seek(offsets.get(path, 0))
                    for line in stream:
                        try:
                            records.append(json.loads(line))
                        except ValueError:
                            pass
            return records
        def process_id():
            value = command('/bin/launchctl', 'print', 'system/' + label, check=False).stdout
            return next((int(line.strip()[6:]) for line in value.splitlines() if line.strip().startswith('pid = ')), None)
        old_process = process_id()
        assert old_process is not None
        with packets(kind, 'dst host 198.51.100.70') as subjects:
            if kind == 'profile-mutation':
                with (RUNTIME / 'candidate.yaml').open('ab') as stream:
                    stream.write(b'\n# VM acceptance: change the verified profile bytes\n')
            else:
                os.kill(old_process, signal.SIGKILL)
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                records = recent_records()
                if any(r['event'] == 'mimo_gate_closed' and r['fields'].get('confirmed') == 'true' for r in records):
                    record(kind + '-closes-protected-gate')
                    break
                request('open', key=kind, host='198.51.100.70')
            else:
                raise RuntimeError(kind + ' did not confirm gate closure')
            deadline = time.monotonic() + 30
            while kind != 'profile-mutation' and (process_id() is None or process_id() == old_process):
                assert time.monotonic() < deadline, kind + ' did not restart'
                time.sleep(0.2)
            if kind == 'mihomo-crash':
                subjects.add(process_id())
            # A manual refresh is also allowed when the automatic startup or
            # network notification already started revalidation.
            client('refresh')
            wait_for(active('global'), kind + '-requires-fresh-Global-verification')
            records = recent_records()
            closed_index = next(i for i, r in enumerate(records) if r['event'] == 'mimo_gate_closed' and r['fields'].get('confirmed') == 'true')
            probe_index = next(i for i, r in enumerate(records) if i > closed_index and r['event'] == 'mimo_private_probe_ready')
            assert any(i > probe_index and r['event'] == 'mimo_traffic_opened' for i, r in enumerate(records))
            (root / (kind + '-events.json')).write_text(json.dumps(records, indent=2))
            assert request('open', key=kind + '-recovered', host='198.51.100.70')
            record(kind + '-restores-proxied-traffic')

    def tailnet_cycle():
        assert request('open', key='provider-public', host='198.51.100.70')
        if peer:
            for udp in (False, True):
                started = time.monotonic()
                while not request('open', key='peer' + str(udp), host=peer['addresses'][0], port=peer['port'],
                                  udp=udp, peer_token=peer['token']):
                    assert time.monotonic() - started < 30, 'Installed tailnet traffic did not become ready within 30 seconds'
                    time.sleep(0.25)
                (root / ('peer-ready-' + str(udp) + '.json')).write_text(json.dumps({'seconds': time.monotonic() - started}))
            record('installed-tailnet-peer-IPv4-TCP-and-UDP')
        client('tailnet', 'stop')
        wait_for(active('global'), 'tailnet-Stop-preserves-verified-public-access')
        if peer:
            assert not request('echo', key='peerFalse')
            assert not request('open', key='peer-stopped', host=peer['addresses'][0], port=peer['port'], peer_token=peer['token'])
            record('tailnet-Stop-blocks-existing-and-new-peer-traffic')
        assert request('echo', key='provider-public')
        client('tailnet', 'start')
        wait_for(active('global'), 'tailnet-Start-preserves-verified-public-access')
        if peer:
            deadline = time.monotonic() + 15
            while not request('open', key='peer-restarted', host=peer['addresses'][0], port=peer['port'], peer_token=peer['token']):
                assert time.monotonic() < deadline, 'Native peer traffic did not recover'
                time.sleep(0.25)
            record('tailnet-Start-restores-peer-traffic')

    def network_change():
        logs = Path('/Library/Logs/ExitIPMonitor')
        offsets = {p: p.stat().st_size for p in logs.glob('runtime-*.jsonl')}
        marker = root / 'test-route'
        routes = command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
        assert not any(line.split() and line.split()[0] == '198.51.100.254' for line in routes.splitlines())
        marker.touch()
        command('/sbin/route', '-n', 'add', '-host', '198.51.100.254', json.loads(credentials.read_text())['bind'])
        try:
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                records = []
                for path in logs.glob('runtime-*.jsonl'):
                    with path.open('rb') as stream:
                        stream.seek(offsets.get(path, 0))
                        for line in stream:
                            try:
                                records.append(json.loads(line))
                            except ValueError:
                                pass
                closed = any(r['event'] == 'mimo_gate_closed' and r['fields'].get('confirmed') == 'true' for r in records)
                checked = any(r['event'] == 'refresh_requested' and r['fields'].get('trigger') == 'network_configuration' for r in records)
                if closed and checked:
                    record('external-route-change-closes-and-immediately-requests-IP-check')
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError('The external route change did not trigger protection and an immediate check')
        finally:
            command('/sbin/route', '-n', 'delete', '-host', '198.51.100.254', check=False)
            marker.unlink()
        wait_for(active('global'), 'Global-reverifies-after-external-network-change')

    def interrupted(signum, frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    with (root / 'watchdog.log').open('w') as log:
        watcher = subprocess.Popen([sys.executable, __file__, '--watchdog', str(root), str(os.getpid())],
                                   stdout=log, stderr=log, start_new_session=True)
    print('Evidence:', root, flush=True)
    try:
        stop_jobs()
        replace_helper(base / 'mimo-core-vm-acceptance')
        # One capture for the whole test: repeatedly creating/removing pktap
        # interfaces is itself a network change and must trigger revalidation.
        capture_log = root / 'installed.capture.log'
        with capture_log.open('w') as stream:
            capture = subprocess.Popen(['/usr/sbin/tcpdump', '-n', '-U', '-i', 'pktap,en0', '-w', str(root / 'installed.pcap'),
                'tcp dst port 443 or udp dst port 53 or dst host 198.51.100.70 or dst host 2001:db8::70'], stdout=stream, stderr=stream)
        (root / 'capture.pid').write_text(str(capture.pid))
        deadline = time.monotonic() + 3
        while 'listening on' not in capture_log.read_text():
            assert capture.poll() is None and time.monotonic() < deadline
            time.sleep(0.05)
        start_jobs()
        wait_for(active('direct'), 'acceptance-helper-restores-Direct')
        account = pwd.getpwnam('jay')
        def identity():
            os.setgroups([])
            os.setgid(account.pw_gid)
            os.setuid(account.pw_uid)
        worker = subprocess.Popen([sys.executable, '-u', '-c', WORKER], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, preexec_fn=identity)
        with packets('Direct-capture-positive-control', 'dst host 1.1.1.1 and udp dst port 53', empty=False):
            request('open', key='capture-control', host='1.1.1.1', port=53, udp=True)
        record('Direct-capture-confirms-ordinary-process-attribution')
        client('initialize')
        client('proxy', credentials)
        client('mode', 'rule')
        state = wait_for(lambda s: blocked(s) and bool(s.get('blockingIP')), 'Rule-empty-allowlist-observes-IP-but-blocks')
        address = state['blockingIP']['address']
        check_blocked('empty-allowlist-denies-ordinary-and-mixed-port-traffic')
        client('allow', address)
        wait_for(active('rule'), 'Rule-opens-only-after-allowlisted-IP-check')
        check_active('rule')
        assert request('echo', key='ruleFalse'), 'The existing TCP flow must be live before revocation'
        client('allow', '203.0.113.254')
        assert not request('echo', key='ruleFalse'), 'Revocation must close the previously live flow'
        wait_for(lambda s: blocked(s) and s.get('blockingIP', {}).get('address') == address, 'wrong-allowlist-shows-triggering-IP')
        check_blocked('wrong-allowlist-closes-existing-and-new-traffic')
        client('allow', address)
        wait_for(active('rule'), 'Rule-recovers-after-allowlist-change')
        client('mode', 'global')
        wait_for(active('global'), 'Global-opens-after-new-verification')
        check_active('global')
        client('allow')
        wait_for(lambda s: blocked(s) and s.get('blockingIP', {}).get('address') == address, 'Global-empty-allowlist-observes-IP-but-blocks')
        check_blocked('Global-empty-allowlist-denies-traffic')
        client('allow', address)
        wait_for(active('global'), 'Global-recovers-after-allowlist-change')
        client('wrong-password', credentials)
        wait_for(blocked, 'wrong-proxy-password-remains-blocked')
        check_blocked('wrong-password-has-no-Direct-fallback')
        client('proxy', credentials)
        wait_for(active('global'), 'Global-recovers-with-correct-proxy-password')
        tailnet_cycle()
        network_change()
        core_hang()
        for service in ('profileHosting', 'mihomo', 'core'):
            service_cycle(service)
        for failure in ('core-crash', 'mihomo-crash', 'profile-mutation'):
            runtime_failure(failure)
        client('mode', 'direct')
        wait_for(active('direct'), 'explicit-Direct-recovers')
        assert ordinary('/usr/bin/curl', '--silent', '--fail', '--max-time', '10', '--head', 'https://github.com/robots.txt').returncode == 0
        assert not (RUNTIME / 'qualification.json').exists()
        record('qualification-manifest-never-created')
        inspect_packets()
        success = True
    finally:
        if capture:
            capture.send_signal(signal.SIGINT)
            capture.wait(timeout=5)
            (root / 'capture.pid').unlink(missing_ok=True)
        if worker:
            worker.terminate()
            worker.wait(timeout=5)
        restore(root)
        record('production-helper-Direct-and-empty-credential-restored')
        if watcher:
            watcher.wait(timeout=5)
        (root / 'report.json').write_text(json.dumps({'passed': completed, 'success': success,
            'helperSHA256': build['helperSHA256'],
            'scope': 'VM-only installed-service integration; not release qualification'}, indent=2))


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--watchdog':
        watchdog(Path(sys.argv[2]), int(sys.argv[3]))
    elif len(sys.argv) == 2:
        run(Path(sys.argv[1]))
    else:
        sys.exit('Usage: installed_acceptance_test.py PRIVATE_FIXTURE_JSON')
