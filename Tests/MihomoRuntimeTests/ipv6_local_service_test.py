#!/usr/bin/env python3
"""Real local IPv6 HTTPS/UDP qualification: Delta services, mimo-vm client.

Host mode only opens temporary, restricted listeners; it changes no networking.
VM mode adds one temporary TUN route for the connected-LAN test destination.
Uses the standalone Global/zero-rule profile and the pinned engine.
"""
import copy
from datetime import datetime, timezone
import hashlib
import http.server
import io
import ipaddress
import json
import os
from pathlib import Path
import secrets
import select
import signal
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time

from ipv6_global_profile_test import ENGINE, SHA256, TUN, address, api, command, dns_state, interface, recv_exact, require_no_engine, stop


class BytesReader:
    def __init__(self, data):
        self.stream = io.BytesIO(data)

    def recv(self, count):
        return self.stream.read(count)


class Fixture:
    def __init__(self, root, host4, host6, client4):
        self.root, self.host4, self.host6, self.client4 = root, host4, host6, client4
        self.token = secrets.token_hex(16)
        self.body = (self.token.encode() + b' real IPv6 HTTPS service\n') * 4096
        self.udp_prefix = b'real IPv6 UDP service ' + self.token.encode() + b':'
        self.events = []
        self.lock = threading.Lock()
        self.stopped = threading.Event()
        self.proxy_stopped = threading.Event()
        self.connections = []
        self.servers = []
        self.sockets = []
        self.start_services()
        self.start_proxy()
        self.start_control()

    def record(self, kind, **fields):
        with self.lock:
            self.events.append(dict(kind=kind, **fields))

    def snapshot(self):
        with self.lock:
            return {'proxy_stopped': self.proxy_stopped.is_set(), 'events': copy.deepcopy(self.events)}

    def bind(self, family, kind, address_value):
        sock = socket.socket(family, kind)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((address_value, 0))
        sock.settimeout(0.2)
        self.sockets.append(sock)
        return sock

    def thread(self, function, *args):
        threading.Thread(target=function, args=args, daemon=True).start()

    def start_services(self):
        fixture = self

        class IPv6HTTP(http.server.ThreadingHTTPServer):
            address_family = socket.AF_INET6
            daemon_threads = True

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != '/' + fixture.token:
                    self.send_error(404)
                    return
                fixture.record('https_service', socket_family='AF_INET6', tls=self.connection.version(),
                               local_address=self.connection.getsockname()[0],
                               peer_address=self.client_address[0], body_bytes=len(fixture.body))
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(len(fixture.body)))
                self.end_headers()
                self.wfile.write(fixture.body)

            def log_message(self, *args):
                pass

        self.https = IPv6HTTP((self.host6, 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(self.root / 'server.crt'), str(self.root / 'server.key'))
        self.https.socket = context.wrap_socket(self.https.socket, server_side=True)
        self.servers.append(self.https)
        self.thread(self.https.serve_forever, 0.1)
        self.udp_service = self.bind(socket.AF_INET6, socket.SOCK_DGRAM, self.host6)
        self.thread(self.serve_udp)

    def serve_udp(self):
        while not self.stopped.is_set():
            try:
                payload, peer = self.udp_service.recvfrom(16384)
                if not payload.startswith(self.token.encode()):
                    continue
                self.record('udp_service', socket_family='AF_INET6', local_address=self.host6,
                            peer_address=peer[0], received_bytes=len(payload))
                self.udp_service.sendto(self.udp_prefix + payload, peer)
            except socket.timeout:
                pass
            except OSError:
                break

    def allowed(self, target, port, protocol):
        expected = self.https.server_port if protocol == 'tcp' else self.udp_service.getsockname()[1]
        return target == self.host6 and port == expected

    def start_proxy(self):
        self.proxy_tcp = self.bind(socket.AF_INET, socket.SOCK_STREAM, self.host4)
        self.proxy_tcp.listen(10)
        self.proxy_udp = self.bind(socket.AF_INET, socket.SOCK_DGRAM, self.host4)
        self.thread(self.accept_proxy)
        self.thread(self.relay_udp)

    def accept_proxy(self):
        while not self.proxy_stopped.is_set():
            try:
                client, peer = self.proxy_tcp.accept()
                if peer[0] != self.client4:
                    client.close()
                    continue
                self.connections.append(client)
                self.thread(self.relay_tcp, client)
            except socket.timeout:
                pass
            except OSError:
                break

    def relay_tcp(self, client):
        upstream = None
        try:
            client.settimeout(5)
            version, count = recv_exact(client, 2)
            assert version == 5 and 0 in recv_exact(client, count)
            client.sendall(b'\x05\x00')
            version, operation, reserved = recv_exact(client, 3)
            target, port = address(client)
            assert version == 5 and reserved == 0 and operation in (1, 3)
            reply = b'\x05\x00\x00\x01' + socket.inet_aton(self.host4)
            if operation == 3:
                client.sendall(reply + struct.pack('!H', self.proxy_udp.getsockname()[1]))
                while not self.proxy_stopped.is_set():
                    try:
                        if not client.recv(1):
                            break
                    except socket.timeout:
                        pass
                return
            assert self.allowed(target, port, 'tcp'), 'Only the test service is allowed'
            upstream = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            self.connections.append(upstream)
            upstream.settimeout(5)
            upstream.connect((target, port))
            client.sendall(reply + struct.pack('!H', upstream.getsockname()[1]))
            counts = {'request_bytes': 0, 'response_bytes': 0}
            while not self.proxy_stopped.is_set():
                ready, _, _ = select.select([client, upstream], [], [], 0.2)
                ended = False
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        ended = True
                        break
                    destination = upstream if source is client else client
                    destination.sendall(data)
                    counts['request_bytes' if source is client else 'response_bytes'] += len(data)
                if ended:
                    break
            self.record('proxy_tcp', destination=target, port=port,
                        upstream_family='AF_INET6', **counts)
        except (OSError, EOFError, ValueError, AssertionError):
            pass
        finally:
            client.close()
            if upstream:
                upstream.close()

    def relay_udp(self):
        while not self.proxy_stopped.is_set():
            try:
                packet, peer = self.proxy_udp.recvfrom(16384)
                if peer[0] != self.client4 or packet[:3] != b'\x00\x00\x00':
                    continue
                reader = BytesReader(packet[3:])
                target, port = address(reader)
                if not self.allowed(target, port, 'udp'):
                    continue
                payload = reader.stream.read()
                with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as upstream:
                    upstream.settimeout(2)
                    upstream.connect((target, port))
                    upstream.sendall(payload)
                    response = upstream.recv(16384)
                header = b'\x00\x00\x00\x04' + socket.inet_pton(socket.AF_INET6, target) + struct.pack('!H', port)
                self.proxy_udp.sendto(header + response, peer)
                self.record('proxy_udp', destination=target, port=port, upstream_family='AF_INET6',
                            request_bytes=len(payload), response_bytes=len(response))
            except socket.timeout:
                pass
            except (OSError, EOFError, ValueError):
                if self.proxy_stopped.is_set():
                    break

    def close_proxy(self):
        self.proxy_stopped.set()
        self.proxy_tcp.close()
        self.proxy_udp.close()
        for connection in self.connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()

    def start_control(self):
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.client_address[0] != fixture.client4 or self.path != '/' + fixture.token:
                    self.send_error(403)
                    return
                data = json.dumps(fixture.snapshot()).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                if self.client_address[0] != fixture.client4 or self.path != '/' + fixture.token + '/stop-proxy':
                    self.send_error(403)
                    return
                fixture.close_proxy()
                self.send_response(204)
                self.end_headers()

            def log_message(self, *args):
                pass

        self.control = http.server.ThreadingHTTPServer((self.host4, 0), Handler)
        self.servers.append(self.control)
        self.thread(self.control.serve_forever, 0.1)

    def close(self):
        self.stopped.set()
        self.close_proxy()
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for sock in self.sockets:
            sock.close()
        (self.root / 'host-report.json').write_text(json.dumps(self.snapshot(), indent=2))


def host(root, host4, host6, client4):
    assert socket.gethostname().split('.')[0] == 'delta'
    assert root.stat().st_mode & 0o077 == 0
    assert ipaddress.ip_address(host4).is_private and ipaddress.ip_address(host6).is_private
    fixture = Fixture(root, host4, host6, client4)
    done = threading.Event()
    for sig in [signal.SIGTERM, signal.SIGINT]:
        signal.signal(sig, lambda *_: done.set())
    data = {'host4': host4, 'host6': host6, 'token': fixture.token,
            'https_port': fixture.https.server_port, 'udp_port': fixture.udp_service.getsockname()[1],
            'proxy_tcp_port': fixture.proxy_tcp.getsockname()[1],
            'proxy_udp_port': fixture.proxy_udp.getsockname()[1],
            'control_port': fixture.control.server_port,
            'https_body_sha256': hashlib.sha256(fixture.body).hexdigest(),
            'https_body_bytes': len(fixture.body), 'udp_prefix': fixture.udp_prefix.decode()}
    (root / 'fixture.json').write_text(json.dumps(data))
    print('READY: IPv6 HTTPS/UDP services and VM-restricted forwarding proxy.', flush=True)
    try:
        done.wait(180)
    finally:
        fixture.close()


def vm(root):
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert root.stat().st_uid == 0 and root.stat().st_mode & 0o077 == 0
    assert hashlib.sha256(Path(ENGINE).read_bytes()).hexdigest() == SHA256
    require_no_engine()
    assert command(['/sbin/ifconfig', TUN])['status'] != 0
    fixture = json.loads((root / 'fixture.json').read_text())
    target = fixture['host6']
    assert interface(target) == 'en0', 'Expected a native connected-LAN baseline'
    baseline_dns = dns_state()
    report = {'tested_at_utc': datetime.now(timezone.utc).isoformat(), 'engine_sha256': SHA256,
              'engine_version': command([ENGINE, '-v'])['stdout'].strip(),
              'scope': 'Real Delta IPv6 services; local forwarding proxy; no public IPv6 dependency.',
              'instrumentation': 'One temporary /128 VM route forces the connected-LAN target into TUN.',
              'checks': {}}
    checks = report['checks']

    def https(label):
        path = root / (label + '.body')
        result = command(['/usr/bin/curl', '--noproxy', '*', '-sS', '--max-time', '5',
            '--cacert', str(root / 'server.crt'), '-o', str(path), '-w', '%{http_code}',
            'https://[' + target + ']:' + str(fixture['https_port']) + '/' + fixture['token']], 6)
        body = path.read_bytes() if path.exists() else b''
        report[label] = {'curl_status': result['status'], 'http_status': result['stdout'],
                         'body_bytes': len(body), 'body_sha256': hashlib.sha256(body).hexdigest()}
        return result['status'] == 0 and result['stdout'] == '200' and hashlib.sha256(body).hexdigest() == fixture['https_body_sha256']

    def udp(size):
        payload = fixture['token'].encode() + b'u' * size
        try:
            with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sock:
                sock.settimeout(2)
                sock.connect((target, fixture['udp_port']))
                sock.sendall(payload)
                return sock.recv(16384) == fixture['udp_prefix'].encode() + payload
        except OSError:
            return False

    def control(stop_proxy=False):
        url = 'http://' + fixture['host4'] + ':' + str(fixture['control_port']) + '/' + fixture['token']
        result = command(['/usr/bin/curl', '--noproxy', '*', '-sS', '--max-time', '3',
                          *(['-X', 'POST'] if stop_proxy else []), url + ('/stop-proxy' if stop_proxy else '')])
        assert result['status'] == 0
        return {} if stop_proxy else json.loads(result['stdout'])

    checks['native_https_baseline'] = https('native_https_before')
    checks['native_udp_baseline'] = udp(64)
    assert all(checks.values()), 'Native service baseline failed'
    config = json.loads((root / 'profile.json').read_text())
    assert config['mode'] == 'global' and config['rules'] == []
    config['tun']['device'] = TUN
    config['external-controller-unix'] = str(root / 'controller.sock')
    config['proxies'][0].update(server=fixture['host4'], port=fixture['proxy_tcp_port'])
    path = root / 'config.json'
    path.write_text(json.dumps(config))
    path.chmod(0o600)
    engine = guard = None
    route_added = False
    captures = []
    log = (root / 'engine.log').open('w')
    try:
        assert command([ENGINE, '-t', '-d', str(root), '-f', str(path)])['status'] == 0
        engine = subprocess.Popen([ENGINE, '-d', str(root), '-f', str(path)], stdout=log,
            stderr=subprocess.STDOUT, start_new_session=True)
        guard = subprocess.Popen(['/usr/bin/python3', str(root / 'ipv6_global_profile_test.py'),
            '--watchdog', str(engine.pid), str(path)], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            assert engine.poll() is None
            if (root / 'controller.sock').exists() and interface('2001:2::1') == TUN:
                break
            time.sleep(0.1)
        checks['connected_lan_normally_native'] = interface(target) == 'en0'
        result = command(['/sbin/route', '-n', 'add', '-inet6', '-host', target, '-interface', TUN])
        assert result['status'] == 0, 'Failed to add isolated test capture route'
        route_added = True
        checks['test_target_captured'] = interface(target) == TUN
        checks['global_zero_rules'] = api(root, '/configs').get('mode') == 'global' and api(root, '/rules').get('rules') == []
        checks['no_ping_stack'] = api(root, '/configs').get('tun', {}).get('stack') == 'gvisor-no-ping'
        checks['selected_proxy'] = api(root, '/proxies/GLOBAL').get('now') == 'Proxy' and api(root, '/proxies/Proxy').get('now') == 'TEST-PROXY'
        checks['dns_unchanged'] = dns_state() == baseline_dns
        assert all(checks.values()), 'Startup invariant failed'
        for nic in ['en0', TUN]:
            pcap = root / (nic + '.pcap')
            err = (root / (nic + '-capture.log')).open('w')
            bpf = '(ip6 and host ' + target + ') or (ip and host ' + fixture['host4'] + ' and (port ' + str(fixture['proxy_tcp_port']) + ' or port ' + str(fixture['proxy_udp_port']) + '))'
            proc = subprocess.Popen(['/usr/sbin/tcpdump', '-n', '-U', '-i', nic, '-s', '128',
                '-w', str(pcap), bpf], stdout=subprocess.DEVNULL, stderr=err)
            captures.append((nic, proc, err, pcap))
        time.sleep(0.5)
        assert all(p.poll() is None for _, p, _, _ in captures)
        checks['https_through_proxy'] = https('proxied_https')
        report['udp_sizes'] = {str(size): udp(size) for size in [64, 1200, 8192]}
        checks['udp_through_proxy'] = all(report['udp_sizes'].values())
        time.sleep(0.2)
        state = control()
        report['host_events'] = state['events']
        checks['proxy_used_real_ipv6_tcp_socket'] = any(e['kind'] == 'proxy_tcp' and e['upstream_family'] == 'AF_INET6' and e['destination'] == target and e['response_bytes'] > fixture['https_body_bytes'] for e in state['events'])
        checks['proxy_used_real_ipv6_udp_socket'] = len([e for e in state['events'] if e['kind'] == 'proxy_udp' and e['upstream_family'] == 'AF_INET6' and e['destination'] == target]) == 3
        service_count = len([e for e in state['events'] if e['kind'].endswith('_service')])
        control(stop_proxy=True)
        checks['proxy_stopped'] = control()['proxy_stopped']
        checks['https_fails_without_proxy'] = not https('proxy_off_https')
        checks['udp_fails_without_proxy'] = not udp(64)
        after = control()
        checks['no_direct_fallback_to_service'] = len([e for e in after['events'] if e['kind'].endswith('_service')]) == service_count
        time.sleep(0.2)
    except Exception as error:
        report['error'] = str(error)
    finally:
        for nic, process, err, pcap in captures:
            stop(process, signal.SIGINT)
            err.close()
            for label, bpf in [('ipv6_tcp', 'ip6 and dst host ' + target + ' and tcp dst port ' + str(fixture['https_port'])),
                               ('ipv6_udp', 'ip6 and dst host ' + target + ' and udp dst port ' + str(fixture['udp_port'])),
                               ('proxy_ipv4', 'ip and dst host ' + fixture['host4'] + ' and (dst port ' + str(fixture['proxy_tcp_port']) + ' or dst port ' + str(fixture['proxy_udp_port']) + ')')]:
                packets = command(['/usr/sbin/tcpdump', '-nn', '-r', str(pcap), bpf])
                report[nic + '_' + label + '_packets'] = len(packets['stdout'].splitlines()) if packets['status'] == 0 else None
        if route_added and interface(target) == TUN:
            command(['/sbin/route', '-n', 'delete', '-inet6', '-host', target, '-interface', TUN])
        stop(engine)
        stop(guard)
        log.close()
        path.unlink(missing_ok=True)
        time.sleep(0.2)
        checks['native_ipv6_tcp_zero'] = report.get('en0_ipv6_tcp_packets') == 0
        checks['native_ipv6_udp_zero'] = report.get('en0_ipv6_udp_packets') == 0
        checks['tcp_and_udp_entered_tun'] = (report.get(TUN + '_ipv6_tcp_packets') or 0) > 0 and (report.get(TUN + '_ipv6_udp_packets') or 0) > 0
        checks['vm_used_proxy_transport'] = (report.get('en0_proxy_ipv4_packets') or 0) > 0
        checks['native_route_restored'] = interface(target) == 'en0'
        checks['tun_removed'] = command(['/sbin/ifconfig', TUN])['status'] != 0
        checks['dns_restored'] = dns_state() == baseline_dns
        checks['native_https_after_cleanup'] = https('native_https_after')
        checks['native_udp_after_cleanup'] = udp(64)
        report['passed'] = not report.get('error') and all(checks.values())
        (root / 'report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps({'passed': report['passed'], 'checks': checks, 'error': report.get('error')}), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    if sys.argv[1] == 'host':
        host(Path(sys.argv[2]), *sys.argv[3:6])
    elif sys.argv[1] == 'vm':
        sys.exit(vm(Path(sys.argv[2])))
    else:
        sys.exit('Usage: ipv6_local_service_test.py host ROOT HOST4 HOST6 VM4 | vm ROOT')
