#!/usr/bin/env python3
"""Delta controller for saved-proxy relay acceptance in the existing mimo-vm.

Stage stage_acceptance.sh output at ~/mimo-tests/saved-proxy in the VM first.
Uses the existing SSH/admin setup. Host networking and Tailscale settings are
unchanged; a nonce-protected echo server binds only the host's tailnet IPv4.
"""
import ipaddress
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time


def main():
    os.umask(0o077)
    repo = Path(__file__).resolve().parents[2]
    os.chdir(repo)
    root = repo / '.build' / ('mimo-saved-relay-' + time.strftime('%Y%m%d-%H%M%S'))
    root.mkdir(mode=0o700, parents=True)
    cli = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
    guest_root = '/Users/jay/mimo-tests/saved-proxy'
    guest_fixture = guest_root + '/relay-fixture.json'
    host = json.loads(subprocess.check_output([cli, 'status', '--json'], text=True, timeout=15))
    guest = json.loads(subprocess.check_output(['ssh', 'mimo-vm', cli + ' status --json'], text=True, timeout=20))
    assert host['BackendState'] == guest['BackendState'] == 'Running'
    assert guest['Self']['ID'] in [value['ID'] for value in host['Peer'].values()]

    def ipv4(node):
        return next(address for address in node['TailscaleIPs'] if ipaddress.ip_address(address).version == 4)

    fixture = root / 'fixture.json'
    fixture.write_text(json.dumps({'peer': {
        'addresses': [ipv4(host['Self'])], 'clients': [ipv4(guest['Self'])],
        'port': 18889, 'token': secrets.token_hex(32)
    }}))
    server = driver = None
    result = 1
    try:
        with (root / 'peer.log').open('w') as log:
            server = subprocess.Popen([sys.executable, '-u', 'Tests/MihomoRuntimeTests/peer_echo.py', str(fixture)], stdout=log, stderr=log)
        deadline = time.monotonic() + 8
        while 'listeners ready' not in (root / 'peer.log').read_text():
            assert server.poll() is None and time.monotonic() < deadline, 'Peer fixture did not start'
            time.sleep(.1)
        subprocess.run(['scp', '-q', str(fixture), 'mimo-vm:' + guest_fixture], check=True, timeout=30)
        versions = {
            'host': subprocess.check_output([cli, 'version'], text=True, timeout=10).splitlines()[0],
            'guest': subprocess.check_output(['ssh', 'mimo-vm', cli + ' version'], text=True, timeout=15).splitlines()[0]
        }
        (root / 'versions.json').write_text(json.dumps(versions))
        print('Versions:', versions, 'Evidence:', root.relative_to(repo), flush=True)
        with (root / 'run.log').open('w') as log:
            driver = subprocess.Popen([sys.executable, 'Scripts/vm-admin.py', '/usr/bin/python3', '-u',
                                       guest_root + '/saved_proxy_test.py', '--relay', guest_fixture], stdout=log, stderr=log)
            result = driver.wait(timeout=1200)
        print('Relay result:', result, flush=True)
    finally:
        try:
            if driver and driver.poll() is None:
                driver.terminate()
                driver.wait(timeout=15)
        finally:
            if server:
                server.terminate()
                server.wait(timeout=5)
            fixture.unlink(missing_ok=True)
            subprocess.run(['ssh', 'mimo-vm', 'rm -f ' + guest_fixture], timeout=20)
    return result


if __name__ == '__main__':
    sys.exit(main())
