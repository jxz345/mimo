#!/usr/bin/env python3
"""VM-only installed release/coexistence check. Always restore the prior helper/state.

Stage mimo-core-v2, pf-guard.pl and release-controls beside this script. Raw state
and backups remain root-private; stdout reports checks, not settings or secrets.
"""
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

SUPPORT = Path('/Library/Application Support/Mimo')
RUNTIME = SUPPORT / 'Runtime'
GUARD = SUPPORT / 'Guard/pf-guard.pl'
HELPER = Path('/Library/PrivilegedHelperTools/mimo-core')
STORAGE = SUPPORT / 'Service/state.plist'
FLAGS = RUNTIME / 'services.json'
BASE = Path(__file__).resolve().parent
ANCHOR = 'com.apple/999.mimo-v2-coexist'
JOBS = ['com.mimo.infrastructure', 'com.mimo.supervisor', 'com.mimo.core', 'com.mimo.mihomo']


def command(*args, check=True, input=None, timeout=90):
    return subprocess.run([str(a) for a in args], input=input, text=True, capture_output=True, check=check, timeout=timeout)


def atomic(source, target, mode):
    tmp = target.with_name('.v2-acceptance-replace')
    shutil.copyfile(source, tmp); os.chown(tmp, 0, 0); tmp.chmod(mode); os.replace(tmp, target)


def stop():
    (RUNTIME / 'maintenance').touch(mode=0o600)
    for job in JOBS:
        command('/bin/launchctl', 'bootout', 'system/' + job, check=False)
    time.sleep(1)


def start():
    (RUNTIME / 'maintenance').unlink(missing_ok=True)
    # launchd can retain a just-booted-out Mach service registration briefly.
    # Bound retries; do not replace an already loaded supervisor.
    for _ in range(30):
        result = command('/bin/launchctl', 'bootstrap', 'system', '/Library/LaunchDaemons/com.mimo.supervisor.plist', check=False)
        if result.returncode == 0:
            return
        if command('/bin/launchctl', 'print', 'system/com.mimo.supervisor', check=False).returncode == 0:
            return
        time.sleep(.5)
    result.check_returncode()


def restore(root):
    if (root / 'restored').exists():
        return
    stop()
    for key, path, mode in [('helper', HELPER, 0o755), ('guard', GUARD, 0o644),
                            ('flags', FLAGS, 0o600), ('storage', STORAGE, 0o600)]:
        atomic(root / key, path, mode)
    command('/sbin/pfctl', '-a', ANCHOR, '-F', 'rules', check=False)
    if (root / 'reference').exists():
        command('/sbin/pfctl', '-X', (root / 'reference').read_text(), check=False)
    start()
    (root / 'restored').touch()


def client(*args):
    return json.loads(command(BASE / 'release-controls', *args).stdout)


def ready(mode, released=None):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            state = client('core')['state']['routing']
            if state['phase'] == 'active' and state.get('effectiveMode') == mode and (
                    released is None or state.get('networkReleased', False) == released):
                return state
        except (KeyError, ValueError, subprocess.CalledProcessError):
            pass
        time.sleep(.5)
    raise AssertionError('Timed out waiting for confirmed routing state')


def main():
    assert os.geteuid() == 0 and command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    os.umask(0o077)
    if len(sys.argv) == 3 and sys.argv[1] == '--watch':
        root = Path(sys.argv[2]); time.sleep(420)
        if not (root / 'restored').exists():
            restore(root)
        return
    root = Path(tempfile.mkdtemp(prefix='mimo-v2-release-', dir='/var/root'))
    print('Private recovery directory:', root, flush=True)
    for key, path in [('helper', HELPER), ('guard', GUARD), ('flags', FLAGS), ('storage', STORAGE)]:
        shutil.copyfile(path, root / key)
    shutil.copyfile(__file__, root / 'watch.py')
    # The watchdog executes only restore(), with fixed installation paths.
    watchdog = subprocess.Popen([sys.executable, str(root / 'watch.py'), '--watch', str(root)],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    checks = []
    listener = None
    def record(name):
        checks.append(name); print('PASS:', name, flush=True)
    try:
        # Read the saved mode without requiring the old app's control protocol.
        original = command(HELPER, '--installation-mode').stdout.strip()
        assert original in ('direct', 'rule', 'global')
        stop(); atomic(BASE / 'mimo-core-v2', HELPER, 0o755); atomic(BASE / 'pf-guard.pl', GUARD, 0o644); start()
        ready(original)
        record('Candidate starts with the saved routing mode')
        assert client('mode', 'rule').get('failure') is None
        ready('rule')
        record('Rule is verified before explicit cleanup')
        command('/sbin/pfctl', '-a', ANCHOR, '-f', '-', input='block return out quick inet to 198.51.100.253\n')
        extra = command('/sbin/pfctl', '-E')
        token = re.search(r'Token\s*:\s*(\d+)', extra.stdout + extra.stderr).group(1)
        (root / 'reference').write_text(token)
        # Disconnect only the owned controller endpoint. Stop must not depend on it.
        (SUPPORT / 'Mihomo/controller.sock').unlink()
        result = client('mihomo', 'stop')
        (root / 'stop.json').write_text(json.dumps(result))
        assert result.get('failure') is None, result.get('routing', {}).get('reason')
        released = ready('direct', True)
        assert command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout.strip() == ''
        assert 'No such key' in command('/usr/sbin/scutil', input='show State:/Network/Service/com.mimo.dns/DNS\n').stdout
        assert command('/sbin/ifconfig', 'utun239', check=False).returncode != 0
        assert command('/bin/launchctl', 'print', 'system/com.mimo.mihomo', check=False).returncode != 0
        assert not (RUNTIME / 'ipv6-original.plist').exists()
        assert not (SUPPORT / 'Mihomo/controller.sock').exists()
        assert {s['id']: s['health'] for s in released['services']} == {
            'core': 'running', 'mihomo': 'stopped', 'profileHosting': 'suspended', 'tailnetProvider': 'suspended'}
        record('Stop works without a controller; TUN, DNS, engine, IPv6 ownership and service states are released')
        assert '198.51.100.253' in command('/sbin/pfctl', '-a', ANCHOR, '-sr').stdout
        assert re.search(r'\s' + token + r'\s', command('/sbin/pfctl', '-s', 'References').stdout)
        record('Another PF anchor and enable reference survive cleanup')
        listener = socket.socket(); listener.bind(('127.0.0.1', 7890)); listener.listen()
        for port in [1053, 18766]:
            with socket.socket() as available: available.bind(('127.0.0.1', port))
        assert client('bypass').get('failure') is None
        ready('direct', True)
        record('Bypass edits while released do not start the engine or reclaim listeners')
        conflict = client('mihomo', 'start')
        assert conflict.get('failure') and conflict['routing']['networkReleased']
        assert '7890' in conflict['routing']['reason']
        assert command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout.strip() == ''
        record('Occupied-port conflict keeps Direct networking released with an actionable error')
        for op in ['--configure', '--boot', '--check']:
            command('/usr/bin/perl', GUARD, op)
        assert command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout.strip() == ''
        assert '# BEGIN MIMO BOOT GUARD' not in Path('/etc/pf.conf').read_text()
        assert json.loads((SUPPORT / 'Guard/health.json').read_text())['pf'] == 'released'
        record('Independent configure, boot and health checks honor released intent')
        stop(); start(); ready('direct', True)
        record('Core and supervisor restart preserves released intent while another listener is active')
        listener.close(); listener = None
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.bind(('127.0.0.1', 1053))
            conflict = client('mihomo', 'start')
            assert conflict.get('failure') and conflict['routing']['networkReleased']
            assert 'UDP port 1053' in conflict['routing']['reason']
            assert command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout.strip() == ''
        record('UDP DNS conflict also leaves networking released')
        assert client('mihomo', 'start').get('failure') is None
        ready('direct', False)
        record('Explicit Start restores ordinary Direct and resumes managed services')
        assert client('mode', 'rule').get('failure') is None
        ready('rule', False)
        rules = json.loads(command('/usr/bin/curl', '--fail', '--silent', '--unix-socket', SUPPORT / 'Mihomo/controller.sock', 'http://localhost/rules').stdout)['rules']
        assert any(r.get('payload') == 'v2-fixture.invalid' and r.get('proxy') == 'DIRECT' for r in rules)
        assert any(r.get('payload') == 'ts.net' and r.get('proxy') == 'TS-DIRECT' for r in rules)
        record('Rule activation loads saved bypass edits while retaining MagicDNS rules')
        assert client('mihomo', 'stop').get('failure') is None
        ready('direct', True)
        assert client('mode', 'rule').get('failure') is None
        ready('rule', False)
        record('Selecting Rule explicitly starts a released engine and verifies before opening')
    finally:
        if listener: listener.close()
        restore(root)
        watchdog.terminate()
        (root / 'evidence.json').write_text(json.dumps({'checks': checks, 'restored': True}, indent=2))
        print('RESTORED: original helper, guard, settings and service intent.', flush=True)


if __name__ == '__main__':
    main()
