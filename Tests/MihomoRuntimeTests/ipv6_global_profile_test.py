#!/usr/bin/env python3
"""VM-only packet qualification of Profiles/mimo-global-ipv6-test.yaml.

Run as root in mimo-vm with a private directory containing profile.json (the
parsed YAML) and optionally proxy.json (one privately supplied SOCKS5 proxy).
Nothing is installed. The engine, captures and temporary credentials are removed
on exit. A separate watchdog bounds each engine's lifetime if SSH is lost.
"""
import copy
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

ENGINE = os.environ.get('MIMO_TEST_ENGINE', '/opt/homebrew/opt/mihomo@1.19.34/bin/mihomo')
SHA256 = os.environ.get('MIMO_TEST_ENGINE_SHA256',
    'a55a9073f9b7b1fa596a82c034d2dae3407ec34732102b6e42c5513ce3033f34')
TUN = 'utun238'
TARGETS = ['2606:4700:4700::1111', '64:ff9b::101:101', '64:ff9b:1::101:101']


def command(args, timeout=8):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return {'status': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr}
    except subprocess.TimeoutExpired:
        return {'status': 'timeout', 'stdout': '', 'stderr': 'deadline exceeded'}


def stop(p, sig=signal.SIGTERM):
    if p is not None and p.poll() is None:
        p.send_signal(sig)
        try:
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=3)


def require_no_engine():
    processes = command(['/bin/ps', '-axo', 'comm='])
    assert processes['status'] == 0
    assert not any(path.strip() == ENGINE or path.strip().endswith(
        ('/mihomo', '/verge-mihomo', '/mihomo-no-ping'))
        for path in processes['stdout'].splitlines()), 'Existing engine: abort'


def interface(ip):
    result = command(['/sbin/route', '-n', 'get', *(['-inet6'] if ':' in ip else []), ip])
    for line in result['stdout'].splitlines():
        if 'interface:' in line:
            return line.split(':', 1)[1].strip()
    return None


def dns_state():
    return command(['/usr/sbin/scutil', '--dns'])['stdout']


def api(case, path):
    result = command(['/usr/bin/curl', '-sS', '--max-time', '5', '--unix-socket',
                      str(case / 'controller.sock'), 'http://localhost' + path])
    try:
        return json.loads(result['stdout'])
    except ValueError:
        return {'transport_status': result['status']}


def recv_exact(s, n):
    data = b''
    while len(data) < n:
        part = s.recv(n - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def address(s):
    kind = recv_exact(s, 1)[0]
    if kind == 1:
        value = socket.inet_ntop(socket.AF_INET, recv_exact(s, 4))
    elif kind == 4:
        value = socket.inet_ntop(socket.AF_INET6, recv_exact(s, 16))
    elif kind == 3:
        value = recv_exact(s, recv_exact(s, 1)[0]).decode()
    else:
        raise ValueError('Unknown SOCKS address type')
    return value, struct.unpack('!H', recv_exact(s, 2))[0]


class EchoProxy:
    """Local SOCKS5 TCP/UDP echo fixture; never dials a remote destination."""
    def __init__(self):
        self.tcp = socket.socket()
        self.tcp.bind(('127.0.0.1', 0))
        self.tcp.listen(20)
        self.tcp.settimeout(0.2)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(('127.0.0.1', 0))
        self.udp.settimeout(0.2)
        self.port = self.tcp.getsockname()[1]
        self.finished = False
        self.events = []
        self.connections = []
        for method in (self.accept, self.datagrams):
            threading.Thread(target=method, daemon=True).start()

    def accept(self):
        while not self.finished:
            try:
                s, _ = self.tcp.accept()
                self.connections.append(s)
                threading.Thread(target=self.connection, args=(s,), daemon=True).start()
            except socket.timeout:
                pass
            except OSError:
                break

    def connection(self, s):
        try:
            s.settimeout(5)
            version, count = recv_exact(s, 2)
            assert version == 5
            recv_exact(s, count)
            s.sendall(b'\x05\x00')
            version, operation, reserved = recv_exact(s, 3)
            destination, port = address(s)
            assert version == 5 and reserved == 0 and operation in (1, 3)
            bind_port = self.udp.getsockname()[1] if operation == 3 else self.port
            s.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01' + struct.pack('!H', bind_port))
            if operation == 1:
                payload = s.recv(4096)
                self.events.append({'protocol': 'tcp', 'destination': destination,
                                    'port': port, 'payload_received': bool(payload)})
                s.sendall(payload)
            else:
                while not self.finished:
                    try:
                        if not s.recv(1):
                            break
                    except socket.timeout:
                        pass
        except (OSError, EOFError, ValueError, AssertionError):
            pass
        finally:
            s.close()

    def datagrams(self):
        while not self.finished:
            try:
                data, sender = self.udp.recvfrom(4096)
                assert data[:3] == b'\x00\x00\x00'
                import io
                class Reader:
                    def __init__(self, raw):
                        self.stream = io.BytesIO(raw)
                    def recv(self, n):
                        return self.stream.read(n)
                reader = Reader(data[3:])
                destination, port = address(reader)
                payload = reader.stream.read()
                self.events.append({'protocol': 'udp', 'destination': destination,
                                    'port': port, 'payload_received': bool(payload)})
                self.udp.sendto(data, sender)
            except socket.timeout:
                pass
            except (OSError, EOFError, ValueError, AssertionError):
                if self.finished:
                    break

    def close(self):
        self.finished = True
        self.tcp.close()
        self.udp.close()
        for s in self.connections:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


def echo(ip, protocol, port=443):
    payload = b'Mimo IPv6 global proxy path test'
    kind = socket.SOCK_STREAM if protocol == 'tcp' else socket.SOCK_DGRAM
    try:
        with socket.socket(socket.AF_INET6, kind) as s:
            s.settimeout(2)
            s.connect((ip, port))
            s.sendall(payload)
            return s.recv(4096) == payload
    except OSError:
        return False


def lookup(case, name, kind='A'):
    result = api(case, '/dns/query?name=' + name + '&type=' + kind)
    return {'status': result.get('Status'), 'answer_count': len(result.get('Answer', [])),
            'error': result.get('message')}


def run(root, peer):
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert root.is_dir() and root.stat().st_uid == 0 and root.stat().st_mode & 0o077 == 0
    assert hashlib.sha256(Path(ENGINE).read_bytes()).hexdigest() == SHA256
    require_no_engine()
    assert command(['/sbin/ifconfig', TUN])['status'] != 0, 'Test TUN in use'
    profile = json.loads((root / 'profile.json').read_text())
    assert profile['mode'] == 'global' and profile['rules'] == []
    assert 'inet6-address' not in profile['tun']
    assert 'proxy-providers' not in profile
    baseline_dns = dns_state()
    routes = {ip: interface(ip) for ip in TARGETS + ['100.100.100.100', '192.168.64.1']}
    assert all(routes[ip] == 'en0' for ip in TARGETS)
    assert routes['100.100.100.100'] and routes['100.100.100.100'] != 'en0'
    report = {'engine_version': command([ENGINE, '-v'])['stdout'].strip(), 'engine_sha256': SHA256, 'cases': [],
              'profile_sha256': hashlib.sha256((root / 'profile.json').read_bytes()).hexdigest(),
              'scope': 'Standalone profile; no app, firewall or macOS resolver changes.'}
    private = root / 'proxy.json'
    if private.exists():
        assert peer and re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.ts\.net', peer), 'Supply a full Tailnet hostname'
    report['tested_at_utc'] = datetime.now(timezone.utc).isoformat()
    report['limits'] = [
        'Controlled SOCKS echo proves proxy transport, not remote Internet reachability.',
        'External IPv6/NAT64 HTTPS results are reported separately from packet-path checks.',
        'Captured ping must be dropped, without a reply or native forwarding.',
        'The macOS resolver is unchanged; listener DNS answers are used explicitly.',
        'No installed-app lifecycle, Tailscale on/off or multi-account qualification.'
    ]
    try:
        for name in ['controlled_proxy'] + (['supplied_proxy'] if private.exists() else []):
            case = root / name
            case.mkdir(mode=0o700)
            fixture = EchoProxy() if name == 'controlled_proxy' else None
            config = copy.deepcopy(profile)
            config['tun']['device'] = TUN
            config['external-controller-unix'] = str(case / 'controller.sock')
            if fixture:
                config['proxies'][0].update(server='127.0.0.1', port=fixture.port)
            else:
                proxy = json.loads(private.read_text())
                assert proxy['type'] == 'socks5'
                config['proxies'][0].update({k: proxy[k] for k in
                    ['server', 'port', 'username', 'password'] if k in proxy})
            config_path = case / 'config.json'
            config_path.write_text(json.dumps(config))
            config_path.chmod(0o600)
            engine = guard = None
            captures = []
            entry = {'name': name, 'checks': {}}
            checks = entry['checks']
            log = (case / 'engine.log').open('w')
            try:
                validation = command([ENGINE, '-t', '-d', str(case), '-f', str(config_path)])
                assert validation['status'] == 0, 'Engine config validation failed'
                engine = subprocess.Popen([ENGINE, '-d', str(case), '-f', str(config_path)],
                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                guard = subprocess.Popen(['/usr/bin/python3', __file__, '--watchdog',
                    str(engine.pid), str(config_path)], stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, start_new_session=True)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    assert engine.poll() is None, 'Engine exited at startup'
                    if (case / 'controller.sock').exists() and interface(TARGETS[0]) == TUN:
                        break
                    time.sleep(0.1)
                checks['global_mode'] = api(case, '/configs').get('mode') == 'global'
                checks['zero_rules'] = api(case, '/rules').get('rules') == []
                checks['no_ping_stack'] = api(case, '/configs').get('tun', {}).get('stack') == 'gvisor-no-ping'
                checks['global_selects_proxy'] = api(case, '/proxies/GLOBAL').get('now') == 'Proxy'
                checks['proxy_selects_test_proxy'] = api(case, '/proxies/Proxy').get('now') == 'TEST-PROXY'
                checks['ipv6_capture_routes'] = all(interface(ip) == TUN for ip in TARGETS)
                checks['ipv4_default_capture'] = interface('198.51.100.1') == TUN
                checks['native_tailnet_route'] = interface('100.100.100.100') == routes['100.100.100.100']
                checks['native_tailnet_ipv6_route'] = interface('fd7a:115c:a1e0::1') == routes['100.100.100.100']
                checks['management_route_unchanged'] = interface('192.168.64.1') == routes['192.168.64.1']
                checks['dns_unchanged_while_running'] = dns_state() == baseline_dns
                checks['default_tun_ipv6_address'] = 'fdfe:dcba:9876::1' in command(['/sbin/ifconfig', TUN])['stdout']
                assert all(checks.values()), 'Profile startup invariant failed'
                for nic in ['en0', TUN]:
                    pcap = case / (nic + '.pcap')
                    err = (case / (nic + '-capture.log')).open('w')
                    bpf = 'ip6 and (' + ' or '.join('host ' + ip for ip in TARGETS) + ')'
                    p = subprocess.Popen(['/usr/sbin/tcpdump', '-n', '-U', '-i', nic,
                        '-s', '128', '-w', str(pcap), bpf], stdout=subprocess.DEVNULL, stderr=err)
                    captures.append((nic, p, err, pcap))
                time.sleep(0.5)
                assert all(p.poll() is None for _, p, _, _ in captures), 'Capture failed'
                entry['ping_status'] = command(['/sbin/ping6', '-c', '3', '-i', '0.2', TARGETS[0]], 4)['status']
                checks['ping_failed'] = entry['ping_status'] != 0
                if fixture:
                    entry['echo_results'] = {ip: {proto: echo(ip, proto) for proto in ['tcp', 'udp']} for ip in TARGETS}
                    checks['all_ipv6_proxy_echoes'] = all(all(v.values()) for v in entry['echo_results'].values())
                    entry['proxy_received'] = fixture.events[:]
                    checks['proxy_received_each_destination'] = all(any(
                        e['destination'] == ip and e['protocol'] == proto and e['payload_received']
                        for e in fixture.events) for ip in TARGETS for proto in ['tcp', 'udp'])
                    fixture.close()
                    entry['unavailable_proxy_echoes'] = {proto: echo(TARGETS[1], proto, 444) for proto in ['tcp', 'udp']}
                    checks['unavailable_proxy_fails'] = not any(entry['unavailable_proxy_echoes'].values())
                else:
                    entry['dns_queries'] = {kind: lookup(case, peer, kind) for kind in ['A', 'AAAA']}
                    checks['magicdns_a'] = entry['dns_queries']['A']['status'] == 0 and entry['dns_queries']['A']['answer_count'] > 0
                    checks['client_aaaa_suppressed'] = entry['dns_queries']['AAAA']['status'] == 0 and entry['dns_queries']['AAAA']['answer_count'] == 0
                    entry['listener_dns'] = {}
                    for transport in ['+tcp', '+notcp']:
                        result = command(['/usr/bin/dig', '@127.0.0.1', '-p', '1053', peer, 'A',
                            transport, '+time=2', '+tries=1', '+noall', '+comments', '+answer'])
                        entry['listener_dns'][transport] = result['status'] == 0 and 'status: NOERROR' in result['stdout'] and '\tA\t' in result['stdout']
                    checks['local_dns_tcp_udp'] = all(entry['listener_dns'].values())
                    entry['public_dns'] = lookup(case, 'example.com')
                    checks['public_dns'] = entry['public_dns']['status'] == 0 and entry['public_dns']['answer_count'] > 0
                    fake_result = command(['/usr/bin/dig', '@127.0.0.1', '-p', '1053',
                        'example.com', 'A', '+time=2', '+tries=1', '+short'])
                    fake_ip = fake_result['stdout'].strip()
                    checks['public_listener_fake_ip'] = ipaddress.ip_address(fake_ip) in ipaddress.ip_network('198.18.0.0/16')
                    entry['https'] = {}
                    for host, url, options in [
                        # System DNS is deliberately untouched. Use this engine's
                        # listener answer, not a fake-IP allocated by the VM host.
                        ('ipv4', 'https://example.com/', ['-4', '--resolve', 'example.com:443:' + fake_ip]),
                        ('ipv6', 'https://one.one.one.one/cdn-cgi/trace', ['-6', '--resolve', 'one.one.one.one:443:[' + TARGETS[0] + ']']),
                        ('nat64', 'https://one.one.one.one/cdn-cgi/trace', ['-6', '--resolve', 'one.one.one.one:443:[' + TARGETS[1] + ']'])]:
                        deadline = 10 if host == 'ipv4' else 4
                        result = command(['/usr/bin/curl', '--noproxy', '*', '-sS', '--max-time', str(deadline),
                            '-o', '/dev/null', '-w', '%{http_code}', *options, url], deadline + 1)
                        entry['https'][host] = {'status': result['status'], 'http_code': result['stdout'],
                                               'error': result['stderr']}
                    listener = command(['/usr/bin/curl', '--proxy', 'socks5h://127.0.0.1:7890',
                        '--noproxy', '', '-sS', '--max-time', '5', '-o', '/dev/null',
                        '-w', '%{http_code}', 'https://example.com/'], 6)
                    entry['https_proxy_listener'] = listener
                    checks['ipv4_tun_https'] = entry['https']['ipv4']['status'] == 0 and entry['https']['ipv4']['http_code'] == '200'
                    checks['proxy_listener_https'] = listener['status'] == 0 and listener['stdout'] == '200'
                    entry['external_ipv6_https_passed'] = all(entry['https'][kind]['status'] == 0
                        for kind in ['ipv6', 'nat64'])
                    for ip in TARGETS:
                        with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as s:
                            s.sendto(b'Mimo IPv6 proxy test', (ip, 443))
                time.sleep(0.5)
            except Exception as error:
                entry['error'] = str(error)
            finally:
                for nic, p, err, pcap in captures:
                    stop(p, signal.SIGINT)
                    err.close()
                    counts = {}
                    for ip in TARGETS:
                        counts[ip] = {}
                        for proto, bpf in [('tcp', 'tcp'), ('udp', 'udp'), ('echo', 'icmp6 and ip6[40] == 128')]:
                            result = command(['/usr/sbin/tcpdump', '-nn', '-r', str(pcap), 'dst host ' + ip + ' and ' + bpf])
                            counts[ip][proto] = len(result['stdout'].splitlines()) if result['status'] == 0 else None
                    entry[nic + '_destination_packets'] = counts
                    replies = command(['/usr/sbin/tcpdump', '-nn', '-r', str(pcap),
                        'src host ' + TARGETS[0] + ' and icmp6 and ip6[40] == 129'])
                    entry[nic + '_ping_replies'] = len(replies['stdout'].splitlines()) if replies['status'] == 0 else None
                stop(engine)
                stop(guard)
                if fixture:
                    fixture.close()
                log.close()
                config_path.unlink(missing_ok=True)
                # Logs can contain the real proxy endpoint or credentials on errors.
                if not fixture:
                    sanitized_log = (case / 'engine.log').read_text()
                    for key in ['server', 'username', 'password']:
                        value = str(config['proxies'][0].get(key, ''))
                        if value:
                            sanitized_log = sanitized_log.replace(value, '<redacted>')
                    sanitized_log = sanitized_log.replace(peer, '<tailnet-peer>')
                    entry['engine_log'] = sanitized_log
                (case / 'engine.log').unlink(missing_ok=True)
                time.sleep(0.3)
                checks['native_ipv6_destination_packets_zero'] = 'en0_destination_packets' in entry and all(
                    count == 0 for counts in entry['en0_destination_packets'].values() for count in counts.values())
                checks['ping_entered_tun'] = entry.get(TUN + '_destination_packets', {}).get(TARGETS[0], {}).get('echo') == 3
                checks['no_ping_reply'] = entry.get(TUN + '_ping_replies') == 0
                checks['routes_restored'] = all(interface(ip) == nic for ip, nic in routes.items())
                checks['dns_restored'] = dns_state() == baseline_dns
                checks['tun_removed'] = command(['/sbin/ifconfig', TUN])['status'] != 0
                entry['required_checks_passed'] = not entry.get('error') and all(checks.values())
                report['cases'].append(entry)
                (root / 'report.json').write_text(json.dumps(report, indent=2))
                print(json.dumps(entry), flush=True)
                assert checks['routes_restored'] and checks['dns_restored'] and checks['tun_removed'], 'Restoration failed'
    finally:
        private.unlink(missing_ok=True)
    return 0 if all(case['required_checks_passed'] for case in report['cases']) else 1


if __name__ == '__main__':
    if sys.argv[1] == '--watchdog':
        time.sleep(60)
        pid = int(sys.argv[2])
        cmd = command(['/bin/ps', '-p', str(pid), '-o', 'command='])['stdout']
        if ENGINE in cmd and sys.argv[3] in cmd:
            os.kill(pid, signal.SIGTERM)
    else:
        sys.exit(run(Path(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else None))
