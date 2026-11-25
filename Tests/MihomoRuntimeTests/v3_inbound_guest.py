#!/usr/bin/env python3
"""VM-only driver for incoming-service and rejected-exit regression checks.

Uses a restricted Delta fixture and the production XPC controls. Original
settings stay in the owner-only campaign directory. Never run on a real Mac.
"""
import json
import os
from pathlib import Path
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import v3_installed_test as t

ROOT = Path(sys.argv[1])
NAME = 'Incoming access qualification'


def wait(predicate):
    deadline = time.monotonic() + 100
    while time.monotonic() < deadline:
        value = t.state()
        if predicate(value):
            return value
        time.sleep(.25)
    raise AssertionError('State did not converge: ' + value['routing']['reason'])


def report(value):
    routing = value['routing']
    print(json.dumps(dict(phase=routing['phase'], reason=routing['reason'],
                         authorization=value['authorizationState'],
                         manualRefresh=value.get('manualRefresh'),
                         observed4=routing.get('observedIP'),
                         observed6=routing.get('ipv6Observation'))), flush=True)


def echo(connection, fixture):
    value = (fixture['token'] + ':' + str(time.monotonic_ns())).encode()
    connection.sendall(value)
    return connection.recv(len(value)) == value


def close_for_test():
    settings = t.state()['settings']
    settings['allowlist'] = {'addresses': []}
    t.request('configure', settings=settings)
    return wait(lambda s: s['routing']['phase'] == 'blocked' and
                'No exit IPs are approved' in s['routing']['reason'])


def loopback_check():
    fixture = json.loads((ROOT / 'fixture.json').read_text())
    with socket.create_connection(('127.0.0.1', 7890), 3) as connection:
        connection.settimeout(3)
        connection.sendall(b'\x05\x01\x00')
        assert connection.recv(2) == b'\x05\x00'
        connection.sendall(b'\x05\x01\x00\x01' + socket.inet_aton(fixture['public4']) +
                           struct.pack('!H', fixture['stream_port']))
        header = connection.recv(4)
        assert header[:2] == b'\x05\x00'
        size = {1: 4, 4: 16}.get(header[3])
        assert size is not None
        remaining = size + 2
        while remaining:
            data = connection.recv(remaining)
            assert data
            remaining -= len(data)
        assert echo(connection, fixture), 'Positive local SOCKS stream failed'
        port = connection.getsockname()[1]
        states = t.run(['/sbin/pfctl', '-ss'])
        assert states.returncode == 0
        assert not any('127.0.0.1:' + str(port) in line for line in states.stdout.splitlines()), \
            'Public loopback proxy flow incorrectly retained PF state'
        value = close_for_test()
        try:
            succeeded = echo(connection, fixture)
        except OSError:
            succeeded = False
        assert not succeeded, 'Existing public proxy flow survived rejection'
    try:
        fresh = socket.create_connection(('127.0.0.1', 7890), 1)
    except OSError:
        fresh = None
    if fresh is not None:
        fresh.close()
        raise AssertionError('Blocked public proxy listener accepted a new connection')
    report(value)


def outbound_state_check():
    fixture = json.loads((ROOT / 'fixture.json').read_text())
    mode = t.state()['routing']['configuration']['mode']
    assert mode in ('rule', 'global')
    anchor = 'com.apple/998.mimo-inbound-state-test'
    assert not t.run(['/sbin/pfctl', '-a', anchor, '-sr']).stdout.strip()
    streams = []
    t.route('direct'); t.wait_active('direct', 100)
    try:
        rules = ''.join('pass out quick ' + family + ' proto tcp from any to ' + fixture[key] +
                        ' port ' + str(fixture['stream_port']) +
                        ' keep state label "mimo:test:outbound-state"\n'
                        for family, key in (('inet', 'data4'), ('inet6', 'data6')))
        result = subprocess.run(['/sbin/pfctl', '-a', anchor, '-f', '-'], input=rules,
                                text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        for key in ('data4', 'data6'):
            connection = socket.create_connection((fixture[key], fixture['stream_port']), 3)
            connection.settimeout(2)
            streams.append(connection)
            assert echo(connection, fixture), 'Positive stateful outbound stream failed'
        states = t.run(['/sbin/pfctl', '-ss']).stdout
        for connection in streams:
            port = str(connection.getsockname()[1])
            assert any(' -> ' in line and (':' + port + ' ' in line or '[' + port + ']' in line)
                       for line in states.splitlines()), 'Outbound PF state not established'
        settings = t.state()['settings']
        settings['allowlist'] = {'addresses': []}
        t.request('configure', settings=settings)
        t.route(mode)
        value = wait(lambda s: s['routing']['phase'] == 'blocked' and
                     'No exit IPs are approved' in s['routing']['reason'])
        states = t.run(['/sbin/pfctl', '-ss']).stdout
        for connection in streams:
            port = str(connection.getsockname()[1])
            assert not any(' -> ' in line and (':' + port + ' ' in line or '[' + port + ']' in line)
                           for line in states.splitlines()), 'Outbound PF state survived closure'
            try:
                succeeded = echo(connection, fixture)
            except OSError:
                succeeded = False
            assert not succeeded, 'Revoked outbound stream exchanged data'
        report(value)
    finally:
        for connection in streams:
            connection.close()
        result = subprocess.run(['/sbin/pfctl', '-a', anchor, '-f', '-'], input='',
                                text=True, capture_output=True)
        assert result.returncode == 0, result.stderr


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    operation = sys.argv[2]
    if operation == 'serve':
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(120)
                try:
                    while True:
                        data = self.request.recv(4096)
                        if not data:
                            return
                        if data.startswith(b'GET /mimo-inbound-test '):
                            self.request.sendall(b'HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK')
                            return
                        if not data.startswith(b'mimo-inbound-test:'):
                            return
                        self.request.sendall(data)
                except OSError:
                    pass
        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True
        class Server6(Server):
            address_family = socket.AF_INET6
        servers = [Server(('0.0.0.0', 18793), Handler), Server6(('::', 18794), Handler)]
        for server in servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        (ROOT / 'server.ready').write_text(str(os.getpid()))
        time.sleep(1200)  # bounded even if the host orchestrator exits
        return
    if operation == 'setup':
        fixture = json.loads((ROOT / 'fixture.json').read_text())
        current = t.state()
        if not (ROOT / 'before.json').exists():
            (ROOT / 'before.json').write_text(json.dumps(current))
        settings = current['settings']
        settings.update(provider='ipWhois', providerPool=['ipWhois', 'ipapiCo', 'ipapiIs'],
                        refreshInterval=-1, bypassBlocks=[],
                        allowlist={'addresses': ['203.0.113.10', '2001:db8::10']})
        t.request('configure', settings=settings)
        old = next((p for p in current['routing']['configuration']['proxies'] if p['proxy']['name'] == NAME), None)
        t.request('saveProxy', proxy={'name': NAME, 'type': 'socks5', 'server': fixture['bridge4'],
                                    'port': fixture['proxy_port'], 'username': ''}, proxyPassword='',
                  **({'proxyID': old['id']} if old else {}))
        entry = next(p for p in t.state()['routing']['configuration']['proxies'] if p['proxy']['name'] == NAME)
        t.request('selectProxy', proxyID=entry['id'])
        t.route('rule', 'dual')
        report(t.wait_active('rule', 100))
    elif operation in ('approve', 'empty', 'reject4', 'reject6'):
        if operation == 'approve':
            t.route(sys.argv[3], sys.argv[4])
        settings = t.state()['settings']
        addresses = {'approve': ['203.0.113.10', '2001:db8::10'], 'empty': [],
                     'reject4': ['192.0.2.1', '2001:db8::10'], 'reject6': ['203.0.113.10']}[operation]
        settings['allowlist'] = {'addresses': addresses}
        t.request('configure', settings=settings)
        expected = {'empty': 'No exit IPs are approved', 'reject4': 'IPv4 exit IP is not approved',
                    'reject6': 'IPv6 exit IP is not approved'}
        report(wait(lambda s: s['routing']['phase'] == 'active' if operation == 'approve' else
                    s['routing']['phase'] == 'blocked' and expected[operation] in s['routing']['reason']))
    elif operation == 'loopback':
        loopback_check()
    elif operation == 'outbound-state':
        outbound_state_check()
    elif operation == 'refresh':
        t.request('refresh')
        report(wait(lambda s: s['routing']['phase'] == 'blocked' and
                    (s.get('manualRefresh') or {}).get('phase') == 'failed'))
    elif operation == 'faults':
        # Reuse the already prepared fixture settings; every traffic assertion,
        # native detector and independent owner-resume path is unchanged.
        import v3_fault_traffic_test as faults
        t.route('direct'); t.wait_active('direct', 100)
        made_log_interface = t.run(['/sbin/ifconfig', 'pflog0']).returncode != 0
        if made_log_interface:
            assert t.run(['/sbin/ifconfig', 'pflog0', 'create']).returncode == 0
        try:
            faults.main(prepared=True, faults=('engine-kill', 'native-route', 'owners-stall-engine-kill'))
        finally:
            if made_log_interface:
                t.run(['/sbin/ifconfig', 'pflog0', 'destroy'])
    elif operation == 'direct':
        t.route('direct'); report(t.wait_active('direct', 100))
    elif operation == 'restore':
        before = json.loads((ROOT / 'before.json').read_text())
        original = before['routing']['configuration']
        t.route('direct'); t.wait_active('direct', 100)
        t.request('configure', settings=before['settings'])
        t.request('selectProxy', **({'proxyID': original['activeProxyID']} if original.get('activeProxyID') else {}))
        for entry in t.state()['routing']['configuration']['proxies']:
            if entry['proxy']['name'] == NAME:
                t.request('removeProxy', proxyID=entry['id'])
        t.request('configureRouting', routing=original)
        value = wait(lambda s: s['routing']['phase'] in ('active', 'blocked'))
        assert value['settings'] == before['settings']
        assert value['routing']['configuration']['proxies'] == original['proxies']
        report(value)
    else:
        raise AssertionError('Unknown operation')


if __name__ == '__main__':
    main()
