#!/usr/bin/env python3
"""Exercise the real, unprivileged verification listener with synthetic credentials.

No active/TUN profile is loaded and no PF rules or system proxy settings are changed.
The upstream proxy is a loopback recording stub; it never forwards to the internet.
"""
import base64
import http.client
import json
from pathlib import Path
import queue
import socket
import socketserver
import subprocess
import sys
import threading
import time
import uuid

PROBE_PASSWORD = "ab" * 32

class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=15)
        self.path = str(path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


class Upstream(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self):
        self.requests = queue.Queue()
        super().__init__(("127.0.0.1", 0), RecordingProxy)


class RecordingProxy(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(2)
        data = b""
        try:
            while b"\r\n\r\n" not in data and len(data) < 8192:
                chunk = self.request.recv(1024)
                if not chunk:
                    return
                data += chunk
            self.server.requests.put(data.split(b"\r\n", 1)[0].decode("ascii", errors="replace"))
            self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            # Accept a tunnel but never forward its bytes. Closing after the first payload
            # makes TLS fail and avoids mihomo retrying an upstream CONNECT rejection.
            self.request.recv(8192)
        except (OSError, TimeoutError):
            pass


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def controller(root, method, path, payload=None):
    connection = UnixHTTP(root / "controller.sock")
    try:
        body = json.dumps(payload) if payload is not None else None
        connection.request(method, path, body=body, headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        data = response.read()
        assert 200 <= response.status < 300, (response.status, data)
        return json.loads(data) if data else None
    finally:
        connection.close()


def http_connect(port, host, destination_port=443, password=PROBE_PASSWORD):
    authorization = ""
    if password is not None:
        token = base64.b64encode(("mimo-core:" + password).encode()).decode()
        authorization = "Proxy-Authorization: Basic " + token + "\r\n"
    request = (f"CONNECT {host}:{destination_port} HTTP/1.1\r\n"
               f"Host: {host}:{destination_port}\r\n{authorization}\r\n").encode()
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        sock.settimeout(2)
        sock.sendall(request)
        data = b""
        try:
            while b"\r\n\r\n" not in data and len(data) < 8192:
                chunk = sock.recv(1024)
                if not chunk:
                    break
                data += chunk
        except ConnectionResetError:
            pass
        status = data.split(b"\r\n", 1)[0].decode("ascii", errors="replace")
        if "200" in status:
            try:
                sock.sendall(b"runtime-fixture")
                assert not sock.recv(1), "recording upstream unexpectedly forwarded data"
            except (ConnectionResetError, BrokenPipeError):
                pass
        return status


def run():
    base = Path(__file__).resolve().parent
    root = base / ("run-" + uuid.uuid4().hex[:8])
    upstream = Upstream()
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    probe_port = free_port()
    process = None
    results = []

    def passed(message):
        results.append(message)
        print("PASS:", message, flush=True)

    def no_upstream():
        try:
            request = upstream.requests.get(timeout=0.25)
        except queue.Empty:
            return
        raise AssertionError("forbidden traffic reached the upstream: " + request)

    try:
        subprocess.run([str(base / "render-profiles"), str(root), str(upstream.server_address[1]),
                        str(probe_port)], check=True)
        version = subprocess.check_output([str(base / "mihomo"), "-v"], text=True)
        assert "Mihomo Meta v1.19.34 " in version, version
        for profile in sorted(root.glob("*.yaml")):
            subprocess.run([str(base / "mihomo"), "-t", "-d", str(root), "-f", str(profile)],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
        passed("all five generated profiles parse with mihomo v1.19.34")
        for policy in sorted(root.glob("*.pf")):
            result = subprocess.run(["/sbin/pfctl", "-n", "-a", "com.apple/000.mimo", "-f", str(policy)],
                                    capture_output=True, text=True, timeout=10)
            (root / (policy.name + ".parse.txt")).write_text(result.stdout + result.stderr)
            assert result.returncode == 0, (policy.name, result.stdout, result.stderr)
        passed("closed, Rule and Global PF policies parse without applying firewall changes")
        with (root / "engine.log").open("wb") as log:
            process = subprocess.Popen([str(base / "mihomo"), "-d", str(root), "-f", str(root / "blocking.yaml")],
                                       stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 10
            while not (root / "controller.sock").exists():
                assert process.poll() is None, "engine exited before creating its controller"
                assert time.monotonic() < deadline, "controller startup timed out"
                time.sleep(0.05)
            initial = controller(root, "GET", "/configs")
            assert initial["mixed-port"] == 0 and not initial["tun"]["enable"]
            rules = controller(root, "GET", "/rules")["rules"]
            (root / "blocking-rules.json").write_text(json.dumps(rules, indent=2))
            assert len(rules) == 1 and rules[0]["type"] == "Match" and rules[0]["proxy"] == "REJECT", rules
            passed("blocking profile has no ordinary listener or TUN and rejects all ordinary rules")

            for mode in ("rule", "global"):
                controller(root, "PUT", "/configs?force=true", {"path": str(root / (mode + "-verification.yaml"))})
                config = controller(root, "GET", "/configs")
                assert config["mode"] == "rule" and config["mixed-port"] == 0 and not config["tun"]["enable"]
                (root / (mode + "-configs.json")).write_text(json.dumps(config, indent=2))
                (root / (mode + "-rules.json")).write_text(json.dumps(controller(root, "GET", "/rules"), indent=2))
                (root / (mode + "-proxies.json")).write_text(json.dumps(controller(root, "GET", "/proxies"), indent=2))
                subprocess.run([str(base / "render-profiles"), "inspect", str(root), mode], check=True, capture_output=True)
                passed(mode + ": production inspection confirms rule types, tunnel settings, ports and proxy selection")
                missing_auth = http_connect(probe_port, "ipwho.is", password=None)
                wrong_auth = http_connect(probe_port, "ipwho.is", password="wrong")
                assert "407" in missing_auth, missing_auth
                assert "407" in wrong_auth or "403" in wrong_auth, wrong_auth
                no_upstream()
                passed(mode + ": missing and wrong HTTP proxy credentials are rejected")

                http_connect(probe_port, "example.com")
                no_upstream()
                http_connect(probe_port, "ipwho.is", destination_port=80)
                no_upstream()
                http_connect(probe_port, "127.0.0.1")
                no_upstream()
                passed(mode + ": unrelated domains, non-443 ports and literal IP targets cannot use the private listener")

                for host in ("api.ipinfo.io", "ipapi.co", "ipwho.is", "api.ipapi.is"):
                    http_connect(probe_port, host)
                    request = upstream.requests.get(timeout=3)
                    assert request == f"CONNECT {host}:443 HTTP/1.1", request
                passed(mode + ": all four lookup hosts use the configured upstream proxy")

                with socket.create_connection(("127.0.0.1", probe_port), timeout=2) as sock:
                    sock.settimeout(2)
                    sock.sendall(b"\x05\x01\x00")
                    negotiation = sock.recv(2)
                    # v1.19.34 requests password auth even when the client only offers no-auth.
                    assert negotiation == b"\x05\x02", ("SOCKS negotiation", negotiation.hex())
                    sock.sendall(b"\x01\x00\x00")
                    assert sock.recv(2) == b"\x01\x01", "SOCKS accepted empty credentials"
                for password, expected in ((b"wrong", b"\x01\x01"), (PROBE_PASSWORD.encode(), b"\x01\x00")):
                    with socket.create_connection(("127.0.0.1", probe_port), timeout=2) as sock:
                        sock.settimeout(2)
                        sock.sendall(b"\x05\x01\x02")
                        assert sock.recv(2) == b"\x05\x02"
                        username = b"mimo-core"
                        sock.sendall(b"\x01" + bytes([len(username)]) + username + bytes([len(password)]) + password)
                        assert sock.recv(2) == expected, "incorrect SOCKS authentication result"
                no_upstream()
                passed(mode + ": SOCKS also requires authentication")

                result = subprocess.run([str(base / "render-profiles"), "lookup", str(probe_port), PROBE_PASSWORD],
                                        check=True, capture_output=True, text=True, timeout=20)
                (root / (mode + "-lookup.txt")).write_text(result.stdout + result.stderr)
                request = upstream.requests.get(timeout=3)
                assert request == "CONNECT ipwho.is:443 HTTP/1.1", request
                while not upstream.requests.empty():
                    assert upstream.requests.get_nowait() == request
                passed(mode + ": core's URLSession authenticates through mihomo and fails with the broken upstream")

            controller(root, "PUT", "/configs?force=true", {"path": str(root / "blocking.yaml")})
            with socket.socket() as sock:
                sock.settimeout(1)
                assert sock.connect_ex(("127.0.0.1", probe_port)) != 0, "blocking reload left the private listener open"
            passed("restoring the blocking profile removes the private listener")
            result = subprocess.run([str(base / "render-profiles"), "lookup", str(probe_port), PROBE_PASSWORD],
                                    check=True, capture_output=True, text=True, timeout=20)
            (root / "unavailable-proxy-lookup.txt").write_text(result.stdout + result.stderr)
            no_upstream()
            passed("core's URLSession fails when its proxy listener is unavailable")
        report = {"version": version.strip(), "passed": results, "scope": "Unprivileged verification listener; no PF or active TUN testing"}
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Evidence:", root, flush=True)
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        upstream.shutdown()
        upstream.server_close()


if __name__ == "__main__":
    run()
