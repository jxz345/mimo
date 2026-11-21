#!/usr/bin/env python3
"""A real invalid hostname must fail closed without changing saved credentials."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events
from upgrade_test import FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    original = read_settings()
    routing = json.loads(original['service.routing'])
    mode = routing['mode']
    assert mode in ('rule', 'global')
    flags = json.loads(FLAGS.read_bytes())
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-hostname-failure-', dir='/var/tmp'))
    original_proxy = root / 'original-proxy-private.json'
    original_proxy.write_text(json.dumps(routing['proxy']))
    invalid = dict(routing['proxy'], server='mimo-unresolvable-acceptance.invalid')
    bad_proxy = root / 'invalid-proxy-private.json'
    bad_proxy.write_text(json.dumps(invalid))
    print('Evidence:', root, flush=True)
    passed, errors = [], []

    def client(*args):
        return command(BASE / 'acceptance-client', *args, timeout=75)

    credential = client('credential-digest').stdout.strip()

    def state():
        return json.loads(client('state').stdout)['routing']

    def active():
        value = state()
        return value['phase'] == 'active' and value.get('effectiveMode') == mode and not value.get('backgroundVerification')

    def wait(predicate, label, seconds=100):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.1)
        raise AssertionError(label + ' timed out')

    def record(label):
        passed.append(label)
        print('PASS:', label, flush=True)

    try:
        wait(active, 'original verified mode')
        baseline = offsets(LOGS)
        client('proxy-metadata', bad_proxy)
        wait(lambda: any(v['event'] == 'mimo_bootstrap_permitted' for v in events(LOGS, baseline)), 'real restricted hostname bootstrap')
        wait(lambda: state()['phase'] == 'blocked' and any(
            v['event'] == 'mimo_gate_closed' and
            'could not be resolved through bootstrap DNS' in v['fields'].get('reason', '')
            for v in events(LOGS, baseline)), 'invalid hostname rejected by the real bootstrap resolver')
        rows = events(LOGS, baseline)
        names = [v['event'] for v in rows]
        assert names.index('mimo_hostname_bootstrap_ready') < names.index('mimo_bootstrap_permitted')
        assert not any(v['event'] in ('mimo_private_probe_ready', 'mimo_traffic_opened') for v in rows)
        assert state().get('effectiveMode') is None
        (root / 'private-events.json').write_text(json.dumps(rows))
        result = command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent',
                         '--fail', '--noproxy', '*', '--max-time', '4', '--head', 'https://1.1.1.1/', check=False)
        assert result.returncode != 0
        record('unresolvable-hostname-never-reaches-private-IP-probe-or-open-and-denies-ordinary-HTTPS')
        record('previous-TUN-removed-under-closed-PF-before-restricted-bootstrap-DNS')
        assert client('credential-digest').stdout.strip() == credential
        record('hostname-failure-does-not-change-saved-proxy-password')
    except Exception as error:
        (root / 'private-failure.txt').write_text(repr(error))
        errors.append(type(error).__name__ + ': ' + str(error) if isinstance(error, AssertionError)
                      else type(error).__name__ + ': details retained privately')
        print('FAIL:', errors[-1], flush=True)
    finally:
        try:
            client('proxy-metadata', original_proxy)
            wait(active, 'original literal endpoint recovery')
            assert configuration_values(read_settings()) == configuration_values(original)
            assert json.loads(FLAGS.read_bytes()) == flags
            assert client('credential-digest').stdout.strip() == credential
            record('original-proxy-mode-settings-credentials-and-service-intent-restored')
        except Exception as error:
            errors.append('Restoration: ' + type(error).__name__)
        (root / 'report.json').write_text(json.dumps(dict(success=not errors, passed=passed, errors=errors,
            packageSHA256=build['packageSHA256'], helperSHA256=build['helperSHA256'],
            scope='Actual saved-proxy metadata changed to a reserved .invalid hostname in mimo-vm. No replacement resolver or helper; fresh restricted bootstrap and ordinary-user HTTPS checked. This tests hostname failure only. Successful hostname startup still requires a user-approved hostname for the actual proxy.'), indent=2) + '\n')
    return int(bool(errors))


if __name__ == '__main__':
    sys.exit(main())
