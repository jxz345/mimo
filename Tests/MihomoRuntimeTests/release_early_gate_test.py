#!/usr/bin/env python3
"""Three focused installed-Release cases in mimo-vm; real route notifications/PF."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events, DESTINATION
from upgrade_test import FLAGS, HELPER, RUNTIME, read_settings
from monotonic_uptime import uptime_ms

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    original = read_settings()
    flags = json.loads(FLAGS.read_bytes())
    mode = json.loads(original['service.routing'])['mode']
    assert mode in ('rule', 'global')
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-early-gate-', dir='/var/tmp'))
    print('Evidence:', root, flush=True)
    passed, errors, trials = [], [], []
    fd, added, direct = None, False, None

    def client(*args):
        return command(BASE / 'acceptance-client', *args, timeout=50)

    credential = client('credential-digest').stdout.strip()

    def active(selected=mode):
        value = json.loads(client('state').stdout)['routing']
        return value['phase'] == 'active' and value.get('effectiveMode') == selected and not value.get('backgroundVerification')

    def wait(predicate, label, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.03)
        raise AssertionError(label + ' timed out')

    def record(label):
        passed.append(label)
        print('PASS:', label, flush=True)

    def route(add):
        command('/sbin/route', '-n', 'add' if add else 'delete', '-host', DESTINATION, *([gateway] if add else []))

    def https():
        command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail',
                '--noproxy', '*', '--max-time', '8', '--head', 'https://1.1.1.1/')

    try:
        wait(active, 'initial verified mode')
        assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
        gateway = re.search(r'gateway: (\S+)', command('/sbin/route', '-n', 'get', 'default').stdout)[1]
        baseline = offsets(LOGS)
        started = uptime_ms()
        route(True)
        added = True
        wait(lambda: any(v['event'] == 'mimo_background_audit_passed' for v in events(LOGS, baseline)) and active(), 'warm early-gate opening and audit', 25)
        rows = events(LOGS, baseline)
        stages = [v['fields'] for v in rows if v['event'] == 'mimo_transition_timing']
        assert any(v['event'] == 'mimo_network_event_dispatch' and v['fields'].get('early_gate') == 'true' for v in rows)
        assert any(v['event'] == 'mimo_traffic_opened' and v['fields'].get('optimistic') == 'true' for v in rows)
        assert sum(v['stage'] == 'barrier_and_confirmation' for v in stages) == 1
        span = lambda name: next(v for v in stages if v['stage'] == name)
        blocking, cleanup, probe = span('barrier_and_confirmation'), span('connection_cleanup'), span('permit_private_probe')
        assert int(blocking['start_uptime_ms']) < int(cleanup['end_uptime_ms']) and int(cleanup['start_uptime_ms']) < int(blocking['end_uptime_ms'])
        assert int(blocking['end_uptime_ms']) <= int(probe['start_uptime_ms'])
        trials.append(dict(event='real-route-added', eventRequestedUptimeMS=started,
                           firewallOpenSeconds=round((int(span('open_gate')['end_uptime_ms']) - started) / 1000, 3),
                           verifiedSeconds=round((int(span('background_audit')['end_uptime_ms']) - started) / 1000, 3), stages=stages))
        (root / 'warm-private-events.json').write_text(json.dumps(rows))
        https()
        record('early-route-gate-overlaps-preparation-shares-one-close-and-confirms-before-probe')

        # Real cross-process PF contention makes the early request wait. Direct
        # must cancel it, including a worker already queued before actor delivery.
        fd = os.open(str(RUNTIME / 'pf-mutation.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        baseline = offsets(LOGS)
        route(False)
        added = False
        wait(lambda: any(v['event'] == 'mimo_network_event_dispatch' and v['fields'].get('early_gate') == 'true' for v in events(LOGS, baseline)), 'early route dispatch while PF lock held', 1)
        with (root / 'direct-private-output.txt').open('w') as output:
            direct = subprocess.Popen([str(BASE / 'acceptance-client'), 'mode', 'direct'], stdout=output, stderr=output)
            time.sleep(.15)
            os.close(fd)
            fd = None
            assert direct.wait(timeout=50) == 0
            direct = None
        wait(lambda: active('direct'), 'Direct supersedes queued early closure')
        time.sleep(.4)
        assert (RUNTIME / 'gate.state').read_text() == 'direct'
        rows = events(LOGS, baseline)
        released = next(v for v in rows if v['event'] == 'mimo_direct_restored')
        supervisor = [v for v in rows if v['file'] == released['file']]
        index = supervisor.index(released)
        assert not any(v['event'] == 'mimo_transition_timing' and v['fields'].get('stage') in ('deny_permission', 'open_gate') for v in supervisor[index + 1:])
        https()
        record('Direct-cancels-an-early-close-queued-behind-the-real-PF-lock')

        baseline = offsets(LOGS)
        route(True)
        added = True
        wait(lambda: any(v['event'] == 'mimo_network_event_dispatch' for v in events(LOGS, baseline)), 'Direct route delivery')
        route(False)
        added = False
        time.sleep(.4)
        rows = events(LOGS, baseline)
        assert not any(v['event'] == 'mimo_network_event_dispatch' and v['fields'].get('early_gate') == 'true' for v in rows)
        assert not any(v['event'] == 'mimo_transition_timing' and v['fields'].get('stage') == 'deny_permission' for v in rows)
        assert active('direct') and (RUNTIME / 'gate.state').read_text() == 'direct'
        https()
        record('Direct-route-changes-do-not-start-PF-blocking')
    except Exception as error:
        (root / 'failure-private.txt').write_text(repr(error))
        errors.append(type(error).__name__ + ': ' + str(error) if isinstance(error, AssertionError) else type(error).__name__ + ': details retained privately')
        print('FAIL:', errors[-1], flush=True)
    finally:
        if fd is not None:
            os.close(fd)
        if direct is not None:
            direct.wait(timeout=50)
        if added:
            route(False)
        try:
            client('mode', mode)
            wait(active, 'restored protected mode')
            assert configuration_values(read_settings()) == configuration_values(original)
            assert json.loads(FLAGS.read_bytes()) == flags
            assert client('credential-digest').stdout.strip() == credential
            assert not (RUNTIME / 'infrastructure-repair').exists()
            record('original-mode-settings-credential-and-service-intent-restored')
        except Exception as error:
            errors.append('Restoration: ' + type(error).__name__)
        report = dict(success=not errors, passed=passed, errors=errors, trials=trials,
                      packageSHA256=build['packageSHA256'], helperSHA256=build['helperSHA256'], guiSHA256=build['guiSHA256'],
                      scope='Three focused installed Release cases in mimo-vm: actual route change/overlap, Direct during real PF-lock contention, Direct route exemption. No broad suite or synthetic event injection. SystemConfiguration early path and physical sleep not newly qualified.')
        (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return int(bool(errors))


if __name__ == '__main__':
    sys.exit(main())
