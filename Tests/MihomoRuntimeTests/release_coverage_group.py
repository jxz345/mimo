#!/usr/bin/env python3
"""Run Direct-baseline installed checks, preserving the user's starting mode.

Child drivers own their fault cleanup. This wrapper restores the starting native
Tailscale state and mode, and independently verifies all configuration values.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_tailnet_lifecycle_test import native
from upgrade_test import FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    group = sys.argv[1]
    assert group in ('accounts', 'dns', 'relay', 'services', 'sleep')
    original = read_settings()
    mode = json.loads(original['service.routing'])['mode']
    flags = json.loads(FLAGS.read_bytes())
    initial_native = json.loads(native('status', '--json').stdout)['BackendState']
    assert initial_native == 'Stopped'
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-coverage-' + group + '-', dir='/var/tmp'))
    print('Group evidence:', root, flush=True)
    errors, passed, child_results = [], [], []
    unsupported = False

    def client(*args):
        return command(BASE / 'acceptance-client', *args, timeout=75)

    credential = client('credential-digest').stdout.strip()

    def ready(selected, seconds=120):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            state = json.loads(client('state').stdout)['routing']
            if state['phase'] == 'active' and state.get('effectiveMode') == selected and not state.get('backgroundVerification'):
                return
            time.sleep(.2)
        raise AssertionError('Mode did not become fully verified: ' + selected)

    def child(script, *args):
        result = subprocess.run([sys.executable, str(BASE / script), *map(str, args)])
        child_results.append(dict(script=script, exit=result.returncode))
        assert result.returncode == 0, script + ' failed; child evidence retained'

    try:
        client('mode', 'direct')
        ready('direct')
        if group == 'accounts':
            child('release_password_free_test.py')
            child('release_user_test.py')
        elif group == 'dns':
            child('release_dns_privacy_test.py')
        elif group == 'services':
            child('release_service_progress_test.py')
        elif group == 'sleep':
            result = subprocess.run([sys.executable, str(BASE / 'release_sleep_test.py')])
            child_results.append(dict(script='release_sleep_test.py', exit=result.returncode))
            unsupported = result.returncode == 2
            assert result.returncode in (0, 2), 'Sleep test failed; child evidence retained'
        else:
            native('up')
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                status = json.loads(native('status', '--json').stdout)
                state = json.loads(client('state').stdout)
                if status['BackendState'] == 'Running' and state['settings']['tailscaleProviderEnabled']:
                    break
                time.sleep(.5)
            else:
                raise AssertionError('Native connection and automatic provider did not start')
            ready('direct')
            peer = None
            for value in status.get('Peer', {}).values():
                if not value.get('Online'):
                    continue
                for address in value.get('TailscaleIPs', []):
                    if ':' in address:
                        continue
                    try:
                        with socket.create_connection((address, 22), timeout=3) as connection:
                            connection.settimeout(3)
                            if connection.recv(256).startswith(b'SSH-'):
                                peer = address
                                break
                    except OSError:
                        pass
                if peer:
                    break
            assert peer, 'No existing online peer SSH service; no peer will be modified'
            fixture = root / 'private-existing-peer.json'
            fixture.write_text(json.dumps(dict(peer=dict(addresses=[peer], port=22, existingService='SSH'))))
            child('saved_proxy_test.py', '--installed-relay-existing', fixture)
            client('mode', mode)
            ready(mode)
            child('release_optimistic_tailnet_test.py')
    except Exception as error:
        (root / 'private-error.txt').write_text(repr(error))
        errors.append(type(error).__name__ + ': ' + str(error) if isinstance(error, AssertionError)
                      else type(error).__name__ + ': details retained privately')
        print('FAIL:', errors[-1], flush=True)
    finally:
        try:
            if json.loads(native('status', '--json').stdout)['BackendState'] != initial_native:
                native('down')
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if not json.loads(client('state').stdout)['settings']['tailscaleProviderEnabled']:
                    break
                time.sleep(.3)
            else:
                raise AssertionError('Provider did not return to native-off state')
            if json.loads(read_settings()['service.routing'])['mode'] != mode:
                client('mode', mode)
            ready(mode)
            assert configuration_values(read_settings()) == configuration_values(original)
            assert json.loads(FLAGS.read_bytes()) == flags
            assert client('credential-digest').stdout.strip() == credential
            passed.append('original-mode-native-state-settings-credentials-and-service-intent-restored')
            print('PASS:', passed[-1], flush=True)
        except Exception as error:
            errors.append('Restoration: ' + type(error).__name__)
        (root / 'report.json').write_text(json.dumps(dict(success=not errors and not unsupported, unsupported=unsupported, group=group, passed=passed,
            errors=errors, children=child_results, packageSHA256=build['packageSHA256'], helperSHA256=build['helperSHA256'],
            scope='Installed tests execute exclusively in mimo-vm. Relay probes use an existing peer SSH service; no remote commands, new peer listeners, or Delta runtime changes.'), indent=2) + '\n')
    return 1 if errors else 2 if unsupported else 0


if __name__ == '__main__':
    sys.exit(main())
