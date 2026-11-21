#!/usr/bin/env python3
"""Real native-writer lock failure and automatic recovery in the installed VM."""
import fcntl, hashlib, json, os, sys, tempfile, time
from pathlib import Path
from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events
from upgrade_test import FLAGS, HELPER, read_settings
BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0 and command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = read_settings(); mode = json.loads(original['service.routing'])['mode']
    assert mode in ('rule', 'global')
    flags = json.loads(FLAGS.read_bytes())
    credential = command(BASE/'acceptance-client', 'credential-digest').stdout.strip()
    build = json.loads((BASE/'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-native-recovery-', dir='/var/tmp'))
    print('Evidence:', root, flush=True)
    passed = []; errors = []; descriptor = None

    def client(*args): return command(BASE/'acceptance-client', *args, timeout=70)
    def active():
        value = json.loads(client('state').stdout)['routing']
        return value['phase'] == 'active' and value.get('effectiveMode') == mode
    def wait(predicate, label):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.2)
        raise AssertionError(label + ' timed out')
    def record(label): passed.append(label); print('PASS:', label, flush=True)

    try:
        wait(active, 'original protected mode')
        baseline = offsets(LOGS)
        descriptor = os.open('/Library/Application Support/Mimo/Runtime/native-transport.lock',
                             os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        wait(lambda: not active() and any(v['event'] == 'mimo_native_transport_failed' for v in events(LOGS, baseline)), 'real native update failure closes')
        # Hold past one infrastructure-monitor interval. No PF policy is edited.
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            assert not active(), 'Failed native rules reopened protected access'
            time.sleep(.3)
        rows = events(LOGS, baseline)
        assert not any(v['event'] == 'mimo_traffic_opened' for v in rows)
        denied = command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail', '--noproxy', '*',
                         '--max-time', '4', '--head', 'https://1.1.1.1/', check=False)
        assert denied.returncode != 0, 'Ordinary HTTPS passed failed native recovery'
        record('native-update-failure-remains-blocked-through-infrastructure-check-and-denies-HTTPS')
        released = offsets(LOGS)
        os.close(descriptor); descriptor = None
        # No Refresh: a successful native update must enable automatic recovery.
        wait(lambda: active() and any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, released)), 'automatic native recovery')
        rows = events(LOGS, released)
        assert any(v['event'] == 'mimo_network_changed' and v['fields'].get('source') == 'infrastructure_recovered' for v in rows)
        for event in ('mimo_private_probe_ready', 'mimo_readiness_passed', 'mimo_exit_ip_approved'):
            assert any(v['event'] == event for v in rows), 'Missing fresh recovery proof: ' + event
        command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail', '--noproxy', '*',
                '--max-time', '8', '--head', 'https://1.1.1.1/')
        (root/'private-events.json').write_text(json.dumps(events(LOGS, baseline)))
        record('successful-native-update-automatically-rechecks-IP-and-critical-state-before-reopening')
    except Exception as error:
        errors.append(type(error).__name__ + ': ' + str(error)); print('FAIL:', errors[-1], flush=True)
    finally:
        if descriptor is not None: os.close(descriptor)
        try:
            if not active(): client('refresh')
            wait(active, 'original mode restored')
            assert configuration_values(read_settings()) == configuration_values(original)
            assert json.loads(FLAGS.read_bytes()) == flags
            assert client('credential-digest').stdout.strip() == credential
            record('original-Rule-settings-credential-and-service-intent-restored')
        except Exception as error: errors.append('Restoration: ' + str(error))
        (root/'report.json').write_text(json.dumps(dict(success=not errors, passed=passed, errors=errors,
            packageSHA256=build['packageSHA256'], helperSHA256=build['helperSHA256'],
            scope='Installed normal arm64 Release in mimo-vm. Actual bounded native-writer lock contention; no PF rule weakened, helper replaced, or synthetic event injected. Recovery uses no manual Refresh.'), indent=2) + '\n')
    return int(bool(errors))


if __name__ == '__main__': sys.exit(main())
