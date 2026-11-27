#!/usr/bin/env python3
"""Reproduce blocked-session recovery on the UNMODIFIED installed app.

Delta host arguments: private-output-directory guest-directory.
Guest operations use the existing signed XPC controls. No token changes, store
edits, clock changes, process restarts or Direct transitions occur between the
fault and recovery assertion. Direct is used only in final cleanup.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request

NAME = 'Blocked retry regression'


def fixture_main():
    import signal
    from v3_closure_fixture import ClosureFixture

    class RetryFixture(ClosureFixture):
        def accept(self):
            # The VM exercises Mimo; Delta independently proves that the same
            # SOCKS endpoint/provider recovered. No other clients are admitted.
            while not self.done.is_set():
                try:
                    client, peer = self.proxy.accept()
                    if peer[0] not in (self.client4, self.bridge4) or self.proxy_off:
                        client.close()
                        continue
                    with self.lock:
                        self.connections.add(client)
                    self.thread(self.connection, client)
                except socket.timeout:
                    pass

    root = Path(sys.argv[1])
    assert sys.argv[7:] in ([], ['--loopback-provider-alias']), 'Unknown fixture option'
    fixture = RetryFixture(root, *sys.argv[3:7], 'S00',
                           loopback_provider_alias='--loopback-provider-alias' in sys.argv[7:])
    (root / 'fixture.json').write_text(json.dumps(fixture.manifest()))
    signal.signal(signal.SIGTERM, lambda *_: fixture.done.set())
    signal.signal(signal.SIGINT, lambda *_: fixture.done.set())
    fixture.done.wait()


def guest_main():
    import v3_installed_test as t
    root = Path(sys.argv[1])
    operation = sys.argv[2]
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    fixture = json.loads((root / 'fixture.json').read_text())
    provider = fixture.get('test_provider', 'ipWhois')
    mode, family = fixture.get('test_mode', 'rule'), fixture.get('test_family', 'ipv4')
    if operation == 'prepare':
        original = t.state()
        assert not (root / 'before.json').exists(), 'Use a fresh campaign directory'
        (root / 'before.json').write_text(json.dumps(original))
        assert not original['hasIPinfoToken'], 'Never replace an existing credential'
        t.route('direct'); t.wait_active('direct', 60)
        t.request('saveProxy', proxy=dict(name=NAME, type='socks5', server=fixture['bridge4'],
                                         port=fixture['proxy_port'], username=''), proxyPassword='')
        entry = next(p for p in t.state()['routing']['configuration']['proxies'] if p['proxy']['name'] == NAME)
        t.request('selectProxy', proxyID=entry['id'])
        settings = t.state()['settings']
        settings.update(provider=provider, providerPool=[provider], refreshInterval=-1,
                        bypassBlocks=[], allowlist={'addresses': []})
        t.request('configure', settings=settings)
        t.route(mode, family)
        if provider == 'ipinfoLite':
            # Set ONCE before the baseline, never again during fault/recovery.
            # The closed fixture cannot forward this disposable value publicly.
            import uuid
            (root / 'fixture-token-owned').write_text('disposable fixture credential')
            t.request('setToken', token='mimo-blocked-retry-fixture-' + uuid.uuid4().hex)
    elif operation in ('approve', 'reject'):
        settings = t.state()['settings']
        allowed = ['203.0.113.10']
        settings['allowlist'] = {'addresses': allowed if operation == 'approve' else []}
        t.request('configure', settings=settings)
    elif operation == 'mismatch':
        settings = t.state()['settings']
        settings['allowlist'] = {'addresses': ['203.0.113.99']}
        t.request('configure', settings=settings)
    elif operation == 'traffic':
        capture = root / 'native-ipv6.pcap'
        # Promiscuous mode changes interface flags and legitimately re-closes
        # Mimo's gate. Observe without changing the network under test.
        stream = subprocess.Popen(['/usr/sbin/tcpdump', '-p', '-n', '-i', 'en0', '-U', '-w', str(capture),
            'ip6 and dst host ' + fixture['public6'] + ' and (tcp or udp)'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(.4)
            outcomes = {}
            for address in (fixture['public4'], fixture['public6']):
                with socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET, socket.SOCK_STREAM) as sock:
                    sock.settimeout(3)
                    try:
                        sock.connect((address, fixture['stream_port']))
                        message = fixture['token'].encode() + b':approval-traffic'
                        sock.sendall(message)
                        outcomes[address] = sock.recv(1024) == message
                    except OSError:
                        outcomes[address] = False
            with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sock:
                sock.settimeout(2)
                sock.sendto(b'mimo-ipv6-denial-check', (fixture['public6'], fixture['udp_port']))
                try: outcomes['udp6'] = bool(sock.recv(1024))
                except OSError: outcomes['udp6'] = False
        finally:
            stream.send_signal(__import__('signal').SIGINT); stream.wait(timeout=5)
        packets = t.run(['/usr/sbin/tcpdump', '-nn', '-r', str(capture)], 5)
        assert packets.returncode == 0
        assert outcomes[fixture['public4']] and not outcomes[fixture['public6']] and not outcomes['udp6'], str(outcomes)
        assert not packets.stdout.strip(), 'Native public IPv6 bypass observed'
        print(json.dumps(dict(ipv4_proxied=True, ipv6_failed=True, native_ipv6_packets=0)))
        return
    elif operation == 'refresh':
        t.request('refresh')
    elif operation == 'events':
        records = [json.loads(line) for line in t.request('events').get('diagnosticEvents', [])]
        # Raw records stay private; public evidence uses event names/times only.
        (root / 'events.json').write_text(json.dumps(records, indent=2))
        print(json.dumps([dict(event=r['event'], timestamp=r['timestamp']) for r in records]))
        return
    elif operation == 'restore':
        original = json.loads((root / 'before.json').read_text())
        if (root / 'fixture-token-owned').exists():
            t.request('removeToken')
            (root / 'fixture-token-owned').unlink()
        t.route('direct'); t.wait_active('direct', 60)
        t.request('configure', settings=original['settings'])
        selected = original['routing']['configuration'].get('activeProxyID')
        t.request('selectProxy', **({'proxyID': selected} if selected else {}))
        for p in t.state()['routing']['configuration']['proxies']:
            if p['proxy']['name'] == NAME:
                t.request('removeProxy', proxyID=p['id'])
        t.request('configureRouting', routing=original['routing']['configuration'])
        restored = t.state()
        assert restored['settings'] == original['settings']
        assert restored['routing']['configuration'] == original['routing']['configuration']
        assert restored['hasIPinfoToken'] == original['hasIPinfoToken']
        print(json.dumps(dict(settings_restored=True, routing_restored=True, credentials_unchanged=True)))
        return
    elif operation != 'status':
        raise AssertionError('Unknown operation')
    value = t.state()
    routing = value['routing']
    print(json.dumps(dict(phase=routing['phase'], mode=routing['configuration']['mode'],
                         effective=routing.get('effectiveMode'), reason=routing['reason'],
                         status=value['status'], manual=value.get('manualRefresh'),
                         cooldowns=value['cooldowns'], health=value['providerHealth'],
                         snapshot=value.get('snapshot'), observed=routing.get('observedIP'),
                         rejected=routing.get('blockingIP'), last_known=routing.get('lastExitObservation'),
                         instance=value['instanceID'])))


def host_main():
    root, guest_root = Path(sys.argv[1]), sys.argv[2]
    assert socket.gethostname().split('.')[0] == 'delta'
    assert root.stat().st_mode & 0o077 == 0
    repo = Path(__file__).resolve().parents[2]
    fixture = json.loads((root / 'fixture/fixture.json').read_text())
    mode, family = fixture.get('test_mode', 'rule'), fixture.get('test_family', 'ipv4')
    provider_host = {'ipWhois': 'ipwho.is', 'ipapiCo': 'ipapi.co', 'ipinfoLite': 'v4.api.ipinfo.io'}[fixture.get('test_provider', 'ipWhois')]
    result = dict(scope='installed build; same protected session; no credential/cooldown reset', mode=mode, family=family, stages=[])
    prepared = False

    def save():
        (root / 'result.json').write_text(json.dumps(result, indent=2))

    def guest(operation):
        command = [sys.executable, str(repo / 'Scripts/vm-console-admin.py'), '/usr/bin/python3',
                   guest_root + '/' + Path(__file__).name, guest_root, operation]
        value = subprocess.run(command, capture_output=True, text=True, timeout=175)
        (root / (operation + '-last.log')).write_text(value.stdout + value.stderr)
        assert value.returncode == 0, operation + ' failed; see private log'
        return json.loads(value.stdout.strip().splitlines()[-1])

    def control(off=False, status=200, retry_after=None, fault=''):
        request = urllib.request.Request('http://' + fixture['bridge4'] + ':' + str(fixture['control_port']),
                                         json.dumps(dict(proxy_off=off, disconnect=True, provider_status=status,
                                                         provider_retry_after=retry_after,
                                                         fault=fault, mode=fixture.get('test_proxy_mode', 'S00'),
                                                         dns_fault=fixture.get('test_dns_fault', ''))).encode(),
                                         headers={'Authorization': 'Bearer ' + fixture['token']})
        with urllib.request.urlopen(request, timeout=4):
            pass

    def provider_count():
        path = root / 'fixture/events.jsonl'
        return sum(json.loads(line)['event'] == 'provider_http' for line in path.read_text().splitlines()) if path.exists() else 0

    def wait(predicate, timeout=85):
        deadline = time.monotonic() + timeout
        while True:
            value = guest('status')
            result['stages'].append(dict(t=time.time(), **value)); save()
            if predicate(value):
                return value
            if time.monotonic() >= deadline:
                raise AssertionError('State did not settle: ' + value['reason'])
            time.sleep(.6)

    def rejected(value):
        return value['phase'] == 'blocked' and 'No exit IPs are approved' in value['reason'] and 'ready' in value['status']

    def healthy(value):
        health = value['health']
        if not isinstance(health, dict): health = dict(zip(health[::2], health[1::2]))
        item = health[fixture.get('test_provider', 'ipWhois')]
        assert item['consecutiveFailures'] == 0 and not item.get('lastError'), 'Successful IPv4 paused the provider'
        assert (value.get('observed') or {}).get('address') == '203.0.113.10'

    try:
        control()
        prepared = True
        guest('prepare')
        baseline = wait(rejected)
        healthy(baseline)
        result['baseline_rejected'] = True
        print('Baseline: fresh exit rejected; provider lookup succeeded.', flush=True)
        for attempt in range(3):
            before = provider_count()
            previous = (baseline['snapshot'] or {}).get('checkedAt')
            guest('refresh')
            baseline = wait(lambda s: rejected(s) and (s['snapshot'] or {}).get('checkedAt') != previous)
            assert provider_count() > before, 'Rejected-state refresh did not reach the provider'
            if fixture.get('test_ipv4_approval'):
                assert provider_count() == before + 1, 'Each explicit check must issue one required IPv4 HTTP request'
                healthy(baseline)
            print('Rejected-session refresh ' + str(attempt + 1) + '/3: PASS', flush=True)
        if fixture.get('test_ipv4_approval'):
            guest('mismatch')
            mismatch = wait(lambda s: s['phase'] == 'blocked' and (s.get('rejected') or {}).get('address') == '203.0.113.10' and 'ready' in s['status'])
            healthy(mismatch)
            assert mismatch['rejected']['address'] == '203.0.113.10'
            # Observe multiple infrastructure audits, not only the first few
            # seconds after rejection. The supervisor's old pending-recovery
            # bug retriggered at roughly 10–12 seconds and escaped a 3s check.
            before = provider_count(); time.sleep(35)
            stable = guest('status'); healthy(stable)
            assert provider_count() == before, 'Polling caused a retry loop'
            result['mismatch_visible_healthy_stable'] = True
        guest('approve')
        wait(lambda s: s['phase'] == 'active')
        if fixture.get('test_ipv4_approval'):
            result['traffic'] = guest('traffic')
        result['allowlist_only_repair'] = 'PASS'
        print('Allowlist-only repair without Direct or credential change: PASS', flush=True)
        if not fixture.get('test_ipv4_approval'):
            guest('reject'); wait(rejected)
        before_events = guest('events')
        control(off=True)
        guest('refresh')
        failed = wait(lambda s: s['phase'] == 'blocked' and 'coolingDown' in s['status'])
        if fixture.get('test_ipv4_approval'):
            assert not failed['observed'] and not failed['rejected'], 'A failed request invented a current result'
            assert failed['last_known']['ipAddress'] == '203.0.113.10'
            result['last_known_after_failure'] = True
            # A host harness can hold the final cell for native UI inspection.
            if fixture.get('ui_checkpoint'):
                (root / 'ui-ready').write_text('blocked with last-known IPv4')
                deadline = time.monotonic() + 600
                while not (root / 'ui-continue').exists():
                    assert time.monotonic() < deadline, 'Native UI checkpoint timed out'
                    time.sleep(1)
        result['injected_failure'] = failed
        print('Transient proxy outage produced a provider cooldown.', flush=True)
        control()
        # Prove that the unchanged fixture proxy/provider is working again.
        health = subprocess.run(['/usr/bin/curl', '--fail', '-sS', '--max-time', '8', '--cacert',
                                 str(root / 'fixture/server.crt'), '--socks5',
                                 fixture['bridge4'] + ':' + str(fixture['proxy_port']),
                                 '--resolve', provider_host + ':443:' + fixture['data4'], 'https://' + provider_host + '/'],
                                capture_output=True, text=True, timeout=12)
        (root / 'fixture-health.log').write_text(health.stdout + health.stderr)
        assert health.returncode == 0 and json.loads(health.stdout)['ip'] == '203.0.113.10', 'Fixture did not recover'
        result['fixture_repaired'] = True
        before = provider_count()
        started = time.monotonic()
        guest('approve')
        guest('refresh')
        # An explicitly requested recovery must run before the ten-minute pause.
        deadline = time.monotonic() + 20
        last = guest('status')
        while time.monotonic() < deadline and last['phase'] != 'active':
            time.sleep(1)
            last = guest('status')
        result.update(recovery=last, recovery_seconds=round(time.monotonic()-started, 3),
                      fresh_provider_requests_after_repair=provider_count()-before,
                      same_core_instance=last['instance'] == failed['instance'],
                      mode_unchanged=last['mode'] == failed['mode'] == mode)
        seen = {(r['timestamp'], r['event']) for r in before_events}
        result['failure_and_recovery_events'] = [r for r in guest('events') if (r['timestamp'], r['event']) not in seen]
        for port, prefix in ((22, b'SSH-'), (5900, b'RFB ')):
            with socket.create_connection((fixture['client4'], port), 4) as connection:
                connection.settimeout(4)
                assert connection.recv(100).startswith(prefix)
        result['incoming_services_reachable'] = True
        assert result['same_core_instance'] and result['mode_unchanged']
        assert last['phase'] == 'active' and provider_count() > before, \
            'RECOVERY DEADLOCK: repaired proxy + approved exit + Refresh still blocked behind provider cooldown'
        print('Same-session local failure recovery: PASS', flush=True)
        if fixture.get('test_ipv4_approval'):
            result['additional_failures'] = []
            for name, injection in [('proxy-authentication', {'fault': 'auth'}),
                                    ('proxy-timeout', {'fault': 'stall'}),
                                    ('provider-503', {'status': 503})]:
                control(**injection); guest('refresh')
                faulted = wait(lambda s: s['phase'] == 'blocked' and 'coolingDown' in s['status'])
                assert not faulted['observed'] and not faulted['rejected']
                assert faulted['last_known']['ipAddress'] == '203.0.113.10'
                for port, prefix in ((22, b'SSH-'), (5900, b'RFB ')):
                    with socket.create_connection((fixture['client4'], port), 4) as connection:
                        connection.settimeout(4)
                        assert connection.recv(100).startswith(prefix)
                control(); before = provider_count(); started = time.monotonic()
                guest('refresh')
                recovered = wait(lambda s: s['phase'] == 'active', 25)
                assert recovered['instance'] == faulted['instance'] and recovered['mode'] == mode
                assert provider_count() > before
                healthy(recovered)
                result['additional_failures'].append(dict(fault=name, recovered=True,
                    recovery_seconds=round(time.monotonic()-started, 3), incoming_services=True))
                print(name + ' same-session recovery: PASS', flush=True)
        control(status=429, retry_after=900)
        guest('refresh')
        hard = wait(lambda s: s['phase'] == 'blocked' and 'coolingDown' in s['status'])
        control()
        before = provider_count()
        guest('refresh')
        restricted = wait(lambda s: (s.get('manual') or {}).get('phase') == 'deferred')
        assert restricted['phase'] == 'blocked' and provider_count() == before, \
            'Explicit Retry bypassed a provider Retry-After restriction'
        # Swift encodes enum-keyed dictionaries as alternating key/value arrays;
        # their order can change between otherwise identical XPC snapshots.
        def deadlines(value):
            return value if isinstance(value, dict) else dict(zip(value[::2], value[1::2]))
        assert deadlines(restricted['cooldowns']) == deadlines(hard['cooldowns']), 'Provider deadline was altered'
        result['provider_retry_after_preserved'] = True
        if fixture.get('test_ipv4_approval'):
            records = [json.loads(line) for line in (root / 'fixture/events.jsonl').read_text().splitlines()]
            requests = [r for r in records if r['event'] == 'provider_http']
            assert requests and all(r['family'] == 4 for r in requests), 'Unexpected IPv6 approval HTTP request'
            result['all_provider_requests_ipv4'] = len(requests)
        print('Provider HTTP 429 / Retry-After remains enforced: PASS', flush=True)
        result['result'] = 'PASS'
    except Exception as error:
        result.update(result='FAIL', error=str(error))
        print(str(error), flush=True)
        raise
    finally:
        control()
        if prepared:
            result['cleanup'] = guest('restore')
        save()


if __name__ == '__main__':
    if sys.argv[2] == 'fixture':
        fixture_main()
    elif sys.argv[2] in ('prepare', 'status', 'approve', 'reject', 'mismatch', 'traffic', 'refresh', 'events', 'restore'):
        guest_main()
    else:
        host_main()
