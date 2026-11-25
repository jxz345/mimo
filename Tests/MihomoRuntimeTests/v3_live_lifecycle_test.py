#!/usr/bin/env python3
"""Human-operated Tailscale and real sleep checks in the isolated installed VM.

Uses the existing closed fixture and packet detector. Commands arrive as an
atomically replaced action.json; raw observations and names stay owner-only.
Never toggles Tailscale or synthesizes a power event on the operator's behalf.
"""
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time
from urllib.parse import quote

import v3_installed_test as t
import v3_fault_traffic_test as ft

ROOT = Path(sys.argv[1])
TS = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'


def write(name, value):
    temporary = ROOT / (name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2))
    temporary.replace(ROOT / name)


def tailscale():
    result = t.run([TS, 'status', '--json'], 6)
    return json.loads(result.stdout) if result.returncode == 0 else {}


def stats():
    output = t.run(['/usr/bin/pmset', '-g', 'stats'], 5).stdout
    return {k: int(v) for k, v in re.findall(r'^([^:\n]+):\s*(\d+)$', output, re.M)}


def snapshot():
    state = t.state()
    ts = tailscale()
    result = t.run([TS, 'debug', 'prefs'], 6)
    prefs = json.loads(result.stdout) if result.returncode == 0 else {}
    pf = t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-vvsr'], 5)
    sample = dict(at=time.time(), state=state, tailscale=ts,
                  tailscale_want_running=prefs.get('WantRunning'), pf=pf.stdout,
                  dns=t.run(['/usr/sbin/scutil', '--dns'], 5).stdout)
    with (ROOT / 'samples.jsonl').open('a') as stream:
        stream.write(json.dumps(sample) + '\n')
    routing = state['routing']
    return dict(at=sample['at'], phase=routing.get('phase'),
                mode=routing['configuration']['mode'],
                family=routing['configuration']['networkFamily'],
                effective_mode=routing.get('effectiveMode'),
                tailscale=ts.get('BackendState'), tailscale_want_running=prefs.get('WantRunning'),
                observation_deadline=json.loads((ROOT / 'deadline.json').read_text())['at'],
                pf_kind=ft.pf_kind())


def checkpoint(label, peer):
    host = peer['DNSName']
    expected = set(peer['TailscaleIPs'])
    checks = {}
    answers = {}
    for kind in ('A', 'AAAA'):
        for attempt in range(3):
            key = kind + '-fresh-' + str(attempt + 1)
            try:
                t.api('/cache/dns/flush', 'POST')
                answer = t.api('/dns/query?name=' + quote(host) + '&type=' + kind)
            except (AssertionError, subprocess.TimeoutExpired, ValueError) as error:
                checks[key] = False
                answers[key] = {'request_error': type(error).__name__}
                continue
            answers[key] = answer
            values = {item.get('data') for item in (answer or {}).get('Answer', [])
                      if item.get('type') == (1 if kind == 'A' else 28)}
            checks[key] = (
                (answer or {}).get('Status') == 0 and values == set(peer['native_dns'][kind]))
    for protocol in ('+tcp', '+notcp'):
        result = t.run(['/usr/bin/dig', '@127.0.0.1', '-p', '1053', host, 'A',
                        protocol, '+time=2', '+tries=1', '+short'], 5)
        checks['local-' + protocol[1:]] = bool(expected.intersection(result.stdout.split()))
    for family in (4, 6):
        address = next((a for a in expected if (':' in a) == (family == 6)), None)
        if address:
            command = (['/sbin/ping', '-n', '-c', '1', '-W', '1500', address] if family == 4
                       else ['/sbin/ping6', '-n', '-c', '1', address])
            try:
                checks['native-ping' + str(family)] = t.run(command, 3).returncode == 0
            except subprocess.TimeoutExpired:
                checks['native-ping' + str(family)] = False
    result = dict(label=label, at=time.time(), snapshot=snapshot(), checks=checks, dns=answers)
    write(label + '.json', result)
    return result


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert t.run(['/usr/sbin/sysctl', '-n', 'hw.model'], 5).stdout.startswith('VirtualMac')
    os.umask(0o077)
    original = t.state()
    assert original['routing']['configuration']['mode'] == 'direct'
    write('deadline.json', {'at': time.time() + 7200, 'duration_seconds': 7200})
    write('before.json', original)
    peer = next(p for p in tailscale().get('Peer', {}).values()
                if p.get('Online') and p.get('DNSName') and p.get('TailscaleIPs'))
    peer['native_dns'] = {}
    for kind in ('A', 'AAAA'):
        native = t.run(['/usr/bin/dig', '@100.100.100.100', peer['DNSName'], kind,
                        '+tcp', '+time=2', '+tries=1', '+noall', '+comments', '+answer'], 5)
        assert native.returncode == 0 and 'status: NOERROR' in native.stdout
        peer['native_dns'][kind] = [line.split()[-1] for line in native.stdout.splitlines()
                                    if line and not line.startswith(';') and kind in line.split()]
    assert set(peer['native_dns']['A']).intersection(peer['TailscaleIPs'])
    write('peer.json', peer)
    offsets = {str(p): p.stat().st_size for p in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl')}
    write('log-offsets.json', offsets)
    log = (ROOT / 'watchdog.log').open('w')
    subprocess.Popen(['/usr/bin/python3', str(ROOT / 'v3_fault_watchdog.py'), str(ROOT), str(os.getpid()), '7200'],
                     stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    created_pflog = t.run(['/sbin/ifconfig', 'pflog0'], 5).returncode != 0
    traffic = None
    selected = None
    try:
        if created_pflog:
            assert t.run(['/sbin/ifconfig', 'pflog0', 'create'], 5).returncode == 0
        ft.containment()
        control = ft.Traffic('direct-detector-control')
        time.sleep(2)
        detected = control.finish()
        write('detector.json', dict(counts={str(af): sum(p['family'] == af for p in detected) for af in (4, 6)}))
        assert all(any(p['family'] == af for p in detected) for af in (4, 6))
        settings = dict(original['settings'], provider='ipWhois', providerPool=['ipWhois'],
                        refreshInterval=-1, allowlist={'addresses': ['203.0.113.10', '2001:db8::10']}, bypassBlocks=[])
        t.request('configure', settings=settings)
        t.request('saveProxy', proxy={'name': 'V3 live lifecycle qualification', 'type': 'socks5',
                  'server': ft.F['bridge4'], 'port': ft.F['proxy_port'], 'username': ''}, proxyPassword='')
        selected = next(p['id'] for p in t.state()['routing']['configuration']['proxies']
                        if p['proxy']['name'] == 'V3 live lifecycle qualification')
        t.request('selectProxy', proxyID=selected)
        t.route('rule', 'dual')
        ft.approved('rule', 'dual')
        baseline = checkpoint('connected-baseline', peer)
        assert all(baseline['checks'].values()), 'Native baseline failed; inspect before asking operator to disconnect'
        traffic = ft.Traffic('manual-lifecycle')
        write('status.json', dict(stage='READY_FOR_TAILSCALE_DISCONNECT', **snapshot()))
        print('READY_FOR_TAILSCALE_DISCONNECT', flush=True)
        last_action = None
        while True:
            path = ROOT / 'action.json'
            if path.exists():
                action = json.loads(path.read_text())
                if action['id'] != last_action:
                    last_action = action['id']
                    command = action['command']
                    if command == 'finish':
                        break
                    elif command == 'checkpoint':
                        result = checkpoint(action['label'], peer)
                    elif command == 'mode':
                        if traffic:
                            packets = traffic.finish()
                            write('traffic-through-' + action['id'] + '.json', dict(
                                  at=time.time(), native_attempts=len(packets),
                                  by_family={str(af): sum(p['family'] == af for p in packets) for af in (4, 6)}))
                            traffic = None
                        t.route(action['mode'], action.get('family'))
                        if action['mode'] == 'direct':
                            t.wait_active('direct', 100)
                        else:
                            ft.approved(action['mode'], action['family'])
                            traffic = ft.Traffic('manual-lifecycle-' + action['id'])
                        result = snapshot()
                    elif command == 'prepare-sleep':
                        result = dict(stats=stats(), state=t.state(), at=time.time())
                    elif command == 'finish-sleep':
                        result = dict(stats=stats(), state=t.state(), at=time.time())
                    else:
                        raise ValueError('Unknown action')
                    write('action-' + action['id'] + '.json', result)
                    write('status.json', dict(stage='OBSERVING', last_action=last_action, **snapshot()))
            time.sleep(2)
            write('status.json', dict(stage='OBSERVING', last_action=last_action, **snapshot()))
    finally:
        if traffic:
            packets = traffic.finish()
            write('traffic-summary.json', dict(native_attempts=len(packets),
                  by_family={str(af): sum(p['family'] == af for p in packets) for af in (4, 6)}))
        t.route('direct')
        t.wait_active('direct', 100)
        t.run(['/sbin/pfctl', '-a', ft.LAB, '-F', 'rules'], 5)
        t.request('configure', settings=original['settings'])
        original_config = original['routing']['configuration']
        t.request('selectProxy', **({'proxyID': original_config['activeProxyID']} if original_config.get('activeProxyID') else {}))
        if selected:
            t.request('removeProxy', proxyID=selected)
        t.request('configureRouting', routing=original_config)
        t.wait_active('direct', 100)
        if created_pflog:
            t.run(['/sbin/ifconfig', 'pflog0', 'destroy'], 5)
        write('restored.json', dict(at=time.time(), settings=t.state()['settings'] == original['settings'],
              configuration=t.state()['routing']['configuration'] == original_config))


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
