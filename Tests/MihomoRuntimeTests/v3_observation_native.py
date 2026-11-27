#!/usr/bin/env python3
"""VM-only TLS relay for native Direct provider checks in the closed lab.

Bind only guest loopback, accept only local clients, and forward opaque TLS to
the already trusted local provider fixture. Rapid mode-change tests use owned
exact-domain macOS resolvers while leaving /etc/hosts unchanged. The campaign
owner installs and removes that separate fixture. Never bind a public interface.
"""
import json
import os
from pathlib import Path
import select
import signal
import socket
import socketserver
import sys
import threading


def main():
    fixture = json.loads(Path(sys.argv[1]).read_text())
    bridge = fixture['bridge4']
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert bridge.startswith('192.168.64.')

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            if self.client_address[0] != '127.0.0.1':
                return
            with socket.create_connection((fixture['data4'], fixture.get('native_provider_port', fixture['https_port'])), timeout=5) as upstream:
                sockets = (self.request, upstream)
                while True:
                    readable, _, _ = select.select(sockets, [], [], 30)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        (upstream if source is self.request else self.request).sendall(data)

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(('127.0.0.1', 443), Handler) as server:
        def stop(*_):
            threading.Thread(target=server.shutdown, daemon=True).start()
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        print('Native provider fixture ready on guest loopback', flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
