#!/usr/bin/env python3
"""Delta-side incoming TCP checks against a prepared, installed test VM.

Requires v3_inbound_guest.py's server and restricted SOCKS fixture already
running. Settings are restored in finally through Tart, independently of PF.
Arguments: owner-only evidence directory, guest directory, VM IPv4, VM IPv6.
"""
import itertools
import json
from pathlib import Path
import socket
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
ROOT, GUEST = Path(sys.argv[1]), sys.argv[2]
ADDRESSES = (sys.argv[3], sys.argv[4])
RESULTS = []


def guest(operation, *arguments):
    result = subprocess.run([sys.executable, str(REPO / 'Scripts/vm-console-admin.py'),
                             '/usr/bin/python3', GUEST + '/v3_inbound_guest.py', GUEST,
                             operation, *arguments], text=True, capture_output=True, timeout=175)
    (ROOT / (operation + '-last.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, operation + ' failed; inspect private log'
    return json.loads(result.stdout.strip().splitlines()[-1])


def record(name, **facts):
    RESULTS.append(dict(id=name, result='PASS', **facts))
    (ROOT / 'incoming-results.json').write_text(json.dumps(RESULTS, indent=2))
    print(name + ': PASS', flush=True)


def open_stream(address, port):
    connection = socket.create_connection((address, port), 4)
    connection.settimeout(4)
    return connection


def echo(connection):
    nonce = ('mimo-inbound-test:' + str(time.monotonic_ns())).encode()
    connection.sendall(nonce)
    answer = b''
    while len(answer) < len(nonce):
        chunk = connection.recv(len(nonce) - len(answer))
        assert chunk, 'Incoming stream closed'
        answer += chunk
    assert answer == nonce


def incoming(label, streams):
    for address, port in zip(ADDRESSES, (18793, 18794)):
        with open_stream(address, port) as connection:
            connection.sendall(b'GET /mimo-inbound-test HTTP/1.0\r\n\r\n')
            assert connection.recv(512).startswith(b'HTTP/1.0 200 OK')
    for port, prefix in ((22, b'SSH-'), (5900, b'RFB ')):
        with open_stream(ADDRESSES[0], port) as connection:
            assert connection.recv(100).startswith(prefix)
    for connection in streams:
        echo(connection)
    record(label, fresh_http4=True, fresh_http6=True, ssh_banner=True,
           screen_sharing_banner=True, existing_stream4=True, existing_stream6=True)


def main():
    assert socket.gethostname().split('.')[0] == 'delta'
    assert ROOT.stat().st_mode & 0o077 == 0
    try:
        for family, mode in itertools.product(('ipv4', 'dual'), ('rule', 'global')):
            label = family + '-' + mode
            value = guest('approve', mode, family)
            assert value['phase'] == 'active' and 'allowed' in value['authorization']
            assert value['observed4']['address'] == '203.0.113.10' and value['observed6'] is None
            streams = [open_stream(address, port) for address, port in zip(ADDRESSES, (18793, 18794))]
            try:
                incoming(label + '-active', streams)
                guest('loopback')
                incoming(label + '-local-proxy-closed', streams)
                value = guest('empty')
                assert 'notAllowed' in value['authorization'] and 'No exit IPs are approved' in value['reason']
                incoming(label + '-empty-allowlist', streams)
                value = guest('refresh')
                assert value['manualRefresh']['phase'] == 'failed'
                assert 'Exit IP checked. Outbound access remains blocked.' in value['manualRefresh']['message']
                incoming(label + '-rejected-refresh', streams)
                value = guest('reject4')
                assert 'IPv4 exit IP is not approved' in value['reason']
                incoming(label + '-rejected-ipv4', streams)
                if family == 'dual' and mode == 'global':
                    guest('outbound-state')
                    incoming(label + '-outbound-states-revoked', streams)
            finally:
                for connection in streams:
                    connection.close()
    finally:
        restored = guest('restore')
        record('saved-settings-restored', phase=restored['phase'])


if __name__ == '__main__':
    main()
