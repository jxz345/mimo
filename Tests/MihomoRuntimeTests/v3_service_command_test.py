#!/usr/bin/env python3
"""Installed VM command audit. Raw state/logs stay in a root-only directory.

This invokes production RPCs, including the GUI's subsequent Refresh request.
It does not claim native clicks or simultaneous logged-in GUI-account coverage.
"""
import collections
import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
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
REPORT = ROOT / 'command-results.json'
checks = json.loads(REPORT.read_text()) if REPORT.exists() else []
FORBIDDEN = {'lookup_started', 'mimo_gate_closed', 'mimo_network_changed',
             'mimo_traffic_opened', 'mimo_network_event_dispatch',
             'mimo_command_rejected', 'mimo_peer_repair_started',
             'mimo_core_command_failed', 'mimo_peer_recovery_wait'}


def record(name, passed, **details):
    checks.append(dict(stage=STAGE, name=name, passed=bool(passed), **details))
    REPORT.write_text(json.dumps(checks, indent=2) + '\n')
    print(('PASS: ' if passed else 'FAIL: ') + name, flush=True)
    return bool(passed)


def wait(predicate, timeout=90):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            value = predicate()
            if value:
                return value
        except (AssertionError, ValueError, OSError, subprocess.TimeoutExpired):
            pass
        time.sleep(.5)
    raise AssertionError('terminal-state deadline exceeded')


def job(label):
    p = t.run(['/bin/launchctl', 'print', 'system/' + label], 8)
    match = re.search(r'^\s*pid = (\d+)', p.stdout, re.M)
    return int(match[1]) if p.returncode == 0 and match else None


def peers():
    return [job('com.mimo.supervisor'), job('com.mimo.core')]


def logfiles():
    return list(Path('/Library/Logs/Mimo').glob('runtime-*.jsonl')) + list(
        Path('/Users').glob('*/Library/Application Support/Mimo/Logs/runtime-*.jsonl'))


def cursor():
    result = {}
    for path in logfiles():
        try:
            info = path.stat()
        except FileNotFoundError:
            continue  # Retention can remove an old segment after listing.
        result[str(path)] = (info.st_ino, info.st_size)
    return result


def events(offsets):
    result = []
    for p in logfiles():
        inode, size = offsets.get(str(p), (0, 0))
        try:
            opened = p.open()
        except FileNotFoundError:
            continue  # Whole-case coverage independently rejects lost required segments.
        with opened as stream:
            info = os.fstat(stream.fileno())
            if info.st_ino == inode and info.st_size >= size:
                stream.seek(size)
            for line in stream:
                try:
                    result.append(json.loads(line))
                except ValueError:
                    pass
    return result


def evidence(name, offsets):
    rows = events(offsets)
    (ROOT / (name + '-events.json')).write_text(json.dumps(rows))
    return rows, dict(collections.Counter(r['event'] for r in rows))


def service_health(s):
    return {v['id']: v['health'] for v in s['routing']['services']}


def healthy(s):
    r = s['routing']
    infra = r.get('infrastructure') or {}
    return r.get('heartbeatHealth') == 'healthy' and infra.get('launchd') == 'healthy' and \
        infra.get('pf') in ('healthy', 'released') and \
        time.time() - (infra.get('checkedAt', 0) + 978307200) < 35


def terminal(mode, phase, monitor='running'):
    s = t.state()
    h = service_health(s)
    r = s['routing']
    return s if r['configuration']['mode'] == mode and r['phase'] == phase and \
        h.get('core') == monitor and h.get('mihomo') == 'running' and \
        h.get('profileHosting') == 'running' and healthy(s) and \
        (phase != 'blocked' or monitor == 'stopped' or
         (r.get('blockingIP') and 'ready' in s['status'])) else None


def native():
    gate = (RUNTIME / 'gate.state').read_text().strip()
    expected = t.inbound_direct_rules() if gate == 'direct' else ''
    return gate in ('direct', 'released') and t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr'], 10).stdout == expected and \
        '1053' not in t.run(['/usr/sbin/scutil', '--dns'], 10).stdout and \
        t.run(['/sbin/ifconfig', 'utun239'], 10).returncode != 0


def audit(name, mode, phase, monitor='running'):
    wait(lambda: terminal(mode, phase, monitor))
    time.sleep(3)
    offsets = cursor()
    initial = [json.loads((RUNTIME / (r + '.progress.json')).read_text())['sequence']
               for r in ('supervisor', 'heartbeat')]
    deadline = time.monotonic() + 35
    max_latency = 0
    while time.monotonic() < deadline:
        start = time.monotonic()
        s = t.state()
        max_latency = max(max_latency, time.monotonic() - start)
        time.sleep(2)
    current = [json.loads((RUNTIME / (r + '.progress.json')).read_text())['sequence']
               for r in ('supervisor', 'heartbeat')]
    rows, counts = evidence(name, offsets)
    bad = [r['event'] for r in rows if r.get('level') in ('warning', 'error') or r['event'] in FORBIDDEN]
    observed = t.state()
    (ROOT / (name + '-state.json')).write_text(json.dumps(observed))
    return record(name, bool(terminal(mode, phase, monitor)) and all(b > a for a, b in zip(initial, current))
                  and not bad and max_latency < 5,
                  event_counts=counts, unexpected_events=bad,
                  max_state_latency_seconds=round(max_latency, 3), observation_seconds=35,
                  observed_phase=observed['routing']['phase'], service_health=service_health(observed),
                  infrastructure=observed['routing'].get('infrastructure'),
                  heartbeat_health=observed['routing'].get('heartbeatHealth'),
                  progress_advanced=all(b > a for a, b in zip(initial, current)))


def invoke(service, operation, refresh=True):
    p = t.run([str(ROOT / 'service-control'), service, operation], 80)
    response = json.loads(p.stdout) if p.returncode == 0 else {'failure': 'client_exit'}
    if not response.get('failure') and operation != 'stop' and refresh:
        t.request('refresh')
    return response


def command_case(service, operation, mode, phase):
    name = STAGE + '-' + service + '-' + operation
    old_check = t.state().get('snapshot', {}).get('checkedAt', 0)
    original_peers = peers()
    old_engine = job('com.mimo.mihomo')
    offsets = cursor()
    began = time.monotonic()
    expected_monitor = 'stopped' if service == 'core' and operation == 'stop' else 'running'
    expected_phase = 'blocked' if mode != 'direct' and expected_monitor == 'stopped' else phase
    response = invoke(service, operation)
    (ROOT / (name + '-response.json')).write_text(json.dumps(response))
    settled = None
    try:
        if not response.get('failure'):
            def completed():
                s = terminal(mode, expected_phase, expected_monitor)
                if not s:
                    return None
                if operation == 'stop':
                    return s
                return s if 'ready' in s['status'] and s.get('snapshot', {}).get('checkedAt', 0) > old_check else None
            settled = wait(completed, 100)
    except AssertionError:
        pass
    rows, counts = evidence(name, offsets)
    service_rows = [r for r in rows if r['event'] == 'mimo_service_changed' and
                    r.get('fields', {}).get('service') == service and
                    r.get('fields', {}).get('operation') == operation]
    expected_engine_change = service == 'mihomo' and operation == 'restart'
    bad = [r['event'] for r in rows if r['event'] in {
        'mimo_peer_repair_started', 'mimo_core_command_failed', 'mimo_service_change_failed',
        'mimo_command_rejected', 'provider_failure_paused'} or r.get('level') in ('warning', 'error')]
    complete_lookup = operation == 'stop' or (counts.get('lookup_started', 0) == 1 and
                                            counts.get('lookup_finished', 0) == 1)
    passed = record(name, settled is not None and not response.get('failure') and
                    peers() == original_peers and len(service_rows) == 1 and not bad and complete_lookup and
                    ((job('com.mimo.mihomo') != old_engine) == expected_engine_change) and
                    (mode != 'direct' or native()),
                    method='production service RPC followed by GUI-equivalent Refresh for non-Stop',
                    duration_seconds=round(time.monotonic() - began, 3), event_counts=counts,
                    unexpected_events=bad, response_failure=response.get('failure') or None,
                    reached_terminal=settled is not None, peers_preserved=peers() == original_peers,
                    fresh_lookup_completed_once=complete_lookup,
                    engine_pid_changed=job('com.mimo.mihomo') != old_engine)
    if settled:
        audit(name + '-quiet', mode, expected_phase, expected_monitor)
    return passed


def restore():
    original = json.loads((ROOT / 'original.json').read_text())
    invoke('core', 'start', refresh=False)
    t.route('direct')
    t.wait_active('direct', 120)
    t.request('configure', settings=original['settings'])
    t.request('configureRouting', routing=original['routing']['configuration'])
    t.wait_active(original['routing']['configuration']['mode'], 120)
    return native()


def setup(mode, family, approved):
    t.route('direct'); t.wait_active('direct', 120)
    settings = t.state()['settings']
    settings['refreshInterval'] = -1
    settings['allowlist'] = {'addresses': []}
    t.request('configure', settings=settings)
    if mode == 'direct':
        wait(lambda: terminal('direct', 'active'))
        return 'active'
    t.route(mode, family)
    denied = wait(lambda: terminal(mode, 'blocked'), 120)
    if approved:
        settings['allowlist'] = {'addresses': [denied['routing']['observedIP']['address']]}
        t.request('configure', settings=settings)
        t.wait_active(mode, 120)
        return 'active'
    return 'blocked'


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert ROOT.stat().st_uid == 0 and ROOT.stat().st_mode & 0o077 == 0
    os.umask(0o077)
    (ROOT / (STAGE + '.started')).write_text(str(time.time()))
    if STAGE == 'init':
        s = t.state()
        assert s['routing']['configuration']['mode'] == 'direct'
        assert not (ROOT / 'original.json').exists()
        (ROOT / 'original.json').write_text(json.dumps(s))
        artifact = {key: hashlib.sha256(path.read_bytes()).hexdigest() for key, path in (
            ('core_sha256', Path('/Library/PrivilegedHelperTools/mimo-core')),
            ('engine_sha256', SUPPORT / 'Runtime/mihomo'))}
        artifact['method'] = 'installed production RPC; not native GUI'
        (ROOT / 'artifact.json').write_text(json.dumps(artifact, indent=2))
        record('baseline-healthy-Direct', healthy(s) and native())
    elif STAGE == 'restore':
        record('original-settings-and-native-Direct-restored', restore())
        audit('restored-Direct-quiet', 'direct', 'active')
    elif STAGE == 'concurrent':
        setup('direct', 'ipv4', True)
        before = peers()
        offsets = cursor()
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
                replies = list(executor.map(lambda op: invoke('core', op, refresh=False),
                                            ['start', 'restart', 'stop', 'start', 'restart', 'start']))
            # Make the final desired state explicit only after all earlier replies.
            final = invoke('core', 'start')
            wait(lambda: terminal('direct', 'active'))
            rows, counts = evidence('concurrent', offsets)
            (ROOT / 'concurrent-replies.json').write_text(json.dumps(replies))
            accepted = sum(not r.get('failure') for r in replies)
            permitted = all(not r.get('failure') or r.get('failure') == 'conflict' for r in replies)
            record('overlapping-root-clients-accounted-for', permitted and not final.get('failure') and
                   counts.get('mimo_service_changed', 0) == accepted + 1 and peers() == before and native(),
                   method='six concurrent root RPC clients; not two GUI accounts',
                   accepted=accepted, conflicts=len(replies)-accepted, event_counts=counts)
            audit('concurrent-final-intent-quiet', 'direct', 'active')
        finally:
            record('concurrent-cleanup', restore())
    elif STAGE == 'lost-reply':
        setup('direct', 'ipv4', True)
        before = peers()
        old_engine = job('com.mimo.mihomo')
        offsets = cursor()
        log = (ROOT / 'lost-reply-client.log').open('w')
        client = subprocess.Popen([str(ROOT / 'service-control'), 'mihomo', 'restart'], stdout=log, stderr=log)
        try:
            wait(lambda: any(r['event'] == 'mimo_service_change_begin' for r in events(offsets)), 20)
            was_pending = client.poll() is None
            if was_pending:
                client.kill()
            client.wait(timeout=5)
            wait(lambda: job('com.mimo.mihomo') not in (None, old_engine), 80)
            # Reconcile the accepted operation without reissuing the restart.
            wait(lambda: terminal('direct', 'active'), 120)
            rows, counts = evidence('lost-reply', offsets)
            record('accepted-restart-survives-client-loss', was_pending and peers() == before and
                   counts.get('mimo_service_changed', 0) == 1 and native(), event_counts=counts,
                   method='terminate RPC client after service-change admission; no resubmission')
            audit('lost-reply-reconciled-quiet', 'direct', 'active')
        finally:
            if client.poll() is None:
                client.kill(); client.wait(timeout=5)
            log.close()
            record('lost-reply-cleanup', restore())
    elif STAGE == 'controller-restart':
        setup('direct', 'ipv4', True)
        before = peers()
        old_engine = job('com.mimo.mihomo')
        offsets = cursor()
        os.kill(old_engine, signal.SIGSTOP)
        try:
            wait(lambda: service_health(t.state()).get('mihomo') == 'unavailable', 45)
            response = invoke('mihomo', 'restart')
            wait(lambda: terminal('direct', 'active'), 120)
            rows, counts = evidence('controller-restart', offsets)
            record('explicit-restart-recovers-suspended-engine', not response.get('failure') and
                   job('com.mimo.mihomo') not in (None, old_engine) and peers() == before and native(),
                   event_counts=counts)
            audit('controller-restart-recovered-quiet', 'direct', 'active')
        finally:
            try:
                os.kill(old_engine, signal.SIGCONT)
            except ProcessLookupError:
                pass
            record('controller-restart-cleanup', restore())
    elif STAGE == 'release-repair-race':
        setup('direct', 'ipv4', True)
        old_heartbeat = job('com.mimo.core')
        offsets = cursor()
        os.kill(old_heartbeat, signal.SIGSTOP)
        try:
            # Exercise a real outstanding peer failure while intentional removal
            # acquires the same repair fence. Never mutate the fence directly.
            time.sleep(35)
            began = time.monotonic()
            result = t.run(['/bin/bash', '/Applications/Mimo.app/Contents/Resources/daemon.sh', 'deactivate'], 240)
            (ROOT / 'deactivate-operation.log').write_text(result.stdout + result.stderr)
            absent = lambda: all(job(label) is None for label in
                                 ('com.mimo.supervisor', 'com.mimo.core', 'com.mimo.mihomo'))
            record('full-release-during-peer-loss', result.returncode == 0 and absent() and native(),
                   duration_seconds=round(time.monotonic() - began, 3))
            removal_offsets = cursor()
            deadline = time.monotonic() + 135
            resurrected = False
            while time.monotonic() < deadline:
                resurrected |= not absent()
                time.sleep(3)
            rows, counts = evidence('release-repair-race', removal_offsets)
            record('removed-services-stay-absent-through-startup-grace', not resurrected and native() and
                   not counts.get('mimo_peer_repair_started', 0), observation_seconds=135, event_counts=counts)
        finally:
            try:
                os.kill(old_heartbeat, signal.SIGCONT)
            except ProcessLookupError:
                pass
            result = t.run(['/bin/bash', '/Applications/Mimo.app/Contents/Resources/daemon.sh',
                            'install', '--non-interactive'], 300)
            (ROOT / 'activate-operation.log').write_text(result.stdout + result.stderr)
            record('activate-after-peer-race-release', result.returncode == 0)
            wait(lambda: terminal('direct', 'active'), 120)
            record('release-race-cleanup', restore())
            audit('reactivated-after-peer-race-quiet', 'direct', 'active')
    elif STAGE == 'engine-stop-start':
        setup('direct', 'ipv4', True)
        before = peers()
        offsets = cursor()
        try:
            stopped = invoke('mihomo', 'stop', refresh=False)
            wait(lambda: job('com.mimo.mihomo') is None, 60)
            time.sleep(50)
            disabled = t.run(['/bin/launchctl', 'print-disabled', 'system'], 10).stdout
            rows, counts = evidence('engine-only-stop', offsets)
            record('engine-only-stop-honored-by-live-peers', not stopped.get('failure') and
                   peers() == before and job('com.mimo.mihomo') is None and native() and
                   '"com.mimo.mihomo" => enabled' not in disabled and
                   '"com.mimo.mihomo" => disabled' in disabled,
                   event_counts=counts, observation_seconds=50)
        finally:
            response = invoke('mihomo', 'start')
            wait(lambda: terminal('direct', 'active'), 120)
            record('engine-start-restores-health-without-peer-restart', not response.get('failure') and peers() == before)
            record('engine-stop-start-cleanup', restore())
            audit('engine-restarted-after-stop-quiet', 'direct', 'active')
    elif STAGE == 'proxy-down':
        original = json.loads((ROOT / 'original.json').read_text())
        fixture = None
        try:
            setup('direct', 'ipv4', True)
            t.request('saveProxy', proxy={'name': 'Local command audit refusal', 'type': 'socks5',
                      'server': '127.0.0.1', 'port': 9, 'username': ''}, proxyPassword='')
            fixture = next(p['id'] for p in t.state()['routing']['configuration']['proxies']
                           if p['proxy']['name'] == 'Local command audit refusal')
            # Explicitly prove the local fixture port is closed before relying
            # on connection refusal as the injected proxy failure.
            try:
                with socket.create_connection(('127.0.0.1', 9), timeout=1):
                    raise AssertionError('fixture port unexpectedly open')
            except ConnectionRefusedError:
                pass
            for mode in ('rule', 'global'):
                for family in ('ipv4', 'dual'):
                    name = 'proxy-down-' + mode + '-' + family
                    t.request('selectProxy', proxyID=original['routing']['configuration']['activeProxyID'])
                    setup(mode, family, True)
                    before = peers()
                    offsets = cursor()
                    t.request('selectProxy', proxyID=fixture)
                    wait(lambda: any(r['event'] == 'lookup_finished' for r in events(offsets)), 120)
                    wait(lambda: t.state()['routing']['phase'] == 'blocked', 60)
                    attempt = cursor()
                    response = invoke('profileHosting', 'restart')
                    wait(lambda: any(r['event'] == 'lookup_finished' for r in events(attempt)), 120)
                    s = wait(lambda: (s if (s := t.state())['routing']['phase'] == 'blocked' and healthy(s) else None), 90)
                    rows, counts = evidence(name, offsets)
                    record(name + '-reload-fails-safely-with-responsive-peers', not response.get('failure') and
                           peers() == before and not counts.get('mimo_traffic_opened', 0) and
                           not counts.get('mimo_peer_repair_started', 0), event_counts=counts,
                           monitoring_status=list(s['status']))
                    quiet = cursor()
                    time.sleep(35)
                    rows, counts = evidence(name + '-failed-settled', quiet)
                    record(name + '-no-retry-loop', not any(r['event'] in FORBIDDEN for r in rows),
                           event_counts=counts, observation_seconds=35)
                    t.request('selectProxy', proxyID=original['routing']['configuration']['activeProxyID'])
                    t.wait_active(mode, 120)
                    record(name + '-same-mode-recovery', peers() == before)
                    t.route('direct'); t.wait_active('direct', 120)
                    record(name + '-Direct-recovery', native())
        finally:
            record('proxy-down-cleanup', restore())
            if fixture:
                t.request('removeProxy', proxyID=fixture)
    elif STAGE in ('direct', 'direct-repeat') or STAGE.startswith('mode-'):
        mode, family, approval = ('direct', 'ipv4', 'approved') if STAGE.startswith('direct') else STAGE.split('-')[1:]
        try:
            phase = setup(mode, family, approval == 'approved')
            for service, operation in [('core', 'stop'), ('core', 'start'), ('core', 'restart'),
                                       ('mihomo', 'restart'), ('profileHosting', 'restart')]:
                command_case(service, operation, mode, phase)
        finally:
            record(STAGE + '-cleanup', restore())
    else:
        raise ValueError('unknown stage')


if __name__ == '__main__':
    try:
        main()
        (ROOT / (STAGE + '.finished')).write_text(str(time.time()))
    except Exception as error:
        record(STAGE + '-harness-completion', False, error_type=type(error).__name__)
        (ROOT / (STAGE + '-exception.txt')).write_text(repr(error))
        raise
