#!/usr/bin/env python3
"""Real SystemConfiguration and missing-tunnel checks in the installed VM.

Changes the actual Ethernet search-domain preference, then restores it. Disables
the actual engine TUN through its controller; no synthesized notifications.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events
from upgrade_test import FLAGS, HELPER, RUNTIME, read_settings

BASE = Path(__file__).resolve().parent
CONTROLLER = '/Library/Application Support/Mimo/Mihomo/controller.sock'


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    original = read_settings()
    mode = json.loads(original['service.routing'])['mode']
    flags = json.loads(FLAGS.read_bytes())
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-remaining-events-', dir='/var/tmp'))
    print('Evidence:', root, flush=True)
    passed, errors = [], []
    domains = command('/usr/sbin/networksetup', '-getsearchdomains', 'Ethernet').stdout.strip().splitlines()
    if domains and domains[0].startswith("There aren't any Search Domains"):
        domains = ['Empty']
    changed = False

    def client(*args):
        return command(BASE / 'acceptance-client', *args, timeout=70)

    credential = client('credential-digest').stdout.strip()

    def active(selected):
        value = json.loads(client('state').stdout)['routing']
        return value['phase'] == 'active' and value.get('effectiveMode') == selected and not value.get('backgroundVerification')

    def wait(predicate, label, seconds=90):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.05)
        raise AssertionError(label + ' timed out')

    def record(label):
        passed.append(label)
        print('PASS:', label, flush=True)

    def https():
        command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail',
                '--noproxy', '*', '--max-time', '12', '--head', 'https://1.1.1.1/')

    try:
        wait(lambda: active(mode), 'original mode')
        for selected in ('rule', 'global', 'direct'):
            if not active(selected):
                client('mode', selected)
            wait(lambda: active(selected), selected + ' before preference change')
            baseline = offsets(LOGS)
            command('/usr/sbin/networksetup', '-setsearchdomains', 'Ethernet', 'mimo-acceptance.invalid')
            changed = True
            wait(lambda: any(v['event'] == 'mimo_network_event_dispatch' and v['fields'].get('source') == 'configuration'
                             for v in events(LOGS, baseline)), 'real configuration callback')
            if selected != 'direct':
                wait(lambda: any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, baseline)) and active(selected), 'protected configuration recovery')
                rows = events(LOGS, baseline)
                assert any(v['event'] == 'mimo_network_event_dispatch' and v['fields'].get('source') == 'configuration'
                           and v['fields'].get('early_gate') == 'true' for v in rows)
                opened = next(v for v in rows if v['event'] == 'mimo_traffic_opened')
                names = [v['event'] for v in rows if v['file'] == opened['file']]
                assert names.index('mimo_private_probe_ready') < names.index('mimo_traffic_opened')
                assert any(v['event'] == 'mimo_gate_closed' and v['fields'].get('confirmed') == 'true' for v in rows)
                record(selected + '-real-search-domain-change-starts-early-block-and-fresh-verification')
            else:
                time.sleep(2)
                rows = events(LOGS, baseline)
                assert active('direct') and (RUNTIME / 'gate.state').read_text() == 'direct'
                assert not any(v['event'] == 'mimo_gate_closed' or
                               (v['event'] == 'mimo_network_event_dispatch' and v['fields'].get('early_gate') == 'true') for v in rows)
                record('Direct-real-search-domain-change-stays-open')
            (root / (selected + '-private-events.json')).write_text(json.dumps(rows))
            https()
            command('/usr/sbin/networksetup', '-setsearchdomains', 'Ethernet', *domains)
            changed = False
            time.sleep(1)
            wait(lambda: active(selected), 'search-domain restoration')

        client('mode', mode)
        wait(lambda: active(mode), 'protected mode before actual TUN loss')
        live = json.loads(command('/usr/bin/curl', '--silent', '--fail', '--max-time', '3',
                                 '--unix-socket', CONTROLLER, 'http://localhost/configs').stdout)
        device = live['tun']['device']
        assert socket.if_nametoindex(device) > 0
        disappeared = threading.Event()
        stop = threading.Event()

        def observe():
            while not stop.is_set():
                try:
                    socket.if_nametoindex(device)
                except OSError:
                    disappeared.set()
                    return
                time.sleep(.005)

        observer = threading.Thread(target=observe, daemon=True)
        observer.start()
        baseline = offsets(LOGS)
        try:
            command('/usr/bin/curl', '--silent', '--fail', '--max-time', '5', '--unix-socket', CONTROLLER,
                    '-X', 'PATCH', '-H', 'Content-Type: application/json', '--data',
                    '{"tun":{"enable":false}}', 'http://localhost/configs')
            assert disappeared.wait(5), 'Actual tunnel did not disappear'
            wait(lambda: any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, baseline)) and active(mode),
                 'actual missing-tunnel recovery', 100)
            rows = events(LOGS, baseline)
            (root / 'tunnel-loss-private-events.json').write_text(json.dumps(rows))
            opened = [v for v in rows if v['event'] == 'mimo_traffic_opened']
            assert opened and opened[0]['fields'].get('optimistic') == 'false'
            assert socket.if_nametoindex(device) > 0
            https()
            record('actual-tunnel-loss-rejects-optimistic-opening-and-recovers-through-full-verification')
        finally:
            stop.set()
            observer.join(timeout=2)
    except Exception as error:
        (root / 'failure-private.txt').write_text(repr(error))
        errors.append(type(error).__name__ + ': ' + str(error) if isinstance(error, AssertionError)
                      else type(error).__name__ + ': details retained privately')
        print('FAIL:', errors[-1], flush=True)
    finally:
        try:
            if changed:
                command('/usr/sbin/networksetup', '-setsearchdomains', 'Ethernet', *domains)
            if json.loads(read_settings()['service.routing'])['mode'] != mode:
                client('mode', mode)
            if not active(mode):
                client('refresh')
            wait(lambda: active(mode), 'original mode restored')
            actual = command('/usr/sbin/networksetup', '-getsearchdomains', 'Ethernet').stdout.strip().splitlines()
            assert actual == domains or (domains == ['Empty'] and actual[0].startswith("There aren't any Search Domains"))
            assert configuration_values(read_settings()) == configuration_values(original)
            assert json.loads(FLAGS.read_bytes()) == flags
            assert client('credential-digest').stdout.strip() == credential
            record('original-network-preferences-mode-settings-credentials-and-service-intent-restored')
        except Exception as error:
            errors.append('Restoration: ' + type(error).__name__)
        (root / 'report.json').write_text(json.dumps(dict(success=not errors, passed=passed, errors=errors,
            packageSHA256=build['packageSHA256'], helperSHA256=build['helperSHA256'],
            scope='Installed normal Release in mimo-vm; real Ethernet search-domain preferences across Rule/Global/Direct, actual engine TUN disable and observed interface disappearance, ordinary-user HTTPS. Not synthetic notifications, packet-boundary proof, or sleep.'), indent=2) + '\n')
    return int(bool(errors))


if __name__ == '__main__':
    sys.exit(main())
