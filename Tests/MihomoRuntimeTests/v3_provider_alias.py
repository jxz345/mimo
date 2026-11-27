#!/usr/bin/env python3
"""Optional, closed provider endpoints for rapid Direct/protected lab tests.

The native relay and SOCKS provider alias have distinct TLS listeners. Neither
listener forwards requests. Only provider names in the existing certificate SAN
are accepted, and HTTP Host must match TLS SNI. No request paths or headers are
logged. This module never changes hosts, trust, routes, or production settings.
"""
import json
import re
import socket
import socketserver
import ssl
import time
import urllib.parse
import uuid

MAX_REQUEST = 8192
VALIDATION_REASONS = {'request_size', 'request_format', 'request_method', 'header_format',
                      'duplicate_header', 'host_mismatch', 'request_body', 'provider_only'}


def transport_error_fields(error):
    """Diagnostics contain identifiers/codes only; never exception messages."""
    name = type(error).__name__
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,63}', name):
        name = 'UnknownError'
    number = getattr(error, 'errno', None)
    if type(number) is not int or not -(2**31) <= number < 2**31:
        number = None
    reason = getattr(error, 'reason', None)
    if not isinstance(reason, str) or not re.fullmatch(r'[A-Z0-9_]{1,80}', reason):
        reason = None
    return {'exception_class':name, 'errno':number, 'ssl_reason':reason}


def certificate_provider_names(path, providers):
    certificate = ssl._ssl._test_decode_cert(str(path))
    names = {value.lower() for kind, value in certificate.get('subjectAltName', []) if kind == 'DNS'}
    return frozenset(providers & names)


def provider_request(data, server_name, names):
    """Parse a single bounded bodyless GET; return only its approved host/path."""
    if len(data) > MAX_REQUEST or not data.endswith(b'\r\n\r\n'):
        raise ValueError('request_size')
    try:
        lines = data.decode('ascii').split('\r\n')
        method, target, version = lines[0].split(' ')
    except (UnicodeError, ValueError):
        raise ValueError('request_format') from None
    if method != 'GET' or version not in ('HTTP/1.0', 'HTTP/1.1') or not target.startswith('/') or target.startswith('//'):
        raise ValueError('request_method')
    if len(target) > 2048 or len(lines) > 36:
        raise ValueError('request_size')
    headers = {}
    for line in lines[1:-2]:
        if ':' not in line or line[:1].isspace():
            raise ValueError('header_format')
        key, value = line.split(':', 1)
        key, value = key.lower(), value.strip()
        if key in headers:
            raise ValueError('duplicate_header')
        headers[key] = value
    host = headers.get('host', '').lower()
    if host.endswith(':443'):
        host = host[:-4]
    if host not in names or host != server_name:
        raise ValueError('host_mismatch')
    if 'transfer-encoding' in headers or headers.get('content-length', '0') != '0':
        raise ValueError('request_body')
    path = urllib.parse.urlsplit(target).path
    if path == '/dns-query':
        raise ValueError('provider_only')
    return host, path


class ProviderAliasEndpoints:
    def __init__(self, fixture, providers):
        self.fixture = fixture
        self.names = certificate_provider_names(fixture.root / 'server.crt', providers)
        if not self.names:
            raise ValueError('The fixture certificate contains no supported provider names')
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(str(fixture.root / 'server.crt'), str(fixture.root / 'server.key'))
        self.context.set_servername_callback(self.server_name)
        self.proxy = self.start('proxy_loopback', {fixture.data4, fixture.bridge4, '127.0.0.1'})
        self.configured_dns = self.start('proxy_configured_dns', {fixture.data4, fixture.bridge4, '127.0.0.1'})
        self.native = self.start('native_relay', {fixture.client4})

    def server_name(self, connection, name, _context):
        name = name.lower() if isinstance(name, str) else None
        connection.provider_sni_accepted = name in self.names
        if name not in self.names:
            return ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME
        connection.provider_name = name
        return None

    def start(self, ingress, clients):
        endpoints = self
        fixture = self.fixture

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                connection_id = uuid.uuid4().hex
                started = time.monotonic()
                started_wall = time.time()
                phase, connection, host_accepted = 'handshake', None, False

                def record(event, **fields):
                    fixture.record(event, ingress=ingress, connection_id=connection_id,
                                   phase=phase, started_monotonic=round(started, 6),
                                   elapsed_seconds=round(time.monotonic()-started, 6),
                                   started_wall_time_epoch=round(started_wall, 6),
                                   wall_time_epoch=round(time.time(), 6),
                                   sni_accepted=bool(getattr(connection, 'provider_sni_accepted', False)),
                                   approved_sni=getattr(connection, 'provider_name', None),
                                   host_accepted=host_accepted, **fields)

                if self.client_address[0] not in clients:
                    record('provider_ingress_rejected', reason='client')
                    return
                self.request.settimeout(5)
                try:
                    # Explicit handshake preserves SNI acceptance facts when a
                    # later handshake/read/write fails. It changes no ACL.
                    connection = endpoints.context.wrap_socket(self.request, server_side=True,
                                                               do_handshake_on_connect=False)
                    with connection:
                        connection.do_handshake()
                        phase = 'read'
                        data = bytearray()
                        while b'\r\n\r\n' not in data and len(data) <= MAX_REQUEST:
                            chunk = connection.recv(min(1024, MAX_REQUEST + 1 - len(data)))
                            if not chunk:
                                record('provider_transport_closed', reason='peer_eof')
                                return
                            data.extend(chunk)
                        phase = 'request_validation'
                        try:
                            host, path = provider_request(bytes(data), getattr(connection, 'provider_name', None), endpoints.names)
                        except ValueError as error:
                            reason = str(error) if str(error) in VALIDATION_REASONS else 'request_format'
                            record('provider_ingress_rejected', reason=reason, **transport_error_fields(error))
                            phase = 'write'
                            connection.sendall(b'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                            return
                        host_accepted = True
                        record('provider_ingress', host=host)
                        phase = 'read'
                        value = fixture.provider_reply(host, path, 4)
                        body = json.dumps(value).encode()
                        status = fixture.provider_status
                        headers = [f'HTTP/1.1 {status} Fixture', 'Content-Type: application/json',
                                   f'Content-Length: {len(body)}', 'Connection: close']
                        retry = fixture.provider_retry_after
                        if retry is not None:
                            headers.append(f'Retry-After: {int(retry)}')
                        phase = 'write'
                        connection.sendall(('\r\n'.join(headers) + '\r\n\r\n').encode() + body)
                        record('provider_response_sent')
                except (OSError, ssl.SSLError) as error:
                    # Keep the strict rejection oracle until an individual
                    # failure is correlated. A write error is not silently
                    # treated as expected cancellation.
                    record('provider_ingress_rejected', reason='tls_or_transport', **transport_error_fields(error))
                except Exception as error:
                    record('provider_ingress_rejected', reason='handler', **transport_error_fields(error))

        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
            request_queue_size = 16

            def handle_error(self, _request, _address):
                fixture.record('provider_ingress_rejected', ingress=ingress, reason='handler',
                               phase='handler', connection_id=uuid.uuid4().hex,
                               started_monotonic=round(time.monotonic(), 6), elapsed_seconds=0,
                               started_wall_time_epoch=round(time.time(), 6), wall_time_epoch=round(time.time(), 6),
                               sni_accepted=False, approved_sni=None, host_accepted=False)

        server = Server((fixture.data4, 0), Handler)
        fixture.servers.append(server)
        fixture.thread(server.serve_forever, .1)
        return server

    def manifest(self):
        return {'loopback_provider_alias': True,
                'loopback_provider_alias_port': self.proxy.server_address[1],
                'protected_provider_port': self.configured_dns.server_address[1],
                'protected_provider_ingress': 'proxy_configured_dns',
                'native_provider_port': self.native.server_address[1],
                'loopback_provider_names': sorted(self.names)}
