#!/usr/bin/env python3
"""Check the installed Quad100 exception and its live revocation; mimo-vm only.

Uses the installed policy without temporary anchors, profile edits or PF writes.
Root DNS deliberately uses group 0 to exercise the physical-Mac group mismatch.
"""
import json
import os
from pathlib import Path
import subprocess
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from upgrade_test import FLAGS, read_settings

BASE = Path(__file__).resolve().parent
SOCKET = '/Library/Application Support/Mimo/Mihomo/controller.sock'
NATIVE = 'com.apple/000.mimo/native-transport'


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    os.umask(0o077)
    output = Path(os.environ['MIMO_MAGICDNS_FIREWALL_EVIDENCE'])
    output.mkdir(parents=True, exist_ok=True)
    original = read_settings()
    original_flags = FLAGS.read_bytes()
    original_mode = json.loads(original['service.routing'])['mode']
    assert json.loads(original['service.settings'])['tailscaleProviderEnabled']
    credential = command(BASE/'acceptance-client', 'credential-digest').stdout
    native = json.loads(command('/usr/bin/sudo', '-n', '-u', 'jay',
        '/Applications/Tailscale.app/Contents/MacOS/Tailscale', 'status', '--json').stdout)
    assert native['BackendState'] == 'Running'
    peer = next(p for p in native['Peer'].values() if p.get('Online'))
    name = peer['DNSName'].rstrip('.')
    addresses = sorted(a for a in peer['TailscaleIPs'] if ':' not in a)
    checks = []

    def client(*args):
        return json.loads(command(BASE/'acceptance-client', *args, timeout=75).stdout)

    def curl(path, method='GET'):
        return command('/usr/bin/curl', '--fail', '--silent', '--show-error', '--max-time', '10',
            '--unix-socket', SOCKET, '-X', method, 'http://localhost/' + path, timeout=15).stdout

    def record(label):
        checks.append(label)
        print('PASS:', label, flush=True)

    def wait(predicate, label):
        until = time.monotonic() + 60
        while time.monotonic() < until:
            if predicate(): return
            time.sleep(.25)
        raise AssertionError(label + ' timed out')

    def active(mode):
        value = client('state')['routing']
        return value['phase'] == 'active' and value.get('effectiveMode') == mode and not value.get('backgroundVerification')

    def native_ready():
        return json.loads(curl('providers/proxies/tailscale-live'))['proxies'][0]['type'] == 'Direct'

    def dig(root=True, tcp=True):
        args = ['/usr/bin/dig', '@100.100.100.100', name, 'A', '+tcp' if tcp else '+notcp', '+time=2', '+tries=1']
        if root:
            def identity():
                os.setgroups([0])
                os.setgid(0)
            result = subprocess.run(args, preexec_fn=identity, capture_output=True, text=True, timeout=8)
        else:
            result = subprocess.run(['/usr/bin/sudo', '-n', '-u', 'jay', *args], capture_output=True, text=True, timeout=8)
        return result.returncode == 0 and 'status: NOERROR' in result.stdout and all(ip in result.stdout for ip in addresses)

    error = None
    try:
        client('mode', 'rule')
        wait(lambda: active('rule'), 'Rule approval')
        wait(native_ready, 'native provider')
        policy = command('/sbin/pfctl', '-a', 'com.apple/000.mimo/open-policy', '-sr').stdout
        early = 'anchor "/' + NATIVE + '" out quick inet proto tcp from any to 100.100.100.100 port = 53 user = 0'
        assert early in policy, 'Installed policy lacks the scoped root Quad100 call'
        assert policy.index(early) < policy.index('port = 53 group !='), 'Exception comes after the DNS block'
        assert 'dns-test' not in policy, 'Temporary test wrapper is present'
        record('installed root TCP Quad100 call precedes DNS group guard; no test wrapper')
        assert dig(), 'Root/group-0 native TCP DNS failed'
        record('root group-0 TCP DNS succeeds through installed native policy')
        assert not dig(root=False), 'Ordinary direct TCP DNS escaped the guard'
        assert not dig(root=False, tcp=False), 'Ordinary direct UDP DNS escaped the guard'
        assert not dig(tcp=False), 'Root group-0 UDP gained an unintended exception'
        record('ordinary direct TCP/UDP DNS and root group-0 UDP remain blocked')
        for _ in range(3):
            curl('cache/dns/flush', 'POST')
            value = json.loads(curl('dns/query?name=' + name + '&type=A'))
            assert value.get('Status') == 0
            assert sorted(a['data'] for a in value.get('Answer', []) if a.get('type') == 1) == addresses
        record('three fresh installed-engine full-name answers without temporary PF rules')
        client('tailnet', 'stop')
        wait(lambda: not native_ready(), 'provider stop')
        assert not dig(), 'Root TCP DNS survived native-policy revocation'
        assert active('rule'), 'Provider Stop lost public Rule approval'
        record('provider Stop revokes root TCP exception while public Rule approval remains active')
        client('tailnet', 'start')
        wait(native_ready, 'provider start')
        assert dig(), 'Root TCP DNS did not recover'
        assert active('rule')
        record('provider Start restores root TCP DNS and preserves active Rule approval')
        state = client('state')['routing']
        for service in state['services']:
            assert 'checkedAt' in service
            age = time.time() - (service['checkedAt'] + 978307200)
            assert -5 <= age <= 35, service['id'] + ' inspection is stale'
        infrastructure = state['infrastructure']
        assert infrastructure.get('checkedAt') is not None
        age = time.time() - (infrastructure['checkedAt'] + 978307200)
        assert -5 <= age <= 35
        assert infrastructure['pf'] == infrastructure['launchd'] == 'healthy'
        record('all four service and two infrastructure rows carry current inspection times')
    except Exception as failure:
        error = str(failure)
    finally:
        client('tailnet', 'start')
        client('mode', original_mode)
        wait(lambda: active(original_mode), 'original mode')
        assert configuration_values(read_settings()) == configuration_values(original)
        assert FLAGS.read_bytes() == original_flags
        assert command(BASE/'acceptance-client', 'credential-digest').stdout == credential
        record('original mode, settings, service intent and credentials preserved')
        (output/'summary.json').write_text(json.dumps({'environment': 'mimo-vm', 'checks': checks, 'error': error}, indent=2)+'\n')
    assert error is None, error


if __name__ == '__main__': main()
