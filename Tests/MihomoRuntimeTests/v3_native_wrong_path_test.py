#!/usr/bin/env python3
"""VM-only: engine-owned private DNS must not escape on a physical interface.

Bind sockets to en0 without deleting a user's native VPN routes. A temporary
interface-scoped IPv6 host route overrides the profile's unreachable exclusion
for this one test destination. A lower lab anchor contains every test packet if
Mimo fails, with a Direct positive control. Never run alongside another campaign.
"""
import fcntl
import itertools
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import v3_installed_test as t
from v3_fault_traffic_test import approved, pid

ROOT = Path(sys.argv[1])
LAB = 'com.apple/999.mimo-qualification'
RESULTS = []
PENDING_ROUTES = []
F = json.loads((ROOT / 'fixture.json').read_text())
RULES = ('block drop out quick on en0 inet to 100.100.100.100 port 53 label "mimo:test:private-dns-v4"\n'
         'block drop out quick on en0 inet6 to fd7a:115c:a1e0::53 port 53 label "mimo:test:private-dns-v6"\n')
# PF requires a transport with ports; render one rule per family/transport.
RULES = '\n'.join(line.replace(' to ', ' proto ' + protocol + ' to ', 1)
                  for line in RULES.splitlines() for protocol in ('tcp', 'udp')) + '\n'


def counts(anchor, label):
    output = t.run(['/sbin/pfctl', '-a', anchor, '-vvsr'], 5)
    assert output.returncode == 0, output.stderr
    total = 0
    for block in re.split(r'(?m)^@', output.stdout):
        lines = block.splitlines()
        if lines and label in lines[0]:
            match = re.search(r'Packets:\s+(\d+)', block)
            assert match, 'Missing packet counter'
            total += int(match.group(1))
    return total


def send(family=None, protocol=None):
    # Same UID/primary GID as the installed engine, but no proxy or TUN.
    owner = t.run(['/bin/ps', '-p', str(pid('mihomo')), '-o', 'uid=,gid=']).stdout.split()
    assert owner == ['0', '10000'], 'Unexpected engine owner for this fixture'
    code = '''import os,socket,struct,json,sys
os.setgroups([]); os.setgid(10000)
index=socket.if_nametoindex("en0")
results=[]
for family,host,level,option in [(socket.AF_INET,"100.100.100.100",socket.IPPROTO_IP,25),(socket.AF_INET6,"fd7a:115c:a1e0::53",socket.IPPROTO_IPV6,125)]:
 for kind in [socket.SOCK_STREAM,socket.SOCK_DGRAM]:
  if sys.argv[1]!="None" and family!=int(sys.argv[1]): continue
  if sys.argv[2]!="None" and kind!=int(sys.argv[2]): continue
  with socket.socket(family,kind) as s:
   s.settimeout(.35); s.setsockopt(level,option,struct.pack("I",index))
   try:
    s.connect((host,53)); s.send(b"mimo-native-route-qualification")
    results.append(dict(family=family,kind=kind,sent=True))
   except OSError as error: results.append(dict(family=family,kind=kind,sent=False,errno=error.errno,error_type=type(error).__name__))
print(json.dumps(results))
'''
    result = t.run(['/usr/bin/python3', '-c', code,
                    'None' if family is None else str(int(family)),
                    'None' if protocol is None else str(int(protocol))], 5)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def record(name, ok, **details):
    RESULTS.append(dict(id=name, result='PASS' if ok else 'NOT_QUALIFIED', **details))
    (ROOT / 'native-wrong-path-results.json').write_text(json.dumps(RESULTS, indent=2))
    print(name + ': ' + RESULTS[-1]['result'], flush=True)


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    assert not t.run(['/sbin/pfctl', '-a', LAB, '-sr']).stdout.strip(), 'Lab anchor occupied'
    loaded = subprocess.run(['/sbin/pfctl', '-a', LAB, '-f', '-'], input=RULES, capture_output=True, text=True)
    assert loaded.returncode == 0, loaded.stderr
    try:
        t.route('direct'); t.wait_active('direct', 100)
        before = [counts(LAB, 'private-dns-' + family) for family in ('v4', 'v6')]
        send()
        control = [counts(LAB, 'private-dns-' + family) - count for family, count in zip(('v4', 'v6'), before)]
        record('native-wrong-path-direct-control', all(n >= 2 for n in control), family_packet_counts=control)
        assert all(n >= 2 for n in control), 'Physical-interface detector not demonstrated in both families'
        for family, mode in itertools.product(('ipv4', 'dual'), ('rule', 'global')):
            t.route(mode, family); approved(mode, family)
            # Keep an audit refresh from resetting counters during the short probe.
            with open('/Library/Application Support/Mimo/Runtime/pf-mutation.lock', 'r+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                assert t.active_guard(t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr']).stdout)
                denied_before = counts(t.ANCHOR, 'mimo:active:tailnet-wrong-path')
                escaped_before = counts(LAB, 'mimo:test:private-dns-')
                args = ['-inet6', '-host', '-ifscope', 'en0', 'fd7a:115c:a1e0::53', F['data6']]
                added = t.run(['/sbin/route', '-n', 'add', *args], 4)
                assert added.returncode == 0, 'Refusing to replace an existing route: ' + added.stderr
                PENDING_ROUTES.append(args)
                # Independent cleanup survives loss of this test process. Delete
                # only the exact scoped route successfully added above.
                cleanup = ('import subprocess,time; time.sleep(10); subprocess.run(' +
                           repr(['/sbin/route', '-n', 'delete', *args]) + ',capture_output=True)')
                restorer = subprocess.Popen(['/usr/bin/python3', '-c', cleanup],
                                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL, start_new_session=True)
                outcomes = []
                try:
                    for af, protocol in itertools.product((socket.AF_INET, socket.AF_INET6), (socket.SOCK_STREAM, socket.SOCK_DGRAM)):
                        previous = counts(t.ANCHOR, 'mimo:active:tailnet-wrong-path')
                        outcome = send(af, protocol)[0]
                        outcome['pf_denied_packets'] = counts(t.ANCHOR, 'mimo:active:tailnet-wrong-path') - previous
                        outcomes.append(outcome)
                finally:
                    removed = t.run(['/sbin/route', '-n', 'delete', *args], 4)
                    assert removed.returncode == 0, 'Test route removal failed; independent cleanup remains scheduled'
                    PENDING_ROUTES.remove(args)
                    restorer.terminate(); restorer.wait(timeout=3)
                denied = counts(t.ANCHOR, 'mimo:active:tailnet-wrong-path') - denied_before
                escaped = counts(LAB, 'mimo:test:private-dns-') - escaped_before
            record(family + '-' + mode + '-native-wrong-path', all(o['pf_denied_packets'] >= 1 for o in outcomes) and escaped == 0,
                   mimo_denied_packets=denied, native_attempts=escaped, socket_outcomes=outcomes,
                   scope='Engine-owned TCP/UDP bound to physical interface; scoped IPv6 test host route; each request must hit the earlier PF denial')
    finally:
        for args in PENDING_ROUTES:
            t.run(['/sbin/route', '-n', 'delete', *args], 4)
        t.route('direct'); t.wait_active('direct', 100)
        t.run(['/sbin/pfctl', '-a', LAB, '-F', 'rules'])


if __name__ == '__main__': main()
