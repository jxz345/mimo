#!/usr/bin/env python3
"""Installed paired-approval recovery in the isolated, explicitly trusted VM lab.

Requires the previously selected closed fixture. No credentials/raw state are
exported. Recovery timing is not a bound on packet leakage before detection.
"""
import itertools
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import v3_installed_test as t

ROOT = Path(sys.argv[1])
results = []


def check(name, valid, **details):
    results.append(dict(id=name, passed=bool(valid), **details))
    (ROOT / 'active-recovery.json').write_text(json.dumps(results, indent=2))
    print(name + ': ' + ('PASS' if valid else 'FAIL'), flush=True)
    assert valid, name


def proof(mode, family):
    value = t.wait_active(mode, timeout=100)['routing']
    obs = value.get('exitObservations') or {}
    v4, v6 = obs.get('ipv4') or {}, obs.get('ipv6')
    valid = value['configuration']['networkFamily'] == family and v4.get('ipAddress') == '203.0.113.10'
    valid &= (v6 is None if family == 'ipv4' else v6 is not None and v6.get('ipAddress') == '2001:db8::10')
    valid &= all(s['health'] == 'running' for s in value['services'])
    valid &= t.active_guard(t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr']).stdout)
    live = t.api('/configs')
    valid &= live['mode'] == mode and live['mimo-destination-family'] == family
    assert valid, 'Active family/profile/readiness does not match'
    return obs['verification']['id']


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert t.run(['/usr/sbin/sysctl', '-n', 'hw.model']).stdout.startswith('VirtualMac')
    assert t.state()['routing']['configuration']['proxy']['name'] == 'V3 local qualification'
    os.umask(0o077)
    try:
        t.route('global', 'dual')
        last = proof('global', 'dual')
        check('active-dual-global-baseline', True)
        for present in itertools.product((False, True), repeat=3):
            start = time.monotonic()
            for role, alive in zip(('core', 'supervisor', 'mihomo'), present):
                if not alive: t.run(['/bin/launchctl', 'bootout', 'system/com.mimo.' + role])
            deadline = time.monotonic() + 100
            current = None
            while time.monotonic() < deadline:
                try:
                    current = proof('global', 'dual')
                    if all(present) or current != last: break
                except (AssertionError, ValueError, KeyError, subprocess.TimeoutExpired): pass
                time.sleep(.5)
            check('active-roles-' + ''.join('1' if v else '0' for v in present),
                  current is not None and (all(present) or current != last),
                  recovery_seconds=round(time.monotonic()-start, 3), fresh_attempt=current != last)
            last = current
        for mode, family in [('global','ipv4'), ('global','dual'), ('rule','dual')]:
            t.route(mode, family)
            current = proof(mode, family)
            check('active-change-' + family + '-' + mode, current != last)
            last = current
    finally:
        t.route('direct')
        t.wait_active('direct')
        check('active-final-direct', not t.run(['/sbin/pfctl','-a',t.ANCHOR,'-sr']).stdout.strip())


if __name__ == '__main__': main()
