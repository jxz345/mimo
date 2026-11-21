#!/usr/bin/env python3
"""Read-only installed-Release lock/unlock observation in mimo-vm.

The human performs the real macOS event. This script never changes modes,
services, saved settings, power state or GUI state. It is not a sleep test.
"""
import hashlib
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from upgrade_test import FLAGS, HELPER, STORAGE, read_settings

BASE = Path(__file__).resolve().parent


def client(*arguments):
    return json.loads(command(BASE / 'acceptance-client', *arguments, timeout=15).stdout)


def check_configuration(root):
    saved = plistlib.loads((root / 'state.plist').read_bytes())
    assert configuration_values(read_settings()) == configuration_values(saved), 'Saved configuration changed'
    assert json.loads(FLAGS.read_bytes()) == json.loads((root / 'services.json').read_bytes()), 'Service intent changed'
    assert command(BASE / 'acceptance-client', 'credential-digest').stdout.strip() == (root / 'credential.digest').read_text(), 'Credential changed'


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    os.umask(0o077)
    if sys.argv[1] == '--prepare':
        root = Path(tempfile.mkdtemp(prefix='mimo-session-', dir='/var/tmp'))
        for src, name in ((STORAGE, 'state.plist'), (FLAGS, 'services.json')):
            shutil.copyfile(src, root / name)
        (root / 'credential.digest').write_text(command(BASE / 'acceptance-client', 'credential-digest').stdout.strip())
        print('Evidence:', root, flush=True)
        print('Saved mode:', json.loads(read_settings()['service.routing'])['mode'], flush=True)
        return
    root = Path(sys.argv[2])
    assert root.parent == Path('/var/tmp') and root.stat().st_uid == 0
    check_configuration(root)
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    app = Path('/Applications/Mimo.app')
    assert (app / 'Contents/MacOS/mimo-core').read_bytes() == HELPER.read_bytes()
    assert hashlib.sha256((app / 'Contents/MacOS/mimo-gui').read_bytes()).hexdigest() == build['guiSHA256']
    command('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    state = client('state')['routing']
    mode = json.loads(read_settings()['service.routing'])['mode']
    assert state['phase'] == 'active' and state['effectiveMode'] == mode, 'Saved mode is not active'
    if sys.argv[1] == '--check':
        print('PASS: installed hashes/signature, original configuration/credential/service intent, active ' + mode, flush=True)
        return
    assert sys.argv[1] == '--observe'
    offsets = {p: p.stat().st_size for p in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl')}
    before_check = state.get('observedIP', {}).get('checkedAt')
    events = []; timeline = []; locks = []; errors = []; passed = []
    deadline = time.monotonic() + 3600
    print('READY: lock and unlock macOS in mimo-vm; current ' + mode + ' is preserved. Evidence: ' + str(root), flush=True)
    try:
        while time.monotonic() < deadline:
            for path in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl'):
                with path.open('rb') as stream:
                    stream.seek(offsets.get(path, 0))
                    for line in stream:
                        try:
                            value = json.loads(line)
                            if value.get('event', '').startswith('mimo_'): events.append(value)
                        except ValueError: pass
                    offsets[path] = stream.tell()
            registry = plistlib.loads(command('/usr/sbin/ioreg', '-a', '-l', '-d', '1').stdout.encode())
            locked = registry.get('IOConsoleLocked')
            if not locks or locks[-1]['locked'] != locked:
                locks.append(dict(at=time.time(), locked=locked))
            routing = client('state')['routing']
            sample = dict(phase=routing.get('phase'), mode=routing.get('effectiveMode'),
                          checkedAt=routing.get('observedIP', {}).get('checkedAt'))
            if not timeline or any(timeline[-1].get(k) != v for k, v in sample.items()):
                timeline.append(dict(at=time.time(), **sample))
            session = [v for v in events if v['event'] == 'mimo_session_changed']
            unlock = next((v for v in session if 'screen_unlocked' in v.get('fields', {}).get('source', '').split(',')), None)
            if unlock and routing.get('phase') == 'active' and sample['checkedAt'] != before_check:
                after = events[events.index(unlock) + 1:]
                if mode == 'direct' or any(v['event'] == 'mimo_traffic_opened' for v in after): break
            time.sleep(.25)
        else: raise AssertionError('No real unlock followed by fresh active verification within the handoff window')
        assert any(v['locked'] is True for v in locks) and locks[-1]['locked'] is False, 'Independent registry did not observe lock then unlock'
        for event in ('screen_locked', 'screen_unlocked'):
            observed = [v for v in session if event in v.get('fields', {}).get('source', '').split(',')]
            assert observed, 'Missing supervisor ' + event
            assert all(v['fields']['action'] == ('direct_refresh' if mode == 'direct' else 'blocked_reverify') for v in observed)
            passed.append(mode + '-' + event + '-observed-and-handled')
        assert not any(v['event'].endswith('guard_failed') for v in events), 'A firewall barrier failed'
        if mode != 'direct':
            after = events[events.index(unlock) + 1:]
            names = [v['event'] for v in after]
            assert names.index('mimo_private_probe_ready') < names.index('mimo_traffic_opened'), 'Open did not follow a fresh private probe'
            assert any(v['phase'] in ('blocked', 'checking') for v in timeline), 'No blocked/checking state observed'
            passed.append('protected-unlock-blocked-checking-fresh-probe-before-open')
        else:
            assert all(v['phase'] == 'active' for v in timeline), 'Direct unexpectedly left active state'
            assert not any(v['event'] == 'mimo_gate_closed' for v in events), 'Direct deliberately closed'
            passed.append('Direct-events-remained-active-with-informational-IP-refresh')
        assert routing['effectiveMode'] == mode
        check_configuration(root)
        passed.append('saved-mode-configuration-credential-and-service-intent-preserved')
    except Exception as exc:
        errors.append(str(exc))
    # Detailed events may contain private IPs: keep them root-only in the VM.
    (root / 'private-events.json').write_text(json.dumps(events, indent=2))
    (root / 'timeline.json').write_text(json.dumps(dict(locks=locks, states=timeline), indent=2))
    timings = []
    for index, event in enumerate(events):
        if event.get('event') != 'mimo_session_changed': continue
        opened = next((v for v in events[index + 1:] if v['event'] == 'mimo_traffic_opened'), None)
        if opened:
            start = datetime.datetime.fromisoformat(event['timestamp'].replace('Z', '+00:00'))
            end = datetime.datetime.fromisoformat(opened['timestamp'].replace('Z', '+00:00'))
            timings.append(dict(source=event['fields'].get('source'), detectedAtUTC=event['timestamp'],
                                openedAtUTC=opened['timestamp'], secondsToOpen=(end-start).total_seconds()))
    report = dict(success=not errors, passed=passed, errors=errors, mode=mode, timings=timings,
                  packageSHA256=build['packageSHA256'], helperSHA256=build['helperSHA256'],
                  readOnlyObserver=True, realSleepTest=False,
                  scope='Human lock/unlock in the installed Release VM; state and ordered event evidence, not continuous packet proof')
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2), flush=True)
    if errors: sys.exit(1)


if __name__ == '__main__': main()
