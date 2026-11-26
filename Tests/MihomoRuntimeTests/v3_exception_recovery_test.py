#!/usr/bin/env python3
"""Installed VM exception/recovery campaign, controlled through Tart.

Run on Delta with: private-evidence-directory guest-directory.
Requires the closed SOCKS fixture, its trusted test certificate and signed XPC
controls. Only a disposable fixture token is used; it is removed BEFORE Direct
so it cannot be sent to a public provider. Existing credentials are never replaced.
The separate coordinator suite tests Direct cancellation during a pending lookup.
"""
import itertools
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request
import uuid

NAME = 'Incoming access qualification'


def guest_main():
    import v3_installed_test as t
    root = Path(sys.argv[1])
    marker = root / 'exception-token-owned'
    fixture = json.loads((root / 'fixture.json').read_text())
    operation = sys.argv[2]
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)

    def remove_token():
        if t.state()['hasIPinfoToken']:
            assert marker.exists(), 'Refusing to overwrite an existing IPinfo credential'
            t.request('removeToken')
        marker.unlink(missing_ok=True)

    def direct():
        remove_token()
        started = time.monotonic()
        t.route('direct')
        t.wait_active('direct', 30)
        assert time.monotonic() - started < 20, 'Direct recovery exceeded its bound'
        assert not t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr']).stdout.strip()
        assert '1053' not in t.run(['/usr/sbin/scutil', '--dns']).stdout
        return round(time.monotonic() - started, 3)

    def proxy(refused=False):
        existing = next(p for p in t.state()['routing']['configuration']['proxies'] if p['proxy']['name'] == NAME)
        value = dict(existing['proxy'], port=fixture['refused_port'] if refused else fixture['proxy_port'])
        t.request('saveProxy', proxyID=existing['id'], proxy=value, proxyPassword='')

    if operation == 'prepare':
        remove_token()
        settings = t.state()['settings']
        settings.update(provider='ipinfoLite', providerPool=['ipinfoLite'], refreshInterval=-1,
                        bypassBlocks=[], allowlist={'addresses': ['203.0.113.10']})
        t.request('configure', settings=settings)
        direct()
        proxy(sys.argv[3] == 'refused')
        addresses = {'empty': [], 'reject4': ['192.0.2.1']}.get(sys.argv[3], ['203.0.113.10'])
        settings['allowlist'] = {'addresses': addresses}
        t.request('configure', settings=settings)
    elif operation in ('start', 'repair'):
        assert not t.state()['hasIPinfoToken'] or marker.exists()
        if operation == 'repair':
            proxy()
            settings = t.state()['settings']
            settings['allowlist'] = {'addresses': ['203.0.113.10']}
            t.request('configure', settings=settings)
        t.route(sys.argv[3], sys.argv[4])
        assert t.state()['routing']['configuration']['mode'] != 'direct'
        marker.write_text('fixture-only disposable credential\n')
        t.request('setToken', token='mimo-local-qualification-' + uuid.uuid4().hex)
    elif operation == 'direct':
        elapsed = direct()
        for address in (fixture['data4'], fixture['data6']):
            host = '[' + address + ']' if ':' in address else address
            url = 'http://' + host + ':' + str(fixture['http_port']) + '/' + fixture['token'] + '/direct-recovery'
            value = t.run(['/usr/bin/curl', '--noproxy', '*', '--fail', '-sS', '--max-time', '4', url], 6)
            assert value.returncode == 0, 'Native HTTP failed after Direct'
        print(json.dumps(dict(direct_seconds=elapsed, native_http4=True, native_http6=True,
                              empty_pf=True, dns_released=True)))
        return
    elif operation == 'events':
        result = t.request('events')
        records = [json.loads(line) for line in result.get('diagnosticEvents', [])]
        print(json.dumps([dict(event=r['event'], timestamp=r['timestamp']) for r in records]))
        return
    elif operation != 'status':
        raise AssertionError('Unknown operation')
    value = t.state()
    routing = value['routing']
    print(json.dumps(dict(phase=routing['phase'], mode=routing['configuration']['mode'],
                         effective=routing.get('effectiveMode'), reason=routing['reason'],
                         status=value['status'], manual=value.get('manualRefresh'),
                         lookup_error=value['indicators'].get('errorMessage'),
                         blockingIP=routing.get('blockingIP'), services=routing['services'],
                         instance=value['instanceID'])))


def host_main():
    root, guest_root = Path(sys.argv[1]), sys.argv[2]
    assert socket.gethostname().split('.')[0] == 'delta'
    assert root.stat().st_mode & 0o077 == 0
    fixture = json.loads((root / 'exceptions-fixture/fixture.json').read_text())
    repo = Path(__file__).resolve().parents[2]
    results = []
    latencies = []

    def guest(operation, *args):
        started = time.monotonic()
        command = [sys.executable, str(repo / 'Scripts/vm-console-admin.py'), '/usr/bin/python3',
                   guest_root + '/' + Path(__file__).name, guest_root, operation, *args]
        value = subprocess.run(command, capture_output=True, text=True, timeout=175)
        (root / ('exception-' + operation + '-last.log')).write_text(value.stdout + value.stderr)
        assert value.returncode == 0, operation + ' failed; inspect private log'
        if operation == 'status':
            latencies.append(time.monotonic() - started)
            assert latencies[-1] < 5, 'Core/Tart status response exceeded five seconds'
        return json.loads(value.stdout.strip().splitlines()[-1])

    def control(fault=''):
        body = dict(fault='auth' if fault == 'auth' else '', provider_status=503 if fault == 'provider503' else 200,
                    proxy_off=False, disconnect=True)
        request = urllib.request.Request('http://' + fixture['bridge4'] + ':' + str(fixture['control_port']),
                                         json.dumps(body).encode(), headers={'Authorization': 'Bearer ' + fixture['token']})
        with urllib.request.urlopen(request, timeout=4):
            pass

    def wait(predicate, timeout=95):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            value = guest('status')
            if predicate(value):
                return value
            time.sleep(.6)
        raise AssertionError('State did not settle: ' + json.dumps(value))

    def incoming():
        for port, prefix in ((22, b'SSH-'), (5900, b'RFB ')):
            with socket.create_connection((fixture['client4'], port), 4) as connection:
                connection.settimeout(4)
                assert connection.recv(100).startswith(prefix), 'Incoming service did not respond'

    try:
        for family, mode in itertools.product(('ipv4', 'dual'), ('rule', 'global')):
            faults = ['refused', 'auth', 'provider503', 'empty', 'reject4']
            for fault in faults:
                label = family + '-direct-to-' + mode + '-' + fault
                control(fault)
                guest('prepare', fault)
                guest('start', mode, family)
                blocked = wait(lambda s: s['phase'] == 'blocked' and
                               (bool(s['blockingIP']) or any(k in s['status'] for k in ('failed', 'coolingDown', 'providerPaused'))))
                assert blocked['effective'] is None and blocked['mode'] == mode
                if fault in ('empty', 'reject4'):
                    expected = {'empty': 'No exit IPs are approved', 'reject4': 'IPv4 exit IP is not approved'}[fault]
                    assert expected in blocked['reason']
                else:
                    assert blocked['lookup_error'], 'Paused failure must retain the lookup error'
                incoming()
                before = guest('events')
                # Poll beyond one independent ten-second service audit. Reading
                # state must not schedule a lookup or restart healthy services.
                until = time.monotonic() + 12
                while time.monotonic() < until:
                    current = guest('status')
                    assert current['phase'] == 'blocked' and current['instance'] == blocked['instance']
                    time.sleep(.8)
                after = guest('events')
                key = lambda e: (e['timestamp'], e['event'])
                seen = {key(e) for e in before}
                retries = [e for e in after if key(e) not in seen and e['event'] in ('lookup_started', 'mimo_traffic_opened')]
                assert not retries, 'Unexpected retry/open loop in settled failure'
                incoming()
                escaped = guest('direct')  # fault still present
                control()
                guest('repair', mode, family)
                recovered = wait(lambda s: s['phase'] == 'active' and s['effective'] == mode)
                incoming()
                results.append(dict(id=label, result='PASS', reason=blocked['reason'], lookup_status=blocked['status'], lookup_error=blocked['lookup_error'],
                                    settled_poll_seconds=12, automatic_lookup_or_open_events=0,
                                    incoming_ssh=True, incoming_screen_sharing=True,
                                    same_core_instance=True, repaired_and_verified=True, **escaped))
                (root / 'exception-results.json').write_text(json.dumps(results, indent=2))
                print(label + ': PASS', flush=True)
                guest('direct')
    finally:
        control()
        guest('direct')
        (root / 'exception-responsiveness.json').write_text(json.dumps(dict(
            samples=len(latencies), max_status_seconds=round(max(latencies, default=0), 3),
            passed_cases=len(results), expected_cases=22), indent=2))


if __name__ == '__main__':
    if sys.argv[2] in ('prepare', 'start', 'repair', 'direct', 'events', 'status'):
        guest_main()
    else:
        host_main()
