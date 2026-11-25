#!/usr/bin/env python3
"""Eight-second VM-only attribution probe for native VPN startup permission.

Never installed as product policy. Keeps the active fallback/wrong-path denials,
permits only the signed native extension's held transport sockets, then restores
the exact original PF policy. Independent recovery resumes paused owners.
"""
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time
import uuid

ROOT = Path(sys.argv[1])
RUNTIME = Path('/Library/Application Support/Mimo/Runtime')
ANCHOR = 'com.apple/000.mimo'
TS = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
IDENTIFIER = 'io.tailscale.ipn.macsys.network-extension'


def run(args, timeout=5, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, **kwargs)


def atomic(path, value):
    temporary = path.with_name('.bootstrap-probe-' + uuid.uuid4().hex)
    temporary.write_text(value)
    temporary.replace(path)


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert run(['/usr/sbin/sysctl', '-n', 'hw.model']).stdout.startswith('VirtualMac')
    os.umask(0o077)
    candidates = [line.strip().split(None, 2) for line in run(['/bin/ps', '-axo', 'pid=,uid=,comm=']).stdout.splitlines()
                  if line.rstrip().endswith('/' + IDENTIFIER)]
    assert len(candidates) == 1
    pid, uid, executable = candidates[0]
    assert uid == '0' and executable.startswith('/Library/SystemExtensions/')
    requirement = 'anchor apple generic and identifier "' + IDENTIFIER + '" and certificate leaf[subject.OU] = "W5364U7YZB"'
    assert run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement, executable], 10).returncode == 0
    raw = run(['/usr/sbin/lsof', '-nP', '-a', '-p', pid, '-i', '-F0puftPnT'])
    assert raw.returncode == 0 and len(raw.stdout) < 1048576
    fields = {}; process = None; owner = None; grants = set()

    def endpoint(value):
        host, port = value.rsplit(':', 1)
        port = int(port)
        assert 1 <= port <= 65535
        host = host.strip('[]')
        return None if host in ('*', '0.0.0.0', '::') else str(ipaddress.ip_address(host)), port

    def finish():
        if process != pid or owner != '0' or fields.get('t') not in ('IPv4', 'IPv6'): return
        family = 'inet6' if fields['t'] == 'IPv6' else 'inet'
        name = fields.get('n', '')
        if fields.get('P') == 'UDP' and '->' not in name:
            source, port = endpoint(name)
            if port >= 1024:
                grants.add(f'pass out quick {family} proto udp from {source or "any"} port = {port} to any user = 0 no state label "mimo:test:native-bootstrap-udp"')
        elif fields.get('P') == 'TCP' and fields.get('T') in ('ST=ESTABLISHED', 'ST=SYN_SENT', 'ST=CLOSED') and '->' in name:
            local, remote = name.split('->')
            source, port = endpoint(local); destination, remote_port = endpoint(remote)
            if source and port >= 1024 and destination and remote_port == 443:
                grants.add(f'pass out quick {family} proto tcp from any to {destination} port = 443 user = 0 no state label "mimo:test:native-bootstrap-https"')

    for raw_field in raw.stdout.split('\0'):
        field = raw_field.strip('\n')
        if not field: continue
        key, value = field[0], field[1:]
        if key in ('p', 'f'): finish(); fields = {}
        if key == 'p': process = value; owner = None
        elif key == 'u': owner = value
        elif key == 'T' and not value.startswith('ST='): continue
        else: fields[key] = value
    finish()
    assert 0 < len(grants) <= 128
    original = run(['/sbin/pfctl', '-a', ANCHOR, '-sr']).stdout
    assert original.endswith('block drop out quick all label "mimo:active:deny-native-fallback"\n')
    assert 'label "mimo:active:tailnet"' not in original
    assert (RUNTIME / 'guard.expected').read_text() == original
    marker = next(line for line in original.splitlines() if 'label "mimo:active:engine"' in line)
    trial = original.replace(marker, '\n'.join(sorted(grants)) + '\n' + marker, 1)
    assert trial.index('mimo:active:tailnet-wrong-path') < trial.index('mimo:test:native-bootstrap')
    assert run(['/sbin/pfctl', '-n', '-a', ANCHOR, '-f', '-'], input=trial).returncode == 0
    backup = ROOT / 'bootstrap-probe-original.pf'
    assert not backup.exists(), 'Do not overwrite prior probe evidence'
    backup.write_text(original)
    owners = []
    for role in ('core', 'supervisor'):
        text = run(['/bin/launchctl', 'print', 'system/com.mimo.' + role]).stdout
        owners.append(int(re.search(r'^\s*pid = (\d+)$', text, re.M)[1]))
    recovery = '''import os,signal,time,subprocess,pathlib
time.sleep(20)
subprocess.run(['/sbin/pfctl','-a',ANCHOR,'-f',BACKUP],capture_output=True,timeout=5)
for pid in OWNERS:
 try:os.kill(pid,signal.SIGCONT)
 except ProcessLookupError:pass
'''.replace('ANCHOR', repr(ANCHOR)).replace('BACKUP', repr(str(backup))).replace('OWNERS', repr(owners))
    watchdog = subprocess.Popen(['/usr/bin/python3', '-c', recovery], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    samples = []; lock = (RUNTIME / 'pf-mutation.lock').open('r+')
    try:
        deadline = time.monotonic() + 5
        while True:
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); break
            except BlockingIOError:
                assert time.monotonic() < deadline
                time.sleep(.02)
        assert run(['/sbin/pfctl', '-a', ANCHOR, '-sr']).stdout == original
        for pid in owners: os.kill(pid, signal.SIGSTOP)
        atomic(RUNTIME / 'pf-mutation.epoch', uuid.uuid4().hex)
        assert run(['/sbin/pfctl', '-a', ANCHOR, '-f', '-'], input=trial).returncode == 0
        started = time.time()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            result = json.loads(run([TS, 'status', '--json'], 2).stdout)
            samples.append(dict(at=time.time(), backend=result.get('BackendState'), online=result.get('Self', {}).get('Online')))
            time.sleep(.3)
        (ROOT / 'bootstrap-probe-counters.txt').write_text(run(['/sbin/pfctl', '-a', ANCHOR, '-vvsr']).stdout)
    finally:
        atomic(RUNTIME / 'pf-mutation.epoch', uuid.uuid4().hex)
        restored = run(['/sbin/pfctl', '-a', ANCHOR, '-f', str(backup)]).returncode == 0
        for pid in owners:
            try: os.kill(pid, signal.SIGCONT)
            except ProcessLookupError: pass
        lock.close()
        if restored:
            watchdog.terminate(); watchdog.wait(timeout=3)
    report = dict(grants=len(grants), started_at=started, samples=samples,
                  restored_original_policy=restored, owners_resumed=True,
                  connected_during_probe=any(s['backend'] == 'Running' for s in samples))
    (ROOT / 'bootstrap-probe-result.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report))


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
