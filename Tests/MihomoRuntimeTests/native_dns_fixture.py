#!/usr/bin/env python3
"""VM-only temporary scoped DNS/search-list fixture; no saved preferences changed."""
import ctypes as C
import json
import os
from pathlib import Path
import plistlib
import select
import socket
import struct
import subprocess
import sys
import threading
import time

from dualstack_fixture import dns_name, exact


class Store:
    def __init__(self):
        self.cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.sc = C.CDLL('/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration')
        for lib, name, result, args in [
            (self.cf, 'CFDataCreate', C.c_void_p, [C.c_void_p, C.c_void_p, C.c_long]),
            (self.cf, 'CFPropertyListCreateWithData', C.c_void_p, [C.c_void_p, C.c_void_p, C.c_ulong, C.c_void_p, C.c_void_p]),
            (self.cf, 'CFPropertyListCreateData', C.c_void_p, [C.c_void_p, C.c_void_p, C.c_long, C.c_ulong, C.c_void_p]),
            (self.cf, 'CFDataGetLength', C.c_long, [C.c_void_p]),
            (self.cf, 'CFDataGetBytePtr', C.c_void_p, [C.c_void_p]),
            (self.cf, 'CFRelease', None, [C.c_void_p]),
            (self.sc, 'SCDynamicStoreCreate', C.c_void_p, [C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p]),
            (self.sc, 'SCDynamicStoreAddTemporaryValue', C.c_bool, [C.c_void_p, C.c_void_p, C.c_void_p]),
            (self.sc, 'SCDynamicStoreSetValue', C.c_bool, [C.c_void_p, C.c_void_p, C.c_void_p]),
            (self.sc, 'SCDynamicStoreCopyMultiple', C.c_void_p, [C.c_void_p, C.c_void_p, C.c_void_p]),
        ]:
            fn = getattr(lib, name); fn.restype = result; fn.argtypes = args
        label = self.ref('Mimo VM DNS test')
        self.store = self.sc.SCDynamicStoreCreate(None, label, None, None)
        self.cf.CFRelease(label)
        assert self.store
        self.keys = set()

    def ref(self, value):
        raw = plistlib.dumps(value)
        data = self.cf.CFDataCreate(None, raw, len(raw))
        value = self.cf.CFPropertyListCreateWithData(None, data, 0, None, None)
        self.cf.CFRelease(data)
        assert value
        return value

    def dns(self):
        pattern = self.ref(['State:/Network/Service/.*/DNS'])
        value = self.sc.SCDynamicStoreCopyMultiple(self.store, None, pattern)
        self.cf.CFRelease(pattern)
        assert value
        data = self.cf.CFPropertyListCreateData(None, value, 200, 0, None)
        try:
            return plistlib.loads(C.string_at(self.cf.CFDataGetBytePtr(data), self.cf.CFDataGetLength(data)))
        finally:
            self.cf.CFRelease(data); self.cf.CFRelease(value)

    def publish(self, key, value):
        k, v = self.ref(key), self.ref(value)
        try:
            fn = self.sc.SCDynamicStoreSetValue if key in self.keys else self.sc.SCDynamicStoreAddTemporaryValue
            assert fn(self.store, k, v), 'Cannot publish temporary DNS'
            self.keys.add(key)
        finally:
            self.cf.CFRelease(k); self.cf.CFRelease(v)

    def close(self):
        if self.store:
            self.cf.CFRelease(self.store); self.store = None


class Client:
    def __init__(self, root):
        self.process = subprocess.Popen(['/usr/bin/python3', str(Path(__file__).resolve()), str(root), str(os.getpid())],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(root / 'native-dns-fixture.log').open('w'), text=True)
        self.read()

    def read(self):
        assert select.select([self.process.stdout], [], [], 5)[0], 'Native DNS fixture deadline'
        value = json.loads(self.process.stdout.readline())
        assert value.get('ok'), value
        return value

    def change_search(self, alternate=False):
        self.process.stdin.write(json.dumps({'alternate': alternate}) + '\n'); self.process.stdin.flush()
        return self.read()

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=3)


def serve(root, parent):
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    f = json.loads((root / 'fixture.json').read_text())
    peer_domain = f.get('native_dns_peer', f['native_peer'])['name'].rstrip('.').partition('.')[2]
    tcp = socket.socket(); tcp.bind(('127.0.0.1', 0)); tcp.listen(8)
    port = tcp.getsockname()[1]
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); udp.bind(('127.0.0.1', port))

    def response(query):
        name, end = dns_name(query, 12); kind = struct.unpack('!H', query[end:end + 2])[0]
        with (root / 'native-dns-queries.jsonl').open('a') as log:
            log.write(json.dumps({'name': name, 'kind': kind}) + '\n')
        if name.endswith('.' + peer_domain):
            try:
                with socket.create_connection(('100.100.100.100', 53), timeout=2) as upstream:
                    upstream.sendall(struct.pack('!H', len(query)) + query)
                    return exact(upstream, struct.unpack('!H', exact(upstream, 2))[0])
            except (OSError, EOFError):
                return query[:2] + struct.pack('!5H', 0x8182, 1, 0, 0, 0) + query[12:end + 4]
        allowed = name.endswith(('.mimo-native.test', '.mimo-native2.test')) and name.split('.')[0].startswith(('lan', 'split'))
        answers = []
        if allowed and kind == 1:
            answers = [b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 0, 4) + socket.inet_aton(f['bridge4'])]
        return query[:2] + struct.pack('!5H', 0x8180 | (0 if allowed else 3), 1, len(answers), 0, 0) + query[12:end + 4] + b''.join(answers)

    def udp_loop():
        while True:
            try: data, address = udp.recvfrom(8192)
            except OSError: return
            try: udp.sendto(response(data), address)
            except (OSError, ValueError, IndexError): pass

    def tcp_loop():
        while True:
            try: client, _ = tcp.accept()
            except OSError: return
            with client:
                client.settimeout(2)
                try:
                    answer = response(exact(client, struct.unpack('!H', exact(client, 2))[0]))
                    client.sendall(struct.pack('!H', len(answer)) + answer)
                except (OSError, EOFError, ValueError, IndexError): pass

    for fn in (udp_loop, tcp_loop): threading.Thread(target=fn, daemon=True).start()
    store = Store(); suffix = root.name
    base = {'ServerAddresses': ['127.0.0.1'], 'ServerPort': port}
    def publish(alternate):
        native_domain = 'mimo-native2.test' if alternate else 'mimo-native.test'
        domains = [native_domain, peer_domain]
        scoped = dict(base, SupplementalMatchDomains=[native_domain], SupplementalMatchOrders=[1])
        store.publish('State:/Network/Service/mimo-test-scoped-' + suffix + '/DNS', scoped)
        store.publish('State:/Network/Service/mimo-test-default-' + suffix + '/DNS',
                      dict(base, SupplementalMatchDomains=[''], SupplementalMatchOrders=[2], SearchDomains=domains))
        print(json.dumps({'ok': True, 'port': port, 'search_count': len(domains)}), flush=True)

    try:
        publish(False)
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            try: os.kill(parent, 0)
            except ProcessLookupError: break
            if select.select([sys.stdin], [], [], .2)[0]:
                line = sys.stdin.readline()
                if not line: break
                publish(json.loads(line)['alternate'])
    finally:
        store.close(); tcp.close(); udp.close()


if __name__ == '__main__':
    serve(Path(sys.argv[1]), int(sys.argv[2]))
