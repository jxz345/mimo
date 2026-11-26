#!/usr/bin/env python3
"""Audit real native family switches without performing UI actions.

Run in mimo-vm, keep the mode and allowlist unchanged, switch family twice
with the GUI and then leave it settled for at least 35 seconds. Every extra
provider attempt must have a recorded provider failure/rotation, not a new
network event. Raw state and addresses are never exported.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import subprocess
import time


def audit(records, switches, verdict='rejected'):
    def matching(event):
        return [r for r in records if r['event'] == event]

    starts = matching('lookup_started')
    finishes = matching('lookup_finished')
    failures = matching('lookup_failed')
    rotations = matching('provider_rotated_after_failure')
    successful = matching('lookup_succeeded')
    edits = matching('mimo_proxy_catalog_changed')
    commands = Counter(r['fields']['command'] for r in matching('mimo_core_command_started'))
    bad = {'mimo_network_changed', 'mimo_network_event_dispatch', 'mimo_command_rejected',
           'mimo_core_command_failed', 'mimo_cycle_event_deferred', 'mimo_liveness_lost',
           'daemon_client_disconnected', 'shared_settings_changed', 'shared_credential_changed',
           'mimo_verification_audit_failed'}
    if verdict == 'rejected':
        bad.add('mimo_traffic_opened')
    checks = dict(
        exact_user_changes=len(edits) == switches and all(r['fields'].get('operation') == 'configureRouting'
            and r['fields'].get('reload') == 'true' for r in edits),
        one_settings_check_per_change=sum(r['fields'].get('trigger') == 'settings_changed' for r in starts) == switches,
        only_explained_provider_followups=len(starts) == switches + len(rotations) and len(failures) == len(rotations)
            and all(r['fields'].get('trigger') in ('settings_changed', 'recheck') for r in starts),
        all_lookups_finished=Counter(r['fields']['lookup'] for r in starts) == Counter(r['fields']['lookup'] for r in finishes),
        one_precommit_close_per_change=commands['close'] == switches + len(failures),
        each_lookup_has_one_preparation=commands['prepare'] == len(starts),
        each_success_has_one_approval=commands['approve'] == len(successful),
        successful_checks_have_expected_verdict=(
            len(matching('mimo_exit_ip_rejected')) == len(successful) if verdict == 'rejected' else
            len(matching('mimo_traffic_opened')) == len(successful) and not matching('mimo_exit_ip_rejected')),
        no_unexplained_event=not any(r['event'] in bad for r in records),
        no_unexplained_warning=not any(r.get('level') in ('warning', 'error') and
            r['event'] not in ('lookup_failed', 'indicator_error_set') for r in records),
    )
    return dict(checks=checks, counts=dict(user_changes=len(edits), lookups=len(starts),
        provider_failures=len(failures), provider_rotations=len(rotations), commands=dict(commands)),
        passed=all(checks.values()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controls', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--seconds', type=float, default=110)
    parser.add_argument('--switches', type=int, default=2)
    parser.add_argument('--verdict', choices=('rejected', 'approved'), default='rejected')
    args = parser.parse_args()
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)

    def state():
        r = subprocess.run([args.controls], capture_output=True, text=True, check=True, timeout=15)
        return json.loads(r.stdout)['state']

    def now():
        return datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

    def settled(value):
        r = value['routing']
        if value['status'] != {'ready': {}}:
            return False
        if args.verdict == 'rejected':
            return r['phase'] == 'blocked' and bool(r.get('blockingIP'))
        return (r['phase'] == 'active' and r.get('effectiveMode') == r['configuration']['mode']
                and not r.get('blockingIP') and r.get('observedIP', {}).get('address') in
                value['settings']['allowlist']['addresses'])

    before = state()
    assert before['routing']['configuration']['mode'] in ('rule', 'global')
    assert settled(before), 'Requires a settled ' + args.verdict + ' exit'
    started = now()
    time.sleep(args.seconds)
    after = state()
    finished = now()
    paths = list(Path('/Library/Logs/Mimo').glob('runtime-*.jsonl'))
    paths += list(Path('/Users').glob('*/Library/Application Support/Mimo/Logs/runtime-*.jsonl'))
    records = []
    allowed_fields = ('processRole', 'pid', 'source', 'trigger', 'lookup', 'attempt', 'sequence',
        'command', 'operation', 'revision', 'family', 'mode', 'reload', 'provider', 'from', 'to',
        'category', 'outcome', 'phase', 'kind', 'duration_ms')
    for path in paths:
        for line in path.read_text().splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if started <= r.get('timestamp', '') <= finished:
                records.append(dict(timestamp=r['timestamp'], event=r['event'], level=r.get('level'),
                    fields={k: v for k, v in r.get('fields', {}).items() if k in allowed_fields}))
    records.sort(key=lambda r: r['timestamp'])
    report = audit(records, args.switches, args.verdict)
    last = max((r['timestamp'] for r in records if r['event'] == 'lookup_finished'), default=finished)
    quiet_seconds = (datetime.fromisoformat(finished.replace('Z', '+00:00')) -
        datetime.fromisoformat(last.replace('Z', '+00:00'))).total_seconds()
    report['checks'].update(
        settled_for_35_seconds=quiet_seconds >= 35,
        monitor_ready=after['status'] == {'ready': {}},
        expected_verdict_retained=settled(after),
        original_mode_and_family_restored=before['routing']['configuration'] == after['routing']['configuration'],
        same_core=before['instanceID'] == after['instanceID'],
        same_settings=before['settings'] == after['settings'],
        health_checks_continue=after['routing']['infrastructure']['checkedAt'] > before['routing']['infrastructure']['checkedAt'],
    )
    report.update(started=started, finished=finished, mode=before['routing']['configuration']['mode'], verdict=args.verdict,
        quiet_seconds=quiet_seconds, passed=all(report['checks'].values()), events=records)
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'events'}, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
