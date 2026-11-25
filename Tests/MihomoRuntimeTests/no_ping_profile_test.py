#!/usr/bin/env python3
"""VM-only true echo-drop qualification, with native LAN/Tailnet controls.

Private root inputs: profile.json and native.json (LAN/Tailnet IPv4/IPv6
addresses keyed by a nonidentifying label). The engine is selected by the
explicit MIMO_TEST_ENGINE and MIMO_TEST_ENGINE_SHA256 environment variables.
No firewall, resolver or installed-service changes are made.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import copy
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

from ipv6_global_profile_test import ENGINE, SHA256, TUN, api, command, dns_state, interface, require_no_engine, stop

BLOCKED = {
    'ipv4_literal': '198.51.100.37',
    'ipv4_fake_ip': '198.18.55.10',
    'ipv6_public': '2606:4700:4700::1111',
    'ipv6_nat64': '64:ff9b::101:101',
    'ipv6_local_nat64': '64:ff9b:1::101:101',
    'ipv6_tun_prefix': 'fdfe:dcba:9876::2',
}


def ping(ip):
    binary = '/sbin/ping6' if ':' in ip else '/sbin/ping'
    return command([binary, '-n', '-c', '2', '-i', '0.2', ip], timeout=3)['status']


def pings(targets):
    with ThreadPoolExecutor(max_workers=len(targets)) as pool:
        return dict(zip(targets, pool.map(ping, targets.values())))


def packet_count(pcap, ip, reply=False):
    family = 'ip6' if ':' in ip else 'ip'
    kind = ('icmp6 and ip6[40] == ' + ('129' if reply else '128')) if ':' in ip else (
        'icmp and icmp[0] == ' + ('0' if reply else '8'))
    bpf = family + ' and ' + ('src' if reply else 'dst') + ' host ' + ip + ' and ' + kind
    result = command(['/usr/sbin/tcpdump', '-nn', '-r', str(pcap), bpf])
    assert result['status'] == 0, 'Could not read packet capture'
    return len(result['stdout'].splitlines())


def run(root):
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    assert root.stat().st_uid == 0 and root.stat().st_mode & 0o077 == 0
    assert hashlib.sha256(Path(ENGINE).read_bytes()).hexdigest() == SHA256
    require_no_engine()
    assert command(['/sbin/ifconfig', TUN])['status'] != 0
    native = json.loads((root / 'native.json').read_text())
    assert set(native) == {'lan_ipv4', 'lan_ipv6', 'tailnet_ipv4', 'tailnet_ipv6'}
    for ip in native.values():
        ipaddress.ip_address(ip)
    baseline_dns = dns_state()
    routes = {key: interface(ip) for key, ip in {**native, **BLOCKED}.items()}
    assert routes['lan_ipv4'] == routes['lan_ipv6'] == 'en0'
    assert routes['tailnet_ipv4'] == routes['tailnet_ipv6']
    assert routes['tailnet_ipv4'].startswith('utun')
    report = {'tested_at_utc': datetime.now(timezone.utc).isoformat(),
              'engine_sha256': SHA256, 'engine_version': command([ENGINE, '-v'])['stdout'].strip(),
              'scope': 'Captured echoes drop; native LAN/Tailnet echoes remain real.',
              'checks': {}, 'baseline_native_ping_status': pings(native)}
    checks = report['checks']
    checks['native_ping_baseline'] = all(status == 0 for status in report['baseline_native_ping_status'].values())
    assert checks['native_ping_baseline'], 'Native ping baseline failed'
    profile = json.loads((root / 'profile.json').read_text())
    assert profile['mode'] == 'global' and profile['rules'] == []
    assert profile['tun']['stack'] == 'gvisor-no-ping'
    config = copy.deepcopy(profile)
    config['tun']['device'] = TUN
    config['external-controller-unix'] = str(root / 'controller.sock')
    # No destination service is needed for an echo-drop policy.
    config['proxies'][0].update(server='127.0.0.1', port=1)
    path = root / 'config.json'
    path.write_text(json.dumps(config))
    path.chmod(0o600)
    stock = '/opt/homebrew/opt/mihomo@1.19.34/bin/mihomo'
    stock_result = command([stock, '-t', '-d', str(root), '-f', str(path)])
    checks['stock_rejects_unsupported_stack'] = stock_result['status'] != 0 and 'invalid tun stack' in (
        stock_result['stdout'] + stock_result['stderr']).lower()
    engine = guard = None
    captures = []
    log = (root / 'engine.log').open('w')
    try:
        assert command([ENGINE, '-t', '-d', str(root), '-f', str(path)])['status'] == 0
        engine = subprocess.Popen([ENGINE, '-d', str(root), '-f', str(path)],
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        guard = subprocess.Popen(['/usr/bin/python3', str(root / 'ipv6_global_profile_test.py'),
            '--watchdog', str(engine.pid), str(path)], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            assert engine.poll() is None, 'Engine exited'
            if (root / 'controller.sock').exists() and interface(BLOCKED['ipv6_public']) == TUN:
                break
            time.sleep(0.1)
        checks['global_zero_rules'] = api(root, '/configs').get('mode') == 'global' and api(root, '/rules').get('rules') == []
        checks['no_ping_stack'] = api(root, '/configs').get('tun', {}).get('stack') == 'gvisor-no-ping'
        checks['blocked_targets_captured'] = all(interface(ip) == TUN for ip in BLOCKED.values())
        checks['native_routes_preserved'] = all(interface(ip) == routes[key] for key, ip in native.items())
        checks['dns_unchanged'] = dns_state() == baseline_dns
        assert all(checks.values()), 'Startup invariant failed'
        for nic in ['en0', routes['tailnet_ipv4'], TUN]:
            pcap = root / (nic + '.pcap')
            err = (root / (nic + '-capture.log')).open('w')
            proc = subprocess.Popen(['/usr/sbin/tcpdump', '-nn', '-U', '-i', nic, '-s', '128',
                '-w', str(pcap), 'icmp or icmp6'], stdout=subprocess.DEVNULL, stderr=err)
            captures.append((nic, proc, err, pcap))
        time.sleep(0.5)
        assert all(p.poll() is None for _, p, _, _ in captures), 'Capture failed'
        report['blocked_ping_status'] = pings(BLOCKED)
        report['native_ping_status'] = pings(native)
        checks['all_captured_pings_fail'] = all(status != 0 for status in report['blocked_ping_status'].values())
        checks['native_pings_succeed'] = all(status == 0 for status in report['native_ping_status'].values())
        time.sleep(0.3)
    except Exception as error:
        report['error'] = str(error)
    finally:
        packets = report['packets'] = {}
        for nic, process, err, pcap in captures:
            stop(process, signal.SIGINT)
            err.close()
            packets[nic] = {key: {'requests': packet_count(pcap, ip), 'replies': packet_count(pcap, ip, True)}
                for key, ip in {**BLOCKED, **native}.items()}
        stop(engine)
        stop(guard)
        log.close()
        path.unlink(missing_ok=True)
        time.sleep(0.3)
        checks['captured_requests_seen'] = bool(captures) and all(packets[TUN][key]['requests'] == 2 for key in BLOCKED)
        checks['no_synthetic_replies'] = bool(captures) and all(packets[TUN][key]['replies'] == 0 for key in BLOCKED)
        checks['no_native_forwarding'] = bool(captures) and all(packets[nic][key]['requests'] == 0 for nic in packets if nic != TUN for key in BLOCKED)
        checks['native_echoes_bypass_tun'] = bool(captures) and all(packets[TUN][key]['requests'] == packets[TUN][key]['replies'] == 0 for key in native)
        checks['native_echoes_real'] = bool(captures) and all(packets[routes[key]][key]['requests'] > 0 and packets[routes[key]][key]['replies'] > 0 for key in native)
        checks['routes_restored'] = all(interface(ip) == routes[key] for key, ip in {**native, **BLOCKED}.items())
        checks['dns_restored'] = dns_state() == baseline_dns
        checks['tun_removed'] = command(['/sbin/ifconfig', TUN])['status'] != 0
        report['native_ping_after_cleanup'] = pings(native)
        checks['native_pings_after_cleanup'] = all(status == 0 for status in report['native_ping_after_cleanup'].values())
        report['passed'] = not report.get('error') and all(checks.values())
        (root / 'report.json').write_text(json.dumps(report, indent=2))
        print(json.dumps({'passed': report['passed'], 'checks': checks, 'error': report.get('error')}), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(run(Path(sys.argv[1])))
