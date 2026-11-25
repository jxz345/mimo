#!/usr/bin/env python3
"""Isolated mimo-vm dual-stack matrix cell; stdlib only, root required.

No installed application is changed. Every cell owns its child engine, captures
and exact data routes. A detached watchdog handles parent loss and deadlines.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import errno
import http.client
import ipaddress
import itertools
import json
import os
import re
from pathlib import Path
import secrets
import signal
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.parse

from dualstack_fixture import MODES, NAT64_TEST_TARGETS, Reader, dns_query, exact, read_socks, socks_address
from ipv6_global_profile_test import command, dns_state, interface, require_no_engine, stop

TUN = 'utun238'
ENGINE = os.environ.get('MIMO_TEST_ENGINE', '')
SHA = os.environ.get('MIMO_TEST_ENGINE_SHA256', 'ff21dbbad799783de14f4a13684b35531b455beff0335dc2e9d468e5bcbe52bd')
assert re.fullmatch('[0-9a-f]{64}', SHA)
TAILSCALE = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
CLASSES = ['aonly', 'aaaaonly', 'dual4', 'dual6', 'nx']


def require_ports_free():
    for port, kind in ((7890, socket.SOCK_STREAM), (1053, socket.SOCK_STREAM), (1053, socket.SOCK_DGRAM)):
        with socket.socket(socket.AF_INET, kind) as sock:
            if kind == socket.SOCK_STREAM:
                # Match the engine's bind behavior: completed mixed-listener
                # connections can leave TIME_WAIT without a live listener.
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(('127.0.0.1', port))


def request_socket(sock, method, path, headers=None, body=b''):
    headers = dict(headers or {})
    headers.setdefault('Host', 'localhost')
    headers['Connection'] = 'close'
    if body:
        headers['Content-Length'] = str(len(body))
    request = method + ' ' + path + ' HTTP/1.1\r\n' + ''.join(k + ': ' + v + '\r\n' for k, v in headers.items()) + '\r\n'
    sock.sendall(request.encode() + body)
    response = http.client.HTTPResponse(sock)
    response.begin()
    return response.status, response.read()


def controller(root, path, method='GET', value=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(4)
        sock.connect(str(root / 'controller.sock'))
        status, data = request_socket(sock, method, path, {'Content-Type': 'application/json'},
                                      b'' if value is None else json.dumps(value).encode())
    return json.loads(data) if data else {'http_status': status}


def control(f, value=None):
    with socket.create_connection((f['bridge4'], f['control_port']), timeout=4) as sock:
        status, data = request_socket(sock, 'GET' if value is None else 'POST', '/',
                                     {'Authorization': 'Bearer ' + f['token'], 'Content-Type': 'application/json'},
                                     b'' if value is None else json.dumps(value).encode())
    assert status in (200, 204)
    return json.loads(data) if data else {}


def tcp_client(f, ca, address, hostname, protocol, case, proxy=False, size=512, timeout=4):
    port = f['https_port'] if protocol == 'https_verified' else f['http_port']
    start = time.monotonic()
    result = {'ok': False}
    sock = None
    try:
        if proxy:
            sock = socket.create_connection((f['bridge4'], f['proxy_port']), timeout=timeout)
            sock.sendall(b'\x05\x01\x00')
            assert exact(sock, 2) == b'\x05\x00', 'SOCKS method refused'
            sock.sendall(b'\x05\x01\x00' + socks_address(address, port))
            reply = exact(sock, 3)
            read_socks(sock)
            if reply[1]:
                raise OSError('SOCKS reply ' + str(reply[1]))
        else:
            sock = socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect((address, port))
        if protocol == 'https_verified':
            context = ssl.create_default_context(cafile=str(ca))
            sock = context.wrap_socket(sock, server_hostname=hostname)
        sock.settimeout(max(.1, timeout - (time.monotonic() - start)))
        status, data = request_socket(sock, 'GET', '/' + f['token'] + '/' + case + '?size=' + str(size), {'Host': hostname})
        value = json.loads(data)
        result.update(ok=status == 200 and value.get('case') == case and value.get('marker') == f['token']
                      and value.get('payload') == 'm' * size,
                      upstream_family=value.get('family'), bytes=len(data), body_sha256=hashlib.sha256(data).hexdigest())
    except (OSError, ValueError, AssertionError, EOFError, http.client.HTTPException) as error:
        result['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        if sock:
            sock.close()
    result['elapsed_ms'] = round((time.monotonic() - start) * 1000)
    return result


def udp_client(f, address, case, size=96, proxy=False, timeout=2):
    start = time.monotonic()
    result, assoc = {'ok': False}, None
    payload = f['token'].encode() + b':' + case.encode() + b':' + b'u' * size
    try:
        if proxy:
            assoc = socket.create_connection((f['bridge4'], f['proxy_port']), timeout=3)
            assoc.sendall(b'\x05\x01\x00')
            assert exact(assoc, 2) == b'\x05\x00'
            assoc.sendall(b'\x05\x03\x00' + socks_address('0.0.0.0', 0))
            reply = exact(assoc, 3)
            relay, port, _ = read_socks(assoc)
            if reply[1]:
                raise OSError('SOCKS reply ' + str(reply[1]))
            destination = (relay, port)
            wire = b'\0\0\0' + socks_address(address, f['udp_port']) + payload
            family = socket.AF_INET
        else:
            destination, wire = (address, f['udp_port']), payload
            family = socket.AF_INET6 if ':' in address else socket.AF_INET
        with socket.socket(family, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.connect(destination)
            sock.sendall(wire)
            data = sock.recv(32768)
        if proxy:
            assert data[:3] == b'\0\0\0'
            reader = Reader(data[3:])
            read_socks(reader)
            data = reader.stream.read()
        result.update(ok=data in (b'4:' + payload, b'6:' + payload),
                      upstream_family=int(data[:1]) if data[:1] in (b'4', b'6') else None,
                      bytes=len(data), body_sha256=hashlib.sha256(data).hexdigest())
    except (OSError, ValueError, EOFError, AssertionError) as error:
        result['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        if assoc:
            assoc.close()
    result['elapsed_ms'] = round((time.monotonic() - start) * 1000)
    return result


def delete_routes(f, owned):
    for key in owned:
        if interface(f[key]) == TUN:
            command(['/sbin/route', '-n', 'delete', *(['-inet6'] if key == 'data6' else []),
                     '-host', f[key], '-interface', TUN])


def restore_tailnet(root):
    marker = root / 'tailscale-restore-needed'
    if not marker.exists():
        return True
    result = command([TAILSCALE, 'up'], 20)
    if result['status'] != 0:
        (root / 'tailscale-restore-error.txt').write_text(result['stdout'] + result['stderr'])
        return False
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        state = command([TAILSCALE, 'status', '--json'], 4)
        try:
            if json.loads(state['stdout']).get('BackendState') == 'Running':
                marker.unlink(missing_ok=True)
                return True
        except ValueError:
            pass
        time.sleep(.5)
    return False


def watchdog(root, parent, engine_pid):
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline and not (root / 'guard-stop').exists():
        try:
            os.kill(parent, 0)
        except ProcessLookupError:
            break
        time.sleep(.5)
    if (root / 'guard-stop').exists():
        return
    identity = command(['/bin/ps', '-p', str(engine_pid), '-o', 'command='])['stdout']
    if str(root / 'config.json') in identity:
        os.kill(engine_pid, signal.SIGTERM)
        time.sleep(1)
        identity = command(['/bin/ps', '-p', str(engine_pid), '-o', 'command='])['stdout']
        if str(root / 'config.json') in identity:
            os.kill(engine_pid, signal.SIGKILL)
    owned = json.loads((root / 'owned-routes.json').read_text()) if (root / 'owned-routes.json').exists() else []
    delete_routes(json.loads((root / 'fixture.json').read_text()), owned)
    restore_tailnet(root)
    for row in json.loads((root / 'capture-pids.json').read_text()) if (root / 'capture-pids.json').exists() else []:
        identity = command(['/bin/ps', '-p', str(row['pid']), '-o', 'command='])['stdout']
        if row['path'] in identity:
            os.kill(row['pid'], signal.SIGINT)
    (root / 'watchdog-fired').write_text('Parent lost or cell deadline reached\n')
    if (root / 'report.json').exists():
        report = json.loads((root / 'report.json').read_text())
        f = json.loads((root / 'fixture.json').read_text())
        baseline = json.loads((root / 'baseline-routes.json').read_text())
        checks = report['checks']
        checks['watchdog_removed_tun'] = command(['/sbin/ifconfig', TUN])['status'] != 0
        checks['watchdog_restored_routes'] = all(interface(f[k]) == v for k, v in baseline.items())
        checks['watchdog_restored_dns'] = dns_state() == (root / 'baseline-dns.txt').read_text()
        for family in (4, 6):
            target = f['data' + str(family)]
            result = tcp_client(f, root / 'server.crt', target, target, 'https_verified', 'watchdog-native-' + str(family))
            checks['watchdog_native_https_' + str(family)] = result['ok'] and result.get('upstream_family') == family
        report.update(status='complete', passed=all(checks.values()), counts={'PASS_FOCUSED': 1},
                      cases=[{'id': 'F14-parent-loss-watchdog', 'kind': 'focused', 'result': 'PASS_FOCUSED' if all(checks.values()) else 'FAIL_FUNCTIONAL'}])
        (root / 'report.json').write_text(json.dumps(report, indent=2))


class Cell:
    def __init__(self, root, profile_id, mode, scope):
        self.root, self.profile_id, self.mode, self.scope = root, profile_id, mode, scope
        self.f = json.loads((root / 'fixture.json').read_text())
        self.config = json.loads((root / 'config.json').read_text())
        self.ca = root / 'server.crt'
        self.rows, self.checks, self.captures, self.owned_routes = [], {}, [], []
        self.engine = self.guard = self.log = None
        self.native_dns_fixture = None
        self.dns_owner = None
        self.tag = secrets.token_hex(3)
        self.baseline_dns = dns_state()
        self.baseline_routes = {k: interface(self.f[k]) for k in ('data4', 'data6', 'bridge4')}
        (root / 'baseline-dns.txt').write_text(self.baseline_dns)
        (root / 'baseline-routes.json').write_text(json.dumps(self.baseline_routes))
        self.report = {'status': 'running', 'profile': profile_id, 'proxy_mode': mode, 'scope': scope,
                       'tested_at_utc': datetime.now(timezone.utc).isoformat(), 'engine_sha256': SHA,
                       'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                       'profile_sha256': hashlib.sha256((root / 'config.json').read_bytes()).hexdigest(),
                       'checks': self.checks, 'cases': self.rows}
        if self.f.get('template_identity'):
            self.report['template'] = self.f['template_identity']
        self.report['engine_mode'] = self.config['mode']

    def name(self, cls, suffix):
        return cls + '-' + self.tag + '-' + suffix.lower().replace('_', '-') + '.mimo-lab.test'

    def service(self, address, hostname, protocol, case, **kwargs):
        if protocol == 'udp_nonce':
            return udp_client(self.f, address, case, **kwargs)
        return tcp_client(self.f, self.ca, address, hostname, protocol, case, **kwargs)

    def expected_family(self, cls, protocol, literal_family=None):
        if literal_family:
            return literal_family
        if self.config.get('mimo-destination-family') == 'ipv4':
            return None if cls in ('aaaaonly', 'nx') else 4
        if cls == 'aonly':
            return 4
        if cls == 'aaaaonly':
            return None if protocol == 'udp_nonce' and self.config['proxies'][0]['ip-version'] == 'ipv4' else 6
        if protocol == 'udp_nonce':
            return 6 if self.config['proxies'][0]['ip-version'] == 'ipv6-prefer' else 4
        return 6 if cls == 'dual6' else 4

    def expect_success(self, family, protocol):
        if family is None:
            return False
        behavior = MODES[self.mode][1 if protocol == 'udp_nonce' else 0]
        return family == 4 or behavior == 'forward'

    def allows_literal(self, family):
        if family == 6 and self.config.get('mimo-destination-family') == 'ipv4':
            return False
        return not (family == 6 and self.config['mode'] == 'rule'
                    and 'IP-CIDR6,::/0,REJECT,no-resolve' in self.config['rules'])

    def literal_result_matches(self, result, family):
        allowed = self.allows_literal(family)
        return result['ok'] == allowed and (not allowed or result.get('upstream_family') == family)

    def system_lookup(self, name):
        result = command(['/usr/bin/python3', '-c', 'import socket,json,sys;print(json.dumps(sorted({x[4][0] for x in socket.getaddrinfo(sys.argv[1],80)})))', name], 6)
        try:
            answers = json.loads(result['stdout']) if result['status'] == 0 else []
        except ValueError:
            answers = []
        if self.scope == 'focus-native-dns':
            # Preserve useful failure details without publishing native identities.
            families = {'real_ipv4': 0, 'real_ipv6': 0, 'fake_ipv4': 0, 'fake_ipv6': 0}
            for answer in answers:
                ip = ipaddress.ip_address(answer)
                fake = ip in ipaddress.ip_network('198.18.0.0/15') if ip.version == 4 else ip in ipaddress.ip_network('fdfe:dcba:9876:1::/64')
                families[('fake' if fake else 'real') + '_ipv' + str(ip.version)] += 1
            self.report.setdefault('native_dns_resolution_observations', []).append({
                'name_kind': ('lan' if name.startswith('lan') else 'split' if name.startswith('split') else 'tailnet') + ('_fqdn' if '.' in name.rstrip('.') else '_short'),
                'answers': families, 'resolver_succeeded': result['status'] == 0,
                'engine_running': self.engine is not None and self.engine.poll() is None})
        return answers

    def flush_system_dns(self):
        command(['/usr/bin/dscacheutil', '-flushcache'])
        command(['/usr/bin/killall', '-HUP', 'mDNSResponder'])

    def native_dns_cases(self):
        import copy
        from native_dns_fixture import Store
        store = Store()
        peer = self.f['native_dns_peer']['name'].rstrip('.')
        short = peer.split('.')[0]
        expected = self.native_dns_baseline['peer_addresses']
        search = lambda: list(dict.fromkeys(re.findall(r'search domain\[\d+\]\s*:\s*(\S+)', dns_state())))
        matches_peer = lambda name: bool(expected) and set(self.system_lookup(name)) == set(expected)
        self.flush_system_dns()
        try:
            current = search()
            self.focus_row('D01-search-list', current == self.native_dns_baseline['search'],
                           baseline_count=len(self.native_dns_baseline['search']), active_count=len(current))
            self.focus_row('D02-lan-short', self.system_lookup('lan' + self.tag) == [self.f['bridge4']])
            self.focus_row('D03-tailnet-fqdn', matches_peer(peer))
            self.focus_row('D04-tailnet-short', matches_peer(short))
            (self.root / 'tailscale-restore-needed').touch()
            down = command([TAILSCALE, 'down'], 10)
            assert down['status'] == 0, 'Tailscale disconnect failed'
            self.flush_system_dns()
            time.sleep(5.2)
            assert controller(self.root, '/cache/dns/flush', 'POST').get('http_status') == 204
            disconnected = self.system_lookup(peer)
            public = self.upstream_query('aonly', 'tailnet-disconnected', 'A')
            events = control(self.f)['events']
            private_in_public_dns = any(e.get('event') == 'dns' and e.get('name', '').endswith('.ts.net') for e in events)
            self.focus_row('D05-tailnet-disconnected', not disconnected and public['ok'] and not private_in_public_dns,
                           private_answer_count=len(disconnected), public_dns_ok=public['ok'], private_query_in_public_doh=private_in_public_dns)
            assert restore_tailnet(self.root), 'Tailscale restoration failed'
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                self.flush_system_dns()
                controller(self.root, '/cache/dns/flush', 'POST')
                if matches_peer(peer): break
                time.sleep(.5)
            self.focus_row('D06-tailnet-reconnected-fqdn', matches_peer(peer))
            self.focus_row('D07-tailnet-reconnected-short', matches_peer(short))
            custom = 'split' + self.tag + '.mimo-native.test'
            self.focus_row('D08-native-split-dns', self.system_lookup(custom) == [self.f['bridge4']])
            switched = copy.deepcopy(self.config)
            switched['mode'] = 'global' if self.config['mode'] == 'rule' else 'rule'
            for i, config in enumerate((switched, self.config)):
                self.reload(config, 'native-mode-' + str(i))
            self.flush_system_dns()
            owned = [k for k in store.dns() if ('/sing-tun-' in k or 'com.mimo.dns' in k)]
            public = self.upstream_query('aonly', 'native-reload', 'A')
            self.focus_row('D09-mode-reload', len(owned) == 1 and public['ok'] and matches_peer(short)
                           and search() == self.native_dns_baseline['search'], owned_resolver_count=len(owned), public_dns_ok=public['ok'])
            self.native_dns_fixture.change_search(True)
            time.sleep(.4); self.flush_system_dns()
            self.focus_row('D10-native-search-change', 'mimo-native2.test' in search()
                           and self.system_lookup('lannew' + self.tag) == [self.f['bridge4']],
                           method='Changed only fixture-owned default and supplemental DNS/search entries; saved network preferences untouched.')
            # Keep capturing shutdown, but distinguish it from active protection.
            # Removing routes/stopping this standalone engine ends enforcement;
            # macOS can still have DNS requests queued for its former endpoint.
            self.report['active_capture_ended_at'] = time.time()
            self.stop_dns_owner()
            delete_routes(self.f, self.owned_routes)
            self.owned_routes.clear(); (self.root / 'owned-routes.json').write_text('[]')
            stop(self.engine)
            time.sleep(.5); self.flush_system_dns()
            native_state = dns_state()
            self.focus_row('D12-graceful-exit', not any(('/sing-tun-' in k or 'com.mimo.dns' in k) for k in store.dns())
                           and command(['/sbin/ifconfig', TUN])['status'] != 0
                           and matches_peer(peer) and matches_peer(short)
                           and self.system_lookup('lanafter' + self.tag) == [self.f['bridge4']])
            # Abort a fresh startup as soon as its temporary DNS entry appears.
            aborted = subprocess.Popen([ENGINE, '-d', str(self.root), '-f', str(self.root / 'config.json')],
                                       stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
            seen = False
            self.start_dns_owner(aborted)
            try:
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline and aborted.poll() is None:
                    if any(('/sing-tun-' in k or 'com.mimo.dns' in k) for k in store.dns()):
                        seen = True; break
                    time.sleep(.01)
            finally:
                stop(aborted, signal.SIGKILL)
            self.stop_dns_owner()
            time.sleep(.5); self.flush_system_dns()
            self.focus_row('D11-startup-aborted-after-dns', seen and dns_state() == native_state
                           and not any(('/sing-tun-' in k or 'com.mimo.dns' in k) for k in store.dns())
                           and command(['/sbin/ifconfig', TUN])['status'] != 0,
                           method='Injected process death immediately after DNS registration; no app workload started.')
        finally:
            store.close()
            assert restore_tailnet(self.root), 'Tailscale restoration failed during cleanup'

    def native_transport_cases(self):
        peer = self.f['native_peer']
        self.report['native_ping_targets'] = peer['addresses']
        for i, target in enumerate(peer['addresses']):
            assert interface(target) != TUN
            ping = command(['/sbin/ping6' if ':' in target else '/sbin/ping', '-n', '-c', '2', '-i', '.2', target], 4)
            self.focus_row('F11-native-peer-ping-' + str(i), ping['status'] == 0)
        for kind in (1, 28):
            native = dns_query('100.100.100.100', 53, peer['name'], kind, 'tcp')
            actual = dns_query('127.0.0.1', 1053, peer['name'], kind, 'tcp')
            expected = [x['data'] for x in native['answers'] if x['type'] == kind]
            if kind == 28 and not self.config['dns']['ipv6']: expected = []
            values = [x['data'] for x in actual['answers'] if x['type'] == kind]
            self.focus_row('F11-native-peer-dns-' + str(kind), actual['rcode'] == native['rcode'] == 0 and values == expected)

    def udp_disabled_cases(self):
        import copy
        config = copy.deepcopy(self.config); config['proxies'][0]['udp'] = False
        self.reload(config, 'udp-disabled')
        for family in (4, 6):
            target = self.f['data' + str(family)]
            for path in ('tun', 'mixed'):
                label = 'UDP-disabled-' + str(family) + '-' + path
                if path == 'tun':
                    result = self.service(target, target, 'udp_nonce', label)
                else:
                    result = udp_client(dict(self.f, bridge4='127.0.0.1', proxy_port=7890), target, label, proxy=True)
                tcp = self.service(self.f['data4'], self.f['data4'], 'https_verified', label + '-tcp-control')
                allowed = self.config['mode'] == 'global' and 'mimo-destination-family' not in self.config
                valid = (not result['ok'] if not allowed else (not result['ok'] or result.get('upstream_family') == family))
                self.focus_row(label, valid and tcp['ok'], udp=result, tcp_control=tcp,
                               expectation='Rule rejects; Global may proxy or fail, never use native fallback.')
        self.reload(self.config, 'udp-restored')

    def preflight(self):
        assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
        assert self.root.stat().st_uid == 0 and self.root.stat().st_mode & 0o077 == 0
        assert ENGINE and hashlib.sha256(Path(ENGINE).read_bytes()).hexdigest() == SHA, 'Test engine checksum mismatch'
        require_no_engine()
        require_ports_free()
        assert command(['/sbin/ifconfig', TUN])['status'] != 0
        assert self.f['bridge4'] != self.f['data4']
        assert self.baseline_routes['bridge4'] == 'en0' and self.baseline_routes['data6'] == 'en0'
        for family in (4, 6):
            target = self.f['data' + str(family)]
            for protocol in ('http', 'https_verified', 'udp_nonce'):
                result = self.service(target, target, protocol, 'native-before-' + str(family) + '-' + protocol)
                self.checks['native_before_' + str(family) + '_' + protocol] = result['ok'] and result.get('upstream_family') == family
            for protocol in ('https_verified', 'udp_nonce'):
                result = self.service(target, target, protocol, 'fixture-' + str(family) + '-' + protocol, proxy=True, timeout=2)
                expected = self.expect_success(family, protocol)
                self.checks['fixture_' + str(family) + '_' + protocol] = result['ok'] == expected and (not result['ok'] or result.get('upstream_family') == family)
        assert all(self.checks.values()), 'Native service or proxy fixture preflight failed'

    def start_dns_owner(self, engine):
        if not (self.root / 'dns-owner').exists(): return
        for name in ('dns-owner-stop', 'dns-owner-ready'): (self.root / name).unlink(missing_ok=True)
        self.dns_owner = subprocess.Popen([str(self.root / 'dns-owner'), str(os.getpid()), str(engine.pid), str(self.root)], stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if (self.root / 'dns-owner-ready').exists(): return
            assert self.dns_owner.poll() is None, 'Production DNS owner exited'
            time.sleep(.05)
        raise AssertionError('Production DNS owner did not install')

    def stop_dns_owner(self):
        if self.dns_owner:
            (self.root / 'dns-owner-stop').touch()
            self.dns_owner.wait(timeout=10)
            self.dns_owner = None

    def start(self):
        config = self.config
        assert config['mode'] in ('global', 'rule')
        if not self.f.get('template_identity'):
            assert config['mode'] == 'global' and config['rules'] == []
        assert config['tun']['stack'] == 'gvisor-no-ping'
        result = command([ENGINE, '-t', '-d', str(self.root), '-f', str(self.root / 'config.json')], 10)
        (self.root / 'validation.log').write_text(result['stdout'] + result['stderr'])
        assert result['status'] == 0, 'Engine rejected variant'
        self.log = (self.root / 'engine.log').open('w')
        self.engine = subprocess.Popen([ENGINE, '-d', str(self.root), '-f', str(self.root / 'config.json')],
                                       stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
        self.guard = subprocess.Popen(['/usr/bin/python3', str(Path(__file__).resolve()), '--watchdog', str(self.root),
                                      str(os.getpid()), str(self.engine.pid)], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert self.engine.poll() is None, 'Engine exited'
            if (self.root / 'controller.sock').exists() and interface('2001:db8::1') == TUN:
                break
            time.sleep(.1)
        assert interface('2001:db8::1') == TUN
        for key in ('data4', 'data6'):
            result = command(['/sbin/route', '-n', 'add', *(['-inet6'] if key == 'data6' else []),
                              '-host', self.f[key], '-interface', TUN])
            assert result['status'] == 0, 'Cannot add exact data capture route: ' + key
            self.owned_routes.append(key)
            (self.root / 'owned-routes.json').write_text(json.dumps(self.owned_routes))
        self.checks['data_routes_captured'] = all(interface(self.f[k]) == TUN for k in ('data4', 'data6'))
        self.checks['control_route_native'] = interface(self.f['bridge4']) == 'en0'
        self.start_dns_owner(self.engine)
        current = controller(self.root, '/configs')
        (self.root / 'active-dns.txt').write_text(dns_state())
        live_rules = controller(self.root, '/rules').get('rules')
        self.report['live_rules'] = live_rules
        self.checks['live_mode_and_rule_count'] = current.get('mode') == config['mode'] and isinstance(live_rules, list) and len(live_rules) == len(config['rules'])
        self.checks['live_proxy_selection'] = controller(self.root, '/proxies/GLOBAL').get('now') == 'Proxy' and controller(self.root, '/proxies/Proxy').get('now') == config['proxies'][0]['name']
        self.checks['live_no_ping_stack'] = current.get('tun', {}).get('stack') == 'gvisor-no-ping'
        if self.config['tun']['dns-mode'] == 'disabled' and self.dns_owner is None:
            self.checks['dns_unchanged_active'] = dns_state() == self.baseline_dns
        else:
            self.checks['native_dns_registered'] = dns_state() != self.baseline_dns
        assert all(self.checks.values()), 'Startup invariants failed'
        bpf = '(host ' + self.f['data4'] + ' or host ' + self.f['data6'] + ' or host 1.1.1.1 or net 198.18.0.0/16 or net fdfe:dcba:9876:1::/64 or net 64:ff9b::/96 or net 64:ff9b:1::/48 or icmp or icmp6 or port 53 or port 853 or (host ' + self.f['bridge4'] + ' and not port 22))'
        interfaces = ['en0', TUN]
        if self.scope.startswith('focus') and self.f.get('native_peer', {}).get('addresses'):
            nic = interface(self.f['native_peer']['addresses'][0])
            if nic and nic not in interfaces:
                interfaces.append(nic)
        for nic in interfaces:
            path = self.root / (nic + '.pcap')
            err = (self.root / (nic + '-capture.log')).open('w')
            process = subprocess.Popen(['/usr/sbin/tcpdump', '-n', '-U', '--immediate-mode', '-i', nic, '-s', '512', '-w', str(path), bpf],
                                       stdout=subprocess.DEVNULL, stderr=err)
            self.captures.append((nic, process, err, path))
        (self.root / 'capture-pids.json').write_text(json.dumps([{'pid': p.pid, 'path': str(path)} for _, p, _, path in self.captures]))
        time.sleep(.4)
        assert all(p.poll() is None for _, p, _, _ in self.captures)

    def focus_row(self, identifier, success, **observation):
        self.rows.append({'id': identifier, 'kind': 'focused', 'result': 'PASS_FOCUSED' if success else 'FAIL_FUNCTIONAL',
                          'observation': observation})

    def reload(self, config, label):
        # Payload reload leaves the original command/config identity available to the watchdog.
        (self.root / ('reload-' + label + '.json')).write_text(json.dumps(config))
        response = controller(self.root, '/configs', 'PUT', {'payload': json.dumps(config)})
        assert response.get('http_status') == 204, response
        time.sleep(.15)
        assert all(interface(self.f[k]) == TUN for k in ('data4', 'data6')), 'Reload changed capture routes'
        assert controller(self.root, '/proxies/GLOBAL').get('now') == 'Proxy'

    def upstream_query(self, cls, label, qtype='AAAA'):
        name = self.name(cls, label + '-' + secrets.token_hex(2))
        try:
            value = controller(self.root, '/dns/query?' + urllib.parse.urlencode({'name': name, 'type': qtype}))
            return {'ok': value.get('Status') == 0 and bool(value.get('Answer')), 'value': value}
        except Exception as error:
            return {'ok': False, 'error': type(error).__name__ + ': ' + str(error)}

    def focused(self):
        import copy
        f = self.f
        # Every focus run first demonstrates both data families, even diagnostics.
        for family in (4, 6):
            target = f['data' + str(family)]
            for protocol in ('http', 'https_verified', 'udp_nonce'):
                result = self.service(target, target, protocol, 'focus-base-' + str(family) + '-' + protocol)
                self.focus_row('base-' + str(family) + '-' + protocol, self.literal_result_matches(result, family), expected_policy_allowed=self.allows_literal(family), **result)
        if self.profile_id in ('P08', 'P09', 'P10'):
            self.diagnostic_variant()
            return
        # F01/F02: DNS transport family is separate from the returned record family.
        for family in (4, 6):
            config = copy.deepcopy(self.config)
            host = f['data4'] if family == 4 else '[' + f['data6'] + ']'
            config['dns']['nameserver'] = ['https://' + host + ':' + str(f['https_port']) + '/dns-query#Proxy']
            self.reload(config, 'doh' + str(family))
            for mode in ('S00', 'S04'):
                control(f, {'mode': mode, 'disconnect': True})
                result = self.upstream_query('aaaaonly', 'doh' + str(family) + mode)
                self.focus_row('F01-doh' + str(family) + '-' + mode, result['ok'] == (family == 4 or mode == 'S00'), **result)
        control(f, {'mode': 'S00', 'disconnect': True})
        self.reload(self.config, 'dns-restore')
        for fault in ('nodata6', 'servfail', 'nxdomain', 'timeout'):
            control(f, {'dns_fault': fault, 'disconnect': True})
            result = self.upstream_query('aaaaonly', fault)
            value = result.get('value', {})
            valid = (value.get('Status') == 0 and not value.get('Answer')) if fault == 'nodata6' else not result['ok']
            self.focus_row('F02-' + fault, valid, **result)
            control(f, {'dns_fault': '', 'disconnect': True})
            recovered = self.upstream_query('aaaaonly', 'recovery-' + fault)
            self.focus_row('F02-recover-' + fault, recovered['ok'], **recovered)
        badca = copy.deepcopy(self.config)
        badca.pop('tls')
        self.reload(badca, 'bad-ca')
        bad = self.upstream_query('aaaaonly', 'bad-ca')
        self.focus_row('F02-tls-untrusted', not bad['ok'], **bad)
        self.reload(self.config, 'ca-restore')
        recovered = self.upstream_query('aaaaonly', 'tls-recovered')
        self.focus_row('F02-tls-recovery', recovered['ok'], **recovered)
        # F03/F04/F05: command, auth, relay and connection failures stay inside SOCKS.
        udp_faults = ('no_udp', 'drop_udp', 'relay_unavailable', 'association_close')
        for fault in ('no_domain', 'reply_3', 'reply_7', 'reply_8', *udp_faults, 'auth', 'reset'):
            control(f, {'fault': fault, 'disconnect': True})
            name = self.name('aonly' if fault in udp_faults else 'aaaaonly', fault)
            address = dns_query('127.0.0.1', 1053, name, 28 if self.config['dns']['ipv6'] else 1)['answers'][0]['data']
            protocol = 'udp_nonce' if fault in udp_faults else 'https_verified'
            result = self.service(address, name, protocol, 'fault-' + fault)
            self.focus_row('F03-F05-' + fault, not result['ok'], **result)
            if fault == 'no_domain' or fault in udp_faults:
                result = self.service(f['data4'], f['data4'], 'https_verified', 'fault-control-' + fault)
                self.focus_row('F03-F05-control-' + fault, result['ok'], **result)
            control(f, {'fault': '', 'disconnect': True})
        control(f, {'fault': 'require_auth', 'disconnect': True})
        for accepted in (False, True):
            config = copy.deepcopy(self.config)
            config['proxies'][0].update(username='lab', password=f['token'] if accepted else 'deliberately-incorrect-local-test')
            self.reload(config, 'auth-' + str(accepted))
            auth_target = f['data6'] if self.allows_literal(6) else f['data4']
            result = self.service(auth_target, auth_target, 'https_verified', 'auth-' + str(accepted))
            self.focus_row('F05-password-' + str(accepted), result['ok'] == accepted, **result)
        control(f, {'fault': '', 'disconnect': True})
        self.reload(self.config, 'auth-restore')
        for family in (4, 6):
            control(f, {'proxy_off': True, 'disconnect': True})
            target = f['data' + str(family)]
            for protocol in ('http', 'udp_nonce'):
                result = self.service(target, target, protocol, 'proxy-off-' + str(family) + '-' + protocol)
                self.focus_row('F05-off-' + str(family) + '-' + protocol, not result['ok'], **result)
            control(f, {'proxy_off': False})
        # F06: retain a fake mapping while the proxy's real capability changes.
        name = self.name('aaaaonly', 'capability-change')
        address = dns_query('127.0.0.1', 1053, name, 28 if self.config['dns']['ipv6'] else 1)['answers'][0]['data']
        for phase, mode in (('initial', 'S00'), ('unavailable', 'S04'), ('recovered', 'S00')):
            control(f, {'mode': mode, 'disconnect': True})
            result = self.service(address, name, 'https_verified', 'warm-' + mode + secrets.token_hex(2))
            self.focus_row('F06-warm-' + mode + '-' + phase, result['ok'] == (mode == 'S00' and self.config.get('mimo-destination-family') != 'ipv4'), **result)
        # F07: browser-style automatic connection selection plus an explicit retry.
        for mode in ('S04', 'S02'):
            control(f, {'mode': mode, 'disconnect': True})
            host = self.name('dual6', 'happy-' + mode)
            resolved = host + ':' + str(f['https_port']) + ':[' + f['data6'] + '],' + f['data4']
            curl = command(['/usr/bin/curl', '--noproxy', '*', '--cacert', str(self.ca), '-sS', '--max-time', '4',
                            '--happy-eyeballs-timeout-ms', '100', '--resolve', resolved,
                            'https://' + host + ':' + str(f['https_port']) + '/' + f['token'] + '/happy-' + mode], 5)
            # An HTTP/TLS failure after TUN accepts TCP need not trigger Happy Eyeballs.
            self.focus_row('F07-auto-' + mode, curl['status'] in (0, 7, 28, 35, 52, 56), client_status=curl['status'],
                           note='Automatic IPv4 retry is measured, not assumed after a successful local TUN TCP handshake.')
            v6 = self.service(f['data6'], f['data6'], 'https_verified', 'retry6-' + mode)
            v4 = self.service(f['data4'], f['data4'], 'https_verified', 'retry4-' + mode)
            self.focus_row('F07-explicit-retry-' + mode, not v6['ok'] and v4['ok'] and v4.get('upstream_family') == 4,
                           ipv6=v6, ipv4=v4)
        control(f, {'mode': 'S00', 'disconnect': True})
        # F09: real payload and fragment/reassembly coverage.
        for family in (4, 6):
            target = f['data' + str(family)]
            for size in (96, 1232, 8224):
                result = self.service(target, target, 'udp_nonce', 'large-' + str(family) + '-' + str(size), size=size)
                self.focus_row('F09-udp-' + str(family) + '-' + str(size), self.literal_result_matches(result, family), expected_policy_allowed=self.allows_literal(family), **result)
            result = self.service(target, target, 'https_verified', 'bulk-' + str(family), size=233472)
            self.focus_row('F09-https-' + str(family), self.literal_result_matches(result, family), expected_policy_allowed=self.allows_literal(family), **result)
        # F10/F11: actual ping packet results are evaluated after capture stops.
        self.report['blocked_ping_targets'] = ['198.51.100.37', '198.18.55.10', '2001:db8::37',
                                               'fdfe:dcba:9876::2', 'fdfe:dcba:9876:1::55', *NAT64_TEST_TARGETS]
        for i, target in enumerate(self.report['blocked_ping_targets']):
            assert interface(target) == TUN
            ping = command(['/sbin/ping6' if ':' in target else '/sbin/ping', '-n', '-c', '2', '-i', '.2', target], 3)
            self.focus_row('F10-ping-' + str(i), ping['status'] != 0, exit_status=ping['status'])
        # Temporarily release only the data6 instrumentation for its native ping.
        delete_routes(f, ['data6'])
        native = [f['bridge4'], f['data6'], *f.get('native_peer', {}).get('addresses', [])]
        self.report['native_ping_targets'] = native
        for i, target in enumerate(native):
            assert interface(target) != TUN
            ping = command(['/sbin/ping6' if ':' in target else '/sbin/ping', '-n', '-c', '2', '-i', '.2', target], 3)
            self.focus_row('F11-native-ping-' + str(i), ping['status'] == 0, exit_status=ping['status'])
        assert command(['/sbin/route', '-n', 'add', '-inet6', '-host', f['data6'], '-interface', TUN])['status'] == 0
        peer = f.get('native_peer', {})
        if peer.get('name'):
            for qtype in (1, 28):
                native_result = dns_query('100.100.100.100', 53, peer['name'], qtype, 'tcp')
                result = dns_query('127.0.0.1', 1053, peer['name'], qtype, 'tcp')
                expected = [x['data'] for x in native_result['answers'] if x['type'] == qtype]
                if qtype == 28 and not self.config['dns']['ipv6']:
                    expected = []
                actual = [x['data'] for x in result['answers'] if x['type'] == qtype]
                self.focus_row('F11-magicdns-' + str(qtype), result['rcode'] == native_result['rcode'] == 0 and actual == expected,
                               answer_count=len(actual), native_answer_count=len(expected),
                               note='Tailnet IPv6 address availability does not imply that Quad100 publishes an AAAA record.')
        # F12: retain literal NAT64 destination through SOCKS; fixture mapping only.
        for i, target in enumerate(NAT64_TEST_TARGETS):
            for mode in ('S00', 'S04'):
                control(f, {'mode': mode, 'disconnect': True})
                for protocol in ('http', 'udp_nonce'):
                    result = self.service(target, target, protocol, 'nat64-' + str(i) + '-' + mode + '-' + protocol)
                    self.focus_row('F12-' + str(i) + '-' + mode + '-' + protocol, result['ok'] == (mode == 'S00' and self.allows_literal(6)),
                                   note='Fixture mapping qualifies transport, not actual NAT64 translation.', **result)
        control(f, {'mode': 'S00', 'disconnect': True})
        # F14: repeat settings reload and stock parser refusal.
        baseline = copy.deepcopy(self.config)
        baseline['dns']['ipv6'] = False
        baseline['dns'].pop('fake-ip-range6', None)
        baseline['proxies'][0]['ip-version'] = 'ipv4'
        if not self.config['dns']['ipv6']:
            baseline['dns'].update(ipv6=True, **{'fake-ip-range6': 'fdfe:dcba:9876:1::/64'})
            baseline['proxies'][0]['ip-version'] = 'dual'
        for i, config in enumerate((baseline, self.config, baseline, self.config)):
            self.reload(config, 'cycle-' + str(i))
            name = self.name('aaaaonly', 'cycle-' + str(i))
            result = dns_query('127.0.0.1', 1053, name, 28)
            self.focus_row('F14-reload-' + str(i), bool(result['answers']) == bool(config['dns']['ipv6']))
        stock = command(['/opt/homebrew/opt/mihomo@1.19.34/bin/mihomo', '-t', '-d', str(self.root), '-f', str(self.root / 'config.json')])
        self.focus_row('F14-stock-rejected', stock['status'] != 0 and 'invalid tun stack' in (stock['stdout'] + stock['stderr']).lower())
        try:
            require_ports_free()
            occupied_rejected = False
        except OSError:
            occupied_rejected = True
        self.focus_row('F14-occupied-port-preflight', occupied_rejected)
        self.report['focused_limits'] = ['Host packet capture unavailable: /dev/bpf is root-only; VM captures and real host socket/service records used.',
                                         'No crafted ICMPv6 Packet Too Big injection; control preservation has existing packet-handler unit tests.',
                                         'Wrong-hash rejection is enforced in preflight; no replacement binary executed.']
        (self.root / 'host-events.json').write_text(json.dumps(control(f)))

    def diagnostic_variant(self):
        if self.profile_id == 'P08':
            for cls in ('aonly', 'aaaaonly', 'dual4', 'dual6'):
                name = self.name(cls, 'prefer6')
                address = dns_query('127.0.0.1', 1053, name, 28)['answers'][0]['data']
                result = self.service(address, name, 'udp_nonce', 'prefer6-' + cls)
                expected = 4 if cls == 'aonly' else 6
                self.focus_row('F07-prefer6-' + cls, result['ok'] and result.get('upstream_family') == expected, **result)
        elif self.profile_id == 'P09':
            for cls in ('aonly', 'aaaaonly', 'dual4', 'dual6', 'nx'):
                for qtype in (1, 28):
                    name = self.name(cls, 'redir' + str(qtype))
                    dns = dns_query('127.0.0.1', 1053, name, qtype)
                    expected = [] if cls == 'nx' or (cls == 'aonly' and qtype == 28) or (cls == 'aaaaonly' and qtype == 1) else [self.f['data4' if qtype == 1 else 'data6']]
                    actual = [x['data'] for x in dns['answers'] if x['type'] == qtype]
                    self.focus_row('F08-redir-' + cls + '-' + str(qtype), actual == expected and dns['rcode'] == (3 if cls == 'nx' else 0))
            self.mixed_listener_cases()
        elif self.profile_id == 'P10' or self.scope == 'focus-system':
            self.focus_row('F13-system-dns-registered', dns_state() != self.baseline_dns)
            for cls in ('aonly', 'aaaaonly', 'dual4'):
                name = self.name(cls, 'system')
                result = command(['/usr/bin/python3', '-c', 'import socket,json,sys;print(json.dumps(sorted({x[4][0] for x in socket.getaddrinfo(sys.argv[1],80)})))', name], 6)
                try:
                    values = json.loads(result['stdout'])
                except ValueError:
                    values = []
                self.focus_row('F13-system-' + cls, result['status'] == 0 and bool(values), families=sorted({6 if ':' in x else 4 for x in values}), status=result['status'])
                result = command(['/usr/bin/curl', '--noproxy', '*', '--cacert', str(self.ca), '-sS', '--max-time', '5',
                                  'https://' + name + ':' + str(self.f['https_port']) + '/' + self.f['token'] + '/system-' + cls], 6)
                try:
                    body = json.loads(result['stdout'])
                except ValueError:
                    body = {}
                expected = cls != 'aaaaonly' or self.config.get('mimo-destination-family') != 'ipv4'
                ok = result['status'] == 0 and body.get('marker') == self.f['token'] and body.get('case') == 'system-' + cls
                self.focus_row('F13-system-https-' + cls, ok == expected, status=result['status'], upstream_family=body.get('family'))
            # Fetch a unique HTTP document in the VM's existing GUI user session.
            # Its service record proves a real browser request; close only that document.
            import pwd
            uid = os.stat('/dev/console').st_uid
            username = pwd.getpwuid(uid).pw_name
            name = self.name('aaaaonly', 'safari')
            url = 'http://' + name + ':' + str(self.f['http_port']) + '/' + self.f['token'] + '/safari-smoke'
            script = 'tell application "Safari"\nmake new document with properties {URL:' + json.dumps(url) + '}\nset labWindowID to id of front window\ndelay 2\nclose window id labWindowID\nend tell'
            safari = command(['/bin/launchctl', 'asuser', str(uid), '/usr/bin/sudo', '-n', '-u', username,
                              '/usr/bin/osascript', '-e', script], 8)
            events = control(self.f)['events']
            browser_seen = any(e.get('event') == 'service_tcp' and e.get('case') == 'safari-smoke' and e.get('family') == 6 for e in events)
            self.focus_row('F07-safari-real-ipv6', safari['status'] == 0 and browser_seen == (self.config.get('mimo-destination-family') != 'ipv4'), exit_status=safari['status'], ipv6_service_seen=browser_seen, automation_error=safari['stderr'])
            # F15 explicitly demonstrates that the profile does not survive engine exit.
            self.engine.kill()
            self.engine.wait(timeout=3)
            self.stop_dns_owner()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and dns_state() != self.baseline_dns:
                time.sleep(.1)
            self.focus_row('F13-crash-dns-cleanup', dns_state() == self.baseline_dns)
            self.focus_row('F15-crash-tun-removed', command(['/sbin/ifconfig', TUN])['status'] != 0,
                           note='Native networking resumes after engine exit; no standalone fail-closed guarantee.')

    def mixed_listener_cases(self):
        f = dict(self.f, bridge4='127.0.0.1', proxy_port=7890)
        for family in (4, 6):
            for hostname in (False, True):
                target = self.name('aonly' if family == 4 else 'aaaaonly', 'mixed') if hostname else self.f['data' + str(family)]
                label = 'F08-mixed-' + str(family) + '-' + str(hostname)
                tcp = tcp_client(f, self.ca, target, target, 'https_verified', label + '-tcp', proxy=True)
                udp = udp_client(f, target, label + '-udp', proxy=True)
                expected_tcp = (hostname or self.allows_literal(family)) and not (family == 6 and self.config.get('mimo-destination-family') == 'ipv4')
                expected_udp = expected_tcp and not (hostname and family == 6 and self.config['proxies'][0]['ip-version'] == 'ipv4')
                self.focus_row(label + '-tcp', tcp['ok'] == expected_tcp and (not expected_tcp or tcp.get('upstream_family') == family), expected_success=expected_tcp, **tcp)
                self.focus_row(label + '-udp', udp['ok'] == expected_udp and (not expected_udp or udp.get('upstream_family') == family), expected_success=expected_udp, **udp)

    def focused_extra(self):
        f = self.f
        for family in (4, 6):
            target = f['data' + str(family)]
            result = self.service(target, target, 'https_verified', 'extra-base-' + str(family))
            self.focus_row('extra-base-' + str(family), self.literal_result_matches(result, family), expected_policy_allowed=self.allows_literal(family), **result)
        self.mixed_listener_cases()
        # Expired cached answers are distinct from a fresh upstream success.
        name = self.name('aaaaonly', 'expiry')
        path = '/dns/query?' + urllib.parse.urlencode({'name': name, 'type': 'AAAA'})
        first = controller(self.root, path)
        control(f, {'dns_fault': 'servfail', 'disconnect': True})
        time.sleep(2.3)
        second = controller(self.root, path)
        time.sleep(.5)
        state = control(f)
        fault_seen = any(e.get('event') == 'dns' and e.get('name') == name and e.get('fault') == 'servfail' for e in state['events'])
        cached = [x.get('data') for x in first.get('Answer', [])]
        after = [x.get('data') for x in second.get('Answer', [])]
        self.focus_row('F02-expired-cache-during-fault', first.get('Status') == 0 and bool(cached) and fault_seen
                       and (after == cached or not after), stale_answer_returned=bool(after), upstream_fault_seen=fault_seen,
                       note='A retained DNS answer does not prove that a new upstream query succeeded.')
        control(f, {'dns_fault': '', 'disconnect': True})
        recovery = self.upstream_query('aaaaonly', 'expiry-recovery')
        self.focus_row('F02-expired-cache-recovery', recovery['ok'], **recovery)
        # Independently verify that the fixture revokes a UDP relay on TCP closure.
        assoc = socket.create_connection((f['bridge4'], f['proxy_port']), timeout=3)
        relay_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            assoc.sendall(b'\x05\x01\x00')
            assert exact(assoc, 2) == b'\x05\x00'
            assoc.sendall(b'\x05\x03\x00' + socks_address('0.0.0.0', 0))
            assert exact(assoc, 3) == b'\x05\x00\x00'
            address, port, _ = read_socks(assoc)
            payload = f['token'].encode() + b':revocation:proof'
            packet = b'\0\0\0' + socks_address(f['data6'], f['udp_port']) + payload
            relay_sock.settimeout(2)
            relay_sock.connect((address, port))
            relay_sock.sendall(packet)
            response = relay_sock.recv(32768)
            reader = Reader(response[3:]); read_socks(reader)
            initial = reader.stream.read() == b'6:' + payload
            assoc.shutdown(socket.SHUT_RDWR); assoc.close()
            time.sleep(.3)
            denied = False
            try:
                relay_sock.sendall(packet)
                relay_sock.recv(32768)
            except OSError:
                denied = True
            events = control(f)['events']
            count = sum(e.get('event') == 'service_udp' and e.get('case') == 'revocation' for e in events)
            self.focus_row('F04-udp-association-revoked', initial and denied and count == 1,
                           initial_reply=initial, after_close_denied=denied, service_requests=count)
        finally:
            assoc.close(); relay_sock.close()
        (self.root / 'host-events.json').write_text(json.dumps(control(f)))

    def application_pair(self, target_index, target, protocol):
        case = self.profile_id + '-' + self.mode + '-a' + str(target_index) + '-' + protocol
        cls = target.get('name_class')
        mapping = {'a_only': 'aonly', 'aaaa_only': 'aaaaonly', 'dual_proxy_tcp_prefers_ipv4': 'dual4', 'dual_proxy_tcp_prefers_ipv6': 'dual6'}
        cls = mapping.get(cls)
        name = self.name(cls, case) if cls else self.f['data4' if target['id'] == 'literal4' else 'data6']
        rows = []
        for cache in ('cold', 'warm'):
            identifier = case + '-' + cache
            row = {'id': identifier, 'kind': 'application', 'target': target['id'], 'protocol': protocol,
                   'cache': cache, 'name': name if cls else None}
            start = time.monotonic()
            try:
                if cls:
                    qtype = 28 if target['client_address'] == 'listener_AAAA' else 1
                    dns = dns_query('127.0.0.1', 1053, name, qtype)
                    addresses = [a['data'] for a in dns['answers'] if a['type'] == qtype]
                    if not addresses:
                        expected_empty = qtype == 28 and not (self.config['dns']['ipv6'] and self.config['dns'].get('fake-ip-range6'))
                        row.update(result='EXPECTED_DNS_SUPPRESSION' if expected_empty else 'FAIL_FUNCTIONAL', dns=dns)
                        rows.append(row)
                        continue
                    address = addresses[0]
                else:
                    address = name
                family = self.expected_family(cls, protocol, (4 if target['id'] == 'literal4' else 6) if cls is None else None)
                expected = self.expect_success(family, protocol)
                if cls is None:
                    expected = expected and self.allows_literal(family)
                observation = self.service(address, name, protocol, identifier)
                valid = observation['ok'] == expected and (not expected or observation.get('upstream_family') == family)
                row.update(client_family=6 if ':' in address else 4, expected_upstream_family=family,
                           expected_success=expected, observation=observation,
                           result=('PASS_SERVICE' if expected else 'PASS_EXPECTED_DENIAL_PENDING_CAPTURE') if valid else 'FAIL_FUNCTIONAL')
            except Exception as error:
                row.update(result='FAIL_FUNCTIONAL', error=type(error).__name__ + ': ' + str(error))
            row['elapsed_ms'] = round((time.monotonic() - start) * 1000)
            rows.append(row)
        return rows

    def dns_case(self, cls, qtype, transport, delivery):
        label = '-'.join((cls, str(qtype), transport, delivery))
        name = self.name(cls, label)
        row = {'id': self.profile_id + '-' + self.mode + '-dns-' + label, 'kind': 'dns_delivery', 'name': name}
        server, port = {'local': ('127.0.0.1', 1053), 'capture4': (self.f['data4'], 53), 'capture6': (self.f['data6'], 53)}[delivery]
        try:
            result = dns_query(server, port, name, qtype, transport)
            answers = [a['data'] for a in result['answers'] if a['type'] == qtype]
            enabled = qtype == 1 or (self.config['dns']['ipv6'] and self.config['dns'].get('fake-ip-range6'))
            network = ipaddress.ip_network('198.18.0.0/16' if qtype == 1 else 'fdfe:dcba:9876:1::/64')
            valid = result['rcode'] == 0 and (bool(answers) if enabled else not answers) and all(ipaddress.ip_address(x) in network for x in answers)
            row.update(observation=result, result='PASS_DNS_EXPECTATION' if valid else 'FAIL_FUNCTIONAL')
        except Exception as error:
            row.update(result='FAIL_FUNCTIONAL', error=type(error).__name__ + ': ' + str(error))
        return row

    def real_dns_case(self, cls, qtype):
        name = self.name(cls, 'real-' + str(qtype))
        row = {'id': self.profile_id + '-' + self.mode + '-real-' + cls + '-' + str(qtype), 'kind': 'real_dns', 'name': name}
        try:
            value = controller(self.root, '/dns/query?' + urllib.parse.urlencode({'name': name, 'type': 'A' if qtype == 1 else 'AAAA'}))
            expected = [] if cls == 'nx' or (cls == 'aonly' and qtype == 28) or (cls == 'aaaaonly' and qtype == 1) else [self.f['data4' if qtype == 1 else 'data6']]
            actual = [x['data'] for x in value.get('Answer', []) if x['type'] == qtype]
            valid = value.get('Status') == (3 if cls == 'nx' else 0) and actual == expected
            row.update(observation=value, result='PASS_DNS_EXPECTATION' if valid else 'FAIL_FUNCTIONAL')
        except Exception as error:
            row.update(result='FAIL_FUNCTIONAL', error=type(error).__name__ + ': ' + str(error))
        return row

    def matrix(self):
        spec = json.loads((self.root / 'matrix.json').read_text())
        with ThreadPoolExecutor(max_workers=4) as pool:
            tasks = [pool.submit(self.application_pair, i, target, protocol)
                     for i, target in enumerate(spec['application_axes']['targets'])
                     for protocol in spec['application_axes']['protocols']]
            for task in tasks:
                self.rows.extend(task.result())
            tasks = [pool.submit(self.dns_case, *args) for args in itertools.product(CLASSES, (1, 28), ('udp', 'tcp'), ('local', 'capture4', 'capture6'))]
            self.rows.extend(t.result() for t in tasks)
            tasks = [pool.submit(self.real_dns_case, *args) for args in itertools.product(CLASSES, (1, 28))]
            self.rows.extend(t.result() for t in tasks)
        assert len(self.rows) == 130
        state = control(self.f)
        (self.root / 'host-events.json').write_text(json.dumps(state))
        questions = {(e['name'], e['qtype']) for e in state['events'] if e['event'] == 'dns'}
        for row in self.rows:
            if row['kind'] == 'real_dns' and row['result'] == 'PASS_DNS_EXPECTATION':
                qtype = 1 if row['id'].endswith('-1') else 28
                if (row['name'], qtype) not in questions:
                    row.update(result='FAIL_FUNCTIONAL', error='Real resolver response not observed at local DoH service')

    def finish(self):
        packet_counts = {}
        if self.captures:
            time.sleep(.3)
        for nic, process, err, path in self.captures:
            stop(process, signal.SIGINT)
            err.close()
            for family in (4, 6):
                bpf = ('ip6' if family == 6 else 'ip') + ' and dst host ' + self.f['data' + str(family)] + ' and (tcp or udp)'
                result = command(['/usr/sbin/tcpdump', '-nn', '-r', str(path), bpf])
                packet_counts[nic + '_all_data' + str(family)] = len(result['stdout'].splitlines()) if result['status'] == 0 else None
                ports = ' or '.join('dst port ' + str(p) for p in (self.f['http_port'], self.f['https_port'], self.f['udp_port'], 53))
                result = command(['/usr/sbin/tcpdump', '-nn', '-r', str(path), bpf + ' and (' + ports + ')'])
                packet_counts[nic + '_data' + str(family)] = len(result['stdout'].splitlines()) if result['status'] == 0 else None
            fake_bpf = '(dst net 198.18.0.0/16 or dst net fdfe:dcba:9876:1::/64)'
            raw = command(['/usr/sbin/tcpdump', '-nn', '-r', str(path), fake_bpf])
            packet_counts[nic + '_all_fake'] = len(raw['stdout'].splitlines()) if raw['status'] == 0 else None
            test_ports = ' or '.join('dst port ' + str(p) for p in (self.f['http_port'], self.f['https_port'], self.f['udp_port'], 53))
            raw = command(['/usr/sbin/tcpdump', '-nn', '-tt', '-r', str(path), fake_bpf + ' and (' + test_ports + ')'])
            packet_counts[nic + '_fake'] = len(raw['stdout'].splitlines()) if raw['status'] == 0 else None
            if self.report.get('active_capture_ended_at'):
                cutoff = self.report['active_capture_ended_at']
                timestamps = [float(line.split()[0]) for line in raw['stdout'].splitlines()] if raw['status'] == 0 else []
                packet_counts[nic + '_fake_while_active'] = sum(t < cutoff for t in timestamps) if raw['status'] == 0 else None
                packet_counts[nic + '_fake_after_stop_began'] = sum(t >= cutoff for t in timestamps) if raw['status'] == 0 else None
            if self.scope.startswith('focus'):
                bootstrap = command(['/usr/sbin/tcpdump', '-nn', '-r', str(path), 'dst host 1.1.1.1 and (tcp or udp)'])
                packet_counts[nic + '_bootstrap'] = len(bootstrap['stdout'].splitlines()) if bootstrap['status'] == 0 else None
                nat = command(['/usr/sbin/tcpdump', '-nn', '-r', str(path), '(dst net 64:ff9b::/96 or dst net 64:ff9b:1::/48) and (tcp or udp)'])
                packet_counts[nic + '_nat64'] = len(nat['stdout'].splitlines()) if nat['status'] == 0 else None
                for group, targets in [('blocked', self.report.get('blocked_ping_targets', [])), ('native', self.report.get('native_ping_targets', []))]:
                    for i, target in enumerate(targets):
                        for direction in ('request', 'reply'):
                            kind = ('icmp6 and ip6[40] == ' + ('128' if direction == 'request' else '129')) if ':' in target else ('icmp and icmp[0] == ' + ('8' if direction == 'request' else '0'))
                            ipfilter = ('dst' if direction == 'request' else 'src') + ' host ' + target
                            value = command(['/usr/sbin/tcpdump', '-nn', '-r', str(path), ipfilter + ' and ' + kind])
                            packet_counts[nic + '_' + group + '_' + str(i) + '_' + direction] = len(value['stdout'].splitlines()) if value['status'] == 0 else None
        self.report['packets'] = packet_counts
        if self.captures:
            self.checks['no_native_data_egress'] = packet_counts.get('en0_data4') == 0 and packet_counts.get('en0_data6') == 0
            if self.report.get('active_capture_ended_at'):
                self.checks['no_native_fake_egress_while_active'] = packet_counts.get('en0_fake_while_active') == 0
                self.report['shutdown_boundary'] = {
                    'native_fake_packets_after_stop_began': packet_counts.get('en0_fake_after_stop_began'),
                    'limitation': 'Standalone shutdown ends route enforcement; queued OS DNS may use the former TUN DNS endpoint over the native route before resolver removal propagates.'}
            else:
                self.checks['no_native_fake_egress'] = packet_counts.get('en0_fake') == 0
            self.checks['both_data_families_entered_tun'] = (packet_counts.get(TUN + '_data4') or 0) > 0 and (packet_counts.get(TUN + '_data6') or 0) > 0
            if self.scope.startswith('focus'):
                self.checks['no_native_nat64_egress'] = packet_counts.get('en0_nat64') == 0
                self.checks['no_native_bootstrap_egress'] = packet_counts.get('en0_bootstrap') == 0
                blocked = self.report.get('blocked_ping_targets', [])
                native = self.report.get('native_ping_targets', [])
                if blocked:
                    self.checks['captured_echo_requests_seen'] = all(packet_counts.get(TUN + '_blocked_' + str(i) + '_request') == 2 for i in range(len(blocked)))
                    self.checks['no_synthetic_echo_replies'] = all(packet_counts.get(TUN + '_blocked_' + str(i) + '_reply') == 0 for i in range(len(blocked)))
                    self.checks['no_native_echo_forwarding'] = all(packet_counts.get(nic + '_blocked_' + str(i) + '_request') == 0 for nic, _, _, _ in self.captures if nic != TUN for i in range(len(blocked)))
                if native:
                    self.checks['native_echoes_bypass_tun'] = all(packet_counts.get(TUN + '_native_' + str(i) + '_' + d) == 0 for i in range(len(native)) for d in ('request', 'reply'))
                    self.checks['native_echoes_real'] = all(any((packet_counts.get(nic + '_native_' + str(i) + '_request') or 0) > 0 and (packet_counts.get(nic + '_native_' + str(i) + '_reply') or 0) > 0 for nic, _, _, _ in self.captures if nic != TUN) for i in range(len(native)))
            for row in self.rows:
                if row['result'] == 'PASS_EXPECTED_DENIAL_PENDING_CAPTURE':
                    row['result'] = 'PASS_EXPECTED_DENIAL_NO_EGRESS' if self.checks['no_native_data_egress'] and self.checks['no_native_fake_egress'] else 'FAIL_LEAK'
        self.stop_dns_owner()
        delete_routes(self.f, self.owned_routes)
        stop(self.engine)
        (self.root / 'guard-stop').touch()
        stop(self.guard)
        if self.native_dns_fixture:
            self.native_dns_fixture.close()
        self.checks['tailscale_restored'] = restore_tailnet(self.root)
        if self.log:
            self.log.close()
        time.sleep(.3)
        self.checks['engine_stopped'] = self.engine is None or self.engine.poll() is not None
        self.checks['tun_removed'] = command(['/sbin/ifconfig', TUN])['status'] != 0
        self.checks['routes_restored'] = all(interface(self.f[k]) == v for k, v in self.baseline_routes.items())
        dns_deadline = time.monotonic() + 5
        while time.monotonic() < dns_deadline and dns_state() != self.baseline_dns:
            time.sleep(.2)
        self.checks['dns_restored'] = dns_state() == self.baseline_dns
        for family in (4, 6):
            target = self.f['data' + str(family)]
            for protocol in ('https_verified', 'udp_nonce'):
                value = self.service(target, target, protocol, 'native-after-' + str(family) + '-' + protocol)
                self.checks['native_after_' + str(family) + '_' + protocol] = value['ok'] and value.get('upstream_family') == family
        counts = {}
        for row in self.rows:
            counts[row['result']] = counts.get(row['result'], 0) + 1
        self.report['counts'] = counts
        self.report['passed'] = not self.report.get('error') and all(self.checks.values()) and not any(k.startswith('FAIL') for k in counts)
        self.report['status'] = 'complete' if len(self.rows) == 130 or (self.scope.startswith('focus') and not self.report.get('error')) else 'incomplete'
        (self.root / 'report.json').write_text(json.dumps(self.report, indent=2))

    def run(self):
        blocker = None
        blocker_ready = False
        try:
            if self.scope == 'focus-occupied':
                blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                blocker.bind(('127.0.0.1', 7890))
                blocker.listen(1)
                blocker_ready = True
            self.preflight()
            if self.scope == 'focus-native-dns':
                from native_dns_fixture import Client
                status = command([TAILSCALE, 'status', '--json'], 8)
                state = json.loads(status['stdout'])
                assert state['BackendState'] == 'Running'
                own = state['Self']['DNSName'].rstrip('.')
                suffix = own.partition('.')[2]
                peers = [p for p in state.get('Peer', {}).values() if p.get('DNSName', '').rstrip('.').endswith('.' + suffix) and p.get('Online')]
                selected = sorted(peers, key=lambda p: p['DNSName'])[0] if peers else state['Self']
                self.f['native_dns_peer'] = {'name': selected['DNSName'], 'self_control': not bool(peers)}
                (self.root / 'fixture.json').write_text(json.dumps(self.f))
                self.report['native_dns_peer_is_self'] = not bool(peers)
                self.native_dns_fixture = Client(self.root)
                time.sleep(.5); self.flush_system_dns()
                search = list(dict.fromkeys(re.findall(r'search domain\[\d+\]\s*:\s*(\S+)', dns_state())))
                peer = self.f['native_dns_peer']['name'].rstrip('.')
                self.native_dns_baseline = {'search': search, 'peer_addresses': self.system_lookup(peer)}
                short_answers = self.system_lookup(peer.split('.')[0])
                (self.root / 'native-baseline-debug.json').write_text(json.dumps({'search': search, 'peer': peer,
                    'fqdn_answers': self.native_dns_baseline['peer_addresses'], 'short_answers': short_answers,
                    'dns_state': dns_state()}))
                assert 'mimo-native.test' in search and self.native_dns_baseline['peer_addresses'], 'Native DNS fixture baseline unavailable'
                assert self.system_lookup('lanbaseline' + self.tag) == [self.f['bridge4']], 'Native LAN short-name fixture invalid'
                assert short_answers == self.native_dns_baseline['peer_addresses'], 'Native Tailnet short-name baseline invalid'
            self.start()
            if self.scope == 'focus-extra':
                self.focused_extra()
            elif self.scope in ('focus-system', 'focus-native-dns', 'focus-udp-disabled', 'focus-native-transport'):
                # Capture controls are infrastructure assertions, not extra cases.
                for family in (4, 6):
                    target = self.f['data' + str(family)]
                    result = self.service(target, target, 'http', 'system-capture-control-' + str(family))
                    self.checks['system_capture_control_' + str(family)] = self.literal_result_matches(result, family)
                if self.scope == 'focus-system':
                    self.diagnostic_variant()
                elif self.scope == 'focus-native-dns':
                    self.native_dns_cases()
                elif self.scope == 'focus-native-transport':
                    self.native_transport_cases()
                else:
                    self.udp_disabled_cases()
            elif self.scope.startswith('focus'):
                self.focused()
            elif self.scope == 'watchdog':
                # Deliberately lose the parent without finally; the independent guard owns recovery.
                self.report['status'] = 'watchdog_armed'
                (self.root / 'report.json').write_text(json.dumps(self.report))
                os._exit(99)
            else:
                self.matrix()
        except Exception as error:
            expected_refusal = ((self.scope == 'focus-invalid-engine' and isinstance(error, AssertionError) and str(error) == 'Test engine checksum mismatch')
                                or (self.scope == 'focus-occupied' and blocker_ready and isinstance(error, OSError) and error.errno == errno.EADDRINUSE))
            if expected_refusal:
                self.focus_row('F14-' + self.scope, True, refusal=type(error).__name__ + ': ' + str(error), engine_started=False)
            else:
                self.report['error'] = type(error).__name__ + ': ' + str(error)
        finally:
            if blocker:
                blocker.close()
            self.finish()
        print(json.dumps({'profile': self.profile_id, 'proxy': self.mode, 'passed': self.report['passed'],
                          'counts': self.report['counts'], 'failed_checks': [k for k, v in self.checks.items() if not v],
                          'error': self.report.get('error')}), flush=True)
        return 0 if self.report['passed'] else 1


if __name__ == '__main__':
    os.umask(0o077)
    if sys.argv[1] == '--watchdog':
        watchdog(Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
    else:
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: (_ for _ in ()).throw(InterruptedError('Test interrupted')))
        sys.exit(Cell(Path(sys.argv[1]), *sys.argv[2:5]).run())
