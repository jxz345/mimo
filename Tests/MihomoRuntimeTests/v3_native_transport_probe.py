#!/usr/bin/env python3
"""Bounded VM-only socket exception experiment; never install this as policy.

Snapshot/restore only Mimo's active anchor under its mutation lock. A separate
watchdog restores the policy and resumes both owners even if this process dies.
No provider, profile, Tailscale settings or foreign firewall rule is changed.
"""
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import v3_installed_test as t
from v3_fault_traffic_test import approved
from v3_active_guard_compat_test import tailnet, peer_checks

ROOT = Path(sys.argv[1])
RUNTIME = Path('/Library/Application Support/Mimo/Runtime')
IDENTIFIER = 'io.tailscale.ipn.macsys.network-extension'


def rules():
    lines = t.run(['/bin/ps', '-axo', 'pid=,uid=,comm=']).stdout.splitlines()
    candidates = [line.strip().split(None, 2) for line in lines if line.rstrip().endswith('/' + IDENTIFIER)]
    assert len(candidates) == 1 and candidates[0][1] == '0'
    pid, _, path = candidates[0]
    assert path.startswith('/Library/SystemExtensions/')
    requirement = 'anchor apple generic and identifier "' + IDENTIFIER + '" and certificate leaf[subject.OU] = "W5364U7YZB"'
    assert t.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement, path], 10).returncode == 0
    value = t.run(['/usr/sbin/lsof', '-nP', '-a', '-p', pid, '-i', '-F0puftPnT'], 5)
    assert value.returncode == 0
    fields = {}; owner = None; process = None; udp = set(); tcp = set()
    def finish():
        if owner != '0' or process != pid or fields.get('t') not in ('IPv4', 'IPv6'): return
        name = fields.get('n', '')
        family = 'inet6' if fields['t'] == 'IPv6' else 'inet'
        def endpoint(value):
            host, port = value.rsplit(':', 1); port = int(port)
            assert 1024 <= port <= 65535
            host = host.strip('[]')
            return ('any' if host == '*' else str(ipaddress.ip_address(host))), port
        if fields.get('P') == 'UDP' and '->' not in name:
            source, port = endpoint(name)
            udp.add(f'pass out quick {family} proto udp from {source} port = {port} to any user = 0 no state label "mimo:test:verified-native-udp"')
        if fields.get('P') == 'TCP' and fields.get('T') in ('ST=ESTABLISHED', 'ST=SYN_SENT') and name.endswith(':443'):
            local, remote = name.split('->'); source, port = endpoint(local)
            destination = str(ipaddress.ip_address(remote[:-4].strip('[]')))
            tcp.add(f'pass out quick {family} proto tcp from {source} port = {port} to {destination} port = 443 user = 0 no state label "mimo:test:verified-native-tcp"')
    for raw in value.stdout.split('\0'):
        field = raw.strip('\n')
        if not field: continue
        key, payload = field[0], field[1:]
        if key in ('p', 'f'): finish(); fields = {}
        if key == 'p': process = payload
        elif key == 'u': owner = payload
        elif key == 'T' and not payload.startswith('ST='): continue
        else: fields[key] = payload
    finish()
    assert udp and len(udp) + len(tcp) < 32
    return sorted(udp), sorted(tcp)


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    t.route('rule', 'ipv4'); approved('rule', 'ipv4')
    peer = tailnet(); assert peer
    before = peer_checks(peer)
    udp, tcp = rules()
    original = t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr']).stdout
    assert t.active_guard(original)
    backup = ROOT / 'transport-probe-original.pf'; backup.write_text(original)
    owners = []
    for role in ('core', 'supervisor'):
        job = t.run(['/bin/launchctl', 'print', 'system/com.mimo.' + role]).stdout
        owners.append(int(next(s.split('=')[1].strip() for s in job.splitlines() if s.strip().startswith('pid ='))))
    resume = 'import pathlib,time,subprocess,os,signal; time.sleep(35); subprocess.run(["/sbin/pfctl","-a",'+repr(t.ANCHOR)+',"-f",'+repr(str(backup))+'],capture_output=True)\nfor pid in '+repr(owners)+':\n try: os.kill(pid,signal.SIGCONT)\n except ProcessLookupError: pass\n'
    watchdog = subprocess.Popen(['/usr/bin/python3', '-c', resume], start_new_session=True)
    result = dict(before_ping=before[0], before_dns=before[1], udp_rules=len(udp), tcp_rules=len(tcp))
    lock = (RUNTIME / 'pf-mutation.lock').open('r+')
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        for pid in owners: os.kill(pid, signal.SIGSTOP)
        # The last variant is only a bounded attribution experiment. Never ship
        # ownerless socket-port grants; it distinguishes PF ownership lookup.
        for label, grants in [('udp', udp), ('udp_tcp', udp + tcp),
                              ('port_only', [line.replace(' user = 0', '') for line in udp + tcp])]:
            policy = ROOT / 'transport-probe.pf'
            policy.write_text('\n'.join(grants) + '\n' + original)
            load = t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-f', str(policy)], 4)
            assert load.returncode == 0, load.stderr
            time.sleep(1)
            answers = [peer_checks(peer) for _ in range(2)]
            live = t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-vvsr']).stdout
            (ROOT / ('transport-' + label + '-counters.txt')).write_text(live)
            result[label] = dict(ping=any(x[0] for x in answers), dns=all(x[1] for x in answers))
    finally:
        t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-f', str(backup)], 4)
        for pid in owners:
            try: os.kill(pid, signal.SIGCONT)
            except ProcessLookupError: pass
        lock.close()
        watchdog.terminate(); watchdog.wait(timeout=3)
        t.route('direct'); t.wait_active('direct', 100)
    (ROOT / 'native-transport-probe.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result))


if __name__ == '__main__': main()
