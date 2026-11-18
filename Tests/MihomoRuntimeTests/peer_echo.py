#!/usr/bin/env python3
"""Temporary TCP/UDP echo on an existing tailnet interface; no routing changes.

Accepts only the test VM's tailnet addresses and a private per-run nonce. Does not
forward traffic, bind public interfaces, or alter Tailscale/firewall configuration.
"""
import hmac
import ipaddress
import json
from pathlib import Path
import socket
import socketserver
import sys
import threading


class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class UDP(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


class TCP6(TCP):
    address_family = socket.AF_INET6


class UDP6(UDP):
    address_family = socket.AF_INET6


def valid(server, client, payload):
    return (client[0] in server.clients and len(payload) <= 512 and
            hmac.compare_digest(payload[:len(server.prefix)], server.prefix))


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        if self.client_address[0] not in self.server.clients:
            return
        self.request.settimeout(30)
        try:
            while True:
                payload = self.request.recv(513)
                if not valid(self.server, self.client_address, payload):
                    return
                self.request.sendall(payload)
        except OSError:
            return


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        payload, sock = self.request
        if valid(self.server, self.client_address, payload):
            sock.sendto(payload, self.client_address)


def main():
    configuration = Path(sys.argv[1])
    assert configuration.stat().st_mode & 0o077 == 0
    peer = json.loads(configuration.read_text())['peer']
    assert len(peer['token']) == 64 and peer['port'] == 18889
    assert all(ipaddress.ip_address(a) in ipaddress.ip_network('fd7a:115c:a1e0::/48' if ':' in a else '100.64.0.0/10')
               for a in peer['addresses'] + peer['clients'])
    servers = []
    try:
        for address in peer['addresses']:
            for kind, handler in ((TCP6 if ':' in address else TCP, TCPHandler),
                                  (UDP6 if ':' in address else UDP, UDPHandler)):
                server = kind((address, peer['port']), handler)
                server.clients = set(peer['clients'])
                server.prefix = ('mimo-peer-' + peer['token'] + '-').encode()
                servers.append(server)
                threading.Thread(target=server.serve_forever, daemon=True).start()
        print('VM-only tailnet TCP/UDP echo listeners ready.', flush=True)
        threading.Event().wait()
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
