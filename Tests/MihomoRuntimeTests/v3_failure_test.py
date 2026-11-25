#!/usr/bin/env python3
"""Installed fail-closed recovery on the named VM with an untrusted local TLS fixture.

Does not qualify successful HTTPS approval. Never disables PF globally. All
requests use the already-selected closed lab proxy; original state is restored
separately after the installed campaign.
"""
import itertools
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

ROOT = Path(sys.argv[1])
CONTROLS = ROOT / 'controls'
ANCHOR = 'com.apple/000.mimo'
results = []


def run(args, timeout=15):
    return subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=timeout)


def state():
    return json.loads(run([CONTROLS], 15).stdout)['state']['routing']


def record(name, valid, **data):
    results.append(dict(id=name, passed=bool(valid), **data))
    (ROOT / 'failure-results.json').write_text(json.dumps(results, indent=2))
    print(name + ': ' + ('PASS' if valid else 'FAIL'), flush=True)
    assert valid, name


def request(mode, family='ipv4'):
    cfg = state()['configuration']
    cfg.update(mode=mode, networkFamily=family)
    p = ROOT / 'failure-request.json'
    p.write_text(json.dumps(dict(command='configureRouting', protocolVersion=8, routing=cfg)))
    result = run([CONTROLS, 'request', p], 90)
    assert result.returncode == 0
    assert not json.loads(result.stdout).get('failure')


def rules():
    return run(['/sbin/pfctl', '-a', ANCHOR, '-sr']).stdout


def recover(closed, timeout=100):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            r = state()
            health = {s['id']: s['health'] for s in r['services']}
            ok = all(health.get(k) == 'running' for k in ('core', 'mihomo', 'profileHosting'))
            ok &= r.get('infrastructure', {}).get('launchd') == 'healthy'
            controller = run(['/usr/bin/curl', '--fail', '--silent', '--max-time', '2', '--unix-socket',
                              '/Library/Application Support/Mimo/Mihomo/controller.sock', 'http://localhost/version'], 4)
            ok &= controller.returncode == 0 and '1.19.34-mimo-v3.1' in controller.stdout
            if closed:
                ok &= r['phase'] == 'blocked' and not r.get('effectiveMode')
                ok &= 'block drop out quick all label "mimo:transition:deny"' in rules()
            else:
                ok &= r['phase'] == 'active' and r.get('effectiveMode') == 'direct' and not rules().strip()
            if ok: return True
        except (KeyError, ValueError, subprocess.TimeoutExpired): pass
        time.sleep(.5)
    return False


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert run(['/usr/sbin/sysctl', '-n', 'hw.model']).stdout.startswith('VirtualMac')
    os.umask(0o077)
    cfg = state()['configuration']
    assert cfg['proxy']['name'] == 'V3 local qualification', 'Requires the isolated closed fixture'
    try:
        for family, mode in itertools.product(('ipv4', 'dual'), ('rule', 'global')):
            label = family + '-' + mode
            request(mode, family)
            record(label + '-failed-verification-closed', recover(True))
            record(label + '-public-listeners-blocked', all(run(['/usr/bin/nc', '-G', '2', '-z', '127.0.0.1', str(p)], 4).returncode != 0 for p in (7890, 1053)))
            record(label + '-flat-no-child-grants', 'anchor ' not in rules())
            request('direct')
            record(label + '-direct-restored', recover(False))
        request('rule')
        record('closed-baseline', recover(True))
        for present in itertools.product((False, True), repeat=3):
            start = time.monotonic()
            for role, alive in zip(('core', 'supervisor', 'mihomo'), present):
                if not alive: run(['/bin/launchctl', 'bootout', 'system/com.mimo.' + role])
            record('closed-roles-' + ''.join('1' if v else '0' for v in present), recover(True), recovery_seconds=round(time.monotonic() - start, 3))
        # Remove only Mimo's closed rules; this deliberately creates an observed
        # detection window, not a claim of zero-gap packet protection.
        run(['/sbin/pfctl', '-a', ANCHOR, '-F', 'rules'])
        start = time.monotonic()
        record('closed-parent-restored-after-removal', recover(True), recovery_seconds=round(time.monotonic()-start, 3))
    finally:
        request('direct')
        record('final-direct', recover(False))


if __name__ == '__main__': main()
