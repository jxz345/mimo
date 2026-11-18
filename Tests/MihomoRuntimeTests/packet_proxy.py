#!/usr/bin/env python3
"""Controlled SOCKS5 upstream for the isolated VM packet tests.

Binds only Delta's existing VM NAT interface. Credentials come from a private JSON
file, never argv. Allows the one VM IP, a fixed set of HTTPS test hosts, and synthetic
IPv4/IPv6 TCP/UDP echo destinations. Never changes host networking or firewall rules.
"""
import hmac
import ipaddress
import json
from pathlib import Path
import select
import socket
import socketserver
import struct
import sys
import threading
import time

ECHO = {"198.51.100.70", "2001:db8::70"}
HTTPS = {"api.ipinfo.io", "ipapi.co", "ipwho.is", "api.ipapi.is", "github.com", "tailscale.com", "1.1.1.1"}


def receive(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


def address(sock):
    kind = receive(sock, 1)[0]
    if kind == 1:
        host = socket.inet_ntop(socket.AF_INET, receive(sock, 4))
    elif kind == 4:
        host = socket.inet_ntop(socket.AF_INET6, receive(sock, 16))
    elif kind == 3:
        host = receive(sock, receive(sock, 1)[0]).decode("ascii").lower()
    else:
        raise ValueError("unsupported SOCKS address")
    return host, struct.unpack("!H", receive(sock, 2))[0]


class PacketServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, configuration, log):
        self.configuration, self.log = configuration, log
        self.lock = threading.Lock()
        super().__init__((configuration["bind"], configuration["port"]), Handler)

    def record(self, event, target=None):
        with self.lock:
            self.log.write(json.dumps({"at": time.time(), "event": event, "target": target}) + "\n")
            self.log.flush()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        if self.client_address[0] != self.server.configuration["client"]:
            return
        self.request.settimeout(20)
        try:
            assert receive(self.request, 1) == b"\x05"
            methods = receive(self.request, receive(self.request, 1)[0])
            if 2 not in methods:
                self.request.sendall(b"\x05\xff")
                return
            self.request.sendall(b"\x05\x02")
            assert receive(self.request, 1) == b"\x01"
            username = receive(self.request, receive(self.request, 1)[0])
            password = receive(self.request, receive(self.request, 1)[0])
            expected = self.server.configuration
            if not (hmac.compare_digest(username, expected["username"].encode()) and
                    hmac.compare_digest(password, expected["password"].encode())):
                self.server.record("authentication-rejected")
                self.request.sendall(b"\x01\x01")
                return
            self.request.sendall(b"\x01\x00")
            version, operation, reserved = receive(self.request, 3)
            assert version == 5 and reserved == 0
            host, port = address(self.request)
            if operation == 3:
                self.udp()
            elif operation == 1:
                self.tcp(host, port)
        except (OSError, EOFError, ValueError, AssertionError):
            return

    def reply(self, port=0):
        self.request.sendall(b"\x05\x00\x00\x01" + socket.inet_aton(self.server.configuration["bind"]) + struct.pack("!H", port))

    def tcp(self, host, port):
        self.server.record("tcp", [host, port])
        if host in ECHO and port == 18888:
            self.reply()
            while True:
                data = self.request.recv(65536)
                if not data:
                    return
                self.request.sendall(data)
        elif host in HTTPS and port == 443:
            with socket.create_connection((host, port), timeout=10) as upstream:
                self.reply()
                while True:
                    readable, _, _ = select.select([self.request, upstream], [], [], 20)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        (upstream if source is self.request else self.request).sendall(data)
        else:
            self.request.sendall(b"\x05\x02\x00\x01" + b"\x00" * 6)

    def udp(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as relay:
            relay.bind((self.server.configuration["bind"], 0))
            self.reply(relay.getsockname()[1])
            client = None
            while True:
                readable, _, _ = select.select([self.request, relay], [], [], 20)
                if not readable or self.request in readable:
                    return
                packet, sender = relay.recvfrom(65535)
                if sender[0] != self.server.configuration["client"] or (client and sender != client):
                    continue
                if len(packet) < 10 or packet[:3] != b"\x00\x00\x00":
                    continue
                kind = packet[3]
                length = 4 if kind == 1 else 16 if kind == 4 else 0
                if not length or len(packet) < 6 + length:
                    continue
                host = str(ipaddress.ip_address(packet[4:4 + length]))
                port = struct.unpack("!H", packet[4 + length:6 + length])[0]
                if host not in ECHO or port != 18888:
                    continue
                client = sender
                self.server.record("udp", [host, port])
                relay.sendto(packet, sender)


def main():
    config = Path(sys.argv[1])
    assert config.stat().st_mode & 0o077 == 0, "Fixture credentials must be private"
    configuration = json.loads(config.read_text())
    assert configuration["bind"] == "192.168.64.1" and configuration["client"].startswith("192.168.64.")
    assert configuration["port"] == 18443
    with Path(sys.argv[2]).open("a", buffering=1) as log, PacketServer(configuration, log) as server:
        print("Controlled VM-only SOCKS upstream ready on the existing NAT interface", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
