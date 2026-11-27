#!/usr/bin/env python3
"""Read-only continuous infrastructure evidence for targeted VM regressions."""
import hashlib
import json
import os
from pathlib import Path
import stat
import threading
import time

SCANS = {'mimo_infrastructure_check_started', 'mimo_infrastructure_check_finished',
         'mimo_infrastructure_check_deferred', 'mimo_infrastructure_retry_scheduled',
         'mimo_infrastructure_reconcile_requested', 'mimo_infrastructure_check_failed',
         'mimo_infrastructure_repaired'}
SCAN_FIELDS = {'check', 'epoch', 'generation', 'outcome', 'duration_ms', 'reason',
               'delay_seconds', 'retry_level', 'deferred_count'}


def state_health(state, now):
    routing = state['routing']
    infra = routing.get('infrastructure') or {}
    checked = infra.get('checkedAt')
    age = now - (checked + 978307200) if isinstance(checked, (int, float)) else None
    heartbeat = routing.get('heartbeatCheckedAt')
    failed = []
    if routing.get('heartbeatHealth') != 'healthy': failed.append('heartbeat')
    if infra.get('launchd') != 'healthy': failed.append('launchd')
    if infra.get('pf') not in ('healthy', 'released'): failed.append('pf')
    if age is None or age >= 35: failed.append('infrastructure_age')
    return {'revision': state.get('revision'), 'mode': routing['configuration']['mode'],
        'family': routing['configuration'].get('networkFamily'), 'phase': routing['phase'],
        'effectiveMode': routing.get('effectiveMode'), 'status': list(state['status']),
        'heartbeatHealth': routing.get('heartbeatHealth'), 'heartbeatCheckedAt': heartbeat,
        'heartbeat_age_seconds': now - (heartbeat + 978307200) if isinstance(heartbeat, (int, float)) else None,
        'infrastructure': {key: infra.get(key) for key in ('pf', 'launchd', 'checkedAt', 'pfCheckedAt', 'launchdCheckedAt', 'completedAt', 'inspection', 'pfEvidenceCurrent')},
        'pf_age_seconds': now - (infra.get('pfCheckedAt', checked) + 978307200) if isinstance(infra.get('pfCheckedAt', checked), (int, float)) else None,
        'launchd_age_seconds': now - (infra.get('launchdCheckedAt', checked) + 978307200) if isinstance(infra.get('launchdCheckedAt', checked), (int, float)) else None,
        'infrastructure_age_seconds': age, 'failed_components': failed,
        'services': [{key: item.get(key) for key in ('id', 'health', 'checkedAt')}
                     for item in routing.get('services', [])]}


def guard_health(path, uid=0):
    """Keep the producer's real timestamp; never advance or rewrite it."""
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    try:
        info = os.fstat(descriptor)
        assert stat.S_ISREG(info.st_mode) and info.st_uid == uid and not info.st_mode & 0o022
        assert info.st_size <= 16384
        payload = os.read(descriptor, 16385)
        value = json.loads(payload)
        return {'inode': info.st_ino, 'mtime_ns': info.st_mtime_ns,
                'sha256': hashlib.sha256(payload).hexdigest(),
                'record': {key: value.get(key) for key in ('checkedAt', 'pf', 'launchd', 'status',
                    'pfCheckedAt', 'launchdCheckedAt', 'completedAt', 'pfMutationEpoch', 'pfState', 'pfPolicyDigest')}}
    finally:
        os.close(descriptor)


class HealthTrace:
    def __init__(self, root, read_state, cursor, events, interval=.5,
                 guard_path='/Library/Application Support/Mimo/Guard/health.json', guard_uid=0, read_policy=None):
        self.root = Path(root)
        self.read_state, self.cursor, self.events = read_state, cursor, events
        self.interval, self.guard_path = interval, guard_path
        self.guard_uid = guard_uid
        self.read_policy = read_policy
        self.stop_event = threading.Event()
        self.samples, self.failures, self.result = [], [], None
        self.thread = None

    def start(self):
        assert self.thread is None
        self.offsets = self.cursor()
        self.started = time.time()
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()
        return self

    def sample(self):
        while not self.stop_event.is_set():
            began = time.monotonic()
            row = {'started_epoch': time.time()}
            try:
                before = self.read_policy() if self.read_policy else None
                rpc_started = time.monotonic()
                state = self.read_state()  # Caller must enforce a three-second subprocess deadline.
                row['rpc_seconds'] = time.monotonic() - rpc_started
                assert row['rpc_seconds'] < 3, 'state_rpc_deadline'
                row.update(state_health(state, time.time()))
                if self.read_policy:
                    after = self.read_policy()
                    row['pf_readback'] = {'before': before, 'after': after}
                    assert not (before == after == 'empty' and row['phase'] == 'active'
                        and row['effectiveMode'] in ('rule', 'global')), 'protected_status_over_released_PF'
                row['guard'] = guard_health(self.guard_path, self.guard_uid)
                row['passed'] = True
            except Exception as error:
                row['passed'] = False
                row['error_class'] = type(error).__name__
                self.failures.append({'at': row['started_epoch'], 'error_class': type(error).__name__})
            row['finished_epoch'] = time.time()
            self.samples.append(row)
            self.stop_event.wait(max(0, self.interval - (time.monotonic() - began)))

    def finish(self, evidence_id):
        if self.result is not None: return self.result
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(4)
            if self.thread.is_alive(): self.failures.append({'error_class': 'SamplerDidNotStop'})
        try:
            rows = self.events(getattr(self, 'offsets', {}))
        except Exception as error:
            self.failures.append({'error_class': type(error).__name__, 'stage': 'events'})
            rows = []
        scans = [{'timestamp': row.get('timestamp'), 'event': row['event'],
                  'fields': {key: value for key, value in row.get('fields', {}).items() if key in SCAN_FIELDS}}
                 for row in rows if row.get('event') in SCANS]
        ages = [row['infrastructure_age_seconds'] for row in self.samples
                if isinstance(row.get('infrastructure_age_seconds'), (int, float))]
        result = {'passed': bool(self.samples) and not self.failures, 'interval_seconds': self.interval,
            'started_epoch': getattr(self, 'started', None), 'finished_epoch': time.time(), 'samples': self.samples,
            'scan_events': scans, 'failures': self.failures, 'max_infrastructure_age_seconds': max(ages, default=None),
            'max_rpc_seconds': max((row.get('rpc_seconds', 0) for row in self.samples), default=None),
            'max_pf_age_seconds': max((row['pf_age_seconds'] for row in self.samples if isinstance(row.get('pf_age_seconds'), (int, float))), default=None),
            'max_launchd_age_seconds': max((row['launchd_age_seconds'] for row in self.samples if isinstance(row.get('launchd_age_seconds'), (int, float))), default=None),
            'health_overdue_sample_count': sum('infrastructure_age' in row.get('failed_components', []) for row in self.samples),
            'method': 'bounded read-only core state plus original guard health file; no timestamp synthesis'}
        (self.root / (evidence_id + '-continuous-health.json')).write_text(json.dumps(result, indent=2) + '\n')
        self.result = result
        return result


def wait_for_phase(phase, read_guard, read_state, healthy, now=time.time,
                   monotonic=time.monotonic, sleep=time.sleep, timeout=40):
    """Wait after a new real successful scan; never synthesize health freshness."""
    assert phase in ('early', 'late')
    low, high = (0, 1) if phase == 'early' else (5, 6)
    entered, deadline = now(), monotonic() + timeout
    while monotonic() < deadline:
        evidence = read_guard()
        record = evidence['record']
        completed = record.get('completedAt')
        if isinstance(completed, (int, float)) and completed >= entered and record.get('status') == 'healthy':
            elapsed = now() - completed
            if low <= elapsed <= high:
                state = read_state()
                ended = now() - completed
                if healthy(state) and low <= ended <= high:
                    return {'phase': phase, 'entered_epoch': entered, 'observed_epoch': now(),
                        'after_completion_seconds': ended, 'window_seconds': [low, high],
                        'guard': evidence, 'state': state_health(state, now())}
        sleep(.1)
    raise AssertionError('Successful infrastructure scan phase was not exercised')
