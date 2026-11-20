#!/usr/bin/env python3
"""Actual installed DNS egress in mimo-vm, using the saved proxy and allowlist.

Captures stay root-private. No mock resolver, helper substitution or peer change.
TXT queries, including a unique name, exercise upstream resolution rather than
fake-IP address answers. A negative response may be NXDOMAIN or NOERROR/NODATA.
"""
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
import uuid

from installed_acceptance_test import command
from release_network_progress_test import offsets, events, LOGS
from release_tailnet_lifecycle_test import native, cleanup
from upgrade_test import STORAGE, FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    assert json.loads(native('status', '--json').stdout)['BackendState'] == 'Stopped'
    original = read_settings()
    assert json.loads(original['service.routing'])['mode'] == 'direct'
    assert not json.loads(original['service.settings'])['tailscaleProviderEnabled']
    assert json.loads(original['service.settings'])['allowlist']['addresses']
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-dns-privacy-', dir='/var/tmp'))
    (root / 'installed-release').touch()
    backup = root / 'private-backup'; backup.mkdir()
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup / name)
    (backup / 'credential.digest').write_text(command(BASE / 'acceptance-client', 'credential-digest').stdout.strip())
    with (root / 'watchdog.log').open('w') as log:
        guard = subprocess.Popen([sys.executable, BASE / 'release_tailnet_lifecycle_test.py', '--watchdog', str(root), str(os.getpid())],
                                 stdout=log, stderr=log, start_new_session=True)
    capture = None
    passed, phases, error = [], [], None
    print('Evidence:', root, flush=True)
    account = pwd.getpwnam('jay')

    def ordinary():
        os.setgroups([]); os.setgid(account.pw_gid); os.setuid(account.pw_uid)

    def record(name):
        passed.append(name); print('PASS:', name, flush=True)

    def client(*args):
        result = command(BASE / 'acceptance-client', *args, timeout=70, check=False)
        if result.returncode:
            (root / 'client-error-private.txt').write_text(result.stdout + result.stderr)
            raise RuntimeError('Core operation failed')
        return json.loads(result.stdout)

    def ready(mode, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = client('state')['routing']
            if value['phase'] == 'active' and value.get('effectiveMode') == mode: return
            time.sleep(.3)
        raise RuntimeError('Timed out: ' + mode)

    def query(server, port, name, kind='TXT', tcp=False, negative=False):
        args = ['/usr/bin/dig', '@' + server, '-p', str(port), name, kind, '+time=5', '+tries=1']
        if tcp: args.append('+tcp')
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, preexec_fn=ordinary)
        out, err = proc.communicate(timeout=15)
        (root / ('query-' + str(proc.pid) + '.json')).write_text(json.dumps(dict(arguments=args,
            exit=proc.returncode, stdout=out, stderr=err, negative=negative, state=client('state'))))
        assert proc.returncode == 0, 'DNS query failed'
        if negative:
            assert re.search(r'status: (NXDOMAIN|NOERROR),', out), 'DNS returned an error instead of a negative answer'
            assert 'ANSWER: 0,' in out and re.search(r'\bIN\s+SOA\b', out), 'DNS negative answer lacks authority'
        else:
            assert 'status: NOERROR,' in out and re.search(r'ANSWER: [1-9]', out), 'DNS returned no answer'
        return proc.pid

    def stop_capture():
        nonlocal capture
        if capture is not None:
            capture.send_signal(signal.SIGINT); capture.wait(timeout=5); capture = None

    def interrupt(signum, frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGINT, interrupt); signal.signal(signal.SIGTERM, interrupt)
    try:
        with (root / 'capture.log').open('w') as log:
            capture = subprocess.Popen(['/usr/sbin/tcpdump', '-n', '-U', '-i', 'pktap,en0', '-w', str(root / 'traffic.pcap'), 'tcp or udp'], stdout=log, stderr=log)
        (root / 'capture.pid').write_text(str(capture.pid))
        deadline = time.monotonic() + 8
        while 'listening on' not in (root / 'capture.log').read_text():
            assert capture.poll() is None and time.monotonic() < deadline
            time.sleep(.1)
        start = time.time()
        direct_pid = query('1.1.1.1', 53, 'example.com')
        phases.append(dict(name='direct-capture-positive-control', start=start, end=time.time(), pids=[direct_pid], expression='dst host 1.1.1.1 and dst port 53', empty=False))
        for mode in ('rule', 'global'):
            client('mode', mode); ready(mode)
            assert client('check-protected-dns')['publicDNSProxied']
            record(mode + '-delivered-profile-uses-proxied-DoH-and-encrypted-bootstrap')
            # The real profile is validated/reloaded by the pinned engine before
            # the normal allowlist gate can become active.
            output = command('/bin/launchctl', 'print', 'system/com.example.exitipmonitor.mihomo').stdout
            engine = int(re.search(r'\bpid = (\d+)', output)[1])
            start, pids = time.time(), [engine]
            pids.append(query('127.0.0.1', 1053, 'example.com'))
            record(mode + '-UDP-public-DNS-query-succeeds')
            pids.append(query('127.0.0.1', 1053, 'github.com', tcp=True))
            record(mode + '-TCP-public-DNS-query-succeeds')
            pids.append(query('127.0.0.1', 1053, 'mimo-' + uuid.uuid4().hex + '.example.com', negative=True))
            phases.append(dict(name=mode + '-no-direct-public-DNS', start=start, end=time.time(), pids=pids,
                expression='dst port 53 or dst port 853 or ((dst host 1.1.1.1 or dst host 120.53.53.53 or dst host 223.5.5.5 or dst host 223.6.6.6) and tcp dst port 443)', empty=True))
            record(mode + '-real-UDP-TCP-and-uncached-DNS-queries-succeed')
            command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail', '--noproxy', '*', '--max-time', '15', '--head', 'https://github.com/robots.txt')
            record(mode + '-ordinary-system-DNS-and-HTTPS-work')
        stop_capture()
        for phase in phases:
            decoded = command('/usr/sbin/tcpdump', '-tt', '-nn', '-k', 'NP', '-r', root / 'traffic.pcap', phase['expression']).stdout
            selected = [row for row in decoded.splitlines() if row and phase['start'] <= float(row.split()[0]) <= phase['end']
                        and any(re.search(r':' + str(pid) + r'[,)]', row) for pid in phase['pids'])]
            (root / (phase['name'] + '.txt')).write_text('\n'.join(selected))
            assert (not selected) if phase['empty'] else bool(selected), 'Packet expectation failed: ' + phase['name']
            record(phase['name'])
        # Native connect deliberately invalidates the old approval. A saved
        # provider-enabled flag is committed before that transaction finishes,
        # so it cannot stand in for a new, usable protected connection.
        baseline = offsets(LOGS)
        previous_check = client('state')['routing']['observedIP']['checkedAt']
        native('up')
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            value = client('state'); routing = value['routing']
            started = any(r['event'] == 'mimo_tailnet_automatic_state_changed'
                          and r['fields'].get('enabled') == 'true' for r in events(LOGS, baseline))
            if (started and value['settings']['tailscaleProviderEnabled'] and routing.get('tailnetExpected')
                    and routing['phase'] == 'active' and routing.get('effectiveMode') == 'global'
                    and routing.get('observedIP', {}).get('checkedAt', 0) > previous_check):
                break
            time.sleep(.4)
        else: raise RuntimeError('Native provider did not complete startup and fresh verification')
        status = json.loads(native('status', '--json').stdout)
        assert status['BackendState'] == 'Running'
        name = status['Self']['DNSName']
        query('127.0.0.1', 1053, name, kind='A', tcp=True)
        record('private-MagicDNS-A-still-resolves-through-native-Tailscale')
    except BaseException as exc:
        (root / 'failure-private.txt').write_text(repr(exc))
        error = type(exc).__name__ + ': see private VM evidence'
    finally:
        stop_capture()
        cleanup(root); guard.wait(timeout=10)
        record('original-Direct-native-off-settings-and-credentials-restored')
        (root / 'report.json').write_text(json.dumps(dict(success=error is None, passed=passed, error=error,
            packageSHA256=build['packageSHA256'], helperSHA256=build['helperSHA256'],
            scope='Exact installed Release and pinned mihomo in mimo-vm; actual UDP/TCP/uncached DNS queries, native MagicDNS, ordinary HTTPS and physical-interface process-attributed packet capture. Direct bootstrap remains an explicit encrypted exception.'), indent=2)+'\n')
    print('RESULT:', 'PASS' if error is None else 'FAIL', flush=True)
    return int(error is not None)


if __name__ == '__main__': sys.exit(main())
