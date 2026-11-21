#!/usr/bin/env python3
"""Exercise both Tailnet switches against the installed app and saved proxy in mimo-vm."""
import json
import os
from pathlib import Path
import socket
import time
from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import events, offsets, LOGS
from upgrade_test import FLAGS, read_settings

BASE = Path(__file__).resolve().parent
CLI = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
PROVIDER = Path('/Library/Application Support/Mimo/Mihomo/proxy_providers/mimo-tailnet.yaml')


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    os.umask(0o077)
    output = Path(os.environ['MIMO_TAILNET_EVIDENCE'])
    output.mkdir(parents=True, exist_ok=True)
    saved = read_settings()
    original_mode = json.loads(saved['service.routing'])['mode']
    assert json.loads(saved['service.settings'])['tailscaleProviderEnabled']
    flags = FLAGS.read_bytes()
    checks = []

    def client(*args): return json.loads(command(BASE/'acceptance-client', *args, timeout=75).stdout)
    def native(*args): return command('/usr/bin/sudo', '-n', '-u', 'jay', CLI, *args, timeout=30)
    def wait(predicate, label):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.25)
        raise AssertionError(label + ' timed out')
    def active():
        state = client('state')['routing']
        return state['phase'] == 'active' and state.get('effectiveMode') == 'rule' and not state.get('backgroundVerification')
    def provider_direct(): return 'type: direct' in PROVIDER.read_text()
    def record(label): checks.append(label); print('PASS:', label, flush=True)
    def unchanged(label, baseline):
        rows = events(LOGS, baseline)
        (output/(label+'.json')).write_text(json.dumps(rows))
        forbidden = {'mimo_gate_closed', 'mimo_parallel_preparation_started', 'mimo_network_changed', 'mimo_final_profile_loaded', 'lookup_started'}
        unexpected = [row['event'] for row in rows if row['event'] in forbidden]
        assert not unexpected, label + ': ' + ','.join(unexpected)
        assert active(), label + ' lost approval'
        public = command('/usr/bin/dig', '@127.0.0.1', '-p', '1053', 'example.com', 'TXT', '+tcp', '+time=5', '+tries=1', timeout=8).stdout
        assert 'status: NOERROR' in public and 'ANSWER: 0' not in public, label + ' public DNS proxy failed'
        record(label + ': public DNS works; no gate closure, IP check or profile reload')
    def dns():
        for tcp in [False, True]:
            args = ['/usr/bin/dig', '@127.0.0.1', '-p', '1053', name, 'A', '+time=3', '+tries=1']
            if tcp: args.append('+tcp')
            result = command(*args, timeout=6).stdout
            if 'status: NOERROR' not in result or not all(ip in result for ip in addresses): return False
        return True

    status = json.loads(native('status', '--json').stdout)
    assert status['BackendState'] == 'Running'
    peer = next(p for p in status['Peer'].values() if p.get('Online'))
    name = peer['DNSName'].rstrip('.')
    addresses = [ip for ip in peer['TailscaleIPs'] if ':' not in ip]
    credential = command(BASE/'acceptance-client', 'credential-digest').stdout
    occupied = None
    try:
        client('mode', 'rule'); wait(active, 'Rule approval'); wait(provider_direct, 'initial provider'); wait(dns, 'initial MagicDNS')
        time.sleep(2)
        for action in ['stop', 'start']:
            baseline = offsets(LOGS)
            client('tailnet', action)
            wait(lambda: provider_direct() == (action == 'start'), 'Mimo provider ' + action)
            time.sleep(3)
            if action == 'start': wait(dns, 'Mimo provider MagicDNS')
            unchanged('mimo-provider-' + action, baseline)
        for action in ['down', 'up']:
            baseline = offsets(LOGS)
            native(action)
            wait(lambda: provider_direct() == (action == 'up'), 'native ' + action)
            time.sleep(3)
            if action == 'up': wait(dns, 'native reconnect MagicDNS')
            unchanged('native-tailnet-' + action, baseline)
        record('full peer MagicDNS works over UDP and TCP after both switches')
        client('tailnet', 'stop'); wait(lambda: not provider_direct(), 'provider stopped for port check')
        occupied = socket.socket(); occupied.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        occupied.bind(('127.0.0.1', 18766)); occupied.listen(4)
        baseline = offsets(LOGS)
        client('tailnet', 'start')
        def fallback():
            service = next(s for s in client('state')['routing']['services'] if s['id'] == 'tailnetProvider')
            return service.get('bindingConfirmed') and service.get('port') not in (None, 18766)
        wait(fallback, 'diagnostic fallback'); wait(provider_direct, 'file provider with occupied HTTP port'); wait(dns, 'occupied-port MagicDNS')
        unchanged('occupied-diagnostic-port', baseline)
        record('occupied diagnostic port does not affect the private provider or MagicDNS')
    finally:
        if occupied: occupied.close()
        if json.loads(native('status', '--json').stdout)['BackendState'] != 'Running': native('up')
        client('tailnet', 'start')
        client('mode', original_mode)
        wait(lambda: client('state')['routing'].get('effectiveMode') == original_mode, 'original mode')
        assert configuration_values(read_settings()) == configuration_values(saved)
        assert FLAGS.read_bytes() == flags
        assert command(BASE/'acceptance-client', 'credential-digest').stdout == credential
        record('original settings, credentials, service intent and native connection preserved')
        (output/'summary.json').write_text(json.dumps({'environment': 'mimo-vm', 'checks': checks}, indent=2)+'\n')


if __name__ == '__main__': main()
