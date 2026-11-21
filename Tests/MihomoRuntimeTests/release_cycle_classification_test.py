#!/usr/bin/env python3
"""Focused installed-release transitions and real route changes in mimo-vm."""
import json
import os
from pathlib import Path
import re
import sys
import time
from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import DESTINATION, LOGS, offsets, events
from upgrade_test import FLAGS, read_settings

BASE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get('MIMO_CYCLE_EVIDENCE', '/Users/jay/mimo-tests/cycle-fix'))


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    phase = sys.argv[1]
    assert phase in ('before', 'after')
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True)
    saved = read_settings()
    original_mode = json.loads(saved['service.routing'])['mode']
    flags = json.loads(FLAGS.read_bytes())
    passed = []
    added = False

    def client(*args):
        return command(BASE/'acceptance-client', *args, timeout=75)

    def active(mode):
        value = json.loads(client('state').stdout)
        routing = value['routing']
        return routing['phase'] == 'active' and routing.get('effectiveMode') == mode and not routing.get('backgroundVerification') and 'ready' in value['status']

    def wait(predicate, label):
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.15)
        raise AssertionError(label + ' timed out')

    def record(label):
        passed.append(label)
        print('PASS:', label, flush=True)

    credential = client('credential-digest').stdout.strip()
    gateway = re.search(r'gateway: (\S+)', command('/sbin/route', '-n', 'get', 'default').stdout)[1]
    assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
    try:
        for iteration in range(1 if phase == 'before' else 2):
            client('mode', 'direct')
            wait(lambda: active('direct'), 'Direct readiness')
            time.sleep(1)
            baseline = offsets(LOGS)
            client('mode', 'rule')
            apply_check = os.environ.get('MIMO_LOCATION_APPLY_CHECK')
            if phase == 'after' and apply_check:
                wait(lambda: any(r['event'] == 'mimo_parallel_preparation_started' for r in events(LOGS, baseline)), 'early preparation')
                command(apply_check)
            wait(lambda: active('rule'), 'Rule readiness')
            rows = events(LOGS, baseline)
            followups = [r for r in rows if r['event'] == 'mimo_network_changed' and r['fields'].get('source') == 'deferred_events']
            if phase == 'before':
                assert any(not r['fields'].get('detail') for r in followups), 'previous-build issue did not reproduce'
                record('previous published Direct-to-Rule transition reproduces an unattributed follow-up')
            else:
                assert not followups, 'owned tunnel update still requests a follow-up'
                assert sum(r['event'] == 'mimo_private_probe_ready' for r in rows) == 1, 'more than one exit-IP pass'
                assert sum(r['event'] == 'mimo_traffic_opened' for r in rows) == 1
                profile_events = [(index, row) for index, row in enumerate(rows)
                                  if row['event'] in ('mimo_final_profile_loaded', 'mimo_final_profile_reused')]
                assert profile_events, 'final profile preparation was not recorded'
                for index, row in profile_events:
                    assert any(previous['event'] == 'mimo_profile_prerequisites_ready'
                               and previous['fields'].get('attempt') == row['fields'].get('attempt')
                               for previous in rows[:index]), 'profile was prepared before native firewall/provider prerequisites'
                assert any(r['event'] == 'mimo_cycle_owned_event_ignored' for r in rows)
                if apply_check:
                    assert any(r['event'] == 'network_location_metadata_ignored' for r in rows), 'apply metadata was not filtered by the installed service'
                record('Direct-to-Rule transition ' + str(iteration + 1) + ' ignores owned setup notifications and opens after one IP pass')
                record('native firewall/provider prerequisites precede final profile preparation for transition ' + str(iteration + 1))
        if phase == 'after':
            baseline = offsets(LOGS)
            command('/sbin/route', '-n', 'add', '-host', DESTINATION, gateway)
            added = True
            wait(lambda: active('rule') and any(r['event'] == 'mimo_traffic_opened' for r in events(LOGS, baseline)), 'real route verification')
            rows = events(LOGS, baseline)
            assert any(r['event'] == 'mimo_gate_closed' for r in rows)
            assert sum(r['event'] == 'mimo_traffic_opened' for r in rows) == 1
            assert not any(r['event'] == 'mimo_network_changed' and r['fields'].get('source') == 'deferred_events' for r in rows)
            record('real route change still blocks and verifies once')

            baseline = offsets(LOGS)
            command('/sbin/route', '-n', 'delete', '-host', DESTINATION)
            added = False
            wait(lambda: any(r['event'] == 'mimo_parallel_preparation_started' for r in events(LOGS, baseline)), 'in-flight verification')
            command('/sbin/route', '-n', 'add', '-host', DESTINATION, gateway)
            added = True
            wait(lambda: any(r['event'] == 'mimo_cycle_event_deferred' for r in events(LOGS, baseline)), 'held external route event')
            wait(lambda: active('rule') and any(r['event'] == 'mimo_traffic_opened' for r in events(LOGS, baseline)), 'follow-up opening')
            rows = events(LOGS, baseline)
            followups = [r for r in rows if r['event'] == 'mimo_network_changed' and r['fields'].get('source') == 'deferred_events']
            assert len(followups) == 1 and followups[0]['fields'].get('detail')
            assert sum(r['event'] == 'mimo_traffic_opened' for r in rows) == 1
            record('external route change during verification keeps PF blocked for one attributed follow-up; stale pass never opens')
    finally:
        client('mode', original_mode)
        if added:
            command('/sbin/route', '-n', 'delete', '-host', DESTINATION)
        wait(lambda: active(original_mode), 'original mode restoration')
        assert configuration_values(read_settings()) == configuration_values(saved)
        assert json.loads(FLAGS.read_bytes()) == flags
        assert client('credential-digest').stdout.strip() == credential
        record('original mode, proxy, allowlist, credentials and service intent restored; temporary route removed')
        (ROOT/(phase+'-summary.json')).write_text(json.dumps({'environment':'mimo-vm','phase':phase,'checks':passed}, indent=2)+'\n')


if __name__ == '__main__':
    main()
