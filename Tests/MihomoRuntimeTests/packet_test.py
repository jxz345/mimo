#!/usr/bin/env python3
"""Production-profile packet fixture, confined to the unconfigured Apple VM.

Runs a separate engine and test PF anchor; never writes a qualification record.
The real supervisor is restored in Direct on completion, interruption or timeout.
Private upstream credentials are read from a staged file and removed at cleanup.
"""
import grp
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

from upgrade_test import CORE, SUPERVISOR, ENGINE, RUNTIME, SUPPORT, read_settings

ANCHOR = "com.apple/001.mimo-packet"
V4, V6 = "198.51.100.70", "2001:db8::70"

WORKER = r'''
import json, socket, sys
sockets = {}
for line in sys.stdin:
    value = json.loads(line)
    try:
        operation, key = value['operation'], value.get('key', 'default')
        if operation == 'open':
            host = value['host']
            family = socket.AF_INET6 if ':' in host and not value.get('mixed') else socket.AF_INET
            sock = socket.socket(family, socket.SOCK_DGRAM if value.get('udp') else socket.SOCK_STREAM)
            sock.settimeout(3)
            if value.get('mixed'):
                sock.connect(('127.0.0.1', 7890))
                authority = ('[' + host + ']' if ':' in host else host) + ':18888'
                sock.sendall(('CONNECT ' + authority + ' HTTP/1.1\r\nHost: ' + authority + '\r\n\r\n').encode())
                response = b''
                while b'\r\n\r\n' not in response:
                    chunk = sock.recv(1)
                    assert chunk, 'CONNECT closed before its response'
                    response += chunk
                assert b' 200 ' in response
            else:
                sock.connect((host, value.get('port', 18888)))
            sockets[key] = sock
            if value.get('peer_token'):
                sockets[key + '-token'] = value['peer_token']
        elif operation == 'close':
            sockets.pop(key).close()
        if operation in ('open', 'echo'):
            prefix = 'mimo-peer-' + sockets[key + '-token'] + '-' if key + '-token' in sockets else 'mimo-packet-'
            payload = prefix.encode() + key.encode()
            sockets[key].send(payload)
            assert sockets[key].recv(len(payload)) == payload
        print(json.dumps({'ok': True}), flush=True)
    except (OSError, AssertionError) as error:
        print(json.dumps({'ok': False, 'error': type(error).__name__}), flush=True)
'''


def command(*args, timeout=20, check=True):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout, check=check)


def restore(root):
    for pid in (root / "engine.pid", root / "provider.pid", root / "dns.pid", root / "native.pid"):
        if pid.exists():
            try:
                os.kill(int(pid.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
    command("/sbin/pfctl", "-a", ANCHOR, "-F", "rules", check=False)
    command("/sbin/pfctl", "-a", ANCHOR + "/native-transport", "-F", "rules", check=False)
    token = root / "pf.token"
    if token.exists():
        command("/sbin/pfctl", "-X", token.read_text().strip(), check=False)
        token.unlink(missing_ok=True)
    for path in root.glob("*.yaml"):
        path.unlink()
    (root / "credentials.json").unlink(missing_ok=True)
    # Used only by the opt-in relay diagnostic; restore its known Automatic
    # Ethernet setting even if the parent process is interrupted.
    ipv6_marker = root / "restore-ethernet-ipv6-automatic"
    if ipv6_marker.exists():
        command('/usr/sbin/networksetup', '-setv6automatic', 'Ethernet')
        ipv6_marker.unlink()
    # Saved settings were never changed; startup restores original Direct.
    command("/bin/launchctl", "bootstrap", "system", "/Library/LaunchDaemons/" + SUPERVISOR + ".plist", check=False)


def watchdog(root, parent):
    deadline = time.monotonic() + 300
    while not (root / "cleanup-complete").exists():
        try:
            os.kill(parent, 0)
        except ProcessLookupError:
            break
        if time.monotonic() >= deadline:
            try:
                os.kill(parent, signal.SIGTERM)
            except ProcessLookupError:
                pass
            time.sleep(3)
            break
        time.sleep(0.25)
    else:
        return
    restore(root)


def run(configuration):
    assert os.geteuid() == 0
    assert command("/usr/sbin/sysctl", "-n", "hw.model").stdout.startswith("VirtualMac")
    original = read_settings()
    routing = json.loads(original.get("service.routing", b"{}"))
    assert "service.settings" not in original and not routing.get("proxy") and routing.get("mode", "direct") == "direct"
    assert not (RUNTIME / "qualification.json").exists()
    assert not command("/sbin/pfctl", "-a", ANCHOR, "-sr").stdout.strip()
    assert 'anchor "com.apple/*"' in command("/sbin/pfctl", "-sr").stdout
    root = Path(tempfile.mkdtemp(prefix="mimo-packet-test-", dir="/var/tmp"))
    base = Path(__file__).resolve().parent
    credentials = root / "credentials.json"
    credentials.write_bytes(configuration.read_bytes())
    credentials.chmod(0o600)
    configuration.unlink()
    fixture = json.loads(credentials.read_text())
    peer = fixture.get('peer')
    if peer:
        assert len(peer['addresses']) == 1 and len(peer['token']) == 64 and 1024 <= peer['port'] <= 65535
        assert all(ipaddress.ip_address(a) in ipaddress.ip_network('100.64.0.0/10')
                   for a in peer['addresses'])
    provider_stop = root / 'provider.stopped'
    account = pwd.getpwnam("jay")
    group = grp.getgrnam("_mimo").gr_gid
    passed, capture, engine, worker, watcher, provider, dns = [], None, None, None, None, None, None
    native_stop = threading.Event()
    native_thread = None
    native_errors = []
    capture_subjects = {}
    success = False

    def record(name):
        passed.append(name)
        print("PASS:", name, flush=True)

    def identity():
        os.setgroups([])
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)

    def engine_identity():
        os.setgroups([])
        os.setgid(group)

    def request(operation, key="default", **values):
        worker.stdin.write(json.dumps(dict(operation=operation, key=key, **values)) + "\n")
        worker.stdin.flush()
        result = json.loads(worker.stdout.readline())
        return result["ok"]

    def api(path, method="GET", body=None):
        args = ["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "5", "--unix-socket",
                root / "controller.sock", "-X", method, "http://localhost/" + path]
        if body is not None:
            (root / "request.json").write_text(json.dumps(body))
            args += ["--data-binary", "@" + str(root / "request.json")]
        return command(*args).stdout

    def load(name):
        command(base / "native-transport-check", "observe-load", root, name, str(engine.pid), timeout=12)

    def policy(name):
        command("/sbin/pfctl", "-a", ANCHOR, "-f", root / (name + ".pf"))
        if name == "closed":
            command("/sbin/pfctl", "-k", "0.0.0.0/0")
            command("/sbin/pfctl", "-k", "::/0")

    def begin_capture(name, expression, exclude_native=False):
        nonlocal capture
        capture_subjects.clear()
        for process, role in ((worker, 'ordinary-worker'), (engine, 'mihomo')):
            if process is not None:
                capture_subjects[process.pid] = role
        if exclude_native:
            # Retain the complete capture, but distinguish independently verified
            # native HTTPS sockets from ordinary application egress. Exclude exact
            # held source/destination tuples, never whole hosts or all root traffic.
            rules = (root / "native.pf").read_text().splitlines()
            exclusions = []
            for line in rules:
                match = re.fullmatch(r"pass out quick inet6? proto tcp from (\S+) port (\d+) to (\S+) port 443 user 0 no state", line)
                if match:
                    source, port, destination = match.groups()
                    exclusions.append("(tcp and src host " + source + " and src port " + port +
                                      " and dst host " + destination + " and dst port 443)")
            (root / (name + ".native-exclusions.txt")).write_text(" or ".join(exclusions))
        log = root / (name + ".capture.log")
        with log.open("w") as stream:
            capture = subprocess.Popen(["/usr/sbin/tcpdump", "-n", "-U", "-i", "pktap,en0", "-w", str(root / (name + ".pcap")), expression], stdout=stream, stderr=stream)
        deadline = time.monotonic() + 3
        while "listening on" not in log.read_text():
            assert capture.poll() is None and time.monotonic() < deadline
            time.sleep(0.05)

    def end_capture(name, expect_empty=True):
        nonlocal capture
        time.sleep(0.25)
        capture.send_signal(signal.SIGINT)
        capture.wait(timeout=4)
        capture = None
        if (root / (name + '.pcap')).stat().st_size == 0:
            # macOS emits no pcap-ng header until its first matching packet.
            assert re.search(r'^0 packets captured$', (root / (name + '.capture.log')).read_text(), re.M)
            (root / (name + '.packets.txt')).write_text('')
            (root / (name + '.ordinary-packets.txt')).write_text('')
            (root / (name + '.subjects.json')).write_text(json.dumps(capture_subjects, indent=2))
            return ''
        packets = command("/usr/sbin/tcpdump", "-nn", "-k", "NP", "-r", root / (name + ".pcap")).stdout
        (root / (name + ".packets.txt")).write_text(packets)
        # PKTAP preserves kernel process attribution. Check the actual ordinary
        # test callers AND the engine, so a DIRECT escape through mihomo is also
        # detected. Concurrent private bootstrap lookups are separate processes.
        # Keep the complete capture and its metadata for independent review.
        assert capture_subjects
        metadata_filter = ' or '.join('pid = ' + str(pid) for pid in capture_subjects)
        (root / (name + '.subjects.json')).write_text(json.dumps(capture_subjects, indent=2))
        packets = command('/usr/sbin/tcpdump', '-nn', '-k', 'NP', '-r', root / (name + '.pcap'), '-Q', metadata_filter).stdout
        (root / (name + ".ordinary-packets.txt")).write_text(packets)
        if expect_empty:
            assert not packets.strip(), name + " leaked onto the guest uplink"
        return packets

    def ordinary_command(arguments, timeout=20):
        process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, preexec_fn=identity)
        if capture is not None:
            capture_subjects[process.pid] = 'ordinary-command'
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise
        return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)

    def interrupted(signum, frame):
        raise KeyboardInterrupt()

    def cli(*args):
        return command("/usr/bin/sudo", "-n", "-u", "jay", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", *args).stdout

    def metrics():
        return {parts[0]: float(parts[1]) for line in cli("debug", "metrics").splitlines()
                if not line.startswith("#") and len(parts := line.split()) == 2}

    def relay_diagnostics(label):
        for suffix, args in (
            ('guard', ('/sbin/pfctl', '-a', ANCHOR, '-vvsr')),
            ('transport', ('/sbin/pfctl', '-a', ANCHOR + '/native-transport', '-vvsr')),
            ('sockets', ('/usr/sbin/lsof', '-nP', '-iTCP', '-sTCP:^CLOSED')),
            ('route', ('/sbin/route', '-n', 'get', peer['addresses'][0])),
        ):
            result = command(*args, check=False)
            (root / (label + '-' + suffix + '.txt')).write_text(result.stdout + result.stderr)

    def dns_answer(server, port, name, kind):
        answer = subprocess.run(["/usr/bin/dig", "+time=3", "+tries=1", "+noall", "+comments", "+answer",
            "@" + server, "-p", str(port), name, kind], capture_output=True, text=True, timeout=8,
            preexec_fn=identity)
        assert answer.returncode == 0 and "status: NOERROR" in answer.stdout, "MagicDNS query failed"
        addresses = sorted(line.split()[-1] for line in answer.stdout.splitlines()
                           if line and not line.startswith(";") and len(line.split()) >= 5 and line.split()[3] == kind)
        return addresses, answer.stdout

    def native_watch():
        process = None
        try:
            with (root / 'native.log').open('w') as log:
                process = subprocess.Popen([base / 'native-transport-check', 'serve-transport', root, provider_stop], stdout=log, stderr=log)
            (root / 'native.pid').write_text(str(process.pid))
            while not native_stop.is_set():
                assert process.poll() is None, 'Production native transport observer exited'
                native_stop.wait(0.5)
        except Exception as error:
            native_errors.append(type(error).__name__)
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=5)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        native = json.loads(cli("status", "--json"))
        name = native["Self"]["DNSName"]
        magicdns = {}
        for kind in ("A", "AAAA"):
            magicdns[kind], answer = dns_answer("100.100.100.100", 53, name, kind)
            (root / ("direct-magicdns-" + kind + ".txt")).write_text(answer)
        assert magicdns["A"] and all(address in native["TailscaleIPs"] for address in magicdns["A"] + magicdns["AAAA"])
        command(base / "render-profiles", "packet-profiles", credentials, root)
        begin_capture('direct-capture-control', 'dst host 1.1.1.1 and tcp dst port 443')
        ordinary_command(['/usr/bin/curl', '--silent', '--max-time', '5', '--noproxy', '*', '--head', 'https://1.1.1.1'])
        assert end_capture('direct-capture-control', expect_empty=False), 'Kernel packet process attribution is unavailable'
        record('Direct-positive-control-confirms-ordinary-packet-attribution')
        if peer:
            peers = list((native.get('Peer') or {}).values())
            assert any(p.get('Online') and set(peer['addresses']).issubset(p['TailscaleIPs']) for p in peers)
            for host in peer['addresses']:
                for udp in (False, True):
                    family = socket.AF_INET6 if ':' in host else socket.AF_INET
                    with socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as connection:
                        connection.settimeout(5)
                        connection.connect((host, peer['port']))
                        payload = ('mimo-peer-' + peer['token'] + '-direct-baseline').encode()
                        connection.sendall(payload)
                        assert connection.recv(len(payload)) == payload, 'Tailnet peer baseline failed'
            record('Direct-tailnet-peer-TCP-UDP-IPv4-baseline')
            for label in ('closed', 'rule', 'global'):
                path = root / (label + '.pf')
                policy_text = path.read_text()
                marker = 'pass out quick to { 10.0.0.0/8'
                assert marker in policy_text
                # The peer is Delta itself. Suppress native LAN UDP in this fixture
                # so successful traffic proves the relay path, not a NAT-host shortcut.
                policy_text = policy_text.replace(marker, 'block return out quick proto udp group != ' + str(group) + '\n' + marker)
                path.write_text(policy_text)
        with (root / "watchdog.log").open("w") as log:
            watcher = subprocess.Popen([sys.executable, __file__, "watchdog", str(root), str(os.getpid())], stdout=log, stderr=log, start_new_session=True)
        assert 'IPv6: Off' in command('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
        for label in (CORE, ENGINE, SUPERVISOR):
            command("/bin/launchctl", "bootout", "system/" + label, check=False)
        deadline = time.monotonic() + 15
        while any(command("/bin/launchctl", "print", "system/" + label, check=False).returncode != 113 for label in (CORE, ENGINE, SUPERVISOR)):
            assert time.monotonic() < deadline
            time.sleep(0.1)
        production_rules = command("/sbin/pfctl", "-a", "com.apple/000.mimo", "-sr").stdout
        assert 'inet6' in production_rules and 'block' in production_rules
        assert 'block drop out quick all' not in production_rules
        policy("closed")
        enabled = command("/sbin/pfctl", "-E")
        token = re.search(r"Token\s*:\s*(\d+)", enabled.stdout + enabled.stderr)
        assert token
        (root / "pf.token").write_text(token[1])
        native_thread = threading.Thread(target=native_watch)
        native_thread.start()
        with (root / "provider.log").open("w") as log:
            provider = subprocess.Popen([base / "native-transport-check", "serve-provider", provider_stop], stdout=log, stderr=log)
        (root / "provider.pid").write_text(str(provider.pid))
        deadline = time.monotonic() + 12
        while not (root / "native.pf").exists() or "pass out" not in (root / "native.pf").read_text():
            assert time.monotonic() < deadline and not native_errors
            time.sleep(0.1)
        before = metrics()
        cli("down")
        cli("up")
        deadline = time.monotonic() + 60
        while metrics().get("controlclient_map_response_map", 0) <= before.get("controlclient_map_response_map", 0):
            assert time.monotonic() < deadline and not native_errors, "Native Tailscale control did not reconnect"
            time.sleep(0.5)
        record("native-Tailscale-control-reconnects-with-ordinary-gate-closed")
        if peer and '--diagnose-relay' in sys.argv:
            reply = cli('ping', '--c=1', '--until-direct=false', '--timeout=5s', peer['addresses'][0])
            (root / 'closed-peer-relay.txt').write_text(reply)
            relay_diagnostics('closed-relay')
        with (root / "engine.log").open("w") as log:
            engine = subprocess.Popen([base / "mihomo", "-d", root, "-f", root / "blocking.yaml"], stdout=log, stderr=log, preexec_fn=engine_identity)
        (root / "engine.pid").write_text(str(engine.pid))
        worker = subprocess.Popen([sys.executable, "-u", "-c", WORKER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, preexec_fn=identity)
        deadline = time.monotonic() + 10
        while not (root / "controller.sock").exists():
            assert engine.poll() is None and time.monotonic() < deadline
            time.sleep(0.1)
        begin_capture("closed", "dst host 1.1.1.1 and (tcp dst port 443 or udp dst port 53)")
        assert not request("open", host="1.1.1.1", port=443)
        assert not request("open", host="1.1.1.1", port=53, udp=True)
        end_capture("closed")
        record("closed-gate-denies-ordinary-public-TCP-and-DNS")
        diagnostic = cli("debug", "dial-types", "1.1.1.1", "443")
        (root / "native-diagnostic-bypass.txt").write_text(diagnostic)
        assert "connected=true" not in diagnostic and "connected=false" in diagnostic
        record("native-Tailscale-diagnostics-cannot-bypass-the-public-gate")

        load("global-verification")
        result = command(base / "render-profiles", "probe-success", credentials, timeout=20)
        (root / "probe-snapshot.json").write_text(result.stdout)
        assert json.loads(result.stdout).get("ipAddress")
        assert not request("open", host=V4)
        record("private-production-IP-check-succeeds-while-ordinary-traffic-stays-blocked")
        load("wrong-password")
        result = command(base / "render-profiles", "probe-success", credentials, timeout=20, check=False)
        assert result.returncode != 0
        assert not request("open", host="1.1.1.1", port=443)
        record("wrong-proxy-password-cannot-fall-back-to-Direct")

        for mode in ("rule", "global"):
            policy("closed")
            load(mode + "-active")
            tunnel = command('/sbin/ifconfig', 'utun239').stdout
            (root / (mode + '-tunnel.txt')).write_text(tunnel)
            assert 'inet ' in tunnel and 'inet6 ' not in tunnel, 'Mimo must create an IPv4-only tunnel'
            for path in ("configs", "rules", "proxies"):
                (root / (mode + "-" + path + ".json")).write_text(api(path))
            command(base / "render-profiles", "inspect", root, mode, "active")
            if dns is None:
                with (root / "dns.log").open("w") as log:
                    dns = subprocess.Popen([base / "native-transport-check", "serve-dns", root, str(engine.pid)], stdout=log, stderr=log)
                (root / "dns.pid").write_text(str(dns.pid))
                time.sleep(3)
                assert dns.poll() is None
                (root / "protected-system-dns.txt").write_text(command("/usr/sbin/scutil", "--dns").stdout)
                record("owned-DNS-override-does-not-trigger-a-verification-loop")
            policy(mode)
            begin_capture(mode + "-https", "tcp dst port 443 or udp dst port 53", exclude_native=mode == "global")
            https = ordinary_command(["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "15",
                "--noproxy", "*", "--head", "https://github.com/robots.txt"], timeout=20)
            (root / (mode + "-https.txt")).write_text(https.stdout + https.stderr)
            end_capture(mode + "-https", expect_empty=mode == "global")
            assert https.returncode == 0, mode + " ordinary DNS/HTTPS failed"
            record(mode + "-ordinary-system-DNS-and-HTTPS-succeed")
            if mode == "global":
                begin_capture("global-public-tailscale", "tcp dst port 443 or udp dst port 53", exclude_native=True)
                website = ordinary_command(["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "15",
                    "--noproxy", "*", "--head", "https://tailscale.com/robots.txt"], timeout=20)
                (root / "global-public-tailscale.txt").write_text(website.stdout + website.stderr)
                end_capture("global-public-tailscale")
                assert website.returncode == 0, "Global incorrectly treated a public Tailscale website as native traffic"
                record("Global-public-Tailscale-website-uses-proxy")
            for kind in ("A", "AAAA"):
                addresses, answer = dns_answer("127.0.0.1", 1053, name, kind)
                (root / (mode + "-magicdns-" + kind + ".txt")).write_text(answer)
                assert addresses == (magicdns[kind] if kind == 'A' else []), mode + " MagicDNS violated IPv4-only policy"
            record(mode + "-MagicDNS-A-matches-native-and-AAAA-is-empty")
            begin_capture(mode, "dst host " + V4 + " or dst host " + V6)
            for host, family in ((V4, "v4"), (V6, "v6")):
                for udp in (False, True):
                    key = mode + family + ("udp" if udp else "tcp")
                    opened = request("open", key, host=host, udp=udp)
                    assert opened == (family == 'v4'), key + " violated IPv4-only routing"
            assert request("open", mode + "mixed", host=V4, mixed=True)
            assert not request("open", mode + "mixed6", host=V6, mixed=True), 'Local proxy accepted an IPv6 destination'
            end_capture(mode)
            record(mode + "-IPv4-TCP-UDP-use-proxy-and-IPv6-is-rejected-with-no-uplink-leak")
            if peer:
                if '--diagnose-relay' in sys.argv:
                    begin_capture(mode + '-relay', 'tcp port 443')
                # A newly selected relay may need a socket observation and TCP
                # retransmission before the narrowly scoped exception is ready.
                deadline = time.monotonic() + 30
                while True:
                    ping = command('/usr/bin/sudo', '-n', '-u', 'jay',
                        '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
                        'ping', '--c=1', '--until-direct=false', '--timeout=5s', peer['addresses'][0], check=False)
                    with (root / (mode + '-peer-relay.txt')).open('a') as stream:
                        stream.write(ping.stdout + ping.stderr)
                    if ping.returncode == 0 and 'via DERP(' in ping.stdout:
                        break
                    if time.monotonic() >= deadline:
                        relay_diagnostics(mode + '-relay')
                        (root / (mode + '-relay-firewall.txt')).write_text((root / 'native.pf').read_text())
                        if '--diagnose-relay' in sys.argv:
                            cli('debug', 'break-derp-conns')
                            retry = command('/usr/bin/sudo', '-n', '-u', 'jay',
                                '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
                                'ping', '--c=3', '--until-direct=false', '--timeout=5s', peer['addresses'][0], check=False)
                            (root / (mode + '-relay-reset.txt')).write_text(retry.stdout + retry.stderr)
                            relay_diagnostics(mode + '-relay-reset')
                            end_capture(mode + '-relay', expect_empty=False)
                        raise AssertionError('Peer transport did not demonstrate the relay path')
                if '--diagnose-relay' in sys.argv:
                    end_capture(mode + '-relay', expect_empty=False)
                for host in peer['addresses']:
                    family = 'v6' if ':' in host else 'v4'
                    for udp in (False, True):
                        key = mode + '-peer-' + family + ('udp' if udp else 'tcp')
                        assert request('open', key, host=host, port=peer['port'], udp=udp, peer_token=peer['token']), key + ' failed'
                record(mode + '-tailnet-peer-TCP-UDP-IPv4-work-through-relay')
                for kind in ('A', 'AAAA'):
                    addresses, answer = dns_answer('127.0.0.1', 1053, peer['name'], kind)
                    (root / (mode + '-peer-magicdns-' + kind + '.txt')).write_text(answer)
                    assert addresses == (peer['dns'][kind] if kind == 'A' else [])
                record(mode + '-peer-MagicDNS-matches-native-provider')
                assert request('echo', mode + 'v4tcp')
                provider_stop.touch()
                deadline = time.monotonic() + 12
                while 'pass out quick on utun' in command('/sbin/pfctl', '-a', ANCHOR + '/native-transport', '-sr').stdout:
                    assert time.monotonic() < deadline and not native_errors
                    time.sleep(0.1)
                for family in ('v4',):
                    for suffix in ('tcp', 'udp'):
                        assert not request('echo', mode + '-peer-' + family + suffix), 'Stopped provider retained a peer flow'
                        assert request('echo', mode + 'v4tcp'), 'Stopping the tailnet provider interrupted verified public traffic'
                for host in peer['addresses']:
                    assert not request('open', mode + '-stopped-peer-' + host, host=host, port=peer['port'], peer_token=peer['token'])
                assert request('echo', mode + 'v4tcp'), 'Stopping the tailnet provider interrupted verified public traffic'
                record(mode + '-provider-Stop-blocks-old-and-new-peer-flows-with-public-access-preserved')
                provider_stop.unlink()
                deadline = time.monotonic() + 12
                while 'pass out quick on utun' not in command('/sbin/pfctl', '-a', ANCHOR + '/native-transport', '-sr').stdout:
                    assert time.monotonic() < deadline and not native_errors
                    time.sleep(0.1)
                assert request('open', mode + '-restarted-peer', host=peer['addresses'][0], port=peer['port'], peer_token=peer['token'])
                record(mode + '-provider-Start-restores-peer-access')
            policy("closed")
            api("connections", "DELETE")
            assert not request("open", "closed-dns", host="127.0.0.1", port=1053)
            for suffix in ("v4tcp", "v4udp", "mixed"):
                assert not request("echo", mode + suffix), "Existing connection survived closure: " + suffix
            record(mode + "-closing-gate-disconnects-existing-TCP-UDP-and-local-CONNECT")
            load(mode + "-verification")
            record(mode + "-own-TUN-start-and-stop-do-not-trigger-external-network-events")

        load("global-active")
        policy("global")
        before = metrics()
        cli("down")
        cli("up")
        deadline = time.monotonic() + 60
        while metrics().get("controlclient_map_response_map", 0) <= before.get("controlclient_map_response_map", 0):
            assert time.monotonic() < deadline and not native_errors, "Native Tailscale control did not reconnect with TUN active"
            time.sleep(0.5)
        record("native-Tailscale-control-reconnects-with-Global-TUN-active")
        begin_capture("dns-bypass", "dst host 8.8.8.8 and (port 53 or port 853)")
        for port, udp in ((53, False), (53, True), (853, False)):
            assert not request("open", "dns" + str(port) + str(udp), host="8.8.8.8", port=port, udp=udp)
        end_capture("dns-bypass")
        record("global-does-not-send-ordinary-DNS-or-DoT-on-uplink")
        engine.kill()
        engine.wait(timeout=5)
        begin_capture("engine-crash", "dst host 1.1.1.1 and tcp dst port 443")
        assert not request("open", host="1.1.1.1", port=443)
        end_capture("engine-crash")
        record("engine-crash-does-not-open-Direct-traffic")
        success = True
    finally:
        native_stop.set()
        if native_thread is not None:
            native_thread.join(timeout=15)
        if provider is not None:
            provider.terminate()
            provider.wait(timeout=4)
        if dns is not None:
            dns.terminate()
            dns.wait(timeout=4)
        if capture is not None:
            capture.terminate()
            capture.wait(timeout=4)
        if worker is not None:
            worker.terminate()
            worker.wait(timeout=4)
        restore(root)
        cli("up")
        if engine is not None:
            engine.wait(timeout=5)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            result = command(base / "installation-check", check=False)
            if result.returncode == 0 and json.loads(result.stdout).get("effectiveMode") == "direct":
                with socket.create_connection(("1.1.1.1", 443), timeout=5):
                    pass
                restored_dns = command("/usr/sbin/scutil", "--dns").stdout
                (root / "restored-system-dns.txt").write_text(restored_dns)
                assert "port     : 1053" not in restored_dns
                restored = subprocess.run(["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "15",
                    "--noproxy", "*", "--head", "https://github.com/robots.txt"], capture_output=True, text=True,
                    timeout=20, preexec_fn=identity)
                (root / "restored-https.txt").write_text(restored.stdout + restored.stderr)
                assert restored.returncode == 0, "Direct DNS/HTTPS did not recover"
                record("original-Direct-services-and-network-restored")
                break
            time.sleep(0.2)
        else:
            success = False
            raise AssertionError("Original Direct did not recover")
        (root / "report.json").write_text(json.dumps({"passed": passed, "success": success,
            "ipProtocol": "IPv4 only; IPv6 denial is required",
            "scope": "Controlled production-profile packet fixture with optional native peer checks; not installed protected-mode qualification"}, indent=2) + "\n")
        (root / "cleanup-complete").touch()
        if watcher is not None:
            watcher.wait(timeout=3)
        print("Evidence:", root, flush=True)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "watchdog":
        watchdog(Path(sys.argv[2]), int(sys.argv[3]))
    else:
        run(Path(sys.argv[1]))
