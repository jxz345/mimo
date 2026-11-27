#!/usr/bin/env python3
"""Closed fixture with public-looking targets and a persistent TCP echo service."""
import json
from pathlib import Path
import signal
import socket
import sys
from v3_installed_fixture import InstalledFixture
from dualstack_fixture import socks_address


class ClosureFixture(InstalledFixture):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Reserve a real non-listening endpoint for connection-refused tests.
        self.refused = self.bind(socket.AF_INET, socket.SOCK_STREAM, self.bridge4)
        first = self.bind(socket.AF_INET, socket.SOCK_STREAM, self.data4)
        self.stream_port = first.getsockname()[1]
        second = self.bind(socket.AF_INET6, socket.SOCK_STREAM, self.data6, self.stream_port)
        for server in (first, second):
            server.listen(32)
            self.thread(self.stream_accept, server)

    def stream_accept(self, server):
        while not self.done.is_set():
            try:
                client, _ = server.accept()
                self.thread(self.stream_client, client)
            except socket.timeout:
                pass

    def stream_client(self, client):
        with client:
            client.settimeout(3)
            while not self.done.is_set():
                try:
                    value = client.recv(4096)
                    if not value or not value.startswith(self.token.encode() + b':'):
                        return
                    client.sendall(value)
                    self.record('service_stream', family=6 if client.family == socket.AF_INET6 else 4,
                                bytes=len(value))
                except OSError:
                    return

    def target(self, host, port, protocol):
        ports = (self.http_port, self.https_port, self.udp_port, getattr(self, 'stream_port', 0))
        if host in ('203.0.113.70', '2001:db8:33::10') and port in ports:
            return self.data4 if host == '203.0.113.70' else self.data6
        if host in (self.data4, self.data6) and port == getattr(self, 'stream_port', 0):
            return host
        if protocol == 'tcp' and port == getattr(self, 'stream_port', 0):
            targets = self.destinations(host)
            return targets[0] if targets else None
        return super().target(host, port, protocol)

    def manifest(self):
        return dict(super().manifest(), stream_port=self.stream_port, refused_port=self.refused.getsockname()[1],
                    public4='203.0.113.70', public6='2001:db8:33::10',
                    dns4='203.0.113.53', dns6='2001:db8:33::53')

    def udp_exchange(self, relay, alive, peer, target, port, payload, family, requested):
        if requested not in ('203.0.113.70', '2001:db8:33::10'):
            return super().udp_exchange(relay,alive,peer,target,port,payload,family,requested)
        try:
            with socket.socket(socket.AF_INET6 if family==6 else socket.AF_INET,socket.SOCK_DGRAM) as sock:
                sock.settimeout(2);sock.connect((target,port));sock.sendall(payload);response=sock.recv(32768)
            if alive.is_set() and not self.done.is_set() and not self.proxy_off:
                # Preserve the requested virtual source, not the mapped lab IP.
                relay.sendto(b'\0\0\0'+socks_address(requested,port)+response,peer)
        except OSError:
            pass


if __name__ == '__main__':
    root = Path(sys.argv[1])
    assert sys.argv[6:] in ([], ['--loopback-provider-alias']), 'Unknown fixture option'
    fixture = ClosureFixture(root, *sys.argv[2:6], 'S00',
                             loopback_provider_alias='--loopback-provider-alias' in sys.argv[6:])
    (root / 'fixture.json').write_text(json.dumps(fixture.manifest()))
    signal.signal(signal.SIGTERM, lambda *_: fixture.done.set())
    signal.signal(signal.SIGINT, lambda *_: fixture.done.set())
    fixture.done.wait()
