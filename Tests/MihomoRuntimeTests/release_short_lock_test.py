#!/usr/bin/env python3
"""Short-lock correction plus retained N1–N3, installed Release in mimo-vm."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import threading

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events, DESTINATION
from upgrade_test import FLAGS, HELPER, RUNTIME, read_settings
from monotonic_uptime import uptime_ms

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0 and command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    original = read_settings()
    flags = json.loads(FLAGS.read_bytes())
    mode = json.loads(original['service.routing'])['mode']
    assert mode in ('rule', 'global')
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-short-lock-', dir='/var/tmp'))
    print('Evidence:', root, flush=True)
    passed, errors, trials = [], [], []
    fd, added, checker = None, False, None

    def client(*args):
        return command(BASE / 'acceptance-client', *args, timeout=50)

    credential = client('credential-digest').stdout.strip()

    def active():
        value = json.loads(client('state').stdout)['routing']
        return value['phase'] == 'active' and value.get('effectiveMode') == mode and not value.get('backgroundVerification')

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

    def hold(name):
        descriptor = os.open(str(RUNTIME / name), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return descriptor

    def priority_held():
        descriptor = os.open(str(RUNTIME / 'pf-revocation.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return False
            except BlockingIOError:
                return True
        finally:
            os.close(descriptor)

    try:
        wait(active, 'initial verified mode')
        assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
        gateway = re.search(r'gateway: (\S+)', command('/sbin/route', '-n', 'get', 'default').stdout)[1]
        # A real independent scan is deliberately in progress during the timed
        # route event. Its read-only snapshot must not hold up PF revocation.
        scan_path = root / 'timed-checker-private.txt'
        scan_output = scan_path.open('w')
        checker = subprocess.Popen(['/usr/bin/perl', '/Library/Application Support/Mimo/Guard/pf-guard.pl', '--check'], stdout=scan_output, stderr=scan_output)
        wait(lambda: 'mimo_pf_scan_started' in scan_path.read_text(), 'independent unlocked scan starts', 20)
        baseline = offsets(LOGS)
        started = uptime_ms()
        route(True)
        added = True
        wait(lambda: any(v['event'] == 'mimo_background_audit_passed' for v in events(LOGS, baseline)) and active(), 'warm route verification', 25)
        rows = events(LOGS, baseline)
        stages = [v['fields'] for v in rows if v['event'] == 'mimo_transition_timing']
        span = lambda name: next(v for v in stages if v['stage'] == name)
        assert any(v['event'] == 'mimo_traffic_opened' and v['fields'].get('optimistic') == 'true' for v in rows)
        assert int(span('barrier_and_confirmation')['end_uptime_ms']) <= int(span('permit_private_probe')['start_uptime_ms'])
        assert 'deny_publish' in [v['stage'] for v in stages]
        assert checker.wait(timeout=25) == 75, 'Overlapping scan accepted a stale PF snapshot'
        checker = None
        scan_output.close()
        assert 'mimo_infrastructure_deferred' in scan_path.read_text()
        trials.append(dict(event='real-route-added', eventRequestedUptimeMS=started,
                           firewallOpenSeconds=round((int(span('open_gate')['end_uptime_ms']) - started) / 1000, 3),
                           verifiedSeconds=round((int(span('background_audit')['end_uptime_ms']) - started) / 1000, 3), stages=stages))
        (root / 'warm-private-events.json').write_text(json.dumps(rows))
        record('warm-route-during-real-unlocked-scan-opens-and-stale-checker-snapshot-is-discarded')

        fd = hold('pf-mutation.lock')
        baseline = offsets(LOGS)
        route(False)
        added = False
        wait(priority_held, 'revocation owns priority admission', 1)
        with (root / 'checker-private.txt').open('w') as output:
            checker = subprocess.Popen(['/usr/bin/perl', '/Library/Application Support/Mimo/Guard/pf-guard.pl', '--check'], stdout=output, stderr=output)
            time.sleep(2.6)
            assert priority_held(), 'Revocation abandoned its admission at the old two-second timeout'
            assert not any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, baseline))
            os.close(fd)
            fd = None
            wait(lambda: any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, baseline)) and active(), 'recovery after held PF mutation')
            assert checker.wait(timeout=30) in (0, 75)
            checker = None
        rows = events(LOGS, baseline)
        waits = [int(v['fields']['duration_ms']) for v in rows if v['event'] == 'mimo_transition_timing' and v['fields'].get('stage') == 'deny_mutation_wait']
        assert waits and max(waits) >= 2500
        assert not any(v['event'] == 'mimo_gate_closed' and v['fields'].get('confirmed') == 'false' for v in rows)
        record('revocation-retains-priority-past-two-seconds-and-recovers-with-real-checker-contention')

        for cycle in (1, 2):
            baseline = offsets(LOGS)
            fd = hold('native-transport.lock')
            wait(lambda: not active() and any(v['event'] == 'mimo_native_transport_failed' for v in events(LOGS, baseline)), 'native failure closes cycle ' + str(cycle), 20)
            permission = command('/sbin/pfctl', '-a', 'com.apple/000.mimo/permission', '-sr').stdout
            assert not permission.strip(), 'Native failure retains a traffic grant'
            os.close(fd)
            fd = None
            wait(lambda: any(v['event'] == 'mimo_verification_recovery_completed' for v in events(LOGS, baseline)) and active(), 'automatic native full recovery cycle ' + str(cycle), 40)
            rows = events(LOGS, baseline)
            assert any(v['event'] == 'mimo_network_changed' and v['fields'].get('source') == 'native_recovered' for v in rows)
            assert any(v['event'] == 'mimo_traffic_opened' and v['fields'].get('optimistic') == 'false' for v in rows)
            record('native-failure-cycle-' + str(cycle) + '-blocks-and-clears-pending-state-after-full-recovery')

        baseline = offsets(LOGS)
        subprocess.run(['/usr/sbin/scutil'], input='remove State:/Network/Service/com.example.exitipmonitor.dns/DNS\nquit\n', text=True, check=True, stdout=subprocess.DEVNULL)
        wait(lambda: any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, baseline)) and active(), 'removed DNS entry requires full verification', 45)
        rows = events(LOGS, baseline)
        opens = [v for v in rows if v['event'] == 'mimo_traffic_opened']
        assert opens and opens[0]['fields'].get('optimistic') == 'false'
        command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail', '--noproxy', '*', '--max-time', '8', '--head', 'https://1.1.1.1/')
        record('removed-protected-DNS-entry-rejects-optimistic-reuse-and-recovers-through-full-verification')

        baseline = offsets(LOGS)
        command('/bin/launchctl', 'kickstart', '-k', 'system/com.example.exitipmonitor.supervisor', timeout=25)
        def resolver_absent():
            result = subprocess.run(['/usr/sbin/scutil'], input='show State:/Network/Service/com.example.exitipmonitor.dns/DNS\nquit\n', text=True, capture_output=True, check=True)
            return 'No such key' in result.stdout
        wait(resolver_absent, 'recreated DNS entry disappears with its owning supervisor', 3)
        wait(lambda: any(v['event'] == 'mimo_supervisor_ready' for v in events(LOGS, baseline)) and active(), 'supervisor restart with temporary DNS reacquisition', 60)
        record('recreated-DNS-entry-remains-temporary-and-supervisor-restart-recovers')

        # Exercise the checker's repair branch too. Temporarily stop the real
        # supervisor so its watchdog cannot repair the deliberate child loss
        # first. Independent PF protection and the real engine remain running.
        baseline = offsets(LOGS)
        text = command('/bin/launchctl', 'print', 'system/com.example.exitipmonitor.supervisor').stdout
        supervisor = int(re.search(r'^\s*pid = (\d+)', text, re.M)[1])
        resume = threading.Timer(15, lambda: os.kill(supervisor, signal.SIGCONT))
        os.kill(supervisor, signal.SIGSTOP)
        resume.start()
        try:
            command('/sbin/pfctl', '-a', 'com.apple/000.mimo/open-policy', '-F', 'rules')
            command('/usr/bin/perl', '/Library/Application Support/Mimo/Guard/pf-guard.pl', '--check', timeout=25)
            assert (RUNTIME / 'gate.state').read_text() == 'blocked'
            assert 'block drop out quick all' in command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout
        finally:
            os.kill(supervisor, signal.SIGCONT)
            resume.cancel()
        wait(lambda: any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, baseline)) and active(), 'full recovery after independent repair', 60)
        assert any(v['event'] == 'mimo_traffic_opened' and v['fields'].get('optimistic') == 'false' for v in events(LOGS, baseline))
        record('independent-checker-repairs-actual-policy-loss-and-requires-full-recovery')
    except Exception as error:
        (root / 'failure-private.txt').write_text(repr(error))
        errors.append(type(error).__name__ + ': ' + str(error) if isinstance(error, AssertionError) else type(error).__name__ + ': details retained privately')
        print('FAIL:', errors[-1], flush=True)
    finally:
        if fd is not None:
            os.close(fd)
        if checker is not None:
            checker.wait(timeout=35)
        if added:
            route(False)
        try:
            if not active():
                client('refresh')
            wait(active, 'restored protected mode')
            assert configuration_values(read_settings()) == configuration_values(original)
            assert json.loads(FLAGS.read_bytes()) == flags
            assert client('credential-digest').stdout.strip() == credential
            record('original-mode-settings-credential-and-service-intent-restored')
        except Exception as error:
            errors.append('Restoration: ' + type(error).__name__)
        report = dict(success=not errors, passed=passed, errors=errors, trials=trials,
                      packageSHA256=build['packageSHA256'], helperSHA256=build['helperSHA256'], guiSHA256=build['guiSHA256'],
                      scope='Seven focused checks in installed normal Release in mimo-vm: warm route timeline overlapping an actual unlocked checker scan with stale-snapshot rejection; PF-lock contention; two native-writer failures/recoveries; actual DNS-entry removal; recreated temporary DNS ownership across actual supervisor restart; independent repair of actual child-policy loss while supervisor is briefly SIGSTOPed with timed/finally resume. No broad suite, replacement helper, synthetic notification or sleep claim. Missing-tunnel rejection not independently fault-qualified.')
        (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return int(bool(errors))


if __name__ == '__main__':
    sys.exit(main())
