#!/usr/bin/env python3
"""Root-only VM fault campaign; private raw logs, sanitized summary only for export."""
import collections
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import sys
import time
import v3_installed_test as t

ROOT = Path(sys.argv[1])
STAGE = sys.argv[2]
SUPPORT = Path('/Library/Application Support/Mimo')
RUNTIME = SUPPORT / 'Runtime'
REPORT = ROOT / 'peer-results.json'
checks = json.loads(REPORT.read_text()) if REPORT.exists() else []
FORBIDDEN = {'lookup_started', 'mimo_gate_closed', 'mimo_network_changed', 'mimo_traffic_opened',
             'mimo_network_event_dispatch', 'mimo_command_rejected', 'mimo_peer_repair_started',
             'mimo_core_command_failed', 'mimo_peer_recovery_wait'}


def record(name, ok, **details):
    checks.append(dict(stage=STAGE, name=name, passed=bool(ok), **details))
    REPORT.write_text(json.dumps(checks, indent=2) + '\n')
    print(('PASS: ' if ok else 'FAIL: ') + name, flush=True)
    assert ok, name


def job(role):
    label = 'com.mimo.supervisor' if role == 'supervisor' else 'com.mimo.core'
    p = t.run(['/bin/launchctl', 'print', 'system/' + label], 5)
    if p.returncode == 113: return None
    assert p.returncode == 0, p.stderr[-200:]
    return next((int(v.strip()[6:]) for v in p.stdout.splitlines() if v.strip().startswith('pid = ')), None)


def wait(check, timeout=180):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            value = check()
            if value: return value
        except (AssertionError, ValueError, OSError, subprocess.TimeoutExpired): pass
        time.sleep(1)
    raise AssertionError('Recovery deadline exceeded')


def events(since):
    rows = []
    files = list(Path('/Library/Logs/Mimo').glob('runtime-*.jsonl'))
    files += list(Path('/Users').glob('*/Library/Application Support/Mimo/Logs/runtime-*.jsonl'))
    for p in files:
        for line in p.read_text(errors='replace').splitlines():
            try:
                r = json.loads(line)
                if datetime.datetime.fromisoformat(r['timestamp'].replace('Z', '+00:00')) >= since:
                    rows.append(r)
            except (ValueError, KeyError, TypeError): pass
    return rows


def healthy(snapshot=None):
    s = snapshot or t.state()
    r = s['routing']
    h = r.get('infrastructure') or {}
    return s if r.get('heartbeatHealth') == 'healthy' and h.get('launchd') == 'healthy' and \
        h.get('pf') in ('healthy', 'released') and time.time() - (h.get('checkedAt', 0) + 978307200) <= 35 else None


def audit(name, mode='direct', phase='active'):
    wait(healthy)
    time.sleep(5)
    since = datetime.datetime.now(datetime.timezone.utc)
    initial = {role: json.loads((RUNTIME / (role + '.progress.json')).read_text())['sequence'] for role in ('supervisor', 'heartbeat')}
    epochs = set()
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        if phase == 'blocked':
            epochs.add((RUNTIME / 'pf-mutation.epoch').read_text())
        time.sleep(.2)
    observed = t.state()
    s = healthy(observed)
    rows = events(since)
    (ROOT / (name + '-events.json')).write_text(json.dumps(rows))
    counts = collections.Counter(r['event'] for r in rows)
    bad = [r['event'] for r in rows if r.get('level') in ('error', 'warning') or r['event'] in FORBIDDEN]
    epoch_changes = max(0, len(epochs) - 1)
    # Two boundary writes can straddle the event collection window. Repeated
    # no-op checks must not continually invalidate the independent PF scan.
    if phase == 'blocked' and epoch_changes > counts['mimo_blocked_native_transport_updated'] + 2:
        bad.append('unexplained_firewall_epoch_churn')
    advanced = all(json.loads((RUNTIME / (role + '.progress.json')).read_text())['sequence'] > initial[role] for role in initial)
    record(name, bool(s) and s['routing']['phase'] == phase and s['routing']['configuration']['mode'] == mode and advanced and not bad,
           event_counts=dict(counts), unexpected_events=bad, progress_advanced=advanced,
           current_health=bool(s), expected_phase=phase, expected_mode=mode,
           observed_phase=observed['routing']['phase'],
           firewall_epoch_changes=epoch_changes,
           infrastructure=observed['routing'].get('infrastructure'),
           heartbeat_health=observed['routing'].get('heartbeatHealth'))


def native():
    assert not t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr']).stdout.strip()
    assert '1053' not in t.run(['/usr/sbin/scutil', '--dns']).stdout
    assert t.run(['/sbin/ifconfig', 'utun239']).returncode != 0


def named_items():
    import re
    expected = {'com.mimo.supervisor': 'mimo-core-supervisor', 'com.mimo.core': 'mimo-core-heartbeat', 'com.mimo.mihomo': 'mihomo'}
    btm = t.run(['/usr/bin/sfltool', 'dumpbtm'], 20).stdout
    items = []
    for block in btm.split('\n\n'):
        if not re.search(r'Identifier: 16\.com\.mimo\.', block): continue
        item = {key: next((line.split(':', 1)[1].strip() for line in block.splitlines() if line.strip().startswith(key + ':')), '')
                for key in ('Name', 'Identifier', 'Executable Path', 'URL')}
        items.append(item)
    good = len(items) == 3
    utility = hashlib.sha256(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).hexdigest()
    for label, name in expected.items():
        executable = str(SUPPORT / 'LaunchHelpers' / name)
        plist = Path('/Library/LaunchDaemons') / (label + '.plist')
        good = good and any(i['Identifier'] == '16.' + label and i['Name'] == name and i['Executable Path'] == executable for i in items)
        good = good and plistlib.loads(plist.read_bytes())['ProgramArguments'][0] == executable
        good = good and hashlib.sha256(Path(executable).read_bytes()).hexdigest() == utility
        good = good and t.run(['/usr/bin/codesign', '--verify', '--strict', executable], 10).returncode == 0
    good = good and not any((SUPPORT / 'LaunchDaemons' / (label + '.plist')).exists() for label in expected)
    record('three-named-registered-jobs-signed-role-paths-no-old-plists', good, items=items)


def engine_service(operation):
    p = t.run([str(ROOT / 'service-control'), 'mihomo', operation], 70)
    assert p.returncode == 0 and not json.loads(p.stdout).get('failure'), p.stderr[-200:]


def engine_status():
    return next(v for v in t.state()['routing']['services'] if v['id'] == 'mihomo')


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert ROOT.stat().st_uid == 0 and ROOT.stat().st_mode & 0o077 == 0
    os.umask(0o077)
    (ROOT / (STAGE + '.started')).write_text(str(time.time()))
    if STAGE == 'installed':
        s = wait(healthy)
        (ROOT / 'peer-original.json').write_text(json.dumps(s))
        supervisor = plistlib.loads(Path('/Library/LaunchDaemons/com.mimo.supervisor.plist').read_bytes())
        heartbeat = plistlib.loads(Path('/Library/LaunchDaemons/com.mimo.core.plist').read_bytes())
        record('two-existing-core-roles-and-correct-API-owner', supervisor['ProgramArguments'][1:] == ['--supervisor'] and
               heartbeat['ProgramArguments'][1:] == ['--heartbeat'] and 'com.mimo.core' in supervisor['MachServices'] and
               'com.mimo.core' not in heartbeat['MachServices'] and job('supervisor') != job('heartbeat'))
        record('retired-jobs-absent', all(t.run(['/bin/launchctl','print','system/'+v]).returncode == 113
               for v in ('com.mimo.pf-boot', 'com.mimo.infrastructure')))
        named_items()
        p = t.run(['/Library/PrivilegedHelperTools/mimo-manage', 'status'], 30)
        record('maintenance-status-inspects-all-three-jobs', p.returncode == 0 and all('system/' + label + ' = {' in p.stdout for label in ('com.mimo.supervisor','com.mimo.core','com.mimo.mihomo')))
        native()
        audit('installed-Direct-quiet')
    elif STAGE == 'ui-audit':
        since = datetime.datetime.fromtimestamp(float((ROOT / 'ui.started').read_text()), datetime.timezone.utc)
        rows = events(since)
        bad = [r['event'] for r in rows if r.get('level') in ('error','warning') or r['event'] in FORBIDDEN]
        record('native-dashboard-maintenance-navigation-no-network-side-effects', not bad,
               event_counts=dict(collections.Counter(r['event'] for r in rows)), unexpected_events=bad)
        audit('native-UI-settled')
    elif STAGE == 'controller-health':
        before = {role: job(role) for role in ('supervisor','heartbeat')}
        text = t.run(['/bin/launchctl','print','system/com.mimo.mihomo']).stdout
        pid = next(int(v.strip()[6:]) for v in text.splitlines() if v.strip().startswith('pid = '))
        since = datetime.datetime.now(datetime.timezone.utc)
        os.kill(pid, signal.SIGSTOP)
        try:
            wait(lambda: engine_status()['health'] == 'unavailable', 40)
            s = t.state()
            record('running-but-hung-engine-and-profile-not-healthy',
                   all(v['health'] == 'unavailable' for v in s['routing']['services'] if v['id'] in ('mihomo','profileHosting')))
            audit('hung-engine-Direct-control-responsive')
        finally: os.kill(pid, signal.SIGCONT)
        wait(lambda: engine_status()['health'] == 'running', 35)
        record('controller-health-recovers-without-peer-restart', before == {role:job(role) for role in before})
        audit('controller-resumed-Direct-quiet')
    elif STAGE == 'engine-stop-before-boot':
        engine_service('stop')
        wait(lambda: engine_status()['health'] == 'stopped')
        disabled = t.run(['/bin/launchctl','print-disabled','system']).stdout
        record('engine-Stop-disables-boot-job-and-keeps-peers', '"com.mimo.mihomo" => disabled' in disabled or '"com.mimo.mihomo" => true' in disabled)
        native(); audit('engine-stopped-before-reboot')
        (ROOT / 'previous-boot').write_text(t.run(['/usr/sbin/sysctl','-n','kern.bootsessionuuid']).stdout.strip())
    elif STAGE == 'engine-stop-after-boot':
        wait(healthy); t.wait_active('direct', 120); native()
        boot = t.run(['/usr/sbin/sysctl','-n','kern.bootsessionuuid']).stdout.strip()
        record('engine-stays-stopped-across-real-reboot', boot != (ROOT / 'previous-boot').read_text() and
               engine_status()['health'] == 'stopped' and t.run(['/bin/launchctl','print','system/com.mimo.mihomo']).returncode == 113)
        audit('engine-stopped-after-reboot')
        engine_service('start')
        wait(lambda: engine_status()['health'] == 'running', 60)
        record('engine-Start-restores-controller-and-profile-health', all(v['health'] == 'running' for v in t.state()['routing']['services']))
        named_items(); audit('engine-started-after-reboot')
    elif STAGE.startswith('fault-'):
        parts = STAGE.split('-')
        _, role, fault = parts[:3]
        protected = len(parts) == 4
        expected = 'global' if protected else 'direct'
        original = json.loads((ROOT / 'peer-original.json').read_text())
        if protected:
            t.route('global', 'dual')
            ready = wait(lambda: (s if (s := t.state())['routing']['phase'] == 'active' or s['routing'].get('blockingIP') else None))
            if ready['routing']['phase'] != 'active':
                settings = ready['settings']; settings['allowlist'] = {'addresses':[ready['routing']['observedIP']['address']]}
                t.request('configure', settings=settings)
            t.wait_active('global', 120)
        old, other = job(role), job('heartbeat' if role == 'supervisor' else 'supervisor')
        assert old
        since = datetime.datetime.now(datetime.timezone.utc)
        started = time.monotonic()
        try:
            if fault == 'remove':
                label = 'com.mimo.supervisor' if role == 'supervisor' else 'com.mimo.core'
                assert t.run(['/bin/launchctl', 'disable', 'system/' + label]).returncode == 0
                assert t.run(['/bin/launchctl', 'bootout', 'system/' + label], 45).returncode == 0
            else: os.kill(old, signal.SIGSTOP if fault == 'hang' else signal.SIGKILL)
            wait(lambda: job(role) not in (old, None) and healthy())
            t.wait_active(expected, 120)
            rows = events(since)
            (ROOT / (STAGE + '-events.json')).write_text(json.dumps(rows))
            repairs = [r for r in rows if r['event'] == 'mimo_peer_repair_started']
            record(role + '-' + fault + '-recovered', job(role) != old and job('heartbeat' if role == 'supervisor' else 'supervisor') == other,
                   duration_seconds=round(time.monotonic()-started, 2), repair_attempts=len(repairs),
                   event_counts=dict(collections.Counter(r['event'] for r in rows)))
            if role == 'heartbeat':
                record('heartbeat-repair-does-not-trigger-verification-or-gate-cycle', not any(r['event'] in FORBIDDEN - {'mimo_peer_repair_started', 'mimo_peer_recovery_wait'} for r in rows))
            if not protected: native()
            audit(STAGE + '-settled', expected)
        finally:
            try: os.kill(old, signal.SIGCONT)
            except ProcessLookupError: pass
            if protected:
                t.route('direct'); t.wait_active('direct', 120)
                t.request('configure', settings=original['settings'])
                t.request('configureRouting', routing=original['routing']['configuration'])
                native()
    elif STAGE.startswith('mode-'):
        _, mode, family = STAGE.split('-')
        original = json.loads((ROOT / 'peer-original.json').read_text())
        try:
            t.route('direct'); t.wait_active('direct')
            settings = t.state()['settings']; settings['allowlist'] = {'addresses': []}; settings['refreshInterval'] = -1
            t.request('configure', settings=settings)
            pids = [job(role) for role in ('supervisor','heartbeat')]
            t.route(mode, family)
            denied = wait(lambda: (s if (s := t.state())['routing']['phase'] == 'blocked' and s['routing'].get('blockingIP') and 'ready' in s['status'] else None))
            record(STAGE + '-rejected-IP-visible', bool(denied['routing']['blockingIP']))
            (ROOT / (STAGE + '-denied-state.json')).write_text(json.dumps(denied))
            record(STAGE + '-denial-does-not-pause-health', 'ready' in denied['status'] and
                   all(v['health'] == 'running' for v in denied['routing']['services']),
                   monitoring_status=list(denied['status']), service_health={v['id']:v['health'] for v in denied['routing']['services']})
            previous = denied['snapshot']['checkedAt']
            t.request('refresh')
            refreshed = wait(lambda: (s if (s := t.state())['routing']['phase'] == 'blocked' and 'ready' in s['status'] and
                                      s.get('snapshot',{}).get('checkedAt',0) > previous else None))
            record(STAGE + '-blocked-manual-refresh-completes', bool(refreshed['routing'].get('blockingIP')))
            audit(STAGE + '-rejected-settled', mode, 'blocked')
            settings['allowlist'] = {'addresses': [denied['routing']['observedIP']['address']]}
            t.request('configure', settings=settings); t.wait_active(mode, 120)
            record(STAGE + '-explicit-recovery-without-peer-restart', [job(role) for role in ('supervisor','heartbeat')] == pids)
            audit(STAGE + '-approved-settled', mode)
        finally:
            t.route('direct'); t.wait_active('direct', 120)
            t.request('configure', settings=original['settings'])
            t.request('configureRouting', routing=original['routing']['configuration'])
            native()
    elif STAGE.startswith('infrastructure-'):
        fault = STAGE.removeprefix('infrastructure-')
        original = json.loads((ROOT / 'peer-original.json').read_text())
        try:
            t.route('global', 'dual')
            ready = wait(lambda: (s if (s := t.state())['routing']['phase'] == 'active' or s['routing'].get('blockingIP') else None))
            if ready['routing']['phase'] != 'active':
                settings = ready['settings']; settings['allowlist'] = {'addresses':[ready['routing']['observedIP']['address']]}
                t.request('configure', settings=settings)
            t.wait_active('global', 120)
            wait(healthy)
            peers = [job(role) for role in ('supervisor','heartbeat')]
            since = datetime.datetime.now(datetime.timezone.utc)
            if fault == 'engine':
                def engine_pid():
                    p = t.run(['/bin/launchctl','print','system/com.mimo.mihomo'],5)
                    return next((int(v.strip()[6:]) for v in p.stdout.splitlines() if v.strip().startswith('pid = ')),None)
                old = engine_pid(); assert old
                os.kill(old,signal.SIGKILL)
                wait(lambda: engine_pid() not in (None,old))
            elif fault == 'dns':
                p = subprocess.run(['/usr/sbin/scutil'], input='remove State:/Network/Service/com.mimo.dns/DNS\nquit\n',capture_output=True,text=True,timeout=5)
                assert p.returncode == 0
            elif fault == 'pf':
                p = t.run(['/Library/PrivilegedHelperTools/mimo-core','--print-startup-firewall'],5)
                assert p.returncode == 0
                policy = ROOT / 'fault-closed.pf'; policy.write_text(p.stdout)
                assert t.run(['/sbin/pfctl','-a',t.ANCHOR,'-f',str(policy)],5).returncode == 0
            else: raise ValueError(fault)
            # Observe the actual repair, not a cached active snapshot immediately after injection.
            wait(lambda: any(row['event'] == 'mimo_traffic_opened' for row in events(since)), 180)
            t.wait_active('global', 120); wait(healthy)
            rows = events(since)
            (ROOT / (STAGE + '-events.json')).write_text(json.dumps(rows))
            record(STAGE + '-repaired-by-supervisor-without-peer-restart', peers == [job(role) for role in ('supervisor','heartbeat')],
                   event_counts=dict(collections.Counter(v['event'] for v in rows)))
            audit(STAGE + '-settled','global')
        finally:
            t.route('direct'); t.wait_active('direct',120)
            t.request('configure',settings=original['settings'])
            t.request('configureRouting',routing=original['routing']['configuration'])
            native()
    elif STAGE == 'monitor':
        initial = {role: job(role) for role in ('supervisor','heartbeat')}
        def service(operation):
            p = t.run([str(ROOT / 'service-control'), 'core', operation], 50)
            assert p.returncode == 0 and not json.loads(p.stdout).get('failure')
        try:
            service('stop')
            wait(lambda: any(v['id'] == 'core' and v['health'] == 'stopped' for v in t.state()['routing']['services']))
            record('IP-monitor-stop-preserves-both-peers', all(job(role) == initial[role] for role in initial))
            p = t.run(['/Library/PrivilegedHelperTools/mimo-core', '--recover-direct'], 90)
            record('CLI-Direct-recovery-with-monitor-stopped', p.returncode == 0 and
                   any(v['id'] == 'core' and v['health'] == 'stopped' for v in t.state()['routing']['services']))
            audit('monitor-stopped-Direct-quiet')
        finally: service('start')
        wait(lambda: any(v['id'] == 'core' and v['health'] == 'running' for v in t.state()['routing']['services']))
        record('IP-monitor-start-preserves-both-peers', all(job(role) == initial[role] for role in initial))
        audit('monitor-started-Direct-quiet')
    elif STAGE in ('lifecycle-stop', 'lifecycle-activate', 'uninstall', 'reinstall'):
        action = {'lifecycle-stop':'deactivate', 'lifecycle-activate':'install', 'uninstall':'uninstall', 'reinstall':'install'}[STAGE]
        args = ['/bin/bash', '/Applications/Mimo.app/Contents/Resources/daemon.sh', action]
        if action == 'install': args += ['--non-interactive']
        p = t.run(args, 240)
        (ROOT / (STAGE + '-operation.log')).write_text(p.stdout + p.stderr)
        record(STAGE + '-completed', p.returncode == 0)
        native()
        if action != 'install':
            time.sleep(50)
            record(STAGE + '-no-resurrection', all(t.run(['/bin/launchctl','print','system/'+v]).returncode == 113
                   for v in ('com.mimo.supervisor','com.mimo.core','com.mimo.mihomo','com.mimo.pf-boot','com.mimo.infrastructure')))
            native()
            record(STAGE + '-named-helpers-and-system-plists-removed', not (SUPPORT / 'LaunchHelpers').exists() and all(not Path('/Library/LaunchDaemons', label + '.plist').exists() for label in ('com.mimo.supervisor','com.mimo.core','com.mimo.mihomo')))
        else:
            wait(healthy); t.wait_active('direct', 120); audit(STAGE + '-settled')
    elif STAGE == 'boot-before':
        t.wait_active('direct', 120)
        native()
        boot = t.run(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid']).stdout.strip()
        assert boot
        (ROOT / 'previous-boot').write_text(boot)
    elif STAGE == 'boot-after':
        boot = t.run(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid']).stdout.strip()
        wait(healthy); t.wait_active('direct', 120); native()
        record('real-reboot-starts-existing-supervisor-and-both-progress-owners',
               boot != (ROOT / 'previous-boot').read_text() and
               (SUPPORT / 'Guard/boot.id').read_text() == boot and
               all(json.loads((RUNTIME / (role + '.progress.json')).read_text())['boot'] == boot for role in ('supervisor', 'heartbeat')))
        audit('rebooted-Direct-quiet')
    elif STAGE == 'final':
        original = json.loads((ROOT / 'peer-original.json').read_text())
        state = wait(healthy)
        native()
        record('original-settings-retained', state['settings'] == original['settings'] and state['routing']['configuration'] == original['routing']['configuration'])
        private = plistlib.loads((SUPPORT / 'Service/state.plist').read_bytes())
        credentials = {k: private[k] for k in ('service.local-ipinfo-token', 'service.local-proxy-passwords') if k in private}
        record('local-credentials-retained-across-lifecycle', hashlib.sha256(plistlib.dumps(credentials, sort_keys=True)).hexdigest() ==
               (ROOT / 'credential-fingerprint-before').read_text())
        btm = t.run(['/usr/bin/sfltool','dumpbtm'], 20).stdout
        blocks = [b for b in btm.split('\n\n') if 'Name: mimo-core' in b]
        named_items()
        record('dashboard-health-current', all(v['health'] == 'running' and time.time() - (v['checkedAt'] + 978307200) < 20 for v in state['routing']['services']))
        for stage in ('lifecycle-stop', 'lifecycle-activate', 'uninstall', 'reinstall'):
            start = ROOT / (stage + '.started')
            began = float(start.read_text()) if start.exists() else (ROOT / (stage + '.log')).stat().st_birthtime
            ended = (ROOT / (stage + '.finished')).stat().st_mtime
            rows = [v for v in events(datetime.datetime.fromtimestamp(began, datetime.timezone.utc))
                    if datetime.datetime.fromisoformat(v['timestamp'].replace('Z', '+00:00')).timestamp() <= ended]
            counts = collections.Counter(v['event'] for v in rows)
            failures = [v for v in rows if v['event'] == 'lookup_failed']
            pauses = [v for v in rows if v['event'] == 'provider_failure_paused']
            rotations = [v for v in rows if v['event'] == 'provider_rotated_after_failure']
            successes = [v for v in rows if v['event'] == 'lookup_succeeded']
            # A live rate limit occurred during the installed activation test.
            # Qualify the exact bounded failover, never suppress arbitrary errors
            # or relax the subsequent 35-second quiet-window assertions.
            recovered_rate_limit = (len(failures) == len(pauses) == len(rotations) == len(successes) == 1 and
                failures[0]['fields'].get('category') == 'rate_limited' and
                pauses[0]['fields'].get('reason') == 'rate_limited' and
                rotations[0]['fields'].get('from') == failures[0]['fields'].get('provider') and
                rotations[0]['fields'].get('to') == successes[0]['fields'].get('provider') and
                failures[0]['timestamp'] < rotations[0]['timestamp'] < successes[0]['timestamp'] and
                counts['lookup_started'] == counts['lookup_finished'] == 2 and counts['indicator_error_set'] == 1)
            expected = {'lookup_failed', 'indicator_error_set'} if recovered_rate_limit else set()
            unexpected = [v['event'] for v in rows if (v.get('level') in ('warning', 'error') and v['event'] not in expected) or v['event'] == 'mimo_peer_repair_started']
            (ROOT / (stage + '-events.json')).write_text(json.dumps(rows))
            record(stage + '-maintenance-log-clean', not unexpected,
                   event_counts=dict(counts), unexpected_events=unexpected, bounded_rate_limit_failover=recovered_rate_limit)
        audit('final-Direct-quiet')
    else: raise ValueError(STAGE)


if __name__ == '__main__':
    try: main()
    finally: (ROOT / (STAGE + '.finished')).write_text('finished')
