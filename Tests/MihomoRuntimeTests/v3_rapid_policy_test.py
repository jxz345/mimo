#!/usr/bin/env python3
"""New VM-only contention cases; never use this to repeat the old pass matrix."""
import hashlib
import collections
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time
import traceback
import uuid

import v3_installed_test as t
import v3_service_command_test as service
import v3_observation_test as observation
import v3_observation_burst_test as burst
import v3_fault_traffic_test as packets
from v3_gui_event_audit import GUICaseAudit
from v3_health_trace import HealthTrace
from v3_rapid_policy_oracle import (audit_queue, audit_native_boundaries, audit_traffic_precondition,
    audit_protected_precondition_native, audit_current_refresh, current_component_evidence)
from v3_rapid_policy_oracle import audit_prior_manual_terminal
from v3_queue_log_visibility import collect_queue_records, audit_queue_window

ROOT = Path(sys.argv[1])


def read_state():
    result = t.run([t.CONTROLS], 3)
    assert result.returncode == 0
    response = json.loads(result.stdout)
    assert response.get('state') and not response.get('failure')
    return response['state']


class Requests:
    def __init__(self, evidence_id):
        self.identity = evidence_id
        self.pending = {}
        self.replies = {}

    def start(self, name, value):
        assert name not in self.pending
        path = ROOT / (self.identity + '-request-' + name + '.json')
        path.write_text(json.dumps(dict(protocolVersion=8, **value)))
        path.chmod(0o600)
        process = subprocess.Popen([t.CONTROLS, 'request', str(path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.pending[name] = (process, path)
        return process

    def finish(self):
        deadline = time.monotonic() + 85
        failures = []
        for name, (process, path) in self.pending.items():
            try:
                output, error = process.communicate(timeout=max(.01, deadline - time.monotonic()))
                assert process.returncode == 0, 'RPC transport failed'
                self.replies[name] = json.loads(output)
            except Exception as error:
                failures.append({'request': name, 'error_class': type(error).__name__})
                if process.poll() is None:
                    process.kill(); process.wait(5)
            finally:
                path.unlink(missing_ok=True)
        observation.save(self.identity + '-request-replies.json', self.replies)
        assert not failures, 'RPC did not finish; inspect retained replies'
        return self.replies


class BoundedHold:
    def __init__(self, identity):
        self.identity, self.process, self.finished = identity, None, None

    def start(self):
        self.process = subprocess.Popen(['/usr/bin/python3', str(ROOT / 'v3_bounded_pf_hold.py'),
            str(ROOT), self.identity, '4'], stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        path = ROOT / (self.identity + '-pf-hold-ready.json')
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if path.exists():
                self.ready = json.loads(path.read_text())
                assert self.ready['pid'] == self.process.pid
                return self.ready
            assert self.process.poll() is None, 'PF hold precondition failed'
            time.sleep(.01)
        raise AssertionError('PF hold acquisition deadline')

    def release(self):
        if self.finished is not None: return self.finished
        if self.process is None: return None
        path = ROOT / (self.identity + '-pf-hold-release')
        if not path.exists():
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(descriptor)
        self.process.wait(10)  # Independent helper deadline also bounds parent-abort cleanup.
        result = ROOT / (self.identity + '-pf-hold-finished.json')
        assert result.exists(), 'PF hold completion evidence missing'
        self.finished = json.loads(result.read_text())
        assert self.process.returncode == 0 and self.finished['lock_inode_unchanged']
        return self.finished


def queued_identity(offsets, known, command):
    matches = [row.get('fields', {}).get('request') for row in service.events(offsets)
               if row['event'] == 'mimo_control_queued' and row.get('fields', {}).get('command') == command
               and row.get('fields', {}).get('request') not in known]
    unique = set(matches)
    if len(unique) == 1: return unique.pop()
    assert len(unique) < 2, 'Ambiguous queued request ownership'
    return None


def wait_short(predicate, seconds=1):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(.02)
    raise AssertionError('Queued-operation precondition not exercised')


def finish_traffic(traffic):
    try:
        return traffic.finish()
    finally:
        # Preserve a parse/capture failure, but stop every owned observer before
        # another case. A partially completed finish must never orphan tcpdump.
        traffic.done.set()
        for thread in traffic.threads: thread.join(4)
        for process, stream, _ in traffic.captures:
            try:
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    try: process.wait(5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait(5)
            finally:
                stream.close()


def run(family, ending):
    assert family in ('ipv4', 'dual') and ending in ('rule-denied', 'direct')
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm-worker')
    assert ROOT == Path('/var/tmp/mimo-observation-worker')
    os.umask(0o077)
    identity = uuid.uuid4().hex
    mode_stream = str(uuid.uuid4())
    final_mode = 'rule' if ending == 'rule-denied' else 'direct'
    name = 'pending-mode-' + family + '-' + ending
    result = {'name': name, 'evidence_id': identity, 'passed': False,
              'family': family, 'ending': ending, 'method': 'real production RPCs behind bounded PF-lock contention; not UI clicks'}
    failures = []
    offsets = service.cursor()
    communication = GUICaseAudit(ROOT, service.cursor, service.events,
        observation.read_only_state_probe, observation.gui_process_ids,
        active_process_ids=observation.active_mimo_process_ids)
    health = HealthTrace(ROOT, read_state, service.cursor, service.events, read_policy=packets.pf_kind)
    hold = BoundedHold(identity)
    requests = Requests(identity)
    traffic = None; native = []; lab_owned = False; replies = {}; ids = {}; operation_start = None
    packet_finished = False; cleanup = {}; preflight = []; samples = []; control_window = None; approved_window = None; stage = 'setup'
    try:
        communication.start(); health.start()
        original_hosts = (ROOT / 'hosts.original').read_bytes()
        assert Path('/etc/hosts').read_bytes() == original_hosts
        provider = burst.eligible_provider()
        baseline_dns = burst.native_fixture_proof(provider)
        def check_dns():
            assert Path('/etc/hosts').read_bytes() == original_hosts
            assert burst.native_fixture_proof(provider) == baseline_dns
        observation.fixture(provider_delay=0, provider_status=200, provider_retry_after=None,
                            provider_ip='203.0.113.10', proxy_off=False)
        settings = read_state()['settings']; settings['allowlist'] = {'addresses': ['203.0.113.10']}
        t.request('configure', settings=settings)
        t.route('direct', family); observation.idle('direct')
        initial_lab = t.run(['/sbin/pfctl', '-a', packets.LAB, '-sr'], 8)
        assert initial_lab.returncode == 0 and not initial_lab.stdout.strip(), 'Cannot claim lab containment anchor'
        lab_owned = True; packets.containment()
        traffic = packets.Traffic(identity + '-rapid-policy')
        began = time.time(); time.sleep(3); control_window = (began, time.time())
        burst.preflight(family, 'rule', provider, preflight, check_dns)
        assert packets.pf_kind() == 'active'
        identity_before = observation.fingerprint()
        began = time.time(); time.sleep(3); approved_window = (began, time.time())
        precondition = audit_traffic_precondition(traffic.events, *approved_window, family)
        result['protected_traffic_precondition'] = precondition
        assert precondition['passed'], 'Protected packet fixture precondition failed'
        operation_start = time.time(); operation_offsets = service.cursor()
        stage = 'hold-and-queue'
        hold.start()
        active = requests.start('active_direct', {'command': 'configureRouting',
            'requestedMode': 'direct', 'modeIntent': {'stream': mode_stream, 'sequence': 1}})
        wait_short(lambda:any(row['event'] == 'mimo_direct_worker_started'
            for row in service.events(operation_offsets)), 1.2)
        assert active.poll() is None, 'Active physical transition was not held'
        state = read_state(); base_revision = state['revision']; configuration = state['routing']['configuration']
        assert configuration['mode'] == 'direct'
        def pending(name, mode, sequence):
            requests.start(name, {'command': 'configureRouting', 'requestedMode': mode,
                'modeIntent': {'stream': mode_stream, 'sequence': sequence}})
            ids[name] = wait_short(lambda: queued_identity(operation_offsets, set(ids.values()), 'configureRouting'))
        pending('first_old', 'rule', 2)
        pending('first_kept', 'global', 3)
        settings = state['settings']; settings['allowlist'] = {'addresses': ['203.0.113.99']}
        requests.start('barrier', {'command': 'configure', 'settings': settings,
                                  'expectedRevision': base_revision + 1})
        ids['barrier'] = wait_short(lambda: queued_identity(operation_offsets, set(ids.values()), 'configure'))
        older_mode = 'global' if final_mode == 'direct' else 'direct'
        pending('last_old', older_mode, 4)
        pending('last_kept', final_mode, 5)
        requests.start('late_older', {'command': 'configureRouting', 'requestedMode': older_mode,
            'modeIntent': {'stream': mode_stream, 'sequence': 4}})
        def older_ignored():
            matches = [row for row in service.events(operation_offsets) if row['event'] == 'mimo_mode_intent_superseded']
            assert len(matches) <= 1, 'Ambiguous delayed mode intent ownership'
            return matches[0]['fields']['request'] if matches else None
        ids['late_older'] = wait_short(older_ignored)
        for index in range(12): requests.start('refresh-' + str(index), {'command': 'refresh'})
        released = hold.release()
        assert released['release_reason'] == 'requested', 'PF contention expired before queue proof'
        stage = 'join-requests'; replies = requests.finish()
        # RPC completion guarantees an in-memory commit, not durable JSONL yet.
        # Freeze attribution now: later unrelated operations cannot satisfy it.
        queue_window_end = time.time()
        queue_records = collect_queue_records(lambda: service.events(operation_offsets),
            replies, ids, base_revision, final_mode,
            window_start=operation_start, window_end=queue_window_end)
        observation.save(identity + '-queue-initial-input.json', queue_records['initial_rows'])
        observation.save(identity + '-queue-final-input.json', queue_records['final_rows'])
        result['queue_log_visibility'] = {key: value for key, value in queue_records.items()
            if key not in ('initial_rows', 'final_rows', 'proof')}
        queue_proof = queue_records['proof']
        result['queue_proof'] = queue_proof
        assert queue_proof['passed'], 'Queue ownership or edit barrier failed'
        # Earlier Refreshes may be cancelled by admitted mode changes. Do not
        # mistake one still pending manual operation for the final new request.
        target_phase = 'blocked' if final_mode == 'rule' else 'active'
        observation.idle(final_mode, target_phase, 'ready')
        stage = 'prior-manual-terminal'
        def previous_finished():
            value = read_state(); manual = value.get('manualRefresh') or {}
            return value if manual.get('phase') not in ('queued', 'checking') else None
        prior = service.wait(previous_finished, 35)
        observation.save(identity + '-prior-manual-state.json', prior)
        result['prior_manual_terminal'] = {'id': (prior.get('manualRefresh') or {}).get('id'),
            'phase': (prior.get('manualRefresh') or {}).get('phase'),
            'result': (prior.get('manualRefresh') or {}).get('result')}
        result['prior_manual_proof'] = audit_prior_manual_terminal(prior, service.events(operation_offsets))
        assert result['prior_manual_proof']['passed'], 'Earlier manual terminal ownership not qualified'
        refresh_offsets = service.cursor(); refresh_started = time.time()
        response = t.request('refresh')
        observation.save(identity + '-final-refresh-response.json', response)
        acknowledged = response.get('state', {}).get('manualRefresh') or {}
        assert acknowledged.get('id') and acknowledged['id'] != result['prior_manual_terminal']['id'], 'Final Refresh reused an old manual identity'
        stage = 'final-manual-terminal'
        def current_finished():
            value = read_state(); manual = value.get('manualRefresh') or {}
            assert manual.get('id') == acknowledged['id'], 'Final Refresh identity was replaced'
            return value if manual.get('finishedAt') is not None and manual.get('phase') not in ('queued', 'checking') else None
        service.wait(current_finished, 35)
        stage = 'final-state'
        observation.idle(final_mode, target_phase, 'ready')
        final = read_state()
        observation.save(identity + '-final-state.json', final)
        final_refresh = audit_current_refresh(response, final, service.events(refresh_offsets),
            refresh_started, final_mode, packets.pf_kind())
        result['final_refresh'] = final_refresh
        assert final_refresh['passed'], 'Current Refresh completion was not qualified'
        if final_mode == 'rule':
            assert (final['routing'].get('blockingIP') or {}).get('address') == '203.0.113.10', 'Denied exit address not visible'
            assert packets.pf_kind() in ('closed', 'probe'), 'Denied Rule did not confirm closure'
        else:
            assert service.native(), 'Direct did not release network controls'
        assert final['settings']['allowlist'] == {'addresses': ['203.0.113.99']}
        quiet = service.cursor(); stage = 'settled'
        for index in range(18):
            check_dns(); sample = burst.health_sample(read_state(), index); samples.append(sample)
            assert sample['mode'] == final_mode and sample['phase'] == target_phase
            assert sample['healthy'] and 'ready' in sample['status'], 'Final health did not remain stable'
            assert current_component_evidence(sample), 'PF health claims conflict with actual current policy evidence'
            time.sleep(2)
        late = service.events(quiet)
        assert not any(row['event'] in service.FORBIDDEN for row in late), 'Unexpected settled activity'
        rows = service.events(operation_offsets)
        requests_per_lookup = collections.Counter(row.get('fields', {}).get('lookup')
            for row in rows if row['event'] == 'lookup_http_request')
        assert requests_per_lookup and all(key and value == 1 for key, value in requests_per_lookup.items()), 'Duplicate or missing HTTP ownership'
        assert len(requests_per_lookup) <= 6, 'Unbounded provider requests'
        assert not any(row['event'] == 'provider_failure_paused' for row in rows), 'Healthy provider was paused'
        assert not any(row.get('level') == 'error' for row in rows), 'Unexpected runtime error'
        # An owned duplicate/wrong terminal is still a failure if its disk write
        # arrives after the initial synchronization. Do not expand the action window.
        queue_final_rows = service.events(operation_offsets)
        observation.save(identity + '-queue-settled-input.json', queue_final_rows)
        result['queue_final_proof'] = audit_queue_window(queue_final_rows, replies, ids,
            base_revision, final_mode, operation_start, queue_window_end)
        assert result['queue_final_proof']['passed'], 'Late queue ownership or commit violation'
        identity_after = observation.fingerprint()
        assert identity_before['engine'] == identity_after['engine'] and identity_before['peers'] == identity_after['peers'], 'Unexpected service restart'
        result.update(final_mode=final_mode, final_phase=target_phase, settled_seconds=36,
                      manual_refresh_phase=final.get('manualRefresh', {}).get('phase'), provider=provider,
                      http_requests=len(requests_per_lookup), max_http_per_lookup=max(requests_per_lookup.values()),
                      overlapping_refresh_requests=12, final_current_refresh_requests=1)
        stage = 'complete'
    except Exception as error:
        failures.append(stage + ':' + type(error).__name__)
        (ROOT / (identity + '-private-error.txt')).write_text(traceback.format_exc())
    finally:
        try: result['pf_hold'] = hold.release()
        except Exception as error: failures.append('hold_cleanup:' + type(error).__name__)
        try:
            if any(process.poll() is None for process, _ in requests.pending.values()): requests.finish()
        except Exception as error: failures.append('request_join:' + type(error).__name__)
        if traffic is not None:
            try:
                native = finish_traffic(traffic); packet_finished = True
                assert not any(thread.is_alive() for thread in traffic.threads)
                if control_window:
                    control = [packet for packet in native if control_window[0] <= packet['t'] <= control_window[1]]
                    result['direct_detector_families'] = sorted({packet['family'] for packet in control})
                    assert result['direct_detector_families'] == [4, 6], 'Packet detector calibration incomplete'
                if approved_window:
                    precondition_native = audit_protected_precondition_native(native, *approved_window)
                    result['protected_precondition_native'] = precondition_native
                    assert precondition_native['passed'], 'Native escape during protected packet precondition'
                if operation_start is not None:
                    packet_proof = audit_native_boundaries(service.events(offsets), native,
                        approved_window[0] if approved_window else operation_start, final_mode)
                    result['packet_policy'] = packet_proof
                    assert packet_proof['passed'], 'Native attempt after confirmed protection'
            except Exception as error: failures.append('packet_audit:' + type(error).__name__)
        if lab_owned:
            try:
                flushed = t.run(['/sbin/pfctl', '-a', packets.LAB, '-F', 'rules'], 8)
                checked = t.run(['/sbin/pfctl', '-a', packets.LAB, '-sr'], 8)
                cleanup = {'flushed': flushed.returncode == 0, 'empty': checked.returncode == 0 and not checked.stdout.strip()}
                if not all(cleanup.values()): failures.append('lab_cleanup_failed')
            except Exception as error: failures.append('lab_cleanup:' + type(error).__name__)
        try:
            proof = health.finish(identity); result['continuous_health'] = {key: value for key, value in proof.items() if key not in ('samples', 'scan_events')}
            if not proof['passed']: failures.append('health_trace_failed')
        except Exception as error: failures.append('health_export:' + type(error).__name__)
        try:
            gui = communication.finish(identity); result['gui_communication'] = gui
            if not gui['passed']: failures.append('GUI_communication_failed')
        except Exception as error: failures.append('GUI_export:' + type(error).__name__)
        try: observation.save(identity + '-raw-events.json', service.events(offsets))
        except Exception as error: failures.append('event_export:' + type(error).__name__)
        observation.save(identity + '-settled-health.json', samples)
        result.update(passed=not failures, failures=failures, last_stage=stage, packet_worker_joined=packet_finished,
            lab_cleanup=cleanup, fixture_preflight=preflight,
            core_sha256=hashlib.sha256(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).hexdigest())
        observation.save(identity + '-targeted-result.json', result)
        print(json.dumps(result), flush=True)
    assert result['passed'], 'New rapid-policy case failed; stop and preserve evidence'


if __name__ == '__main__':
    assert sys.argv[2] == 'latest-mode'
    run(sys.argv[3], sys.argv[4])
