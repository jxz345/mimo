#!/usr/bin/env python3
"""Installed v3 recovery/removal qualification in the named isolated macOS VM."""
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
SUPPORT = Path('/Library/Application Support/Mimo')
ROLES = ('core', 'supervisor', 'mihomo')
checks = []
ROLES_ONLY = '--roles-only' in sys.argv[2:]


def run(args, timeout=15, input=None):
    return subprocess.run([str(v) for v in args], input=input, text=True, capture_output=True, timeout=timeout)


def check(name, valid):
    checks.append({'id': name, 'passed': bool(valid)})
    (ROOT / ('roles-controller-results.json' if ROLES_ONLY else 'lifecycle-results.json')).write_text(json.dumps(checks, indent=2))
    print(name + ': ' + ('PASS' if valid else 'FAIL'), flush=True)
    assert valid, name


def wait_healthy(label):
    end = time.monotonic() + 100
    while time.monotonic() < end:
        try:
            value = run([CONTROLS], 12)
            state = json.loads(value.stdout)['state']['routing']
            health = {v['id']: v['health'] for v in state.get('services', [])}
            ready = state['phase'] == 'active' and state.get('effectiveMode') == 'direct'
            ready &= all(health.get(k) == 'running' for k in ('core', 'mihomo', 'profileHosting'))
            ready &= all(state.get('infrastructure', {}).get(k) == 'healthy' for k in ('pf', 'launchd'))
            ready &= run(['/bin/launchctl', 'print', 'system/com.mimo.supervisor']).returncode == 0
            ready &= not run(['/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr']).stdout.strip()
            controller = run(['/usr/bin/curl', '--fail', '--silent', '--max-time', '2', '--unix-socket',
                              str(SUPPORT / 'Mihomo/controller.sock'), 'http://localhost/version'], 4)
            ready &= controller.returncode == 0 and '1.19.34-mimo-v3.1' in controller.stdout
            if ready:
                check(label, True)
                return
        except (KeyError, ValueError, subprocess.TimeoutExpired):
            pass
        time.sleep(.5)
    check(label, False)


def install(operation):
    result = run(['/bin/bash', '/Applications/Mimo.app/Contents/Resources/daemon.sh', operation,
                  *(['--non-interactive'] if operation == 'install' else [])], 240)
    (ROOT / ('lifecycle-' + operation + '.log')).write_text(result.stdout + result.stderr)
    check(operation + '-completed', result.returncode == 0)


def released(label):
    labels = [f'com.mimo.{r}' for r in (*ROLES, 'pf-boot', 'infrastructure')]
    check(label + '-jobs-absent', all(run(['/bin/launchctl', 'print', 'system/' + v]).returncode == 113 for v in labels))
    check(label + '-owned-resolver-absent', '1053' not in run(['/usr/sbin/scutil', '--dns']).stdout)
    check(label + '-tunnel-absent', run(['/sbin/ifconfig', 'utun239']).returncode != 0)
    for anchor in ('com.apple/000.mimo', 'com.apple/000.mimo/v3-test-legacy'):
        for query in ('-sr', '-sn', '-sT'):
            check(label + '-' + anchor.rsplit('/', 1)[-1] + query,
                  not run(['/sbin/pfctl', '-a', anchor, query]).stdout.strip())
    check(label + '-boot-stanza-absent', 'BEGIN MIMO BOOT GUARD' not in Path('/etc/pf.conf').read_text())
    native = run(['/usr/bin/perl', '/Applications/Mimo.app/Contents/Resources/release-network.pl', '--verify-native'], 25)
    (ROOT / (label + '-native.log')).write_text(native.stdout + native.stderr)
    check(label + '-native-check', native.returncode == 0)


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert run(['/usr/sbin/sysctl', '-n', 'hw.model']).stdout.startswith('VirtualMac')
    os.umask(0o077)
    wait_healthy('baseline-direct')
    for present in itertools.product((False, True), repeat=3):
        for role, alive in zip(ROLES, present):
            if not alive:
                run(['/bin/launchctl', 'bootout', 'system/com.mimo.' + role])
        wait_healthy('roles-' + ''.join('1' if v else '0' for v in present))
    if ROLES_ONLY:
        return
    # Neither stale, unreferenced descendants nor old DNS keys may survive Stop.
    legacy = 'table <mimo_test_legacy> persist { 192.0.2.123 }\nblock drop out quick to 192.0.2.123 label "mimo:test:legacy"\n'
    assert run(['/sbin/pfctl', '-a', 'com.apple/000.mimo/v3-test-legacy', '-f', '-'], input=legacy).returncode == 0
    install('deactivate')
    released('stop')
    check('stop-monitoring-only-marker', (SUPPORT / 'deactivated').is_file())
    install('install')
    wait_healthy('reinstall-restores-all-roles')
    install('uninstall')
    released('uninstall')
    install('install')
    wait_healthy('final-installed-direct')


if __name__ == '__main__':
    main()
