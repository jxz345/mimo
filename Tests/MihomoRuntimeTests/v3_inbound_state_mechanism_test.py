#!/usr/bin/env python3
"""Six isolated PF mechanism checks. Never modifies Mimo's production anchor.

Host: --output NEW_DIRECTORY --expected-uuid UUID [--policy-fixture JSON] --start
Guest modes are internal. Root's Tart administrator transport is mandatory.
This tests real PF with fixture tuples while Mimo stays Direct; it is not an
installed lifecycle, SSH, Screen Sharing, IPv6 or UDP qualification.
"""
import argparse
import base64
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
import uuid

ANCHOR = 'com.apple/001.mimo-inbound-test'
CORE = '4263cf39e9779b03d00bc73b40fd523e4ba8e42012ec2aa84f824ba5dd48e067'
VM = 'mimo-test-macos'
GUEST = '192.168.64.2'
HOST = '192.168.64.1'
RUNTIME = Path('/Library/Application Support/Mimo/Runtime')
MAXIMUM = 180


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    os.chmod(temp, 0o600)
    temp.replace(path)


def command(args, timeout=4, input_text=None):
    p = subprocess.run(args, input=input_text, capture_output=True, text=True,
                       timeout=timeout)
    return {'args': args, 'status': p.returncode, 'stdout': p.stdout,
            'stderr': p.stderr, 'epoch': time.time()}


def line(sock, timeout=2):
    sock.settimeout(timeout)
    result = bytearray()
    try:
        while len(result) < 4096:
            b = sock.recv(1)
            if not b:
                return {'received': False, 'closed': True, 'epoch': time.time()}
            result.extend(b)
            if b == b'\n':
                return {'received': True, 'value': json.loads(result), 'epoch': time.time()}
        raise RuntimeError('Oversized fixture message')
    except socket.timeout:
        return {'received': False, 'timeout': True, 'epoch': time.time()}


def send(sock, value):
    sock.sendall((json.dumps(value) + '\n').encode())


class NCClient:
    """Native nc transport; Python only reserves a source port and handles pipes.

    Host Python connect is unavailable in this environment. This does not
    change network permissions or the fixture tuple/bounds.
    """
    def __init__(self, output):
        self.output = output
        self.address = None
        self.peer = None
        self.timeout = 3
        self.process = None
        self.log = None

    def settimeout(self, value):
        self.timeout = value

    def bind(self, address):
        assert address[0] == HOST and address[1] == 0
        reservation = socket.socket()
        reservation.bind(address)
        self.address = reservation.getsockname()
        reservation.close()

    def getsockname(self):
        return self.address

    def connect(self, address):
        assert self.address and address[0] == GUEST and self.process is None
        self.peer = address
        self.log = (self.output / ('nc-' + str(self.address[1]) + '.log')).open('x')
        args = ['/usr/bin/nc', '-s', HOST, '-p', str(self.address[1]), '-G', '3',
                address[0], str(address[1])]
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, bufsize=0)
        save(self.output / ('nc-' + str(self.address[1]) + '-owner.json'),
             {'pid': self.process.pid, 'args': args, 'started_epoch': time.time(),
              'requested_source': self.address, 'destination': address})

    def recv(self, size):
        assert self.process is not None
        ready, _, _ = select.select([self.process.stdout], [], [], self.timeout)
        if not ready:
            raise socket.timeout()
        return os.read(self.process.stdout.fileno(), size)

    def sendall(self, data):
        assert len(data) <= 4096 and self.process is not None
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def close(self):
        if self.process is None:
            return
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(1)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(2)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(2)
        self.process.stdout.close()
        self.log.close()
        save(self.output / ('nc-' + str(self.address[1]) + '-joined.json'),
             {'pid': self.process.pid, 'joined': True, 'exit_code': self.process.returncode,
              'finished_epoch': time.time()})


class Echo:
    def __init__(self, address):
        self.socket = socket.socket()
        self.socket.bind((address, 0))
        self.socket.listen(8)
        self.socket.settimeout(.2)
        self.address = self.socket.getsockname()
        self.connections = []
        self.events = []
        self.done = threading.Event()
        self.threads = []
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.done.is_set():
            try:
                c, peer = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.connections.append(c)
            self.events.append({'event': 'accepted', 'peer': peer,
                                'local': c.getsockname(), 'epoch': time.time()})
            t = threading.Thread(target=self.handle, args=(c,), daemon=True)
            self.threads.append(t)
            t.start()

    def handle(self, c):
        try:
            send(c, {'ready': True, 'server_epoch': time.time()})
            while not self.done.is_set():
                v = line(c, .3)
                if v.get('closed'):
                    break
                if not v['received']:
                    continue
                self.events.append({'event': 'received', 'value': v['value'],
                                    'epoch': time.time(), 'peer': c.getpeername()})
                response = {'echo': v['value'], 'server_epoch': time.time()}
                self.events.append({'event': 'generated', 'value': response,
                                    'epoch': time.time(), 'peer': c.getpeername()})
                send(c, response)
        except (OSError, ValueError):
            pass
        finally:
            c.close()

    def stop(self):
        self.done.set()
        self.socket.close()
        for c in self.connections:
            try:
                c.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            c.close()
        self.thread.join(2)
        for t in self.threads:
            t.join(2)
        return not self.thread.is_alive() and all(not t.is_alive() for t in self.threads)


def current_rules():
    return command(['/sbin/pfctl', '-a', ANCHOR, '-sr'])


def identity(expected_uuid):
    core = Path('/Library/PrivilegedHelperTools/mimo-core')
    hardware = command(['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice'])
    found = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', hardware['stdout'])
    assert found and found.group(1).upper() == expected_uuid.upper(), 'VM UUID mismatch'
    target_path = Path(__file__).with_name('target.json')
    target = json.loads(target_path.read_text()) if target_path.exists() else {'core_sha256':CORE,'production_rules':''}
    assert core.exists() and digest(core.read_bytes()) == target['core_sha256'], 'Core identity mismatch'
    assert (RUNTIME / 'gate.state').read_text().strip() == 'direct', 'Mimo is not Direct'
    production = command(['/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr'])
    assert production['status'] == 0 and production['stdout'] == target['production_rules'], 'Mimo production policy changed'
    route = command(['/sbin/route', '-n', 'get', HOST])
    assert route['status'] == 0 and 'interface: en0' in route['stdout'], 'Unexpected fixture route'
    interface = command(['/sbin/ifconfig', 'en0'])
    assert 'inet ' + GUEST + ' ' in interface['stdout'], 'Guest IPv4 mismatch'
    return {'uuid': found.group(1), 'core_sha256': target['core_sha256'], 'gate': 'direct',
            'production_rules': production, 'route': route,
            'hostname': socket.gethostname(), 'epoch': time.time()}


def safe_root(value):
    p = Path(value)
    assert re.fullmatch(r'/var/tmp/mimo-inbound-mechanism-[0-9a-f]{32}', str(p))
    assert p.is_dir() and p.stat().st_uid == 0 and p.stat().st_mode & 0o077 == 0
    return p


def owned_clear(root):
    """Clear only an empty or exact journaled test policy, never unknown rules."""
    live = current_rules()
    assert live['status'] == 0, 'Cannot inspect fixture anchor'
    journal = json.loads((root / 'policies.json').read_text())
    assert digest(live['stdout'].encode()) in journal, 'Fixture anchor ownership changed'
    r = command(['/sbin/pfctl', '-a', ANCHOR, '-f', '-'], input_text='')
    assert r['status'] == 0 and not current_rules()['stdout'].strip(), 'Fixture release failed'
    return {'anchor_empty': True, 'epoch': time.time()}


def watchdog(root):
    root = safe_root(root)
    m = json.loads((root / 'manifest.json').read_text())
    deadline = m['started_epoch'] + MAXIMUM
    while time.time() < deadline and not (root / 'cleanup-complete.json').exists():
        time.sleep(.2)
    if (root / 'cleanup-complete.json').exists():
        return
    outcome = {'watchdog': True, 'epoch': time.time()}
    try:
        outcome.update(owned_clear(root))
    except Exception as e:
        outcome['cleanup_error'] = type(e).__name__
    # Signal only the recorded process that still owns this exact command/root.
    for pid, marker in [(m['pid'], 'serve')] + [(v['pid'], 'tcpdump') for v in m.get('captures', [])]:
        p = command(['/bin/ps', '-ww', '-p', str(pid), '-o', 'command='])
        if p['status'] == 0 and str(root) in p['stdout'] and marker in p['stdout']:
            try:
                os.kill(pid, signal.SIGTERM if marker == 'serve' else signal.SIGINT)
            except ProcessLookupError:
                pass
    save(root / 'watchdog-result.json', outcome)


def serve(root, expected_uuid, host_port):
    root = safe_root(root)
    os.umask(0o077)
    initial = identity(expected_uuid)
    root_rules = command(['/sbin/pfctl', '-sr'])
    assert root_rules['status'] == 0 and 'anchor "com.apple/*"' in root_rules['stdout']
    live = current_rules()
    # A never-created anchor can report EINVAL. Do not accept any preexisting rules.
    assert not live['stdout'].strip(), 'Fixture anchor already occupied'
    check = command(['/sbin/pfctl', '-n', '-a', ANCHOR, '-f', '-'], input_text='')
    assert check['status'] == 0
    load = command(['/sbin/pfctl', '-a', ANCHOR, '-f', '-'], input_text='')
    assert load['status'] == 0
    save(root / 'policies.json', [digest(current_rules()['stdout'].encode())])
    data, loop = Echo(GUEST), Echo('127.0.0.1')
    captures = []
    clients = {}
    tracked_tuples = set()
    w = None
    nonce = uuid.uuid4().hex
    fixture_ports = [data.address[1], loop.address[1], host_port]
    manifest = {'pid': os.getpid(), 'started_epoch': time.time(), 'uuid': expected_uuid,
                'anchor': ANCHOR, 'root': str(root), 'source_sha256': digest(Path(__file__).read_bytes()),
                'data_port': data.address[1], 'loop_port': loop.address[1], 'host_port': host_port,
                'nonce': nonce, 'initial': initial, 'root_rules': root_rules, 'captures': []}

    def snapshot():
        root_now = command(['/sbin/pfctl', '-sr'])
        assert root_now['status'] == 0 and root_now['stdout'] == root_rules['stdout'], 'Root rules changed'
        return {'epoch': time.time(), 'identity': identity(expected_uuid), 'root_rules': root_now,
                'rules': current_rules(), 'states': command(['/sbin/pfctl', '-ss', '-vv']),
                'data_events': list(data.events), 'loop_events': list(loop.events)}

    def apply(rules):
        identity(expected_uuid)
        assert isinstance(rules, str) and len(rules) < 4096
        assert all('mimo:test:incoming:' in x for x in rules.splitlines() if x.strip())
        # Only generated fixture policies are accepted by this private controller.
        assert not any(x in rules for x in ['anchor ', 'include ', 'table ', 'nat ', 'rdr ', 'route-to', 'reply-to'])
        assert all(x.startswith(('pass in ', 'block drop out ')) for x in rules.splitlines() if x.strip())
        for rule in rules.splitlines():
            match = re.search(r'from ([0-9.]+) port ([0-9]+) to ([0-9.]+) port ([0-9]+)', rule)
            assert match, 'All fixture rules need exact addresses and ports'
            src, sport, dst, dport = match.groups()
            assert src in (HOST, GUEST, '127.0.0.1') and dst in (HOST, GUEST, '127.0.0.1')
            assert 1 <= int(sport) <= 65535 and 1 <= int(dport) <= 65535
            assert int(sport) in fixture_ports or int(dport) in fixture_ports
            if 'keep state' in rule:
                tracked_tuples.add((src, int(sport), dst, int(dport)))
        old = current_rules()
        journal = json.loads((root / 'policies.json').read_text())
        assert old['status'] == 0 and digest(old['stdout'].encode()) in journal
        parsed = command(['/sbin/pfctl', '-n', '-a', ANCHOR, '-f', '-'], input_text=rules)
        assert parsed['status'] == 0, 'Fixture PF syntax rejected'
        # Record normalized readback immediately after this bounded owned mutation.
        loaded = command(['/sbin/pfctl', '-a', ANCHOR, '-f', '-'], input_text=rules)
        assert loaded['status'] == 0
        observed = current_rules()
        assert observed['status'] == 0
        journal.append(digest(observed['stdout'].encode()))
        save(root / 'policies.json', journal)
        return {'loaded': loaded, 'readback': observed}

    def handle(value):
        action = value['action']
        if action == 'snapshot':
            return snapshot()
        if action == 'apply':
            return apply(value['rules'])
        if action == 'preflight_outbound':
            c = socket.socket(); c.settimeout(3); c.bind((GUEST, 0))
            try:
                c.connect((HOST, host_port))
                return {'local': c.getsockname(), 'peer': c.getpeername(), 'ready': line(c)}
            finally:
                c.close()
        if action == 'connect':
            which = value['which']
            assert which in ('outbound', 'loop') and which not in clients
            c = socket.socket()
            c.settimeout(3)
            c.bind((GUEST if which == 'outbound' else '127.0.0.1', value.get('source_port', 0)))
            c.connect((HOST, host_port) if which == 'outbound' else loop.address)
            clients[which] = c
            return {'local': c.getsockname(), 'peer': c.getpeername(), 'ready': line(c)}
        if action == 'reserve_loop':
            c = socket.socket(); c.bind(('127.0.0.1', 0))
            port = c.getsockname()[1]; c.close()
            return {'port': port}
        if action == 'send':
            send(clients[value['which']], value['value'])
            return {'sent_to_socket': True, 'epoch': time.time()}
        if action == 'receive':
            return line(clients[value['which']], min(float(value.get('timeout', 2)), 3))
        if action == 'stop':
            return {'stopping': True}
        raise ValueError('Unknown action')

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            if self.path != '/control' or self.headers.get('Authorization') != 'Bearer ' + nonce:
                self.send_error(403); return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                assert 0 < length <= 8192
                value = json.loads(self.rfile.read(length))
                result = handle(value)
                payload = json.dumps({'ok': True, 'result': result}).encode()
                status = 200
            except Exception as e:
                payload = json.dumps({'ok': False, 'error': type(e).__name__, 'reason': str(e)[:200]}).encode()
                status = 500
            self.send_response(status); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)
            if status == 200 and value['action'] == 'stop':
                threading.Thread(target=server.shutdown, daemon=True).start()

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    server.timeout = 2
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    manifest['control_port'] = server.server_port
    try:
        for interface in ('en0', 'lo0'):
            logfile = root / (interface + '-tcpdump.log')
            pcap = root / (interface + '.pcap')
            f = logfile.open('x')
            args = ['/usr/sbin/tcpdump', '-U', '-n', '-s', '0', '-i', interface,
                    '-w', str(pcap), 'tcp and (' + ' or '.join('port ' + str(p) for p in fixture_ports) + ')']
            p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT)
            captures.append((p, f))
            time.sleep(.15)
            manifest['captures'].append({'pid': p.pid, 'args': args, 'running': p.poll() is None})
        save(root / 'manifest.json', manifest)
        w = subprocess.Popen(['/usr/bin/python3', __file__, 'watchdog', str(root)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        save(root / 'watchdog.json', {'pid': w.pid, 'deadline_epoch': manifest['started_epoch'] + MAXIMUM})
        server.serve_forever(poll_interval=.1)
    finally:
        outcome = {'epoch': time.time(), 'failures': []}
        try:
            outcome.update(owned_clear(root))
        except Exception as e:
            outcome['failures'].append(type(e).__name__ + ': ' + str(e))
        for c in clients.values():
            try:
                c.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            c.close()
        data_joined = data.stop()
        loop_joined = loop.stop()
        outcome['echo_threads_joined'] = data_joined and loop_joined
        outcome['tracked_tuples'] = [list(x) for x in sorted(tracked_tuples)]
        outcome['state_expiry_samples'] = []
        expiry_deadline = time.monotonic() + 16
        while True:
            states = command(['/sbin/pfctl', '-ss', '-vv'])
            remaining = []
            if states['status'] != 0:
                outcome['failures'].append('Cannot inspect owned state expiry')
                break
            for row in states['stdout'].splitlines():
                if ' tcp ' not in ' ' + row + ' ': continue
                for src, sport, dst, dport in tracked_tuples:
                    patterns = [re.compile(re.escape(address) + ':' + str(port) + r'(?:\s|$)')
                                for address, port in ((src, sport), (dst, dport))]
                    if all(pattern.search(row) for pattern in patterns): remaining.append(row)
            outcome['state_expiry_samples'].append({'epoch': time.time(), 'remaining_owned_states': remaining})
            if not remaining:
                outcome['owned_states_expired'] = True
                break
            if time.monotonic() >= expiry_deadline:
                outcome['owned_states_expired'] = False
                outcome['failures'].append('Owned state aging remains unqualified at bounded deadline')
                break
            time.sleep(.5)
        try:
            outcome['final_identity'] = identity(expected_uuid)
            final_root = command(['/sbin/pfctl', '-sr'])
            outcome['root_rules_unchanged'] = final_root['status'] == 0 and final_root['stdout'] == root_rules['stdout']
            outcome['production_rules_unchanged'] = outcome['final_identity']['production_rules']['stdout'] == initial['production_rules']['stdout']
            assert outcome['root_rules_unchanged'] and outcome['production_rules_unchanged']
        except Exception as error:
            outcome['failures'].append('Final identity/rules: ' + type(error).__name__)
        for p, f in captures:
            if p.poll() is None:
                p.send_signal(signal.SIGINT)
                try:
                    p.wait(3)
                except subprocess.TimeoutExpired:
                    p.terminate(); p.wait(3)
            f.close()
        outcome['captures_joined'] = all(p.poll() is not None for p, _ in captures)
        save(root / 'endpoint-events.json', {'data': data.events, 'loop': loop.events})
        save(root / 'cleanup-complete.json', {'epoch': time.time()})
        if w is not None:
            try:
                w.wait(3)
                outcome['watchdog_joined'] = w.returncode == 0
            except subprocess.TimeoutExpired:
                outcome['watchdog_joined'] = False
                outcome['failures'].append('Watchdog did not join')
        else:
            outcome['watchdog_joined'] = False
        save(root / 'finished.json', outcome)
        server.server_close()


def guest_rpc(root, encoded):
    root = safe_root(root)
    m = json.loads((root / 'manifest.json').read_text())
    payload = base64.b64decode(encoded, validate=True)
    assert len(payload) <= 8192
    request = urllib.request.Request('http://127.0.0.1:' + str(m['control_port']) + '/control',
                                     data=payload, headers={'Authorization': 'Bearer ' + m['nonce']}, method='POST')
    with urllib.request.urlopen(request, timeout=15) as response:
        print(response.read(2_000_000).decode())


def state_lines(snapshot, a_port, b_port, loop=False):
    result = snapshot['states']
    assert result['status'] == 0
    # The unabridged state table remains in every snapshot. Both ports must
    # occur as full numeric socket-port tokens on the same TCP state line.
    pairs = [(('127.0.0.1', a_port), ('127.0.0.1', b_port))] if loop else [
        ((HOST, a_port), (GUEST, b_port)), ((GUEST, a_port), (HOST, b_port))]
    patterns = [[re.compile(re.escape(address) + ':' + str(port) + r'(?:\s|$)')
                 for address, port in pair] for pair in pairs]
    return [row for row in result['stdout'].splitlines() if ' tcp ' in ' ' + row + ' '
            and any(all(pattern.search(row) for pattern in pair) for pair in patterns)]


def host(output, expected_uuid, policy_fixture=None, policy_exporter=None, expected_core=CORE, production_policy_fixture=None):
    output = Path(output).resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.umask(0o077)
    repo = Path(__file__).resolve().parents[2]
    admin_path = repo / '.build/observation-parallel/vm-admin.py'
    assert admin_path.is_file()
    root = '/var/tmp/mimo-inbound-mechanism-' + uuid.uuid4().hex
    source = Path(__file__).read_bytes()
    policies = json.loads(Path(policy_fixture).read_text()) if policy_fixture else None
    def validate_policies():
        assert policies is not None
        assert policies['schema'] == 2 and policies['fully_released'] == ''
        assert policies['direct_readback_accepted'] is True
        assert policies['direct_tracking'] == policies['inbound_tcp'] + '\n' + policies['inbound_loopback'] + '\n'
        assert policies['local_destinations'] == policies['parsed_destinations']
        assert GUEST in policies['local_destinations'], 'Policy export must run on the target VM'
        assert policies['policy_source_sha256'] == digest((repo / 'Sources/MimoShared/MimoFirewallPolicy.swift').read_bytes())
        save(output / 'generated-production-policies.json', policies)
    if policies is not None:
        validate_policies()
    assert re.fullmatch('[0-9a-f]{64}', expected_core)
    production_rules = json.loads(Path(production_policy_fixture).read_text())['direct_tracking'] if production_policy_fixture else ''
    target = {'core_sha256':expected_core,'production_rules':production_rules}
    host_server = Echo(HOST)
    deadline = time.monotonic() + 170
    calls = 0
    rows = []
    clients = []
    guest_started = False
    pending_cleanup_case = None

    def admin(code):
        nonlocal calls
        calls += 1
        left = deadline - time.monotonic()
        assert left > 0, 'Host mechanism deadline expired'
        p = subprocess.run([sys.executable, str(admin_path), '--vm', VM, '/usr/bin/python3', '-c', code],
                           capture_output=True, text=True, timeout=min(30, left))
        (output / ('admin-' + str(calls).zfill(3) + '.log')).write_text(p.stdout + p.stderr)
        assert p.returncode == 0, 'Guest support call failed'
        return json.loads(p.stdout)

    def rpc(action, **kw):
        payload = base64.b64encode(json.dumps(dict(action=action, **kw)).encode()).decode()
        result = admin('import runpy,sys;sys.argv=[' + repr(root + '/harness.py') + ',"rpc",' + repr(root) + ',' + repr(payload) + '];runpy.run_path(sys.argv[0],run_name="__main__")')
        assert result['ok'], result
        return result['result']

    def apply(rules):
        return rpc('apply', rules=rules)

    def tracking(cp, gp, interface='en0', loop_override=False):
        peer, local = (HOST, GUEST) if interface == 'en0' else ('127.0.0.1', '127.0.0.1')
        if policies:
            matching = [line for line in policies['inbound_tcp'].splitlines()
                        if ' inet proto tcp from any to ' + local + ' flags ' in line]
            assert len(matching) == 1, 'Actual production destination missing or duplicated'
            original = matching[0]
            assert 'on ! utun239 inet proto tcp from any to ' + local in original
            assert 'keep state (if-bound)' in original and ' quick ' not in original
            # Preserve the actual exported destination. Only source/ports and
            # ingress interface narrow the fixture; never replace a dynamic or
            # unknown production destination with a known-good literal.
            r = original.replace('on ! utun239 ', 'on ' + interface + ' ')
            r = r.replace('from any to ' + local + ' flags ',
                'from ' + peer + ' port ' + str(cp) + ' to ' + local + ' port ' + str(gp) + ' flags ')
            r = r.replace('keep state (if-bound)', 'keep state (if-bound, tcp.closed 1, tcp.finwait 1, tcp.closing 1)')
            r = r.replace('"mimo:inbound:tcp"', '"mimo:test:incoming:syn"') + '\n'
        else:
            r = ('pass in on ' + interface + ' inet proto tcp from ' + peer + ' port ' + str(cp) +
                 ' to ' + local + ' port ' + str(gp) + ' flags S/SA keep state (if-bound, tcp.closed 1, tcp.finwait 1, tcp.closing 1) label "mimo:test:incoming:syn"\n')
        if loop_override:
            if policies:
                original = policies['inbound_loopback']
                assert original == 'pass in on lo0 all no state label "mimo:inbound:loopback"'
                r += original.replace('all no state', 'inet proto tcp from 127.0.0.1 port ' + str(cp) + ' to 127.0.0.1 port ' + str(gp) + ' no state').replace('"mimo:inbound:loopback"', '"mimo:test:incoming:loopback"') + '\n'
            else:
                r += 'pass in on lo0 inet proto tcp from 127.0.0.1 port ' + str(cp) + ' to 127.0.0.1 port ' + str(gp) + ' no state label "mimo:test:incoming:loopback"\n'
        return r

    def deny(sp, dp, loop=False):
        src, dst, interface = ('127.0.0.1', '127.0.0.1', 'lo0') if loop else (GUEST, HOST, 'en0')
        prefix = ('block drop out quick on ' + interface + ' inet proto tcp from ' + src + ' port ' + str(sp) +
                  ' to ' + dst + ' port ' + str(dp))
        if policies:
            original = policies['startup_blocking'].strip().splitlines()[-1]
            assert original == 'block drop out quick all label "mimo:transition:deny"'
            return original.replace('block drop out quick all', prefix).replace('"mimo:transition:deny"', '"mimo:test:incoming:deny"') + '\n'
        return prefix + ' label "mimo:test:incoming:deny"\n'

    def record(row):
        rows.append(row)
        save(output / ('case-' + str(len(rows)) + '.json'), row)
        print(json.dumps({'done': len(rows), 'planned': 6, 'case': row['name'],
                          'mechanism_assertion_passed': row.get('passed'),
                          'observed_reply_while_blocked': row.get('reply_while_blocked')}), flush=True)

    try:
        assert policy_exporter and policies is None, 'Use a production exporter executed on the target VM'
        exporter = Path(policy_exporter).read_bytes(); target['exporter_sha256'] = digest(exporter)
        bundle = output/'staging.tar.gz'
        with tarfile.open(bundle,'w:gz') as archive:
            for name,data in {'harness.py':source,'policy-exporter':exporter,'target.json':json.dumps(target).encode()}.items():
                info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o700 if name=='policy-exporter' else 0o600
                archive.addfile(info,io.BytesIO(data))
        admin('import subprocess,json;hw=subprocess.check_output(["/usr/sbin/ioreg","-rd1","-c","IOPlatformExpertDevice"],text=True);assert '+repr(expected_uuid)+' in hw;print(json.dumps({"expected_vm":True}))')
        transfer='/tmp/mimo-inbound-mechanism-'+uuid.uuid4().hex+'.tar.gz'
        copied=command(['/usr/bin/scp','-q','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes',
            '-o','HostKeyAlias=mimo-test-macos','-o','UserKnownHostsFile='+str(Path.home()/'.ssh/known_hosts_mimo-test-macos'),
            '-i',str(Path.home()/'.ssh/mimo-vm-admin_ed25519'),str(bundle),'mimotest@'+GUEST+':'+transfer],20)
        save(output/'transfer.json',{'status':copied['status'],'target':GUEST,'path':transfer,'sha256':digest(bundle.read_bytes())})
        assert copied['status']==0, 'Pinned fixture transfer failed'
        code='import pathlib,hashlib,tarfile,os,subprocess,json;os.umask(0o077);hw=subprocess.check_output(["/usr/sbin/ioreg","-rd1","-c","IOPlatformExpertDevice"],text=True);assert '+repr(expected_uuid)+' in hw;r=pathlib.Path('+repr(root)+');b=pathlib.Path('+repr(transfer)+');assert not b.is_symlink() and hashlib.sha256(b.read_bytes()).hexdigest()=='+repr(digest(bundle.read_bytes()))+';r.mkdir(mode=0o700);\nwith tarfile.open(b) as t:\n assert set(t.getnames())=={"harness.py","policy-exporter","target.json"}\n for m in t:\n  assert m.isfile();p=r/m.name;p.write_bytes(t.extractfile(m).read());p.chmod(0o700 if m.name=="policy-exporter" else 0o600)\nb.unlink();print(subprocess.check_output([str(r/"policy-exporter")],text=True))'
        policies=admin(code);validate_policies()
        code = ('import pathlib,subprocess,json;r=pathlib.Path(' + repr(root) + ');p=r/"harness.py";f=(r/"server.log").open("x");c=subprocess.Popen(["/usr/bin/python3",str(p),"serve",str(r),' + repr(expected_uuid) + ',' + repr(str(host_server.address[1])) + '],stdin=subprocess.DEVNULL,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);print(json.dumps({"pid":c.pid,"root":str(r)}))')
        launch = admin(code); guest_started = True
        save(output / 'launch.json', dict(launch, source_sha256=digest(source), vm=VM, guest_ip=GUEST,
                                         expected_uuid=expected_uuid, host_port=host_server.address[1]))
        manifest = None
        for _ in range(30):
            try:
                manifest = admin('import json,pathlib;v=json.loads(pathlib.Path(' + repr(root + '/manifest.json') + ').read_text());v.pop("nonce");print(json.dumps(v))')
                break
            except (AssertionError, json.JSONDecodeError):
                time.sleep(.2)
        assert manifest is not None, 'Guest did not become ready'
        assert manifest['source_sha256'] == digest(source)
        save(output / 'manifest.json', manifest)
        gp = manifest['data_port']
        host_preflight = rpc('preflight_outbound')
        save(output / 'host-listener-preflight.json', host_preflight)
        assert host_preflight['ready']['received'] and host_preflight['ready']['value']['ready'], 'Host fixture listener unreachable'
        sequence = ((1, 'before'), (2, 'protected'), (3, 'after')) if policies else ((1, 'none'), (2, 'before'), (3, 'after'))
        for number, timing in sequence:
            row = {'name': (['normal-direct-tracked-continuity', 'protected-born-through-direct', 'pretracking-limit-and-fresh-reconnect'] if policies else ['empty-direct-born', 'tracking-before-birth', 'tracking-after-birth'])[number-1],
                   'expected_reply_while_blocked': timing in ('before', 'protected'), 'started_epoch': time.time()}
            apply('')
            c = NCClient(output); c.settimeout(3); c.bind((HOST, 0)); clients.append(c)
            cp = c.getsockname()[1]
            rule = tracking(cp, gp)
            if timing in ('before', 'protected'): row['tracking_install'] = apply(rule + (deny(gp, cp) if timing == 'protected' else ''))
            c.connect((GUEST, gp)); row['ready'] = line(c)
            assert row['ready']['received'] and row['ready']['value']['ready']
            row['tuple'] = {'source': [HOST, cp], 'destination': [GUEST, gp], 'interface': 'en0', 'protocol': 'tcp'}
            row['birth'] = rpc('snapshot'); states = state_lines(row['birth'], cp, gp)
            assert any(e['event'] == 'accepted' and e['peer'] == [HOST, cp] and e['local'] == [GUEST, gp]
                       for e in row['birth']['data_events']), 'Actual nc tuple differs from pinned tuple'
            assert bool(states) == (timing in ('before', 'protected')), 'Birth-state precondition failed'
            if timing in ('before', 'protected'): assert all('<-' in x and 'en0' in x for x in states)
            if timing == 'protected':
                row['ordinary_direct'] = apply(rule)
                row['ordinary_direct_snapshot'] = rpc('snapshot')
                assert state_lines(row['ordinary_direct_snapshot'], cp, gp), 'Direct transition lost incoming state'
            if timing == 'after': row['tracking_install'] = apply(rule)
            row['closure'] = apply((rule if timing != 'none' else '') + deny(gp, cp))
            row['closed_snapshot'] = rpc('snapshot')
            nonce = uuid.uuid4().hex; row['nonce'] = nonce; row['client_sent_epoch'] = time.time(); send(c, {'nonce': nonce})
            row['blocked_receive'] = line(c, 2); row['reply_while_blocked'] = row['blocked_receive']['received']
            row['after_send'] = rpc('snapshot')
            generated = [e for e in row['after_send']['data_events'] if e['event'] == 'generated' and e['value']['echo'] == {'nonce': nonce}]
            row['server_generated'] = generated
            assert generated, 'Server did not generate expected echo'
            assert row['reply_while_blocked'] == row['expected_reply_while_blocked'], 'Unexpected continuity outcome'
            assert bool(state_lines(row['after_send'], cp, gp)) == (timing in ('before', 'protected'))
            apply('')
            row['after_release'] = line(c, 4) if not row['reply_while_blocked'] else {'not_needed': True}
            assert row['reply_while_blocked'] or row['after_release']['received'], 'Native release did not resume echo'
            c.close(); clients.remove(c)
            if policies and number == 3:
                fresh = NCClient(output); fresh.bind((HOST, 0)); clients.append(fresh)
                fp = fresh.getsockname()[1]; fr = tracking(fp, gp)
                reconnect = {'source_port': fp, 'tracking_install': apply(fr)}
                fresh.connect((GUEST, gp)); reconnect['ready'] = line(fresh)
                assert reconnect['ready']['received']
                reconnect['birth'] = rpc('snapshot'); assert state_lines(reconnect['birth'], fp, gp)
                reconnect['closure'] = apply(fr + deny(gp, fp))
                fresh_nonce = uuid.uuid4().hex; reconnect['nonce'] = fresh_nonce
                send(fresh, {'nonce': fresh_nonce}); reconnect['blocked_receive'] = line(fresh, 2)
                assert reconnect['blocked_receive']['received'] and reconnect['blocked_receive']['value']['echo'] == {'nonce': fresh_nonce}
                reconnect['after_send'] = rpc('snapshot'); assert state_lines(reconnect['after_send'], fp, gp)
                apply(''); fresh.close(); clients.remove(fresh)
                reconnect['passed'] = True; row['fresh_reconnect'] = reconnect
            row['passed'] = True; row['finished_epoch'] = time.time(); record(row)

        row = {'name': 'old-outbound-reply-negative', 'started_epoch': time.time()}
        apply(''); connect = rpc('connect', which='outbound'); cp = connect['local'][1]; hp = host_server.address[1]
        assert connect['ready']['received']
        row['tuple'] = {'source': [GUEST, cp], 'destination': [HOST, hp], 'interface': 'en0', 'protocol': 'tcp'}
        row['birth'] = rpc('snapshot'); assert not state_lines(row['birth'], cp, hp)
        candidate = tracking(hp, cp)
        row['closure'] = apply(candidate + deny(cp, hp))
        remote = next(c for c in host_server.connections if c.fileno() >= 0 and c.getpeername()[1] == cp)
        send(remote, {'return_only': True}); row['incoming_return'] = rpc('receive', which='outbound')
        assert row['incoming_return']['received'], 'Negative test did not deliver inbound reply'
        nonce = uuid.uuid4().hex; row['nonce'] = nonce; rpc('send', which='outbound', value={'nonce': nonce})
        time.sleep(2)
        row['remote_received_while_blocked'] = any(e['event'] == 'received' and e['value'] == {'nonce': nonce} for e in host_server.events)
        row['after_send'] = rpc('snapshot')
        assert not row['remote_received_while_blocked'] and not state_lines(row['after_send'], cp, hp), 'Outbound reply created permission'
        apply(''); row['passed'] = True; row['finished_epoch'] = time.time(); record(row)

        row = {'name': 'loopback-state-exclusion', 'started_epoch': time.time()}
        cp = rpc('reserve_loop')['port']; lp = manifest['loop_port']
        rule = tracking(cp, lp, 'lo0', True); row['tracking_install'] = apply(rule)
        connection = rpc('connect', which='loop', source_port=cp); assert connection['ready']['received']
        row['tuple'] = {'source': ['127.0.0.1', cp], 'destination': ['127.0.0.1', lp], 'interface': 'lo0', 'protocol': 'tcp'}
        row['birth'] = rpc('snapshot'); assert not state_lines(row['birth'], cp, lp, loop=True)
        row['closure'] = apply(rule + deny(cp, lp, True)); nonce = uuid.uuid4().hex; row['nonce'] = nonce
        rpc('send', which='loop', value={'nonce': nonce}); row['blocked_receive'] = rpc('receive', which='loop')
        row['after_send'] = rpc('snapshot')
        assert not row['blocked_receive']['received'] and not state_lines(row['after_send'], cp, lp, loop=True)
        assert not any(e['event'] == 'received' and e['value'] == {'nonce': nonce} for e in row['after_send']['loop_events'])
        apply(''); row['after_release'] = rpc('receive', which='loop', timeout=3)
        assert row['after_release']['received']; row['passed'] = True; row['finished_epoch'] = time.time(); record(row)

        row = {'name': 'cleanup-and-native-release', 'started_epoch': time.time()}
        row['release'] = apply(''); row['released'] = rpc('snapshot')
        assert not row['released']['rules']['stdout'].strip()
        c = NCClient(output); c.bind((HOST, 0)); c.connect((GUEST, gp)); clients.append(c)
        assert line(c)['received']; nonce = uuid.uuid4().hex; send(c, {'nonce': nonce}); response = line(c)
        assert response['received'] and response['value']['echo'] == {'nonce': nonce}
        row['native_echo'] = response; c.close(); clients.remove(c)
        pending_cleanup_case = row
    except Exception as e:
        failure = {'name': row.get('name', 'setup') if 'row' in locals() else 'setup',
                   'passed': False, 'error': type(e).__name__, 'reason': str(e)[:300], 'epoch': time.time()}
        if 'row' in locals(): failure['partial'] = row
        save(output / 'failure.json', failure)
        print(json.dumps({'failure': failure['name'], 'error': failure['error'], 'reason': failure['reason']}), flush=True)
    finally:
        for c in clients:
            c.close()
        cleanup = {'host_echo_joined': host_server.stop(), 'guest_root': root, 'errors': []}
        save(output / 'host-endpoint-events.json', host_server.events)
        if guest_started:
            try:
                rpc('stop')
            except Exception as e:
                cleanup['errors'].append('stop:' + type(e).__name__)
            try:
                # Guest watchdog remains independent if this export/transport fails.
                code = ('import pathlib,time,json,tarfile,io,base64,hashlib; r=pathlib.Path(' + repr(root) + ');end=time.monotonic()+22\nwhile not (r/"finished.json").exists() and time.monotonic()<end:time.sleep(.1)\nassert (r/"finished.json").exists();b=io.BytesIO()\nwith tarfile.open(fileobj=b,mode="w:gz") as t:\n for p in r.iterdir():\n  if p.is_file():t.add(p,arcname=p.name)\ndata=b.getvalue();assert len(data)<8*1024*1024;print(json.dumps({"finished":json.loads((r/"finished.json").read_text()),"sha256":hashlib.sha256(data).hexdigest(),"base64":base64.b64encode(data).decode()}))')
                exported = admin(code); data = base64.b64decode(exported.pop('base64'), validate=True)
                assert digest(data) == exported['sha256']
                (output / 'guest-private.tar.gz').write_bytes(data)
                cleanup['guest'] = exported
                finish = exported['finished']
                if finish.get('failures'): cleanup['errors'].append('guest_cleanup_failed')
                for field in ('anchor_empty','echo_threads_joined','owned_states_expired','root_rules_unchanged',
                              'production_rules_unchanged','captures_joined','watchdog_joined'):
                    if finish.get(field) is not True: cleanup['errors'].append('guest_' + field)
            except Exception as e:
                cleanup['errors'].append('export:' + type(e).__name__)
        save(output / 'cleanup.json', cleanup)
        if pending_cleanup_case is not None:
            pending_cleanup_case['cleanup'] = cleanup
            pending_cleanup_case['passed'] = not cleanup['errors'] and cleanup['host_echo_joined']
            pending_cleanup_case['finished_epoch'] = time.time()
            record(pending_cleanup_case)
        summary = {'planned': 6, 'completed': len(rows), 'passed': sum(r.get('passed') is True for r in rows),
                   'source_sha256': digest(source), 'core_sha256': expected_core, 'vm': VM,
                   'mechanism_only': True, 'installed_lifecycle_qualified': False,
                   'post_fix_policy_round': policies is not None,
                   'generated_policy_source_sha256': policies['policy_source_sha256'] if policies else None,
                   'policy_fixture_sha256': digest((output/'generated-production-policies.json').read_bytes()) if policies else None,
                   'policy_exporter_sha256': target.get('exporter_sha256'),
                   'policy_projection': 'Exact exported production destination preserved with SYN/if-bound/action/order; source, interface, ports and labels narrowed; closing timeouts1second only for owned test states. No production lifecycle change.' if policies else 'Original baseline fixture rules',
                   'host_incoming_transport': 'Native /usr/bin/nc with pinned source IPv4/port; host Python connect unavailable, cause not attributed.',
                   'cleanup': cleanup, 'results': [{k:r.get(k) for k in ('name','passed','expected_reply_while_blocked','reply_while_blocked')} for r in rows]}
        summary['all_assertions_passed'] = len(rows) == 6 and all(r.get('passed') for r in rows) and not cleanup['errors']
        save(output / 'summary.json', summary)
        print(json.dumps({'completed': len(rows), 'planned': 6, 'all_assertions_passed': summary['all_assertions_passed']}), flush=True)
    return summary['all_assertions_passed']


def main():
    os.umask(0o077)
    if len(sys.argv) > 1 and sys.argv[1] == 'serve':
        assert os.geteuid() == 0
        serve(sys.argv[2], sys.argv[3], int(sys.argv[4])); return
    if len(sys.argv) > 1 and sys.argv[1] == 'watchdog':
        watchdog(sys.argv[2]); return
    if len(sys.argv) > 1 and sys.argv[1] == 'rpc':
        guest_rpc(sys.argv[2], sys.argv[3]); return
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', required=True)
    p.add_argument('--expected-uuid', required=True)
    p.add_argument('--start', action='store_true')
    p.add_argument('--policy-fixture')
    p.add_argument('--policy-exporter')
    p.add_argument('--core-sha256', default=CORE)
    p.add_argument('--production-policy-fixture')
    a = p.parse_args()
    assert re.fullmatch(r'[0-9A-Fa-f-]{36}', a.expected_uuid)
    if not a.start:
        print(json.dumps({'planned': 6, 'vm': VM, 'mutations': False, 'requires_start': True})); return
    sys.exit(0 if host(a.output, a.expected_uuid, a.policy_fixture, a.policy_exporter, a.core_sha256, a.production_policy_fixture) else 1)


if __name__ == '__main__':
    main()
