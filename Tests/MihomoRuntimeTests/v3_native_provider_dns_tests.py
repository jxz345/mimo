#!/usr/bin/env python3
"""Local DNS/parser and temporary-directory ownership tests; never touches /etc."""
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import unittest
from unittest.mock import patch

from v3_native_provider_dns import MAX_DNS, NativeDNS, ResolverFiles, dns_reply


def query(name='ipwho.is', kind=1):
    labels = b''.join(bytes([len(x)]) + x.encode() for x in name.split('.')) + b'\0'
    return struct.pack('!6H', 123, 0x100, 1, 0, 0, 0) + labels + struct.pack('!HH', kind, 1)


class DNSParserTests(unittest.TestCase):
    def testExactProviderAHasLoopbackAndZeroTTL(self):
        response = dns_reply(query(), {'ipwho.is'})
        self.assertEqual(struct.unpack('!6H', response[:12]), (123, 0x8500, 1, 1, 0, 0))
        self.assertEqual(response[-16:], b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 0, 4) + socket.inet_aton('127.0.0.1'))

    def testKnownAAAAAndHTTPSAreLocalNodata(self):
        for kind in (28, 65, 64, 255):
            with self.subTest(kind=kind):
                response = dns_reply(query(kind=kind), {'ipwho.is'})
                self.assertEqual(struct.unpack('!H', response[2:4])[0] & 15, 0)
                self.assertEqual(struct.unpack('!H', response[6:8])[0], 0)

    def testUnknownAndLookalikeNamesAreLocalNXDomain(self):
        for name in ('example.com', 'ipwho.is.attacker.test', 'sub.ipwho.is', 'gulf'):
            self.assertEqual(struct.unpack('!H', dns_reply(query(name), {'ipwho.is'})[2:4])[0] & 15, 3)

    def testMalformedCompressedAndOversizedQueriesAreFormerr(self):
        malformed = [b'', b'123', query()[:14], query() + b'junk', b'x' * (MAX_DNS + 1),
                     query()[:12] + b'\xc0\x0c' + struct.pack('!HH', 1, 1),
                     query()[:12] + b'\x40' + b'x' * 64 + b'\0' + struct.pack('!HH', 1, 1)]
        for value in malformed:
            self.assertEqual(struct.unpack('!H', dns_reply(value, {'ipwho.is'})[2:4])[0] & 15, 1)

    def testWrongOpcodeClassAndQuestionCountAreRejected(self):
        for offset, value in [(2, 0x8100), (2, 0x0900), (4, 2), (6, 1), (8, 1), (10, 2)]:
            data = bytearray(query()); data[offset:offset + 2] = struct.pack('!H', value)
            self.assertEqual(struct.unpack('!H', dns_reply(bytes(data), {'ipwho.is'})[2:4])[0] & 15, 1)
        self.assertEqual(struct.unpack('!H', dns_reply(query()[:-2] + b'\0\x03', {'ipwho.is'})[2:4])[0] & 15, 1)

    def testSingleBoundedEDNSRecordIsAccepted(self):
        data = bytearray(query()); data[10:12] = b'\0\x01'
        data += b'\0' + struct.pack('!HHIH', 41, 1232, 0, 0)
        self.assertEqual(struct.unpack('!H', dns_reply(bytes(data), {'ipwho.is'})[6:8])[0], 1)
        self.assertEqual(struct.unpack('!H', dns_reply(bytes(data) + b'extra', {'ipwho.is'})[2:4])[0] & 15, 1)


class DNSTransportTests(unittest.TestCase):
    def setUp(self): self.server = NativeDNS({'ipwho.is'})
    def tearDown(self): self.server.close()

    def testUDPLoopbackQuery(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.settimeout(2); client.sendto(query(), ('127.0.0.1', self.server.port))
            response, source = client.recvfrom(MAX_DNS)
        self.assertEqual(source, ('127.0.0.1', self.server.port))
        self.assertEqual(response, dns_reply(query(), {'ipwho.is'}))
        self.assertGreaterEqual(self.server.port, 1024)

    def testTCPFramedQuery(self):
        with socket.create_connection(('127.0.0.1', self.server.port), timeout=2) as client:
            message = query(); client.sendall(struct.pack('!H', len(message)) + message)
            length = struct.unpack('!H', client.recv(2))[0]
            response = bytearray()
            while len(response) < length: response.extend(client.recv(length - len(response)))
        self.assertEqual(bytes(response), dns_reply(query(), {'ipwho.is'}))

    def testTCPOversizedFrameClosesWithoutReadingBody(self):
        with socket.create_connection(('127.0.0.1', self.server.port), timeout=2) as client:
            client.sendall(struct.pack('!H', MAX_DNS + 1))
            self.assertEqual(client.recv(1), b'')


class ResolverOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mimo-resolver-ownership-')
        self.root = Path(self.temporary.name); self.root.chmod(0o700)
        self.directory = self.root / 'resolver'
        self.fixture = {'loopback_provider_names': ['ipapi.co', 'ipwho.is']}
        self.manifest = {'native_provider_dns': {'nameserver': '127.0.0.1', 'port': 54321,
                         'names': ['ipapi.co', 'ipwho.is'], 'pid': 123, 'instance': 'fixture-test'}}
        path = self.root / 'native-resolver.json'
        path.write_text(json.dumps(self.manifest)); path.chmod(0o600)
        self.files = ResolverFiles(self.root, self.fixture, self.directory, os.getuid())

    def tearDown(self): self.temporary.cleanup()

    def testInstallReadOnlyVerifyCleanupAndIdempotence(self):
        result = self.files.install()
        self.assertTrue(result['installed']); self.assertEqual(result['port'], 54321)
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.directory.iterdir()}
        self.assertEqual(self.files.verify(), result)
        self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.directory.iterdir()})
        self.assertEqual(self.files.cleanup()['owned_files_removed'], 2)
        self.assertFalse(self.directory.exists())
        self.assertTrue(self.files.cleanup()['cleaned'])

    def testJournalExistsBeforeEachResolverFileCreation(self):
        original = os.open
        observed = []
        def checked(path, *args, **kwargs):
            if Path(path).parent == self.directory:
                observed.append(Path(path).name)
                journal = json.loads(self.files.journal.read_text())
                self.assertIn(Path(path).name, journal['files'])
            return original(path, *args, **kwargs)
        with patch('v3_native_provider_dns.os.open', checked): self.files.install()
        self.assertEqual(sorted(observed), self.fixture['loopback_provider_names'])

    def testRestrictiveProcessUmaskStillCreatesReadableResolverFiles(self):
        previous = os.umask(0o077)
        try: self.files.install()
        finally: os.umask(previous)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o755)
        for name in self.files.names:
            self.assertEqual((self.directory / name).stat().st_mode & 0o777, 0o644)

    def testExistingResolverFileIsNeverOverwritten(self):
        self.directory.mkdir(); existing = self.directory / 'ipwho.is'; existing.write_text('foreign')
        with self.assertRaisesRegex(ValueError, 'already exists'): self.files.install()
        self.assertEqual(existing.read_text(), 'foreign'); self.assertFalse(self.files.journal.exists())

    def testSymlinkResolverDirectoryIsRejected(self):
        target = self.root / 'other'; target.mkdir(); self.directory.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'directory'): self.files.install()

    def testSymlinkProviderFileIsRejected(self):
        self.directory.mkdir(); target = self.root / 'foreign'; target.write_text('untouched')
        (self.directory / 'ipwho.is').symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'already exists'): self.files.install()
        self.assertEqual(target.read_text(), 'untouched')

    def testChangedFileBlocksCleanupBeforeAnyRemoval(self):
        self.files.install(); (self.directory / 'ipwho.is').write_text('foreign replacement')
        with self.assertRaisesRegex(ValueError, 'changed independently'): self.files.cleanup()
        self.assertTrue((self.directory / 'ipapi.co').exists())
        self.assertEqual((self.directory / 'ipwho.is').read_text(), 'foreign replacement')

    def testReplacedInodeWithIdenticalBytesIsNotOwned(self):
        self.files.install(); path = self.directory / 'ipwho.is'
        replacement = self.root / 'replacement'; replacement.write_bytes(path.read_bytes()); replacement.chmod(0o644)
        os.replace(replacement, path)
        with self.assertRaisesRegex(ValueError, 'replaced'): self.files.cleanup()
        self.assertTrue((self.directory / 'ipapi.co').exists())

    def testChangedModeIsRejected(self):
        self.files.install(); (self.directory / 'ipwho.is').chmod(0o600)
        with self.assertRaisesRegex(ValueError, 'permissions'): self.files.verify()

    def testForeignFileAndPreexistingDirectoryRemain(self):
        self.directory.mkdir(mode=0o755); foreign = self.directory / 'unrelated.test'; foreign.write_text('keep')
        self.files.install(); self.files.cleanup()
        self.assertEqual(foreign.read_text(), 'keep'); self.assertTrue(self.directory.exists())

    def testWrongManifestOwnerAndUnknownProviderAreRejected(self):
        with self.assertRaises(ValueError): ResolverFiles(self.root, self.fixture, self.directory, os.getuid() + 1)
        with self.assertRaisesRegex(ValueError, 'provider list'):
            ResolverFiles(self.root, {'loopback_provider_names': ['attacker.test']}, self.directory, os.getuid())

    def testPartialInstallCleanupRemovesOnlyRecordedOwnedFile(self):
        original = os.open
        def fail_second(path, *args, **kwargs):
            if Path(path) == self.directory / 'ipwho.is': raise OSError('simulated creation failure')
            return original(path, *args, **kwargs)
        with patch('v3_native_provider_dns.os.open', fail_second):
            with self.assertRaises(OSError): self.files.install()
        self.assertEqual(self.files.cleanup()['owned_files_removed'], 1)


if __name__ == '__main__': unittest.main()
