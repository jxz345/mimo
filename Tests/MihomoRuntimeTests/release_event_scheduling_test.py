#!/usr/bin/env python3
"""Small installed-Release check: real Tailscale toggles and real route events.

Run only inside mimo-vm. Preserve the saved proxy, allowlist, credentials,
service intent, mode and native Tailscale state. No injected notifications.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

from installed_acceptance_test import command
from monotonic_uptime import uptime_ms
from release_final_state import configuration_values
from release_network_progress_test import DESTINATION, LOGS, offsets, events
from release_tailnet_lifecycle_test import native
from upgrade_test import FLAGS, HELPER, RUNTIME, read_settings

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    assert HELPER.read_bytes() == Path('/Applications/Mimo.app/Contents/MacOS/mimo-core').read_bytes()
    command('/usr/bin/codesign', '--verify', '--deep', '--strict', '/Applications/Mimo.app')
    original = read_settings()
    original_mode = json.loads(original['service.routing'])['mode']
    flags = json.loads(FLAGS.read_bytes())
    original_native = json.loads(native('status', '--json').stdout)['BackendState']
    assert original_native in ('Running', 'Stopped')
    assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
    gateway = re.search(r'gateway: (\S+)', command('/sbin/route', '-n', 'get', 'default').stdout)[1]
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-event-scheduling-', dir='/var/tmp'))
    print('Evidence:', root, flush=True)
    passed, trials, errors = [], [], []
    added = False

    def client(*args):
        for attempt in range(5):
            result = command(BASE / 'acceptance-client', *args, timeout=45, check=False)
            if result.returncode == 0:
                return result
            if 'DaemonFailure.conflict' not in result.stderr or attempt == 4:
                (root / 'client-failure-private.txt').write_text(result.stdout + result.stderr)
                raise AssertionError('client command failed; diagnostic retained privately')
            time.sleep(.2)

    credential = client('credential-digest').stdout.strip()

    def state():
        return json.loads(client('state').stdout)

    def active(mode):
        value = state()
        routing = value['routing']
        return (routing['phase'] == 'active' and routing.get('effectiveMode') == mode
                and not routing.get('backgroundVerification') and 'ready' in value['status'])

    def wait(predicate, label, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.1)
        raise AssertionError(label + ' timed out')

    def record(name):
        passed.append(name)
        print('PASS:', name, flush=True)

    def set_mode(mode):
        if state()['routing']['configuration']['mode'] != mode:
            client('mode', mode)
        wait(lambda: active(mode), mode + ' verified')

    def route(add):
        nonlocal added
        command('/sbin/route', '-n', 'add' if add else 'delete', '-host', DESTINATION,
                *([gateway] if add else []))
        added = add

    def trial(name, mode, action, expected_native=None):
        baseline = offsets(LOGS)
        started = uptime_ms()
        action()
        last_count, last_change = -1, time.monotonic()

        def settled():
            nonlocal last_count, last_change
            rows = events(LOGS, baseline)
            count = sum(v['event'] == 'mimo_network_changed' for v in rows)
            if count != last_count:
                last_count, last_change = count, time.monotonic()
            if not count or time.monotonic() - last_change < 1.5 or not active(mode):
                return False
            if mode != 'direct' and not any(v['event'] == 'mimo_traffic_opened' for v in rows):
                return False
            if expected_native is not None:
                value = state()
                if value['settings']['tailscaleProviderEnabled'] != expected_native:
                    return False
                response = command('/usr/bin/curl', '--silent', '--fail', '--noproxy', '*', '--max-time', '2',
                                   'http://127.0.0.1:18766/provider.yaml', check=False)
                if (response.returncode == 0 and 'type: direct' in response.stdout) != expected_native:
                    return False
            return True

        wait(settled, name)
        rows = events(LOGS, baseline)
        (root / (name + '-private-events.json')).write_text(json.dumps(rows))
        in_flight = set()
        for row in rows:
            event, fields = row['event'], row.get('fields', {})
            if event == 'lookup_started':
                assert not in_flight, name + ': overlapping lookups'
                in_flight.add(fields['lookup'])
            elif event == 'lookup_finished':
                in_flight.discard(fields['lookup'])
            elif event == 'lookup_failed':
                assert 'Blocking traffic and preparing verification' not in fields.get('message', ''), name + ': spurious provider error'
        assert not in_flight, name + ': unfinished lookup'
        stages = [v['fields'] for v in rows if v['event'] == 'mimo_transition_timing']
        openings = [v for v in stages if v['stage'] == 'open_gate']
        if mode == 'direct':
            assert not openings and (RUNTIME / 'gate.state').read_text() == 'direct'
            assert not any(v['event'] == 'mimo_gate_closed' for v in rows)
        else:
            assert openings
            assert any(v['event'] == 'mimo_private_probe_ready' for v in rows)
            value = state()['routing']
            assert value['observedIP']['address'] in json.loads(original['service.settings'])['allowlist']['addresses']
        command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail',
                '--noproxy', '*', '--max-time', '8', '--head', 'https://1.1.1.1/')
        result = dict(name=name, networkEvents=last_count,
                      lookups=sum(v['event'] == 'lookup_started' for v in rows),
                      coalesced=sum(v['event'] == 'refresh_coalesced_in_flight' for v in rows),
                      probes=sum(v['event'] == 'mimo_private_probe_ready' for v in rows),
                      opens=len(openings), eventRequestedUptimeMS=started, stages=stages)
        if openings:
            result['firstOpenSeconds'] = round((int(openings[0]['end_uptime_ms']) - started) / 1000, 3)
            result['finalOpenSeconds'] = round((int(openings[-1]['end_uptime_ms']) - started) / 1000, 3)
        trials.append(result)
        record(name)
        print('Timing:', json.dumps({k: v for k, v in result.items() if k not in ('stages', 'eventRequestedUptimeMS')}), flush=True)

    try:
        set_mode('rule')
        enabled = original_native == 'Running'
        for index in range(2 if '--quick' in sys.argv else 4):
            enabled = not enabled
            trial('rule-tailnet-' + ('on-' if enabled else 'off-') + str(index + 1), 'rule',
                  lambda: native('up' if enabled else 'down'), enabled)
        set_mode('global')
        trial('global-real-route-added', 'global', lambda: route(True))
        route(False)
        wait(lambda: active('global'), 'route restoration')
        set_mode('direct')
        trial('direct-real-route-added', 'direct', lambda: route(True))
    except Exception as error:
        (root / 'failure-private.txt').write_text(repr(error))
        errors.append(str(error) if isinstance(error, AssertionError) else type(error).__name__ + ': private diagnostic')
        print('FAIL:', errors[-1], flush=True)
    finally:
        try:
            if added:
                route(False)
            current_native = json.loads(native('status', '--json').stdout)['BackendState']
            if current_native != original_native:
                native('up' if original_native == 'Running' else 'down')
            set_mode(original_mode)
            wait(lambda: state()['settings']['tailscaleProviderEnabled'] == (original_native == 'Running'), 'original provider state')
            assert configuration_values(read_settings()) == configuration_values(original)
            assert json.loads(FLAGS.read_bytes()) == flags
            assert client('credential-digest').stdout.strip() == credential
            assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
            record('original-mode-native-state-settings-credentials-and-service-intent-restored')
        except Exception as error:
            (root / 'restoration-failure-private.txt').write_text(repr(error))
            errors.append('restoration failed; see private diagnostic')
            print('FAIL:', errors[-1], flush=True)
        (root / 'report.json').write_text(json.dumps(dict(build=build, passed=passed, errors=errors, trials=trials), indent=2) + '\n')
    if errors:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
