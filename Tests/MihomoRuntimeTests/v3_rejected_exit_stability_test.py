#!/usr/bin/env python3
"""Read-only installed-VM regression: a settled exit must not recheck itself.

Run as root in mimo-vm with an existing release-controls executable. Keep the
current mode and do not edit settings/refresh during the observation.
Output contains event metadata and health assertions, never addresses/secrets.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controls', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--seconds', type=float, default=35)
    parser.add_argument('--verdict', choices=('rejected', 'approved', 'direct'), default='rejected')
    parser.add_argument('--require-navigation', action='store_true',
                        help='Require native GUI Dashboard/Settings and all six sections during the window')
    args = parser.parse_args()
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert args.seconds >= 30, 'Observe at least two 10-second infrastructure scans'
    os.umask(0o077)

    def state():
        result = subprocess.run([args.controls], capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, 'State request failed'
        return json.loads(result.stdout)['state']

    def settled(value):
        routing = value['routing']
        if args.verdict == 'direct':
            return (routing['configuration']['mode'] == 'direct' and routing['phase'] == 'active'
                    and routing.get('effectiveMode') == 'direct' and value['status'] == {'ready': {}})
        if routing['configuration']['mode'] not in ('rule', 'global') or value['status'] != {'ready': {}}:
            return False
        if args.verdict == 'rejected':
            return routing['phase'] == 'blocked' and bool(routing.get('blockingIP'))
        return (routing['phase'] == 'active' and routing.get('effectiveMode') == routing['configuration']['mode']
                and not routing.get('blockingIP') and routing.get('observedIP', {}).get('address') in
                value['settings']['allowlist']['addresses'])

    deadline = time.monotonic() + 45
    before = state()
    while not settled(before) and time.monotonic() < deadline:
        time.sleep(.5)
        before = state()
    assert settled(before), 'Requires a completed ' + args.verdict + ' exit observation with a healthy provider'
    mode = before['routing']['configuration']['mode']
    family = before['routing']['configuration']['networkFamily']
    started = datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    print('Observing', args.verdict, 'exit for', args.seconds, 'seconds:', mode, family, flush=True)
    time.sleep(args.seconds)
    after = state()
    finished = datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    events = []
    paths = list(Path('/Library/Logs/Mimo').glob('runtime-*.jsonl'))
    if args.require_navigation:
        paths += list(Path('/Users').glob('*/Library/Application Support/Mimo/Logs/runtime-*.jsonl'))
    abnormal = {'mimo_liveness_lost', 'mimo_core_command_failed', 'mimo_command_rejected',
                'mimo_cycle_event_deferred', 'mimo_verification_audit_failed',
                'mimo_dns_configuration_lost', 'mimo_network_configuration_external',
                'mimo_network_event_dispatch', 'mimo_routing_changed',
                'shared_settings_changed', 'shared_credential_changed', 'mimo_proxy_catalog_changed',
                'daemon_client_disconnected', 'daemon_storage_failed', 'mimo_network_changed',
                'mimo_traffic_opened', 'mimo_exits_approved', 'mimo_direct_restored',
                'mimo_service_changed', 'mimo_final_profile_loaded', 'mimo_recovery_verification_consumed'}
    watched = abnormal | {'mimo_network_changed', 'refresh_requested', 'lookup_started',
                         'mimo_recovery_verification_consumed', 'mimo_exit_ip_rejected',
                         'mimo_core_command_started', 'mimo_gate_closed',
                         'mimo_navigation_requested', 'mimo_navigation_applied',
                         'mimo_navigation_window_updated', 'mimo_access_presentation_changed'}
    for path in paths:
        if path.stat().st_mtime < datetime.fromisoformat(started.replace('Z', '+00:00')).timestamp():
            continue
        for line in path.read_text().splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if (started <= record.get('timestamp', '') <= finished and
                    (record['event'] in watched or record.get('level') in ('warning', 'error'))):
                fields = record.get('fields', {})
                events.append(dict(timestamp=record['timestamp'], event=record['event'], level=record.get('level'),
                    fields={k: fields[k] for k in ('source', 'trigger', 'command', 'lookup', 'attempt',
                            'navigation_id', 'tab', 'section', 'duration_ms', 'phase', 'kind') if k in fields}))
    events.sort(key=lambda r: r['timestamp'])
    checks = {
        'no_new_lookup': not any(r['event'] == 'lookup_started' for r in events),
        'no_recovery_loop': not any(r['event'] == 'mimo_network_changed' and
                                  r['fields'].get('source') == 'infrastructure_recovered' for r in events),
        'no_warning_or_error': not any(r['level'] in ('warning', 'error') for r in events),
        'no_unexpected_control_or_failure_event': not any(r['event'] in abnormal or
                    r['event'] in ('mimo_core_command_started', 'mimo_gate_closed') for r in events),
        'expected_verdict_and_monitor_ready': bool(settled(after)),
        'same_core': before['instanceID'] == after['instanceID'],
        'settings_unchanged': before['settings'] == after['settings'],
        'routing_unchanged': before['routing']['configuration'] == after['routing']['configuration'],
        'health_checks_continue': after['routing']['infrastructure']['checkedAt'] >
                                 before['routing']['infrastructure']['checkedAt'],
        'rejected_observation_retained': before['routing'].get('blockingIP') == after['routing'].get('blockingIP'),
        'observed_ip_unchanged': before['routing'].get('observedIP') == after['routing'].get('observedIP'),
    }
    if args.require_navigation:
        requested = [r for r in events if r['event'] == 'mimo_navigation_requested']
        completed = {r['fields']['navigation_id'] for r in events if r['event'] == 'mimo_navigation_window_updated'}
        checks.update(
            both_tabs_observed={r['fields']['tab'] for r in requested} == {'Dashboard', 'Settings'},
            all_settings_sections_observed={'Proxy', 'Bypass', 'Allowed IPs', 'Monitoring', 'General', 'Maintenance'} <=
                {r['fields']['section'] for r in requested if r['fields']['tab'] == 'Settings'},
            every_navigation_completed=bool(requested) and all(r['fields']['navigation_id'] in completed for r in requested),
        )
    report = dict(mode=mode, family=family, verdict=args.verdict, started=started, finished=finished,
                  seconds=args.seconds, passed=all(checks.values()), checks=checks, events=events)
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
