#!/usr/bin/env python3
"""Installed active-guard compatibility; private names never enter exported results."""
import itertools
import json
import os
from pathlib import Path
import socket
import sys
import time
import uuid
from urllib.parse import quote
import v3_installed_test as t
from v3_fault_traffic_test import approved

ROOT = Path(sys.argv[1])
F = json.loads((ROOT / 'fixture.json').read_text())
RESULTS = []
TAILSCALE = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'


def record(name, ok, **details):
    RESULTS.append(dict(id=name, result='PASS' if ok else 'FAIL', **details))
    (ROOT / 'compat-results.json').write_text(json.dumps(RESULTS, indent=2))
    print(name + ': ' + RESULTS[-1]['result'], flush=True)


def tailnet():
    r = t.run([TAILSCALE, 'status', '--json'], 12)
    if r.returncode: return None
    peers = json.loads(r.stdout).get('Peer', {}).values()
    return next((p for p in peers if p.get('Online') and p.get('DNSName') and p.get('TailscaleIPs')), None)


def peer_checks(peer):
    host = next(ip for ip in peer['TailscaleIPs'] if ':' not in ip)
    ping = t.run(['/sbin/ping', '-c', '1', '-W', '1500', host], 4)
    dns = t.run(['/usr/bin/dig', '@100.100.100.100', peer['DNSName'], 'A', '+tcp', '+time=2', '+tries=1', '+short'], 4)
    return ping.returncode == 0, dns.returncode == 0 and host in dns.stdout


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    t.route('direct'); t.wait_active('direct', 100)
    peer = tailnet()
    baseline = peer_checks(peer) if peer else (False, False)
    record('tailnet-direct-baseline', all(baseline), peer_available=peer is not None)
    saved = t.state()['settings']
    suffix = uuid.uuid4().hex + '.mimo-lab.test'
    names = {family + '-' + mode: 'aonly-guard-' + family + '-' + mode + '-' + suffix
             for family, mode in itertools.product(('ipv4', 'dual'), ('rule', 'global'))}
    settings = dict(saved, bypassBlocks=[dict(id=str(uuid.uuid4()), name='Guard qualification', enabled=True,
                                            domains=[dict(domain=name, match='exact') for name in names.values()])])
    try:
        t.request('configure', settings=settings)
        for family, mode in itertools.product(('ipv4', 'dual'), ('rule', 'global')):
            t.route(mode, family)
            if '--empty-active-comparison' in sys.argv[2:]:
                t.wait_active(mode, 100)
                assert not t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr']).stdout.strip()
            else:
                approved(mode, family)
            label = family + '-' + mode
            name = names[label]
            try:
                with socket.create_connection((name, F['stream_port']), timeout=6) as client:
                    value = (F['token'] + ':guard-direct').encode()
                    client.sendall(value)
                    intended = 'DIRECT' if mode == 'rule' else 'Proxy'
                    answer = b''
                    while len(answer) < len(value):
                        part = client.recv(len(value) - len(answer))
                        if not part: break
                        answer += part
                    # Connection publication and the echo response are concurrent.
                    deadline = time.monotonic() + 1
                    while True:
                        connections = t.api('/connections')['connections']
                        chosen = [c for c in connections if c.get('metadata', {}).get('host') == name]
                        chains = [c.get('chains', []) for c in chosen]
                        if any(intended in c for c in chains) or time.monotonic() >= deadline: break
                        time.sleep(.05)
                    record(label + '-bypass-selection', answer == value and any(intended in c for c in chains),
                           expected=intended, matched_connections=len(chosen), payload_matched=answer == value,
                           intended_chain_present=any(intended in c for c in chains))
            except Exception as error:
                record(label + '-bypass-selection', False, error=type(error).__name__)
            if peer and all(baseline):
                ping, dns = peer_checks(peer)
                record(label + '-native-tailnet-ping', ping)
                record(label + '-native-tailnet-dns', dns)
                try:
                    answer = t.api('/dns/query?name=' + quote(peer['DNSName']) + '&type=A')
                    expected = set(peer['TailscaleIPs'])
                    ok = any(a.get('data') in expected for a in answer.get('Answer', []))
                    record(label + '-engine-private-dns', ok)
                except Exception:
                    record(label + '-engine-private-dns', False)
            # Dedicated-group grants must actually match engine traffic, not just ps.
            counters = t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-vvsr']).stdout
            (ROOT / (label + '-guard-counters.txt')).write_text(counters)
    finally:
        t.route('direct'); t.wait_active('direct', 100)
        t.request('configure', settings=saved)


if __name__ == '__main__': main()
