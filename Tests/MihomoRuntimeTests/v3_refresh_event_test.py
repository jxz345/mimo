#!/usr/bin/env python3
"""VM-only Refresh now audit. Setup uses RPC; refresh is clicked by the operator.

Raw settings, addresses and log records remain in the root-only VM directory.
The exported report contains event names, timings and correlation IDs only.
Run init, setup MODE FAMILY APPROVAL, arm CASE, click, collect, then restore.
"""
import collections
import hashlib
import json
import os
from pathlib import Path
import socket
import sys
import time

import v3_installed_test as t
import v3_service_command_test as service

ROOT = Path(sys.argv[1])
ACTION = sys.argv[2]
REPORT = ROOT / 'refresh-results.json'


def save(name, value):
    (ROOT / name).write_text(json.dumps(value, indent=2) + '\n')


def terminal(mode, phase):
    s = service.terminal(mode, phase)
    return s if s and 'ready' in s['status'] else None


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert ROOT.stat().st_uid == 0 and ROOT.stat().st_mode & 0o077 == 0
    os.umask(0o077)
    if ACTION == 'init':
        assert not (ROOT / 'original.json').exists()
        save('original.json', t.state())
        save('artifact.json', {'core_sha256': hashlib.sha256(
            Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).hexdigest(),
            'method': 'native dashboard Refresh now clicks; production RPC setup'})
        print('Saved original settings privately', flush=True)
    elif ACTION == 'setup':
        mode, family, approval = sys.argv[3:6]
        # Do not request a no-op routing mutation when already in Direct.
        if t.state()['routing']['configuration']['mode'] != 'direct':
            t.route('direct')
            t.wait_active('direct', 120)
        settings = t.state()['settings']
        settings['refreshInterval'] = -1
        settings['allowlist'] = {'addresses': []}
        t.request('configure', settings=settings)
        config = t.state()['routing']['configuration']
        config.update(mode=mode, networkFamily=family)
        t.request('configureRouting', routing=config)
        phase = 'active' if mode == 'direct' else 'blocked'
        s = service.wait(lambda: terminal(mode, phase), 120)
        if mode != 'direct' and approval == 'approved':
            settings['allowlist'] = {'addresses': [s['routing']['observedIP']['address']]}
            t.request('configure', settings=settings)
            phase = 'active'
            service.wait(lambda: terminal(mode, phase), 120)
        save('case.json', dict(mode=mode, family=family, approval=approval, phase=phase))
        # Observe setup separately. A late setup check must not be blamed on a click.
        offsets = service.cursor()
        time.sleep(35)
        rows = service.events(offsets)
        save('setup-events.json', rows)
        counts = dict(collections.Counter(r['event'] for r in rows))
        print(json.dumps({'setup_terminal': bool(terminal(mode, phase)),
                          'settle_event_counts': counts}), flush=True)
    elif ACTION == 'arm':
        case = json.loads((ROOT / 'case.json').read_text())
        assert terminal(case['mode'], case['phase'])
        save('armed.json', dict(case=case, name=sys.argv[3], offsets=service.cursor(),
            peers=service.peers(), engine=service.job('com.mimo.mihomo'),
            checkedAt=t.state().get('snapshot', {}).get('checkedAt'), at=time.time()))
        print('ARMED: click Refresh now once', flush=True)
    elif ACTION == 'collect':
        armed = json.loads((ROOT / 'armed.json').read_text())
        offsets, case = armed['offsets'], armed['case']
        deadline = time.monotonic() + 120
        completed = None
        while time.monotonic() < deadline:
            rows = service.events(offsets)
            if any(r['event'] == 'manual_refresh_finished' for r in rows):
                completed = terminal(case['mode'], case['phase'])
                if completed:
                    break
            time.sleep(.5)
        # Several infrastructure scans run after the terminal result.
        quiet_start = service.cursor()
        time.sleep(35)
        rows = service.events(offsets)
        quiet = service.events(quiet_start)
        save(armed['name'] + '-raw-events.json', rows)
        s = t.state()
        save(armed['name'] + '-raw-state.json', s)
        counts = dict(collections.Counter(r['event'] for r in rows))
        relevant = {'refresh_requested', 'refresh_coalesced_in_flight', 'lookup_started',
                    'lookup_finished', 'lookup_succeeded', 'lookup_failed',
                    'manual_refresh_queued', 'manual_refresh_finished', 'mimo_gate_closed',
                    'mimo_traffic_opened', 'mimo_network_changed', 'mimo_network_event_dispatch',
                    'mimo_liveness_lost', 'mimo_verification_audit_failed',
                    'mimo_core_command_started', 'mimo_core_command_finished',
                    'mimo_supervisor_command_received', 'lookup_http_request',
                    'mimo_peer_repair_started', 'mimo_final_profile_loaded', 'mimo_final_profile_reused'}
        # Explicit whitelist: never export addresses, credentials or arbitrary messages.
        safe_fields = {'trigger', 'lookup', 'activeLookup', 'source', 'outcome', 'attempt',
                       'mode', 'optimistic', 'generation', 'revision', 'command', 'sequence',
                       'duration_ms'}
        timeline = [dict(timestamp=r.get('timestamp'), event=r['event'],
                        fields={k: v for k, v in r.get('fields', {}).items() if k in safe_fields})
                    for r in rows if r['event'] in relevant or r.get('level') in ('warning', 'error')]
        timeline.sort(key=lambda r: r.get('timestamp') or '')
        errors = [r['event'] for r in rows if r.get('level') in ('warning', 'error')]
        late = [r['event'] for r in quiet if r['event'] in service.FORBIDDEN]
        one_lookup = counts.get('lookup_started', 0) == counts.get('lookup_finished', 0) == 1
        direct_untouched = case['mode'] != 'direct' or not any(counts.get(e) for e in
            ('mimo_gate_closed', 'mimo_traffic_opened', 'mimo_final_profile_loaded'))
        commands = collections.Counter(r.get('fields', {}).get('command') for r in rows
                                       if r['event'] == 'mimo_core_command_started')
        expected_commands = {} if case['mode'] == 'direct' else {'prepare': 1, 'approve': 1}
        commands_match = dict(commands) == expected_commands
        fresh = s.get('snapshot', {}).get('checkedAt') != armed['checkedAt']
        same_peers = service.peers() == armed['peers']
        same_engine = service.job('com.mimo.mihomo') == armed['engine']
        result = dict(name=armed['name'], **case, method='native dashboard click',
                      passed=bool(completed) and bool(terminal(case['mode'], case['phase'])) and
                      one_lookup and counts.get('lookup_http_request') == 1 and commands_match and
                      fresh and same_peers and same_engine and direct_untouched and not errors and not late,
                      one_lookup=one_lookup, direct_routing_untouched=direct_untouched,
                      fresh_snapshot=fresh, commands=dict(commands),
                      returned_to_expected_state=bool(terminal(case['mode'], case['phase'])),
                      peers_preserved=same_peers, engine_preserved=same_engine,
                      event_counts=counts, errors=errors, late_events=late,
                      settled_observation_seconds=35, timeline=timeline)
        results = json.loads(REPORT.read_text()) if REPORT.exists() else []
        results.append(result)
        save(REPORT.name, results)
        print(json.dumps({k: v for k, v in result.items() if k != 'timeline'}), flush=True)
    elif ACTION == 'restore':
        original = json.loads((ROOT / 'original.json').read_text())
        t.route('direct'); t.wait_active('direct', 120)
        t.request('configure', settings=original['settings'])
        t.request('configureRouting', routing=original['routing']['configuration'])
        t.wait_active(original['routing']['configuration']['mode'], 120)
        print(json.dumps({'settings_restored': t.state()['settings'] == original['settings'],
                          'routing_restored': t.state()['routing']['configuration'] ==
                                              original['routing']['configuration'],
                          'native_controls_released': service.native()}), flush=True)
    else:
        raise ValueError('Unknown action')


if __name__ == '__main__':
    main()
