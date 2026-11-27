#!/usr/bin/env python3
"""VM-only exact-provider DNS. No forwarding, hosts edits, or trust changes.

create ROOT [--port PORT] runs an owned loopback listener. install/inspect/cleanup
are separate commands. Resolver files are journaled before creation and removed
only when their recorded identity, ownership, mode and exact bytes still match.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import socketserver
import stat
import struct
import threading
import time
import uuid

PROVIDERS = frozenset({'ipwho.is', 'ipapi.co', 'api.ipapi.is', 'api.ipinfo.io',
                       'v4.api.ipinfo.io', 'v6.api.ipinfo.io'})
MAX_DNS = 4096


def names_from_fixture(fixture):
    names = fixture.get('loopback_provider_names')
    if not isinstance(names, list) or not names or len(set(names)) != len(names) or not set(names) <= PROVIDERS:
        raise ValueError('Invalid certificate-supported provider list')
    return sorted(names)


def dns_reply(query, names):
    identifier = query[:2] if len(query) >= 2 else b'\0\0'
    def error():
        return identifier + struct.pack('!5H', 0x8001, 0, 0, 0, 0)
    if not 12 <= len(query) <= MAX_DNS:
        return error()
    flags, qd, an, ns, ar = struct.unpack('!5H', query[2:12])
    if flags & 0xf800 or qd != 1 or an or ns or ar > 1:
        return error()
    offset, labels = 12, []
    try:
        while True:
            length = query[offset]; offset += 1
            if length == 0:
                break
            # Compression is unnecessary for one question; reject pointers,
            # extended labels, loops and out-of-range references uniformly.
            if length > 63 or offset + length > len(query):
                return error()
            labels.append(query[offset:offset + length].decode('ascii').lower())
            offset += length
            if len(labels) > 127 or sum(map(len, labels)) + len(labels) - 1 > 253:
                return error()
        qtype, qclass = struct.unpack('!HH', query[offset:offset + 4])
        offset += 4
        question_end = offset
        if qclass != 1:
            return error()
        if ar:
            if query[offset] != 0:
                return error()
            kind, _, _, size = struct.unpack('!HHIH', query[offset + 1:offset + 11])
            if kind != 41 or offset + 11 + size != len(query):
                return error()
        elif offset != len(query):
            return error()
    except (IndexError, UnicodeError, struct.error):
        return error()
    known = '.'.join(labels) in names
    answer = b''
    if known and qtype == 1:
        answer = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 0, 4) + socket.inet_aton('127.0.0.1')
    # Known AAAA, HTTPS and other types receive local NODATA, never forwarding.
    response_flags = 0x8400 | (flags & 0x0100) | (0 if known else 3)
    return identifier + struct.pack('!5H', response_flags, 1, bool(answer), 0, 0) + query[12:question_end] + answer


class NativeDNS:
    def __init__(self, names, port=0):
        self.names, self.done = frozenset(names), threading.Event()
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(('127.0.0.1', port)); self.udp.settimeout(.2)
        self.port = self.udp.getsockname()[1]
        if self.port < 1024:
            self.udp.close(); raise ValueError('An unprivileged DNS port is required')
        owner = self
        slots = threading.BoundedSemaphore(16)
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                if not slots.acquire(False):
                    return
                try:
                    deadline = time.monotonic() + 3
                    def exact(count):
                        value = bytearray()
                        while len(value) < count:
                            self.request.settimeout(max(.001, deadline - time.monotonic()))
                            if time.monotonic() >= deadline:
                                raise TimeoutError()
                            data = self.request.recv(count - len(value))
                            if not data:
                                raise EOFError()
                            value.extend(data)
                        return bytes(value)
                    length = struct.unpack('!H', exact(2))[0]
                    if not 12 <= length <= MAX_DNS:
                        return
                    reply = dns_reply(exact(length), owner.names)
                    self.request.sendall(struct.pack('!H', len(reply)) + reply)
                except (OSError, EOFError):
                    pass
                finally:
                    slots.release()
        class TCP(socketserver.ThreadingTCPServer):
            daemon_threads = True
            request_queue_size = 16
            def handle_error(self, *_): pass
        try:
            self.tcp = TCP(('127.0.0.1', self.port), Handler)
        except BaseException:
            self.udp.close(); raise
        self.threads = [threading.Thread(target=self.tcp.serve_forever, args=(.1,), daemon=True),
                        threading.Thread(target=self.serve_udp, daemon=True)]
        for thread in self.threads: thread.start()

    def serve_udp(self):
        while not self.done.is_set():
            try:
                query, peer = self.udp.recvfrom(MAX_DNS + 1)
                if peer[0] == '127.0.0.1': self.udp.sendto(dns_reply(query, self.names), peer)
            except socket.timeout: pass
            except OSError: return

    def close(self):
        self.done.set(); self.udp.close(); self.tcp.shutdown(); self.tcp.server_close()
        for thread in self.threads: thread.join(1)


def regular(path, owner, mode):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != owner or stat.S_IMODE(info.st_mode) != mode:
        raise ValueError('Unexpected owned file identity or permissions')
    return info


class ResolverFiles:
    def __init__(self, root, fixture, resolver_dir=Path('/etc/resolver'), owner=0):
        self.root, self.directory, self.owner = Path(root), Path(resolver_dir), owner
        root_info = self.root.lstat()
        if not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != owner or stat.S_IMODE(root_info.st_mode) != 0o700:
            raise ValueError('Private fixture directory required')
        manifest_path = self.root / 'native-resolver.json'
        regular(manifest_path, owner, 0o600)
        self.manifest = json.loads(manifest_path.read_text())['native_provider_dns']
        self.names = names_from_fixture(fixture)
        if self.manifest.get('names') != self.names or self.manifest.get('nameserver') != '127.0.0.1':
            raise ValueError('Native resolver manifest mismatch')
        self.port = self.manifest.get('port')
        if type(self.port) is not int or not 1024 <= self.port <= 65535:
            raise ValueError('Invalid native resolver port')
        self.journal = self.root / 'native-resolver-journal.json'

    def content(self, name):
        return f'# mimo:observation-test native provider DNS\ndomain {name}\nnameserver 127.0.0.1\nport {self.port}\nsearch_order 1\n'.encode()

    def write_journal(self, value, initial=False):
        data = (json.dumps(value, indent=2) + '\n').encode()
        if initial:
            fd = os.open(self.journal, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as stream: stream.write(data); stream.flush(); os.fsync(stream.fileno())
        else:
            regular(self.journal, self.owner, 0o600)
            temporary = self.root / ('journal-' + uuid.uuid4().hex)
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as stream: stream.write(data); stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, self.journal)

    def read_journal(self):
        regular(self.journal, self.owner, 0o600)
        value = json.loads(self.journal.read_text())
        if value.get('instance') != self.manifest.get('instance') or set(value.get('files', {})) != set(self.names):
            raise ValueError('Resolver journal identity mismatch')
        return value

    def check_directory(self):
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != self.owner or info.st_mode & 0o022:
            raise ValueError('Resolver directory is not safely owned')
        return info

    def install(self):
        if self.journal.exists(): raise ValueError('Resolver journal already exists')
        existed = self.directory.exists()
        if existed: self.check_directory()
        for name in self.names:
            if os.path.lexists(self.directory / name): raise ValueError('Provider resolver already exists')
        journal = {'instance': self.manifest['instance'], 'created_directory': not existed,
                   'files': {name: None for name in self.names}, 'state': 'prepared'}
        self.write_journal(journal, initial=True)  # Before any resolver mutation.
        if not existed:
            self.directory.mkdir(mode=0o755)
            self.directory.chmod(0o755)
        directory_info = self.check_directory()
        journal['directory_identity'] = {'device': directory_info.st_dev, 'inode': directory_info.st_ino}
        self.write_journal(journal)
        for name in self.names:
            path = self.directory / name
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
            try:
                os.fchmod(fd, 0o644)
                if self.owner == 0: os.fchown(fd, 0, 0)
                info = os.fstat(fd)
                journal['files'][name] = {'device': info.st_dev, 'inode': info.st_ino}
                self.write_journal(journal)
                with os.fdopen(fd, 'wb', closefd=False) as stream:
                    stream.write(self.content(name)); stream.flush(); os.fsync(stream.fileno())
            finally: os.close(fd)
        journal['state'] = 'installed'; self.write_journal(journal)
        return self.verify()

    def verify_file(self, name, identity):
        path = self.directory / name
        info = regular(path, self.owner, 0o644)
        if not identity or (info.st_dev, info.st_ino) != (identity['device'], identity['inode']):
            raise ValueError('Resolver file was replaced')
        content = path.read_bytes()
        if content != self.content(name): raise ValueError('Resolver file changed independently')
        return hashlib.sha256(content).hexdigest()

    def verify(self):
        self.check_directory()
        journal = self.read_journal()
        if journal['state'] != 'installed': raise ValueError('Resolver installation is incomplete')
        hashes = {name: self.verify_file(name, identity) for name, identity in journal['files'].items()}
        return {'installed': True, 'nameserver': '127.0.0.1', 'port': self.port,
                'names': self.names, 'file_sha256': hashes, 'instance': self.manifest['instance']}

    def cleanup(self):
        journal = self.read_journal()
        if journal['state'] == 'cleaned':
            return {'cleaned': True, 'owned_files_removed': journal.get('removed_count', 0)}
        info = self.check_directory()
        identity = journal.get('directory_identity')
        if identity and (info.st_dev, info.st_ino) != (identity['device'], identity['inode']):
            raise ValueError('Resolver directory was replaced')
        # Validate every existing owned file before removing any of them.
        for name, identity in journal['files'].items():
            path = self.directory / name
            if os.path.lexists(path): self.verify_file(name, identity)
        removed = 0
        for name, identity in journal['files'].items():
            if identity and os.path.lexists(self.directory / name):
                (self.directory / name).unlink(); removed += 1
        journal['state'] = 'cleaned'; journal['removed_count'] = removed
        self.write_journal(journal)
        if journal['created_directory'] and not any(self.directory.iterdir()): self.directory.rmdir()
        return {'cleaned': True, 'owned_files_removed': removed}


def verify(root, fixture):
    """Read-only ownership/content proof for the burst harness."""
    return ResolverFiles(root, fixture).verify()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('create', 'install', 'inspect', 'cleanup'))
    parser.add_argument('root', type=Path)
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    if os.geteuid() != 0 or not socket.gethostname().startswith('mimo-vm'):
        parser.error('This helper runs only as root in the test VM')
    info = args.root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        parser.error('Use an existing root-owned private fixture directory')
    fixture = json.loads((args.root / 'fixture.json').read_text())
    names = names_from_fixture(fixture)
    if args.operation == 'create':
        if args.port != 0 and not 1024 <= args.port <= 65535: parser.error('Use an unprivileged port')
        listener = NativeDNS(names, args.port)
        try:
            manifest = {'native_provider_dns': {'nameserver': '127.0.0.1', 'port': listener.port,
                        'names': names, 'pid': os.getpid(), 'instance': uuid.uuid4().hex}}
            fd = os.open(args.root / 'native-resolver.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as stream: json.dump(manifest, stream); stream.flush(); os.fsync(stream.fileno())
            signal.signal(signal.SIGTERM, lambda *_: listener.done.set())
            signal.signal(signal.SIGINT, lambda *_: listener.done.set())
            print(json.dumps(manifest), flush=True)
            listener.done.wait()
        finally: listener.close()
    else:
        files = ResolverFiles(args.root, fixture)
        print(json.dumps(getattr(files, 'verify' if args.operation == 'inspect' else args.operation)()), flush=True)


if __name__ == '__main__': main()
