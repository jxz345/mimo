#!/usr/bin/env python3
"""VM-only production XPC/engine/PF integration; results stay owner-only."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

ROOT = Path(sys.argv[1])
CONTROLS = str(ROOT / 'controls')
SOCKET = '/Library/Application Support/Mimo/Mihomo/controller.sock'
ANCHOR = 'com.apple/000.mimo'
report = {'cases': [], 'states': [], 'scope': 'installed production v3 app'}


def run(args, timeout=90):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def state():
    value = run([CONTROLS], 12)
    assert value.returncode == 0, value.stderr[-1000:]
    return json.loads(value.stdout)['state']


def request(command, **fields):
    path = ROOT / 'request.json'
    path.write_text(json.dumps(dict(command=command, protocolVersion=8, **fields)))
    path.chmod(0o600)
    value = run([CONTROLS, 'request', str(path)], 90)
    assert value.returncode == 0, value.stderr[-1000:]
    result = json.loads(value.stdout)
    assert not result.get('failure'), result.get('failure')
    return result


def route(mode, family=None):
    config = state()['routing']['configuration']
    config['mode'] = mode
    if family: config['networkFamily'] = family
    request('configureRouting', routing=config)


def wait_active(mode, timeout=55):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        last = state()
        r = last['routing']
        if r['phase'] == 'active' and r.get('effectiveMode') == mode:
            report['states'].append(last)
            return last
        time.sleep(.4)
    report['states'].append(last)
    raise AssertionError('Activation timed out: ' + last['routing']['reason'])


def api(path, method='GET'):
    value = run(['/usr/bin/curl', '-sS', '--max-time', '8', '--unix-socket', SOCKET,
                 '-X', method, 'http://localhost' + path], 10)
    assert value.returncode == 0, value.stderr
    return json.loads(value.stdout) if value.stdout else None


def check(name, valid, **details):
    report['cases'].append(dict(id=name, passed=bool(valid), **details))
    (ROOT / 'report.json').write_text(json.dumps(report, indent=2))
    print(name + ': ' + ('PASS' if valid else 'FAIL'), flush=True)
    assert valid, name


def active_guard(rules):
    lines = rules.splitlines()
    return (bool(lines) and lines[-1] == 'block drop out quick all label "mimo:active:deny-native-fallback"'
            and 'mimo:active:tunnel' in rules and 'mimo:active:engine' in rules
            and all('no state' in line for line in lines if line.startswith('pass out '))
            and 'pass in on ! utun239 proto tcp all flags S/SA keep state (if-bound) label "mimo:inbound:tcp"' in lines
            and 'pass in on lo0 all no state label "mimo:inbound:loopback"' in lines
            and not any(line.startswith('anchor ') for line in lines))


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    f = json.loads((ROOT / 'fixture.json').read_text())
    original = state()
    # Preserve the pre-fixture snapshot across failed/retried campaigns.
    if not (ROOT / 'before.json').exists():
        (ROOT / 'before.json').write_text(json.dumps(original))
    settings = original['settings']
    settings.update(provider='ipWhois', providerPool=['ipWhois'], refreshInterval=-1,
                    allowlist={'addresses': ['203.0.113.10']}, bypassBlocks=[])
    request('configure' if original['initialized'] else 'initialize', settings=settings)
    name = 'V3 local qualification'
    existing = next((p for p in state()['routing']['configuration'].get('proxies', []) if p['proxy']['name'] == name), None)
    request('saveProxy', proxy={'name': name, 'type': 'socks5', 'server': f['bridge4'],
                              'port': f['proxy_port'], 'username': ''},
            **({'proxyID': existing['id']} if existing else {}), proxyPassword='')
    saved = next(p for p in state()['routing']['configuration']['proxies'] if p['proxy']['name'] == name)
    request('selectProxy', proxyID=saved['id'])
    try:
        for family in ('ipv4', 'dual'):
            for mode in ('rule', 'global'):
                label = family + '-' + mode
                route(mode, family)
                active = wait_active(mode)
                check(label + '-approved', active['routing']['configuration']['networkFamily'] == family)
                observations = active['routing'].get('exitObservations') or {}
                verification = observations.get('verification') or {}
                v4, v6 = observations.get('ipv4') or {}, observations.get('ipv6')
                fresh = v4.get('ipAddress') == '203.0.113.10' and v4.get('checkedAt', 0) >= verification.get('startedAt', float('inf'))
                check(label + '-fresh-ipv4-approval', fresh and v6 is None)
                live = api('/configs')
                check(label + '-actual-engine-mode', live['mode'] == mode and live['mimo-destination-family'] == family)
                rules = run(['/sbin/pfctl', '-a', ANCHOR, '-sr'])
                check(label + '-active-fallback-guard', rules.returncode == 0 and active_guard(rules.stdout))
                dns = run(['/usr/sbin/scutil', '--dns'])
                check(label + '-owned-dns', '1053' in dns.stdout)
                providers = api('/providers/proxies').get('providers', {})
                # Mihomo exposes inline proxies through its built-in Compatible
                # provider. The removed feature is the external native provider,
                # not this engine-internal representation of ordinary proxies.
                check(label + '-no-external-native-provider', all(
                    v.get('vehicleType') == 'Compatible' and name not in ('tailscale-live', 'TS-NATIVE') and
                    all(p.get('name') != 'TS-NATIVE' for p in v.get('proxies', []))
                    for name, v in providers.items()))
                for af, host in [(4, f['data4']), (6, '2001:db8:33::10')]:
                    url = 'https://' + ('[' + host + ']' if af == 6 else host) + ':' + str(f['https_port']) + '/' + f['token'] + '/' + label
                    response = run(['/usr/bin/curl', '--noproxy', '*', '--cacert', str(ROOT / 'server.crt'), '-sS', '--max-time', '5', url], 7)
                    allowed = af == 4 or family == 'dual'
                    body = json.loads(response.stdout) if response.returncode == 0 else {}
                    check(label + '-https' + str(af), (response.returncode == 0) == allowed and
                          (not allowed or body.get('family') == af), exit_status=response.returncode)
                # Refresh must produce new observations, not just redisplay cached status.
                old = active['routing'].get('exitObservations')
                request('refresh')
                deadline = time.monotonic() + 55
                refreshed = None
                while time.monotonic() < deadline:
                    refreshed = state()['routing']
                    if refreshed['phase'] == 'active' and refreshed.get('exitObservations') != old: break
                    time.sleep(.4)
                new = refreshed.get('exitObservations') or {}
                check(label + '-refresh-fresh', refreshed['phase'] == 'active' and
                      new.get('verification', {}).get('id') != (old or {}).get('verification', {}).get('id') and
                      new.get('ipv4', {}).get('checkedAt', 0) > (old or {}).get('ipv4', {}).get('checkedAt', 0) and
                      (family == 'ipv4' or new.get('ipv6', {}).get('checkedAt', 0) > (old or {}).get('ipv6', {}).get('checkedAt', 0)))
                route('direct')
                wait_active('direct')
                check(label + '-direct-empty-pf', not run(['/sbin/pfctl', '-a', ANCHOR, '-sr']).stdout.strip())
                check(label + '-direct-dns-removed', '1053' not in run(['/usr/sbin/scutil', '--dns']).stdout)
    finally:
        try:
            route('direct'); wait_active('direct')
        except Exception as error:
            report['recovery_error'] = str(error)
            run(['/Library/PrivilegedHelperTools/mimo-core', '--restore-direct-offline'], 90)
        report['completed_at'] = time.time()
        (ROOT / 'report.json').write_text(json.dumps(report, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        report['error'] = str(error)
        (ROOT / 'report.json').write_text(json.dumps(report, indent=2))
        raise
