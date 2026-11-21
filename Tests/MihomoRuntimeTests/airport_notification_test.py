#!/usr/bin/env python3
"""Replay real configd AirPort notifications against installed Mimo in mimo-vm.

The VM has no Wi-Fi radio. A reserved nonexistent interface supplies status
values to the normal notification path; a real host route checks protection.
"""
import json
import os
from pathlib import Path
import sys
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import DESTINATION, LOGS, offsets, events
from upgrade_test import FLAGS, read_settings

BASE = Path(__file__).resolve().parent
ROOT = Path('/Users/jay/mimo-tests/airport')
KEY = 'State:/Network/Interface/mimowifi0/AirPort'


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    expected = sys.argv[1]
    assert expected in ('before', 'after')
    os.umask(0o077)
    saved = read_settings()
    original_mode = json.loads(saved['service.routing'])['mode']
    flags = FLAGS.read_bytes()
    passed = []
    route_added = False

    def client(*args):
        return command(BASE/'acceptance-client', *args, timeout=75)

    def fixture(*args):
        command(BASE/'airport-state-fixture', *args)

    def state():
        return json.loads(client('state').stdout)

    def active(mode):
        value = state(); routing = value['routing']
        return routing['phase'] == 'active' and routing.get('effectiveMode') == mode and not routing.get('backgroundVerification') and 'ready' in value['status']

    def wait(predicate, label):
        end = time.monotonic() + 60
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(.2)
        raise AssertionError(label + ' timed out')

    def record(label):
        passed.append(label)
        print('PASS:', label, flush=True)

    credential = client('credential-digest').stdout.strip()
    try:
        fixture('connected')
        time.sleep(1)
        client('mode', 'rule')
        wait(lambda: active('rule'), 'Rule approval')
        time.sleep(1)
        baseline = offsets(LOGS)
        if expected == 'before':
            fixture('timestamp', '2')
            wait(lambda: any(r['event'] == 'mimo_network_changed' and KEY in r.get('fields', {}).get('detail', '') for r in events(LOGS, baseline)), 'old-build AirPort trigger')
            wait(lambda: active('rule'), 'old-build reopen')
            rows = events(LOGS, baseline)
            assert any(r['event'] == 'network_airport_connection_changed' and r['fields']['fields'] == 'AutoJoinTimestamp' for r in rows)
            record('previous published build reproduces block/check/open for AutoJoinTimestamp alone')
        else:
            for operation in ['timestamp', 'timestamp-busy', 'telemetry']:
                baseline = offsets(LOGS)
                for i in range(2, 12):
                    fixture(operation, str(i))
                    time.sleep(.15)
                time.sleep(1)
                rows = events(LOGS, baseline)
                assert any(r['event'] == 'network_airport_telemetry_ignored' and 'AutoJoinTimestamp' in r['fields']['fields'] for r in rows)
                assert not any(r['event'] in ('mimo_network_changed', 'mimo_gate_closed', 'mimo_cycle_event_deferred') for r in rows)
                assert active('rule')
                record('ten ' + operation + ' updates cause no block, recheck or deferred cycle')

            import re
            gateway = re.search(r'gateway: (\S+)', command('/sbin/route', '-n', 'get', 'default').stdout)[1]
            assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
            baseline = offsets(LOGS)
            command('/sbin/route', '-n', 'add', '-host', DESTINATION, gateway)
            route_added = True
            wait(lambda: any(r['event'] == 'mimo_gate_closed' for r in events(LOGS, baseline)), 'real route closure')
            for i in range(12, 15):
                fixture('timestamp-busy', str(i))
            wait(lambda: active('rule') and any(r['event'] == 'mimo_traffic_opened' for r in events(LOGS, baseline)), 'real route approval')
            time.sleep(1)
            rows = events(LOGS, baseline)
            assert sum(r['event'] == 'mimo_traffic_opened' for r in rows) == 1
            assert not any(r['event'] == 'mimo_network_changed' and r.get('fields', {}).get('source') == 'deferred_events' for r in rows)
            assert not any(r['event'] == 'mimo_cycle_event_deferred' and KEY in r.get('fields', {}).get('detail', '') for r in rows)
            record('real route change blocks and verifies once; concurrent timestamp/Busy changes add no follow-up')

            for operation, field in [('association', 'SSID'), ('power', 'Power Status')]:
                baseline = offsets(LOGS)
                fixture(operation)
                wait(lambda: any(r['event'] == 'mimo_network_changed' and KEY in r.get('fields', {}).get('detail', '') for r in events(LOGS, baseline)), operation + ' change trigger')
                wait(lambda: active('rule') and any(r['event'] == 'mimo_traffic_opened' for r in events(LOGS, baseline)), operation + ' approval')
                rows = events(LOGS, baseline)
                assert any(r['event'] == 'network_airport_connection_changed' and field in r['fields']['fields'] for r in rows)
                assert not any('Mimo other fixture' in json.dumps(r) for r in rows)
                record(operation + ' metadata still triggers protection without logging Wi-Fi identifiers')
    finally:
        client('mode', original_mode)
        if route_added:
            command('/sbin/route', '-n', 'delete', '-host', DESTINATION)
        fixture('remove')
        wait(lambda: active(original_mode), 'original mode restoration')
        assert configuration_values(read_settings()) == configuration_values(saved)
        assert json.loads(FLAGS.read_bytes()) == json.loads(flags)
        assert client('credential-digest').stdout.strip() == credential
        record('original mode, proxy, allowlist, credential and service intent restored; fixture removed')
        (ROOT/(expected+'-summary.json')).write_text(json.dumps({'environment': 'mimo-vm', 'phase': expected, 'checks': passed}, indent=2)+'\n')


if __name__ == '__main__':
    main()
