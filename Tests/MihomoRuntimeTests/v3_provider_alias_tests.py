#!/usr/bin/env python3
"""Local, ephemeral-loopback tests; no VM, trust-store, or network-setting changes."""
import json
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

from dualstack_fixture import exact, read_socks, socks_address
from v3_installed_fixture import InstalledFixture, PROVIDERS
from v3_provider_alias import MAX_REQUEST, ProviderAliasEndpoints, certificate_provider_names, provider_request


class ProviderAliasTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='mimo-provider-alias-')
        cls.root = Path(cls.directory.name)
        config = cls.root / 'certificate.cnf'
        config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n'
                          '[dn]\nCN=ipwho.is\n[ext]\nsubjectAltName=DNS:ipwho.is,DNS:ipapi.co,DNS:unapproved.test\n')
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-keyout', str(cls.root / 'server.key'), '-out', str(cls.root / 'server.crt'),
                        '-config', str(config)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.context = ssl.create_default_context(cafile=str(cls.root / 'server.crt'))

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        # Exercise production fixture routing and SOCKS handling without starting
        # its public-looking aliases, DNS service, or control endpoint.
        self.fixture = InstalledFixture.__new__(InstalledFixture)
        f = self.fixture
        f.root, f.data4, f.data6 = self.root, '127.0.0.1', '::1'
        f.bridge4 = f.client4 = '127.0.0.1'
        f.servers, f.sockets, f.events, f.connections = [], [], [], set()
        f.lock, f.done = threading.RLock(), threading.Event()
        f.proxy_off, f.provider_status, f.provider_retry_after = False, 200, None
        f.provider_delay, f.fault, f.mode = 0, '', 'S00'
        f.http_port, f.https_port, f.udp_port = 41001, 41002, 41003
        f.provider_alias = None

    def tearDown(self):
        self.fixture.close()

    def enable(self):
        self.fixture.provider_alias = ProviderAliasEndpoints(self.fixture, PROVIDERS)
        return self.fixture.provider_alias

    def request(self, port, host='ipwho.is', request=None, sni='ipwho.is', sock=None):
        if sock is None:
            sock = socket.create_connection(('127.0.0.1', port), timeout=3)
        with self.context.wrap_socket(sock, server_hostname=sni) as connection:
            connection.sendall(request or f'GET /json/?secret=never-log HTTP/1.1\r\nHost: {host}\r\n\r\n'.encode())
            result = bytearray()
            while True:
                chunk = connection.recv(4096)
                if not chunk:
                    return bytes(result)
                result.extend(chunk)

    def wait_event(self, event):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            matches = [r for r in self.fixture.events if r['event'] == event]
            if matches:
                return matches[-1]
            time.sleep(.01)
        self.fail('Expected bounded fixture diagnostic: ' + event)

    def assert_diagnostic(self, row, phase, sni, host):
        self.assertEqual(row['phase'], phase)
        self.assertIs(row['sni_accepted'], sni)
        self.assertIs(row['host_accepted'], host)
        self.assertRegex(row['connection_id'], r'^[a-f0-9]{32}$')
        self.assertGreater(row['started_monotonic'], 0)
        self.assertGreaterEqual(row['elapsed_seconds'], 0)
        self.assertLess(row['elapsed_seconds'], 10)
        self.assertLess(abs(row['wall_time_epoch'] - time.time()), 10)
        self.assertLessEqual(row['started_wall_time_epoch'], row['wall_time_epoch'])
        if sni:
            self.assertIn(row['approved_sni'], ('ipwho.is', 'ipapi.co'))
        else:
            self.assertIsNone(row['approved_sni'])

    def testCancellationBeforeRequestRecordsReadEOFWithoutProviderRequest(self):
        endpoints = self.enable()
        connection = self.context.wrap_socket(socket.create_connection(('127.0.0.1', endpoints.proxy.server_address[1]), timeout=3), server_hostname='ipwho.is')
        connection.close()
        row = self.wait_event('provider_transport_closed')
        self.assert_diagnostic(row, 'read', True, False)
        self.assertEqual(row['reason'], 'peer_eof')
        self.assertFalse(any(r['event'] in ('provider_http', 'provider_ingress_rejected') for r in self.fixture.events))

    def testCancelledAcceptedRequestRecordsWriteErrorWithoutLeakingPayload(self):
        endpoints = self.enable()
        entered, release = threading.Event(), threading.Event()
        original = self.fixture.provider_reply
        def held_reply(*args):
            value = original(*args)
            entered.set()
            if not release.wait(3):
                raise TimeoutError('Local cancellation test did not release')
            return value
        self.fixture.provider_reply = held_reply
        connection = self.context.wrap_socket(socket.create_connection(('127.0.0.1', endpoints.proxy.server_address[1]), timeout=3), server_hostname='ipwho.is')
        try:
            connection.sendall(b'GET /json/?PRIVATE_SECRET HTTP/1.1\r\nHost: ipwho.is\r\nAuthorization: PRIVATE_SECRET\r\n\r\n')
            self.assertTrue(entered.wait(3))
            connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
            connection.close()
            time.sleep(.05)
            release.set()
            row = self.wait_event('provider_ingress_rejected')
            self.assert_diagnostic(row, 'write', True, True)
            self.assertEqual(row['reason'], 'tls_or_transport')
            self.assertIn(row['exception_class'], ('SSLEOFError', 'SSLError', 'BrokenPipeError', 'ConnectionResetError'))
            ingress = self.wait_event('provider_ingress')
            self.assertEqual(row['connection_id'], ingress['connection_id'])
            self.assertNotIn('PRIVATE_SECRET', json.dumps(self.fixture.events))
        finally:
            release.set()
            connection.close()

    def testUnknownSNIHasHandshakeDiagnosticAndRemainsRejected(self):
        endpoints = self.enable()
        with self.assertRaises(ssl.SSLError):
            self.request(endpoints.proxy.server_address[1], host='unapproved.test', sni='unapproved.test')
        row = self.wait_event('provider_ingress_rejected')
        self.assert_diagnostic(row, 'handshake', False, False)
        self.assertEqual(row['exception_class'], 'SSLError')
        self.assertIsInstance(row['errno'], int)
        self.assertRegex(row['ssl_reason'], r'^[A-Z0-9_]{1,80}$')
        self.assertFalse(any(r['event'] == 'provider_http' for r in self.fixture.events))

    def testHostMismatchHasValidationDiagnosticAndRemainsRejected(self):
        endpoints = self.enable()
        self.assertTrue(self.request(endpoints.proxy.server_address[1], host='ipapi.co').startswith(b'HTTP/1.1 400'))
        row = self.wait_event('provider_ingress_rejected')
        self.assert_diagnostic(row, 'request_validation', True, False)
        self.assertEqual(row['reason'], 'host_mismatch')
        self.assertEqual(row['exception_class'], 'ValueError')
        self.assertIsNone(row['errno'])

    def testNonTLSTransportFailureHasHandshakeDiagnostic(self):
        endpoints = self.enable()
        with socket.create_connection(('127.0.0.1', endpoints.proxy.server_address[1]), timeout=3) as connection:
            connection.sendall(b'GET /PRIVATE_SECRET HTTP/1.1\r\nHost: PRIVATE_SECRET\r\n\r\n')
            row = self.wait_event('provider_ingress_rejected')
        self.assert_diagnostic(row, 'handshake', False, False)
        self.assertEqual(row['exception_class'], 'SSLError')
        self.assertNotIn('PRIVATE_SECRET', json.dumps(self.fixture.events))

    def testSuccessfulResponseHasCorrelatedBoundedDiagnostics(self):
        endpoints = self.enable()
        self.assertTrue(self.request(endpoints.proxy.server_address[1]).startswith(b'HTTP/1.1 200'))
        ingress = self.wait_event('provider_ingress')
        sent = self.wait_event('provider_response_sent')
        self.assert_diagnostic(ingress, 'request_validation', True, True)
        self.assert_diagnostic(sent, 'write', True, True)
        self.assertEqual(ingress['connection_id'], sent['connection_id'])

    def testExceptionDiagnosticsExcludeRawErrorText(self):
        from v3_provider_alias import transport_error_fields
        fields = transport_error_fields(OSError(5, 'PRIVATE_SECRET https://private.invalid/?token=PRIVATE_SECRET'))
        self.assertEqual(fields, {'exception_class':'OSError', 'errno':5, 'ssl_reason':None})
        self.assertNotIn('PRIVATE_SECRET', json.dumps(fields))

    def testAuthenticatedControlReturnsAuthoritativeClock(self):
        self.fixture.token='local-clock-test'
        self.fixture.dns_fault=''
        self.fixture.start_control()
        url='http://127.0.0.1:'+str(self.fixture.control.server_address[1])
        request=urllib.request.Request(url,headers={'Authorization':'Bearer local-clock-test'})
        before=time.time()
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=3) as response:
            value=json.load(response)
        after=time.time()
        self.assertLessEqual(before,value['fixture_clock_epoch'])
        self.assertLessEqual(value['fixture_clock_epoch'],after)

    def testUnauthenticatedControlDoesNotReturnClock(self):
        self.fixture.token='local-clock-test'
        self.fixture.dns_fault=''
        self.fixture.start_control()
        url='http://127.0.0.1:'+str(self.fixture.control.server_address[1])
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.build_opener(urllib.request.ProxyHandler({})).open(url,timeout=3)
        self.assertEqual(caught.exception.code,403)

    def testDisabledAliasPreservesExistingDestinations(self):
        f = self.fixture
        f.data4, f.data6 = '192.0.2.254', '2001:db8::254'
        self.assertIsNone(f.target('127.0.0.1', 443, 'tcp'))
        self.assertIsNone(f.target('ipwho.is', 443, 'tcp'))
        self.assertEqual(f.target('1.1.1.1', 443, 'tcp'), f.data4)
        self.assertEqual(f.connect_port('1.1.1.1', 443), f.https_port)
        self.assertEqual(f.servers, [])

    def testOnlyLoopbackAndCertificateProvidersTCP443GetAliasPort(self):
        endpoints = self.enable()
        f = self.fixture
        f.data4, f.data6 = '192.0.2.254', '2001:db8::254'
        self.assertEqual(f.target('127.0.0.1', 443, 'tcp'), f.data4)
        self.assertEqual(f.connect_port('127.0.0.1', 443), endpoints.proxy.server_address[1])
        for host in endpoints.names:
            self.assertEqual(f.target(host, 443, 'tcp'), f.data4)
            self.assertEqual(f.connect_port(host, 443), endpoints.proxy.server_address[1])
            self.assertIsNone(f.target(host, 443, 'udp'))
            for port in (22, 80, 444, 8443):
                self.assertIsNone(f.target(host, port, 'tcp'))
        for host in ('127.0.0.2', '::1', 'localhost', '192.0.2.1',
                     'ipwho.is.attacker.test', 'unapproved.test', 'api.ipapi.is'):
            for protocol in ('tcp', 'udp'):
                with self.subTest(host=host, protocol=protocol):
                    self.assertIsNone(f.target(host, 443, protocol))
        for port in (22, 80, 444, 8443):
            self.assertIsNone(f.target('127.0.0.1', port, 'tcp'))
        self.assertIsNone(f.target('127.0.0.1', 443, 'udp'))

    def testProviderAllowlistIntersectsCertificateSAN(self):
        self.assertEqual(certificate_provider_names(self.root / 'server.crt', PROVIDERS), {'ipwho.is', 'ipapi.co'})
        endpoints = self.enable()
        self.assertNotIn('api.ipapi.is', endpoints.names)
        self.assertNotIn('unapproved.test', endpoints.names)

    def testNativeIngressUsesVerifiedTLSAndNoQueryLogging(self):
        endpoints = self.enable()
        response = self.request(endpoints.native.server_address[1])
        self.assertTrue(response.startswith(b'HTTP/1.1 200'))
        self.assertEqual(json.loads(response.split(b'\r\n\r\n')[1])['ip'], '203.0.113.10')
        self.assertTrue(any(r['event'] == 'provider_ingress' and r['ingress'] == 'native_relay' for r in self.fixture.events))
        self.assertNotIn('never-log', json.dumps(self.fixture.events))

    def testSOCKSAliasUsesSeparateProxyIngress(self):
        self.enable()
        client, server = socket.socketpair()
        worker = threading.Thread(target=self.fixture.connection, args=(server,), daemon=True)
        worker.start()
        client.settimeout(3)
        client.sendall(b'\x05\x01\x00')
        self.assertEqual(exact(client, 2), b'\x05\x00')
        client.sendall(b'\x05\x01\x00' + socks_address('127.0.0.1', 443))
        self.assertEqual(exact(client, 3), b'\x05\x00\x00')
        read_socks(client)
        response = self.request(None, sock=client)
        worker.join(3)
        self.assertTrue(response.startswith(b'HTTP/1.1 200'))
        self.assertTrue(any(r['event'] == 'provider_ingress' and r['ingress'] == 'proxy_loopback' for r in self.fixture.events))
        self.assertFalse(any(r.get('ingress') == 'native_relay' for r in self.fixture.events))

    def testSOCKSHostnameAliasUsesVerifiedProviderTLS(self):
        self.enable()
        client, server = socket.socketpair()
        worker = threading.Thread(target=self.fixture.connection, args=(server,), daemon=True)
        worker.start()
        client.settimeout(3)
        client.sendall(b'\x05\x01\x00')
        self.assertEqual(exact(client, 2), b'\x05\x00')
        client.sendall(b'\x05\x01\x00' + socks_address('ipwho.is', 443))
        self.assertEqual(exact(client, 3), b'\x05\x00\x00')
        read_socks(client)
        response = self.request(None, sock=client)
        worker.join(3)
        self.assertTrue(response.startswith(b'HTTP/1.1 200'))
        self.assertTrue(any(r['event'] == 'proxy_tcp_attempt' and r.get('name') == 'ipwho.is' for r in self.fixture.events))
        self.assertTrue(any(r['event'] == 'provider_ingress' and r['ingress'] == 'proxy_loopback' for r in self.fixture.events))

    def testSOCKSHostnameLookalikeAndOtherPortAreRejected(self):
        self.enable()
        for host, port in [('ipwho.is.attacker.test', 443), ('unapproved.test', 443),
                           ('api.ipapi.is', 443), ('ipwho.is', 80), ('ipwho.is', 444)]:
            with self.subTest(host=host, port=port):
                client, server = socket.socketpair()
                worker = threading.Thread(target=self.fixture.connection, args=(server,), daemon=True)
                worker.start()
                with client:
                    client.settimeout(3)
                    client.sendall(b'\x05\x01\x00')
                    self.assertEqual(exact(client, 2), b'\x05\x00')
                    client.sendall(b'\x05\x01\x00' + socks_address(host, port))
                    self.assertEqual(exact(client, 3), b'\x05\x02\x00')
                    read_socks(client)
                worker.join(3)
        self.assertFalse(any(r['event'] == 'provider_http' for r in self.fixture.events))

    def testUnknownSNIRejectedEvenIfCertificateCoversIt(self):
        endpoints = self.enable()
        with self.assertRaises(ssl.SSLError):
            self.request(endpoints.proxy.server_address[1], host='unapproved.test', sni='unapproved.test')
        self.assertFalse(any(r['event'] == 'provider_http' for r in self.fixture.events))

    def testNativeEndpointRejectsUnexpectedClient(self):
        self.fixture.client4 = '192.0.2.254'
        endpoints = self.enable()
        with self.assertRaises((ssl.SSLError, ConnectionError)):
            self.request(endpoints.native.server_address[1])
        self.assertTrue(any(r.get('reason') == 'client' for r in self.fixture.events))
        self.assertFalse(any(r['event'] == 'provider_http' for r in self.fixture.events))

    def testHostMustMatchApprovedSNI(self):
        endpoints = self.enable()
        for host in ('ipapi.co', 'unapproved.test', 'ipwho.is:444', 'ipwho.is.attacker.test'):
            with self.subTest(host=host):
                response = self.request(endpoints.proxy.server_address[1], host=host)
                self.assertTrue(response.startswith(b'HTTP/1.1 400'))
        self.assertFalse(any(r['event'] == 'provider_http' for r in self.fixture.events))

    def testMalformedDuplicateAndBodyRequestsRejected(self):
        endpoints = self.enable()
        requests = [b'POST / HTTP/1.1\r\nHost: ipwho.is\r\n\r\n',
                    b'GET / HTTP/1.1\r\nHost: ipwho.is\r\nHost: ipwho.is\r\n\r\n',
                    b'GET / HTTP/1.1\r\nHost: ipwho.is\r\nContent-Length: 1\r\n\r\n',
                    b'GET /dns-query HTTP/1.1\r\nHost: ipwho.is\r\n\r\n',
                    b'GET https://ipwho.is/ HTTP/1.1\r\nHost: ipwho.is\r\n\r\n']
        for request in requests:
            self.assertTrue(self.request(endpoints.proxy.server_address[1], request=request).startswith(b'HTTP/1.1 400'))
        self.assertFalse(any(r['event'] == 'provider_http' for r in self.fixture.events))

    def testRequestSizeIsBounded(self):
        names = {'ipwho.is'}
        request = b'GET / HTTP/1.1\r\nHost: ipwho.is\r\nX-Large: ' + b'x' * MAX_REQUEST + b'\r\n\r\n'
        with self.assertRaisesRegex(ValueError, 'request_size'):
            provider_request(request, 'ipwho.is', names)

    def testIPv4ProviderStatusAndRetryRemainControlled(self):
        endpoints = self.enable()
        self.fixture.provider_status, self.fixture.provider_retry_after = 429, 600
        response = self.request(endpoints.native.server_address[1])
        self.assertTrue(response.startswith(b'HTTP/1.1 429'))
        self.assertIn(b'Retry-After: 600', response)
        self.assertEqual(sum(r['event'] == 'provider_http' for r in self.fixture.events), 1)

    def testManifestIncludesDistinctPortsAndNoCredentials(self):
        endpoints = self.enable()
        manifest = endpoints.manifest()
        self.assertIs(manifest['loopback_provider_alias'], True)
        self.assertNotEqual(manifest['native_provider_port'], manifest['loopback_provider_alias_port'])
        self.assertNotEqual(manifest['native_provider_port'], manifest['protected_provider_port'])
        self.assertEqual(manifest['protected_provider_ingress'], 'proxy_configured_dns')
        self.assertEqual(manifest['loopback_provider_names'], ['ipapi.co', 'ipwho.is'])
        self.assertEqual(set(manifest), {'loopback_provider_alias', 'loopback_provider_alias_port', 'native_provider_port',
                                        'protected_provider_port', 'protected_provider_ingress', 'loopback_provider_names'})

    def testConfiguredDNSProviderUsesDedicatedIngressAndLeavesDoHUnchanged(self):
        endpoints = self.enable()
        self.fixture.data4 = '192.0.2.254'
        self.assertEqual(self.fixture.connect_port('192.0.2.254', 443), endpoints.configured_dns.server_address[1])
        self.assertEqual(self.fixture.connect_port('1.1.1.1', 443), self.fixture.https_port)
        response = self.request(endpoints.configured_dns.server_address[1])
        self.assertTrue(response.startswith(b'HTTP/1.1 200'))
        self.assertTrue(any(r['event'] == 'provider_ingress' and r['ingress'] == 'proxy_configured_dns' for r in self.fixture.events))


if __name__ == '__main__':
    unittest.main()
