#!/usr/bin/env python3
"""Real private-listener ACL checks; loopback fixtures only, no TUN/PF changes."""
import base64
import ipaddress
import json
from pathlib import Path
import secrets
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
from dualstack_fixture import exact, dns_name, read_socks

attempts = []


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        _, end = dns_name(data, 12)
        kind = struct.unpack('!H', data[end:end + 2])[0]
        raw = ipaddress.ip_address('192.0.2.10' if kind == 1 else '2001:db8::10').packed
        answer = b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, 1, len(raw)) + raw
        reply = data[:2] + struct.pack('!5H', 0x8180, 1, 1 if kind in (1, 28) else 0, 0, 0)
        reply += data[12:end + 4] + (answer if kind in (1, 28) else b'')
        sock.sendto(reply, self.client_address)


class SOCKS(socketserver.BaseRequestHandler):
    def handle(self):
        s = self.request
        s.settimeout(3)
        try:
            head = exact(s, 2); exact(s, head[1]); s.sendall(b'\x05\x00')
            head = exact(s, 3)
            host, port, kind = read_socks(s)
            attempts.append({'host': host, 'port': port, 'kind': kind, 'command': head[1]})
            s.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x01')
            # An actual round trip, not CONNECT's potentially optimistic 200.
            while True:
                data = s.recv(4096)
                if not data: break
                s.sendall(data)
        except (OSError, EOFError):
            pass


def connect(port, user, password, host='ipwho.is', destination=443):
    with socket.create_connection(('127.0.0.1', port), timeout=3) as s:
        auth = '' if user is None else 'Proxy-Authorization: Basic ' + base64.b64encode((user + ':' + password).encode()).decode() + '\r\n'
        s.sendall(('CONNECT ' + host + ':' + str(destination) + ' HTTP/1.1\r\nHost: ' + host + '\r\n' + auth + '\r\n').encode())
        header = b''
        while b'\r\n\r\n' not in header:
            part = s.recv(1)
            if not part: return False
            header += part
        if b' 200 ' not in header.split(b'\r\n')[0]: return False
        nonce = secrets.token_bytes(32)
        s.sendall(nonce)
        try: return exact(s, len(nonce)) == nonce
        except (OSError, EOFError): return False


def main():
    engine, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
    results = []
    with socketserver.UDPServer(('127.0.0.1', 0), DNS) as dns, socketserver.ThreadingTCPServer(('127.0.0.1', 0), SOCKS) as proxy:
        for server in (dns, proxy): threading.Thread(target=server.serve_forever, daemon=True).start()
        with tempfile.TemporaryDirectory(prefix='mimo-v3-probe-') as temporary:
            root = Path(temporary)
            for family in ('ipv4', 'dual'):
                for mode in ('rule', 'global'):
                    with socket.socket() as reserve:
                        reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
                    password = secrets.token_hex(16)
                    config = {'mode': mode, 'ipv6': True, 'mimo-destination-family': family,
                              'mixed-port': 0, 'allow-lan': False, 'log-level': 'silent', 'tun': {'enable': False},
                              'dns': {'enable': True, 'ipv6': True, 'nameserver': [f'udp://127.0.0.1:{dns.server_address[1]}']},
                              'proxies': [{'name': 'Fixture', 'type': 'socks5', 'server': '127.0.0.1', 'port': proxy.server_address[1]}],
                              'proxy-groups': [{'name': 'Proxy', 'type': 'select', 'proxies': ['Fixture']}, {'name': 'GLOBAL', 'type': 'select', 'proxies': ['Proxy']}],
                              'rules': ['MATCH,Proxy'], 'listeners': [{'name': 'mimo-private-probe', 'type': 'mixed', 'listen': '127.0.0.1', 'port': port,
                                  'udp': False, 'rule': 'mimo-verification', 'users': [{'username': u, 'password': password} for u in ('mimo-core','mimo-core-ipv4','mimo-core-ipv6')]}],
                              'sub-rules': {'mimo-verification': ['AND,((DOMAIN,ipwho.is),(DST-PORT,443)),Proxy', 'MATCH,REJECT']}}
                    path = root / 'profile.json'; path.write_text(json.dumps(config)); path.chmod(0o600)
                    with (root / 'engine.log').open('w') as log:
                        process = subprocess.Popen([str(engine), '-d', str(root), '-f', str(path)], stdout=log, stderr=log)
                        try:
                            for _ in range(50):
                                try:
                                    with socket.create_connection(('127.0.0.1', port), timeout=.1): pass
                                    break
                                except OSError: time.sleep(.1)
                            for name, user, host, target_port, allowed in [
                                ('base', 'mimo-core', 'ipwho.is', 443, True),
                                ('v4', 'mimo-core-ipv4', 'ipwho.is', 443, True),
                                ('v6', 'mimo-core-ipv6', 'ipwho.is', 443, family == 'dual'),
                                ('wrong-host', 'mimo-core', 'example.com', 443, False),
                                ('suffix-spoof', 'mimo-core', 'ipwho.is.example.com', 443, False),
                                ('wrong-port', 'mimo-core', 'ipwho.is', 80, False),
                                ('wrong-user', 'other', 'ipwho.is', 443, False),
                                ('no-auth', None, 'ipwho.is', 443, False),
                                ('literal', 'mimo-core', '192.0.2.10', 443, False)]:
                                offset = len(attempts)
                                success = connect(port, user, password, host, target_port)
                                new = attempts[offset:]
                                valid = success == allowed and (bool(new) if allowed else not new)
                                if allowed and (family == 'ipv4' or name in ('v4', 'v6')):
                                    valid &= new[-1]['kind'] == (4 if name == 'v6' else 1)
                                results.append({'id': family + '-' + mode + '-' + name, 'passed': valid, 'upstream_connections': len(new)})
                        finally:
                            process.terminate(); process.wait(timeout=5)
        dns.shutdown(); proxy.shutdown()
    output.write_text(json.dumps({'scope': 'real engine private probe over loopback, no system routing changes', 'cases': results}, indent=2))
    print(f'{sum(r["passed"] for r in results)}/{len(results)} private-probe cases passed')
    assert all(r['passed'] for r in results)


if __name__ == '__main__': main()
