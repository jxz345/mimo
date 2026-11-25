#!/usr/bin/env python3
"""Restricted Delta SOCKS5, DNS and real dual-stack service test fixture.

Only ephemeral listeners are opened on Delta. No routing, DNS, trust or firewall
configuration is changed. The VM runner imports the wire helpers below.
"""
import base64
import hmac
import io
import ipaddress
import json
import os
from pathlib import Path
import secrets
import select
import signal
import socket
import ssl
import struct
import threading
import time
import http.server
import urllib.parse


def exact(sock, count):
    result = b''
    while len(result) < count:
        part = sock.recv(count - len(result))
        if not part:
            raise EOFError('Connection closed')
        result += part
    return result


def socks_address(host, port):
    try:
        ip = ipaddress.ip_address(host)
        prefix = bytes([1 if ip.version == 4 else 4]) + ip.packed
    except ValueError:
        raw = host.encode('ascii')
        assert len(raw) < 256
        prefix = bytes([3, len(raw)]) + raw
    return prefix + struct.pack('!H', port)


def read_socks(sock):
    kind = exact(sock, 1)[0]
    if kind in (1, 4):
        host = socket.inet_ntop(socket.AF_INET if kind == 1 else socket.AF_INET6,
                               exact(sock, 4 if kind == 1 else 16))
    elif kind == 3:
        host = exact(sock, exact(sock, 1)[0]).decode('ascii')
    else:
        raise ValueError('Invalid SOCKS address type')
    return host, struct.unpack('!H', exact(sock, 2))[0], kind


class Reader:
    def __init__(self, data):
        self.stream = io.BytesIO(data)

    def recv(self, n):
        return self.stream.read(n)


def dns_name(data, offset):
    parts, end, seen = [], None, set()
    while True:
        if offset in seen:
            raise ValueError('DNS compression loop')
        seen.add(offset)
        n = data[offset]
        if n & 0xc0 == 0xc0:
            if end is None:
                end = offset + 2
            offset = ((n & 0x3f) << 8) | data[offset + 1]
        elif n == 0:
            return '.'.join(parts), end if end is not None else offset + 1
        else:
            parts.append(data[offset + 1:offset + 1 + n].decode('ascii'))
            offset += n + 1


def dns_question(name, kind):
    identity = secrets.randbelow(65536)
    data = b''.join(bytes([len(x)]) + x.encode('ascii') for x in name.rstrip('.').split('.')) + b'\0'
    return struct.pack('!6H', identity, 0x0100, 1, 0, 0, 0) + data + struct.pack('!HH', kind, 1)


def decode_dns(data):
    identity, flags, qd, an, ns, ar = struct.unpack('!6H', data[:12])
    offset = 12
    for _ in range(qd):
        _, offset = dns_name(data, offset)
        offset += 4
    answers = []
    for _ in range(an):
        name, offset = dns_name(data, offset)
        kind, cls, ttl, length = struct.unpack('!HHIH', data[offset:offset + 10])
        offset += 10
        raw = data[offset:offset + length]
        value = socket.inet_ntop(socket.AF_INET if kind == 1 else socket.AF_INET6, raw) if kind in (1, 28) else raw.hex()
        answers.append({'name': name, 'type': kind, 'ttl': ttl, 'data': value})
        offset += length
    return {'id': identity, 'rcode': flags & 15, 'answers': answers}


def dns_query(server, port, name, kind, transport='udp', timeout=3):
    request = dns_question(name, kind)
    family = socket.AF_INET6 if ':' in server else socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM if transport == 'tcp' else socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.connect((server, port))
        sock.sendall((struct.pack('!H', len(request)) if transport == 'tcp' else b'') + request)
        response = exact(sock, struct.unpack('!H', exact(sock, 2))[0]) if transport == 'tcp' else sock.recv(65535)
    result = decode_dns(response)
    assert result['id'] == struct.unpack('!H', request[:2])[0]
    return result


MODES = {
    'S00': ('forward', 'forward'), 'S01': ('reject', 'forward'),
    'S02': ('stall', 'forward'), 'S03': ('forward', 'drop'),
    'S04': ('reject', 'drop'), 'S05': ('stall', 'drop'),
}
NAT64_TEST_TARGETS = ('64:ff9b::c000:225', '64:ff9b:1::c000:225')


class Fixture:
    def __init__(self, root, bridge4, data4, data6, client4, mode):
        self.root, self.bridge4, self.data4, self.data6, self.client4 = root, bridge4, data4, data6, client4
        assert bridge4 != data4 and mode in MODES
        self.token = secrets.token_hex(20)
        self.mode, self.fault, self.dns_fault = mode, '', ''
        self.events, self.servers, self.sockets = [], [], []
        self.connections = set()
        self.lock = threading.RLock()
        self.done = threading.Event()
        self.proxy_off = False
        self.start_http(False)
        self.start_http(True)
        self.start_udp()
        self.proxy = self.bind(socket.AF_INET, socket.SOCK_STREAM, bridge4)
        self.proxy.listen(64)
        self.thread(self.accept)
        self.start_control()

    def thread(self, fn, *args):
        threading.Thread(target=fn, args=args, daemon=True).start()

    def record(self, event, **fields):
        with self.lock:
            row = dict(t=time.monotonic(), event=event, **fields)
            self.events.append(row)
            with (self.root / 'events.jsonl').open('a') as out:
                out.write(json.dumps(row) + '\n')

    def bind(self, family, kind, address, port=0):
        sock = socket.socket(family, kind)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((address, port))
        sock.settimeout(.2)
        self.sockets.append(sock)
        return sock

    def name_class(self, name):
        name = name.lower().rstrip('.')
        if not name.endswith('.mimo-lab.test'):
            return None
        prefix = name.split('-', 1)[0]
        return prefix if prefix in ('aonly', 'aaaaonly', 'dual4', 'dual6', 'nx') else None

    def destinations(self, name):
        cls = self.name_class(name)
        return {'aonly': [self.data4], 'aaaaonly': [self.data6],
                'dual4': [self.data4, self.data6], 'dual6': [self.data6, self.data4]}.get(cls, [])

    def dns_response(self, query):
        name, end = dns_name(query, 12)
        kind, cls = struct.unpack('!HH', query[end:end + 4])
        fault = self.dns_fault
        if fault == 'timeout':
            time.sleep(6)
        values = self.destinations(name)
        rcode = 3 if not values else 0
        if fault == 'servfail':
            rcode, values = 2, []
        if fault == 'nxdomain':
            rcode, values = 3, []
        if fault == 'nodata6' and kind == 28:
            values = []
        answers = []
        for value in values:
            ip = ipaddress.ip_address(value)
            if (kind == 1 and ip.version == 4) or (kind == 28 and ip.version == 6):
                answers.append(b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, 2, len(ip.packed)) + ip.packed)
        self.record('dns', name=name, qtype=kind, rcode=rcode, answer_count=len(answers), fault=fault)
        return query[:2] + struct.pack('!5H', 0x8180 | rcode, 1, len(answers), 0, 0) + query[12:end + 4] + b''.join(answers)

    def start_http(self, tls):
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def handle_query(self, query):
                data = fixture.dns_response(query)
                self.send_response(200)
                self.send_header('Content-Type', 'application/dns-message')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                if self.path == '/dns-query' and tls:
                    self.handle_query(self.rfile.read(min(int(self.headers.get('Content-Length', '0')), 65535)))
                else:
                    self.send_error(404)

            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                if parsed.path == '/dns-query' and tls:
                    data = urllib.parse.parse_qs(parsed.query).get('dns', [''])[0]
                    self.handle_query(base64.urlsafe_b64decode(data + '=' * (-len(data) % 4)))
                    return
                provider = getattr(fixture, 'provider_reply', None)
                if provider and tls:
                    family = 6 if self.connection.family == socket.AF_INET6 else 4
                    value = provider(self.headers.get('Host', '').split(':')[0], parsed.path, family)
                    if value is not None:
                        data = json.dumps(value).encode()
                        self.send_response(200); self.send_header('Content-Type', 'application/json')
                        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
                        return
                parts = parsed.path.strip('/').split('/')
                if len(parts) != 2 or parts[0] != fixture.token:
                    self.send_error(404)
                    return
                case = parts[1]
                family = 6 if self.connection.family == socket.AF_INET6 else 4
                size = int(urllib.parse.parse_qs(parsed.query).get('size', ['512'])[0])
                size = min(max(size, 0), 262144)
                value = {'case': case, 'family': family, 'marker': fixture.token, 'payload': 'm' * size}
                data = json.dumps(value, separators=(',', ':')).encode()
                fixture.record('service_tcp', case=case, family=family, tls=tls, bytes=len(data))
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(data)
                self.close_connection = True

            def log_message(self, *args):
                pass

        class HTTP4(http.server.ThreadingHTTPServer):
            daemon_threads = True
            request_queue_size = 64

            def handle_error(self, request, client_address):
                pass

        class HTTP6(HTTP4):
            address_family = socket.AF_INET6

            def server_bind(self):
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                super().server_bind()

        first = HTTP4((self.data4, 0), Handler)
        second = HTTP6((self.data6, first.server_port), Handler)
        for server in (first, second):
            if tls:
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                ctx.load_cert_chain(str(self.root / 'server.crt'), str(self.root / 'server.key'))
                server.socket = ctx.wrap_socket(server.socket, server_side=True)
            self.servers.append(server)
            self.thread(server.serve_forever, .1)
        setattr(self, 'https_port' if tls else 'http_port', first.server_port)

    def start_udp(self):
        first = self.bind(socket.AF_INET, socket.SOCK_DGRAM, self.data4)
        self.udp_port = first.getsockname()[1]
        second = self.bind(socket.AF_INET6, socket.SOCK_DGRAM, self.data6, self.udp_port)
        for sock in (first, second):
            self.thread(self.udp_service, sock)

    def udp_service(self, sock):
        while not self.done.is_set():
            try:
                data, peer = sock.recvfrom(32768)
                parts = data.split(b':', 2)
                if len(parts) != 3 or parts[0].decode() != self.token:
                    continue
                family = 6 if sock.family == socket.AF_INET6 else 4
                self.record('service_udp', case=parts[1].decode(), family=family, bytes=len(data))
                sock.sendto(str(family).encode() + b':' + data, peer)
            except socket.timeout:
                pass
            except OSError:
                return

    def accept(self):
        while not self.done.is_set():
            try:
                client, peer = self.proxy.accept()
                if peer[0] != self.client4 or self.proxy_off:
                    client.close()
                    continue
                with self.lock:
                    self.connections.add(client)
                self.thread(self.connection, client)
            except socket.timeout:
                pass
            except OSError:
                return

    def target(self, host, port, protocol):
        allowed_ports = (self.http_port, self.https_port) if protocol == 'tcp' else (self.udp_port,)
        if port not in allowed_ports:
            return None
        targets = [self.data6] if host in NAT64_TEST_TARGETS else ([host] if host in (self.data4, self.data6) else self.destinations(host))
        return targets[0] if targets else None

    def connect_port(self, host, port):
        return port

    def reply(self, client, code, host='0.0.0.0', port=0):
        client.sendall(bytes([5, code, 0]) + socks_address(host, port))

    def connection(self, client):
        upstream = relay = None
        relay_port = 0
        alive = threading.Event()
        alive.set()
        try:
            client.settimeout(6)
            version, count = exact(client, 2)
            methods = exact(client, count)
            if self.fault == 'require_auth' and version == 5 and 2 in methods:
                client.sendall(b'\x05\x02')
                auth_version, user_len = exact(client, 2)
                username = exact(client, user_len)
                password = exact(client, exact(client, 1)[0])
                accepted = auth_version == 1 and username == b'lab' and hmac.compare_digest(password, self.token.encode())
                client.sendall(bytes([1, 0 if accepted else 1]))
                self.record('authentication', accepted=accepted)
                if not accepted:
                    return
            elif version != 5 or 0 not in methods or self.fault in ('auth', 'require_auth'):
                client.sendall(b'\x05\xff')
                return
            else:
                client.sendall(b'\x05\x00')
            version, operation, reserved = exact(client, 3)
            host, port, atyp = read_socks(client)
            assert version == 5 and reserved == 0
            if operation == 3:
                if self.fault == 'no_udp':
                    self.reply(client, 7)
                    return
                relay = self.bind(socket.AF_INET, socket.SOCK_DGRAM, self.bridge4)
                relay_port = relay.getsockname()[1]
                self.reply(client, 0, self.bridge4, relay_port)
                self.record('udp_association', relay_port=relay_port, state='open')
                if self.fault == 'association_close':
                    return
                if self.fault == 'relay_unavailable':
                    relay.close()
                else:
                    self.thread(self.udp_relay, relay, alive)
                while not self.done.is_set() and not self.proxy_off:
                    try:
                        if not client.recv(1):
                            break
                    except socket.timeout:
                        pass
                return
            target = self.target(host, port, 'tcp')
            if operation != 1 or target is None:
                self.reply(client, 7 if operation != 1 else 2)
                return
            family = 6 if ':' in target else 4
            behavior = MODES[self.mode][0] if family == 6 else 'forward'
            self.record('proxy_tcp_attempt', name=host if atyp == 3 else None, atyp=atyp,
                        requested=host, family=family, port=port, behavior=behavior)
            if self.fault == 'no_domain' and atyp == 3:
                self.reply(client, 8)
                return
            if self.fault.startswith('reply_'):
                self.reply(client, int(self.fault.split('_')[1]))
                return
            if behavior == 'reject':
                self.reply(client, 3)
                return
            if behavior == 'stall':
                self.done.wait(6)
                return
            upstream = socket.socket(socket.AF_INET6 if family == 6 else socket.AF_INET, socket.SOCK_STREAM)
            upstream.settimeout(4)
            upstream.connect((target, self.connect_port(host, port)))
            with self.lock:
                self.connections.add(upstream)
            self.reply(client, 0, target, upstream.getsockname()[1])
            self.record('proxy_tcp_connected', family=family, name=host if atyp == 3 else None, port=port)
            if self.fault == 'reset':
                return
            while not self.done.is_set() and not self.proxy_off:
                ready, _, _ = select.select([client, upstream], [], [], .2)
                for src in ready:
                    data = src.recv(65536)
                    if not data:
                        return
                    (upstream if src is client else client).sendall(data)
        except (OSError, EOFError, ValueError, AssertionError):
            pass
        finally:
            alive.clear()
            if relay:
                self.record('udp_association', relay_port=relay_port, state='closed')
                relay.close()
            for sock in (client, upstream):
                if sock:
                    with self.lock:
                        self.connections.discard(sock)
                    sock.close()

    def udp_relay(self, relay, alive):
        client_peer = None
        while alive.is_set() and not self.done.is_set() and not self.proxy_off:
            try:
                data, peer = relay.recvfrom(32768)
                if peer[0] != self.client4 or data[:3] != b'\0\0\0':
                    continue
                if client_peer is not None and peer != client_peer:
                    continue
                client_peer = peer
                reader = Reader(data[3:])
                host, port, atyp = read_socks(reader)
                target = self.target(host, port, 'udp')
                if target is None:
                    continue
                payload = reader.stream.read()
                family = 6 if ':' in target else 4
                behavior = MODES[self.mode][1] if family == 6 else 'forward'
                self.record('proxy_udp_attempt', family=family, atyp=atyp, behavior=behavior,
                            requested=host,
                            case=payload.split(b':', 2)[1].decode(errors='replace') if b':' in payload else '')
                if behavior == 'drop' or self.fault == 'drop_udp':
                    continue
                self.thread(self.udp_exchange, relay, alive, peer, target, port, payload, family, host)
            except socket.timeout:
                pass
            except (OSError, ValueError, EOFError, IndexError):
                return

    def udp_exchange(self, relay, alive, peer, target, port, payload, family, requested):
        try:
            with socket.socket(socket.AF_INET6 if family == 6 else socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(2)
                sock.connect((target, port))
                sock.sendall(payload)
                response = sock.recv(32768)
            if alive.is_set() and not self.done.is_set() and not self.proxy_off:
                # The labeled NAT64 fixture maps a virtual destination; replies
                # must preserve that virtual source for the client's UDP flow.
                source = requested if requested in NAT64_TEST_TARGETS else target
                relay.sendto(b'\0\0\0' + socks_address(source, port) + response, peer)
        except OSError:
            pass

    def start_control(self):
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def allowed(self):
                return self.client_address[0] in (fixture.client4, fixture.bridge4) and self.headers.get('Authorization') == 'Bearer ' + fixture.token

            def do_GET(self):
                if not self.allowed():
                    self.send_error(403)
                    return
                with fixture.lock:
                    data = json.dumps({'mode': fixture.mode, 'fault': fixture.fault,
                                       'dns_fault': fixture.dns_fault, 'events': fixture.events}).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                if not self.allowed():
                    self.send_error(403)
                    return
                value = json.loads(self.rfile.read(min(int(self.headers.get('Content-Length', 0)), 4096)))
                with fixture.lock:
                    if 'mode' in value:
                        assert value['mode'] in MODES
                        fixture.mode = value['mode']
                    if 'fault' in value:
                        assert value['fault'] in ('', 'auth', 'require_auth', 'no_udp', 'no_domain', 'drop_udp', 'relay_unavailable', 'association_close', 'reset', 'reply_3', 'reply_7', 'reply_8')
                        fixture.fault = value['fault']
                    if 'dns_fault' in value:
                        assert value['dns_fault'] in ('', 'nodata6', 'servfail', 'nxdomain', 'timeout')
                        fixture.dns_fault = value['dns_fault']
                    if value.get('disconnect'):
                        for sock in tuple(fixture.connections):
                            try:
                                sock.shutdown(socket.SHUT_RDWR)
                            except OSError:
                                pass
                    if 'proxy_off' in value:
                        fixture.proxy_off = bool(value['proxy_off'])
                    if value.get('stop'):
                        fixture.done.set()
                self.send_response(204)
                self.end_headers()

            def log_message(self, *args):
                pass

        self.control = http.server.ThreadingHTTPServer((self.bridge4, 0), Handler)
        self.servers.append(self.control)
        self.thread(self.control.serve_forever, .1)

    def manifest(self):
        return {'bridge4': self.bridge4, 'data4': self.data4, 'data6': self.data6,
                'client4': self.client4, 'token': self.token, 'mode': self.mode,
                'proxy_port': self.proxy.getsockname()[1], 'control_port': self.control.server_port,
                'http_port': self.http_port, 'https_port': self.https_port, 'udp_port': self.udp_port}

    def close(self):
        self.done.set()
        for sock in tuple(self.connections):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for sock in self.sockets:
            sock.close()


def main():
    import sys
    root = Path(sys.argv[1])
    assert socket.gethostname().split('.')[0] == 'delta'
    assert root.is_dir() and root.stat().st_mode & 0o077 == 0
    os.umask(0o077)
    fixture = Fixture(root, *sys.argv[2:7])
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: fixture.done.set())
    (root / 'fixture.json').write_text(json.dumps(fixture.manifest()))
    print('READY: restricted dual-stack fixture', flush=True)
    try:
        fixture.done.wait(480)
    finally:
        fixture.close()


if __name__ == '__main__':
    main()
