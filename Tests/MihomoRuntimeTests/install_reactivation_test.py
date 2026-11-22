#!/usr/bin/env python3
"""VM-only installed service restoration; detached with an independent cleanup deadline.
Stage next to installation-check, events-client and installer_conflicts_test.py.
No proxy credentials or public settings are changed. Leave Mimo fully deactivated.
"""
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import time
import uuid
from installer_conflicts_test import terminal

BASE = Path(__file__).resolve().parent
ROOT = Path('/var/root/mimo-install-reactivation')
APP = Path('/Applications/Mimo.app')
SUPPORT = Path('/Library/Application Support/Mimo')
JOBS = ['com.mimo.infrastructure', 'com.mimo.pf-boot', 'com.mimo.core', 'com.mimo.mihomo', 'com.mimo.supervisor']
assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')


def command(*args, check=True, timeout=240):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        (ROOT / 'last-error.log').write_text(result.stdout + result.stderr)
        raise AssertionError('Command failed; see private last-error.log: ' + str(args[0]))
    return result


def daemon(action, name=None):
    for attempt in range(3):
        result = command('/bin/bash', APP / 'Contents/Resources/daemon.sh', action, check=False)
        suffix = '' if attempt == 0 else '-retry-' + str(attempt)
        (ROOT / ((name or action) + suffix)).with_suffix('.log').write_text(result.stdout + result.stderr)
        if result.returncode == 0:
            return
        if action != 'deactivate' or 'Another firewall transition did not finish. Retry shortly.' not in result.stderr:
            break
        time.sleep(2)
    assert result.returncode == 0, 'Installer failed; see private ' + (name or action) + '.log'


def record(text):
    print('PASS: ' + text, flush=True)


def verify():
    command('/Library/PrivilegedHelperTools/mimo-core', '--check-installation', timeout=95)
    assert not (SUPPORT / 'deactivated').exists()
    flags = json.loads((SUPPORT / 'Runtime/services.json').read_text())
    assert all(flags.get(key) is True for key in ['core', 'engine', 'profile']) and not flags.get('releaseNetwork')
    for label in JOBS:
        command('/bin/launchctl', 'print', 'system/' + label)
    events = json.loads(command(BASE / 'events-client').stdout)
    assert any(e['fields']['stage'] == 'succeeded' for e in events)
    return events


def run():
    label = 'org.mimotest.reinstall-conflict.' + uuid.uuid4().hex
    target = 'system/' + label
    success = False
    try:
        assert (SUPPORT / 'deactivated').exists(), 'Start from confirmed full Stop'
        daemon('install', 'inactive-install')
        verify()
        state = json.loads(command(BASE / 'installation-check').stdout)
        assert state['configuration']['mode'] == 'direct'
        record('Install after full Stop restores and verifies all five jobs, engine, provider and controller in Direct')
        for service in ['profileHosting', 'mihomo', 'core']:
            command(BASE / 'installation-check', service, 'stop')
        daemon('install', 'stopped-services-install')
        verify()
        record('Reinstall overrides individual stopped profile/engine/core intent')
        lock = SUPPORT / 'Service/install.lock'
        command('/usr/bin/shlock', '-p', str(os.getpid()), '-f', lock)
        try:
            conflict = command('/bin/bash', APP / 'Contents/Resources/daemon.sh', 'install', check=False)
            assert conflict.returncode != 0 and 'Another service operation is active.' in conflict.stderr
            assert lock.exists(), 'A second account must not remove the first operation lock'
        finally:
            lock.unlink(missing_ok=True)
        verify()
        record('A concurrent installer is rejected without removing the active operation lock or changing services')
        daemon('deactivate', 'before-conflict')
        executable = ROOT / 'mihomo'
        # A system binary copy can fail platform execution checks after relocation.
        subprocess.run(['/usr/bin/clang', '-x', 'c', '-', '-o', str(executable)],
                       input='#include <unistd.h>\nint main(void) { sleep(600); return 0; }\n',
                       text=True, capture_output=True, timeout=30, check=True)
        plist = ROOT / 'conflict.plist'
        plist.write_bytes(plistlib.dumps({'Label': label, 'ProgramArguments': [str(executable), '600'],
                                         'RunAtLoad': True, 'KeepAlive': True}))
        plist.chmod(0o644)
        command('/bin/launchctl', 'bootstrap', 'system', plist)
        time.sleep(0.5)
        assert 'pid = ' in command('/bin/launchctl', 'print', target).stdout, 'Fixture must be running before testing consent'
        args = ['/bin/bash', str(APP / 'Contents/Resources/daemon.sh'), 'install']
        code, _ = terminal(args, 'n', target, ROOT / 'cancel.log')
        assert code == 130
        command('/bin/launchctl', 'print', target)
        assert (SUPPORT / 'deactivated').exists()
        record('Inactive reinstall still checks conflicts; cancellation preserves competitor and inactive state')
        code, _ = terminal(args, 'y', target, ROOT / 'approve.log')
        assert code == 0, 'Approved install failed; private approve.log'
        assert command('/bin/launchctl', 'print', target, check=False).returncode != 0
        events = verify()
        stages = {e['fields']['stage'] for e in events}
        assert {'conflict_detected', 'conflict_cancelled', 'cancelled', 'conflict_approved', 'conflict_disabled',
                'conflicts_cleared', 'services_verified', 'succeeded'} <= stages
        # Same read-only core API from a different OS account, while the root client remains usable.
        other = command('/usr/bin/sudo', '-H', '-u', 'mimotest', BASE / 'events-client')
        assert json.loads(other.stdout) == events
        record('Approved reinstall disables/unloads only the identified KeepAlive competitor; shared core events visible across accounts')
        success = True
    finally:
        command('/bin/launchctl', 'bootout', target, check=False)
        command('/bin/launchctl', 'enable', target, check=False)
        daemon('deactivate', 'final-cleanup')
        (ROOT / 'report.json').write_text(json.dumps({'passed': success, 'scope': 'Installation/reactivation/conflicts/shared event replies; no protected traffic qualification'}, indent=2))
        if success:
            (ROOT / 'passed').touch()
        (ROOT / 'done').touch()


if sys.argv[1:] == ['start']:
    ROOT.mkdir(mode=0o700, exist_ok=True)
    for marker in ['passed', 'done']:
        (ROOT / marker).unlink(missing_ok=True)
    with (ROOT / 'test.log').open('w') as log:
        subprocess.Popen(['/usr/bin/python3', __file__, 'run'], stdout=log, stderr=log, start_new_session=True)
        subprocess.Popen(['/usr/bin/python3', __file__, 'watchdog'], stdout=log, stderr=log, start_new_session=True)
    print('VM installation regression started with cleanup watchdog.')
elif sys.argv[1:] == ['watchdog']:
    for _ in range(720):
        if (ROOT / 'done').exists():
            break
        time.sleep(1)
    else:
        daemon('deactivate', 'watchdog-cleanup')
elif sys.argv[1:] == ['run']:
    run()
else:
    raise SystemExit('Usage: install_reactivation_test.py start|run|watchdog')
