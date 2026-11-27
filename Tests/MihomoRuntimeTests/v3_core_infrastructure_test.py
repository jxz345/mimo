#!/usr/bin/env python3
"""Installed core-guard migration/recovery checks, root in mimo-vm only.

Pass an owner-only evidence directory containing current `controls` and this
file's sibling v3_installed_test.py. Raw state never leaves that private folder.
Stages run separately so the operator can observe progress and reboot the VM.
"""
import collections
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import sys
import time
import v3_installed_test as t

ROOT = Path(sys.argv[1])
SUPPORT = Path('/Library/Application Support/Mimo')
HEALTH = SUPPORT / 'Guard/health.json'
LABEL = 'com.mimo.supervisor'
CORE = Path('/Library/PrivilegedHelperTools/mimo-core')
STAGE = sys.argv[2]
REPORT = ROOT / 'results.json'
checks = json.loads(REPORT.read_text()) if REPORT.exists() else []


def record(name, ok=True, **details):
    checks.append(dict(stage=STAGE, name=name, passed=bool(ok), **details))
    REPORT.write_text(json.dumps(checks, indent=2) + '\n')
    print(('PASS: ' if ok else 'FAIL: ') + name, flush=True)
    assert ok, name


def command(*args, timeout=90):
    p = t.run(list(args), timeout)
    assert p.returncode == 0, 'Command failed: ' + str(args[0]) + '\n' + p.stderr[-700:]
    return p.stdout


def job(label=LABEL):
    return command('/bin/launchctl', 'print', 'system/' + label)


def pid(label=LABEL):
    for line in job(label).splitlines():
        if line.strip().startswith('pid = '):
            return int(line.strip().split(' = ')[1])
    raise AssertionError('Job not running: ' + label)


def wait(check, timeout=80):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (AssertionError, ValueError, OSError):
            pass
        time.sleep(.5)
    raise AssertionError('Timed out waiting for recovery')


def healthy():
    h = json.loads(HEALTH.read_text())
    return h.get('status') == 'healthy' and time.time() - h['checkedAt'] < 20


def migrated():
    p = plistlib.loads(Path('/Library/LaunchDaemons/' + LABEL + '.plist').read_bytes())
    assert p['ProgramArguments'] == [str(CORE), '--supervisor']
    assert p['KeepAlive'] is True and p['ExitTimeOut'] >= 30 and 'StartInterval' not in p
    assert 'program = ' + str(CORE) in job()
    for retired in ('com.mimo.pf-boot', 'com.mimo.infrastructure'):
        assert t.run(['/bin/launchctl', 'print', 'system/' + retired]).returncode == 113
        assert not Path('/Library/LaunchDaemons/' + retired + '.plist').exists()
        assert not (SUPPORT / ('Guard/' + retired + '.plist')).exists()
    assert [p.name for p in Path('/Library/LaunchDaemons').glob('com.mimo.*.plist')] == [LABEL + '.plist']
    assert healthy()


def dashboard_state():
    s = t.state()
    r = s['routing']
    inspection = r['infrastructure']
    assert inspection['pf'] in ('healthy', 'released') and inspection['launchd'] == 'healthy'
    assert time.time() - (inspection['checkedAt'] + 978307200) < 35
    assert {v['id'] for v in r['services']} == {'core', 'mihomo', 'profileHosting'}
    assert all(v['health'] == 'running' and time.time() - (v['checkedAt'] + 978307200) < 15 for v in r['services'])
    return s


def event_rows(since):
    rows = []
    for p in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl'):
        for line in p.read_text(errors='replace').splitlines():
            try:
                r = json.loads(line)
                if datetime.datetime.fromisoformat(r['timestamp'].replace('Z', '+00:00')) >= since:
                    rows.append(r)
            except (ValueError, KeyError, TypeError):
                pass
    return rows


def settled(name, phase, mode):
    time.sleep(2)
    since = datetime.datetime.now(datetime.timezone.utc)
    before = json.loads(HEALTH.read_text())['checkedAt']
    time.sleep(35)
    s = t.state()
    rows = event_rows(since)
    (ROOT / (name + '-events.json')).write_text(json.dumps(rows))
    counts = collections.Counter(r['event'] for r in rows)
    r = s['routing']
    bad = [v for v in rows if v.get('level') in ('error', 'warning')]
    health = json.loads(HEALTH.read_text())
    record(name + '-stable-through-multiple-audits', r['phase'] == phase and
           r['configuration']['mode'] == mode and healthy() and
           json.loads(HEALTH.read_text())['checkedAt'] > before and not bad and
           not any(counts[k] for k in ('lookup_started', 'mimo_gate_closed', 'mimo_network_changed',
                                      'mimo_traffic_opened', 'mimo_network_event_dispatch')),
           event_counts=dict(counts), error_events=[v['event'] for v in bad],
           actual_phase=r['phase'], actual_mode=r['configuration']['mode'],
           health_status=health['status'], health_age_seconds=round(time.time() - health['checkedAt'], 2),
           health_advanced=health['checkedAt'] > before)
    migrated()
    dashboard_state()


def native():
    assert not command('/sbin/pfctl', '-a', t.ANCHOR, '-sr').strip()
    assert '1053' not in command('/usr/sbin/scutil', '--dns')
    assert t.run(['/sbin/ifconfig', 'utun239']).returncode != 0


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert ROOT.stat().st_uid == 0 and ROOT.stat().st_mode & 0o077 == 0
    os.umask(0o077)
    if STAGE == 'installed':
        s = t.state()
        assert s['routing']['configuration']['mode'] == 'direct'
        (ROOT / 'original.json').write_text(json.dumps(s))
        command(str(CORE), '--check-installation', timeout=150)
        migrated()
        record('upgrade-removes-separate-jobs-and-reuses-existing-supervisor', core_sha256=hashlib.sha256(CORE.read_bytes()).hexdigest())
        assert CORE.read_bytes() == Path('/Applications/Mimo.app/Contents/MacOS/mimo-core').read_bytes()
        command('/usr/bin/codesign', '--verify', '--deep', '--strict', '/Applications/Mimo.app')
        record('installed-core-matches-sealed-candidate')
        native()
        settled('initial-Direct', 'active', 'direct')
    elif STAGE == 'recovery':
        for label in (LABEL, 'com.mimo.core'):
            old = pid(label)
            fault_at = time.time()
            os.kill(old, signal.SIGKILL)
            wait(lambda: pid(label) != old and healthy() and json.loads(HEALTH.read_text())['checkedAt'] > fault_at)
            t.wait_active('direct', 90)
            migrated(); dashboard_state()
            record('crashed-' + label + '-recovers-and-updates-dashboard-status')
        old = pid()
        fault_at = time.time()
        command('/bin/launchctl', 'disable', 'system/' + LABEL)
        command('/bin/launchctl', 'bootout', 'system/' + LABEL, timeout=45)
        wait(lambda: pid() != old and healthy() and json.loads(HEALTH.read_text())['checkedAt'] > fault_at)
        t.wait_active('direct', 90)
        record('existing-core-restores-missing-supervisor-without-extra-job')
        native(); dashboard_state()
        settled('recovered-Direct', 'active', 'direct')
    elif STAGE == 'modes' or STAGE in ('modes-rule-ipv4', 'modes-global-ipv4', 'modes-rule-dual', 'modes-global-dual'):
        original = json.loads((ROOT / 'original.json').read_text())
        try:
            for family in ('ipv4', 'dual'):
                for mode in ('rule', 'global'):
                    if STAGE != 'modes' and STAGE != f'modes-{mode}-{family}':
                        continue
                    t.route('direct'); t.wait_active('direct')
                    settings = t.state()['settings']
                    settings['allowlist'] = {'addresses': []}
                    settings['refreshInterval'] = -1
                    t.request('configure', settings=settings)
                    t.route(mode, family)
                    def rejected():
                        s = t.state()
                        # rejectedExit is a Swift computed property, not a wire field.
                        return s if s['routing']['phase'] == 'blocked' and s['routing'].get('blockingIP') else None
                    denied = wait(rejected)
                    record(f'{mode}-{family}-rejection-visible')
                    settled(f'{mode}-{family}-rejected', 'blocked', mode)
                    observed = denied['routing']['observedIP']['address']
                    settings['allowlist'] = {'addresses': [observed]}
                    t.request('configure', settings=settings)
                    t.wait_active(mode, 90)
                    record(f'{mode}-{family}-explicit-allowlist-edit-recovers')
                    settled(f'{mode}-{family}-approved', 'active', mode)
        finally:
            t.route('direct'); t.wait_active('direct', 90)
            t.request('configure', settings=original['settings'])
            t.request('configureRouting', routing=original['routing']['configuration'])
            native()
            record('original-Direct-settings-restored')
    elif STAGE in ('lifecycle', 'lifecycle-stop', 'lifecycle-activate'):
        for action in ('deactivate', 'install'):
            if STAGE == 'lifecycle-stop' and action != 'deactivate': continue
            if STAGE == 'lifecycle-activate' and action != 'install': continue
            args = ['/bin/bash', '/Applications/Mimo.app/Contents/Resources/daemon.sh', action]
            if action == 'install': args.append('--non-interactive')
            p = t.run(args, 180)
            (ROOT / (action + '.log')).write_text(p.stdout + p.stderr)
            record(action + '-completed', p.returncode == 0)
            native()
            if action == 'deactivate':
                for label in (LABEL, 'com.mimo.pf-boot', 'com.mimo.infrastructure', 'com.mimo.core', 'com.mimo.mihomo'):
                    assert t.run(['/bin/launchctl', 'print', 'system/' + label]).returncode == 113
                record('Stop-removes-current-and-legacy-jobs-and-network-controls')
            else:
                t.wait_active('direct', 90); wait(healthy); migrated()
                record('Activate-restores-existing-supervisor-without-extra-job')
        if STAGE != 'lifecycle-stop':
            settled('reactivated-Direct', 'active', 'direct')
    elif STAGE == 'boot-prepare':
        (ROOT / 'previous-boot').write_text(command('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid').strip())
        record('reboot-baseline-saved')
    elif STAGE == 'boot-check':
        boot = command('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid').strip()
        assert boot != (ROOT / 'previous-boot').read_text()
        wait(healthy); t.wait_active('direct', 90); migrated(); native()
        assert (SUPPORT / 'Guard/boot.id').read_text() == boot
        record('real-reboot-runs-existing-supervisor-boot-guard-and-restores-Direct')
        settled('rebooted-Direct', 'active', 'direct')
    elif STAGE == 'final':
        original = json.loads((ROOT / 'original.json').read_text())
        s = t.state()
        record('original-settings-and-routing-retained', s['settings'] == original['settings'] and
               s['routing']['configuration'] == original['routing']['configuration'])
        before = plistlib.loads((ROOT / 'before-state.plist').read_bytes())
        after = plistlib.loads((SUPPORT / 'Service/state.plist').read_bytes())
        keys = ('service.local-ipinfo-token', 'service.local-proxy-passwords')
        record('local-credentials-retained', all(before.get(k) == after.get(k) for k in keys))
        migrated(); native(); dashboard_state()
        record('final-services-healthy-and-Direct-network-controls-released')
        # Full BTM output contains unrelated personal app names. Retain only
        # this job's registration, not other applications' history.
        btm = command('/usr/bin/sfltool', 'dumpbtm')
        blocks = [b for b in btm.split('\n\n') if 'Name: mimo-core' in b]
        record('macOS-registers-one-existing-mimo-core-background-item', len(blocks) == 1 and 'Identifier: 16.com.mimo.supervisor' in blocks[0] and
               all('Executable Path: ' + str(CORE) in b for b in blocks))
        (ROOT / 'btm-infrastructure.txt').write_text('\n\n'.join(blocks))
    else:
        raise AssertionError('Unknown test stage')


if __name__ == '__main__':
    main()
