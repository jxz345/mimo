#!/usr/bin/env python3
"""Installed saved-proxy MagicDNS and occupied-provider-port checks; VM only.

Uses the existing native tailnet/peer, without changing that peer or credentials.
A temporary loopback server occupies the preferred provider port during recovery.
Raw observations stay root-private; exported evidence contains check names only.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import events, offsets, LOGS
from upgrade_test import FLAGS, HELPER, STORAGE, read_settings

BASE = Path(__file__).resolve().parent
CLI = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = read_settings()
    original_mode = json.loads(original['service.routing'])['mode']
    assert json.loads(original['service.settings'])['tailscaleProviderEnabled']
    original_flags = json.loads(FLAGS.read_bytes())
    assert original_flags['core'] and original_flags['engine'] and original_flags['profile']
    native = json.loads(command('/usr/bin/sudo', '-n', '-u', 'jay', CLI, 'status', '--json').stdout)
    assert native['BackendState'] == 'Running'
    peer = next(p for p in native['Peer'].values() if p.get('Online'))
    name = peer['DNSName'].rstrip('.')
    addresses = sorted(a for a in peer['TailscaleIPs'] if ':' not in a)
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-magicdns-', dir='/var/tmp'))
    private = root / 'private-backup'; private.mkdir()
    for source in [STORAGE, FLAGS]: shutil.copyfile(source, private / source.name)
    checks = []
    server = None
    requests = []
    print('Evidence:', root, flush=True)

    def client(*args):
        return json.loads(command(BASE / 'acceptance-client', *args, timeout=75).stdout)

    credential = command(BASE / 'acceptance-client', 'credential-digest').stdout
    (private / 'credential.digest').write_text(credential)

    def record(value):
        checks.append(value); print('PASS:', value, flush=True)

    def ready(mode, fallback=None, timeout=90):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            state = client('state'); routing = state['routing']
            provider = next(s for s in routing['services'] if s['id'] == 'tailnetProvider')
            if routing['phase'] == 'active' and routing.get('effectiveMode') == mode and not routing.get('backgroundVerification'):
                if fallback is None or (provider.get('bindingConfirmed') and (provider.get('port') != 18766) == fallback):
                    return provider
            time.sleep(.25)
        (root / 'timeout-state.json').write_text(json.dumps(client('state')))
        raise AssertionError('Timed out waiting for mode/provider readiness')

    def service(operation):
        command(BASE / 'installation-check', 'core', operation, timeout=40)

    def tailnet_provider():
        return json.loads(command('/usr/bin/curl', '--silent', '--fail', '--max-time', '3', '--unix-socket',
            '/Library/Application Support/Mimo/Mihomo/controller.sock',
            'http://localhost/providers/proxies/tailscale-live').stdout)

    def dns_checks(label):
        for style, host in [('full', name), ('absolute', name + '.'), ('uppercase', name.upper())]:
            result = command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/python3', '-c',
                'import json,socket,sys;print(json.dumps(sorted({r[4][0] for r in socket.getaddrinfo(sys.argv[1],None,socket.AF_INET)})))', host, timeout=15)
            assert json.loads(result.stdout) == addresses, label + '-' + style + '-system-DNS'
        for tcp in [False, True]:
            args = ['/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/dig', '@127.0.0.1', '-p', '1053', name, 'A', '+time=3', '+tries=1']
            if tcp: args.append('+tcp')
            result = command(*args, timeout=8)
            assert 'status: NOERROR' in result.stdout and all(a in result.stdout for a in addresses)
        public = command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/dig', '@127.0.0.1', '-p', '1053',
            'example.com', 'TXT', '+tcp', '+time=5', '+tries=1', timeout=12)
        assert 'status: NOERROR' in public.stdout and 'ANSWER: 0' not in public.stdout
        assert client('check-protected-dns')['publicDNSProxied']
        assert client('check-tailnet-provider')['profileUsesOwnedTailnetFile']
        record(label + '-system-full-absolute-uppercase-peer-names-and-UDP-TCP-MagicDNS')
        record(label + '-public-TXT-and-owned-provider-file')

    class Occupied(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            self.send_error(503)
        def log_message(self, *args): pass

    error = None
    try:
        for mode in ['rule', 'global']:
            client('mode', mode); ready(mode)
            dns_checks(mode)
        client('mode', 'direct'); ready('direct')
        service('stop')
        server = http.server.HTTPServer(('127.0.0.1', 18766), Occupied)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        service('start'); ready('direct', fallback=True)
        record('occupied-preferred-port-selects-a-free-loopback-port-in-Direct')
        client('mode', 'rule'); provider = ready('rule', fallback=True)
        dns_checks('fallback-rule')
        service('restart'); ready('rule', fallback=True)
        dns_checks('fallback-after-core-restart')
        assert not requests, 'Mihomo contacted the unrelated service on the occupied preferred port'
        record('core-restart-rebinds-without-contacting-the-occupied-port')
        server.shutdown(); server.server_close(); server = None
        service('restart'); ready('rule', fallback=False)
        dns_checks('preferred-port-recovered')
        command('/usr/bin/sudo', '-n', '-u', 'jay', CLI, 'down')
        until = time.monotonic() + 75
        while time.monotonic() < until:
            value = tailnet_provider()
            if value.get('vehicleType') == 'File' and value.get('proxies', [{}])[0].get('type') == 'Reject': break
            time.sleep(.25)
        else: raise AssertionError('Stopped native tailnet did not reach the live file provider')
        record('native-tailnet-stop-updates-the-live-file-provider-to-Reject')
        command('/usr/bin/sudo', '-n', '-u', 'jay', CLI, 'up')
        until = time.monotonic() + 90
        while time.monotonic() < until:
            value = tailnet_provider()
            if value.get('vehicleType') == 'File' and value.get('proxies', [{}])[0].get('type') == 'Direct': break
            time.sleep(.25)
        else: raise AssertionError('Reconnected native tailnet did not update the live file provider')
        ready('rule'); dns_checks('native-tailnet-reconnected')
        baseline = offsets(LOGS)
        start = time.monotonic()
        subprocess.run(['/usr/sbin/scutil'], input='remove State:/Network/Service/com.mimo.dns/DNS\n',
                       capture_output=True, text=True, check=True)
        until = start + 60
        while time.monotonic() < until:
            state = client('state')['routing']
            closed = any(v['event'] == 'mimo_gate_closed' for v in events(LOGS, baseline))
            if closed and state['phase'] == 'active' and state.get('effectiveMode') == 'rule': break
            time.sleep(.25)
        else: raise AssertionError('Missing resolver did not close and recover')
        (root / 'resolver-loss-events.json').write_text(json.dumps(events(LOGS, baseline)))
        record('missing-system-resolver-closes-and-automatically-restores-Rule')
        dns_checks('resolver-recovered')
    except Exception as failure:
        error = str(failure)
        (root / 'failure.txt').write_text(repr(failure))
    finally:
        if server is not None: server.shutdown(); server.server_close()
        if json.loads(command('/usr/bin/sudo', '-n', '-u', 'jay', CLI, 'status', '--json').stdout)['BackendState'] != 'Running':
            command('/usr/bin/sudo', '-n', '-u', 'jay', CLI, 'up')
        service('start')
        client('mode', original_mode); ready(original_mode)
        assert configuration_values(read_settings()) == configuration_values(original)
        assert json.loads(FLAGS.read_bytes()) == original_flags
        assert command(BASE / 'acceptance-client', 'credential-digest').stdout == credential
        assert json.loads(command('/usr/bin/sudo', '-n', '-u', 'jay', CLI, 'status', '--json').stdout)['BackendState'] == 'Running'
        record('original-mode-settings-credential-service-intent-and-native-tailnet-preserved')
        result = dict(environment='mimo-vm', helperSHA256=hashlib.sha256(HELPER.read_bytes()).hexdigest(), checks=checks, error=error)
        (root / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
    assert error is None, error


if __name__ == '__main__': main()
