#!/usr/bin/env python3
"""Installed build 6 validation; only mimo-vm. Saved proxy/allowlist are not changed.

Stage beside acceptance-client and installation-check. `start` detaches a runner
and an independent cleanup watchdog so a closed transition cannot strand SSH.
Raw state and command failures stay in the root-only guest evidence directory.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent
ROOT = Path('/var/root/mimo-build6-acceptance')
APP = Path('/Applications/Mimo.app')
SUPPORT = Path('/Library/Application Support/Mimo')
ANCHOR = 'com.apple/000.mimo'
SOCKET = str(SUPPORT / 'Mihomo/controller.sock')
DNS = 'State:/Network/Service/com.mimo.dns/DNS'
JOBS = ['com.mimo.infrastructure', 'com.mimo.pf-boot', 'com.mimo.core', 'com.mimo.mihomo', 'com.mimo.supervisor']
assert socket.gethostname().startswith('mimo-vm') and os.geteuid() == 0

def cmd(*args, check=True, input=None, timeout=180):
    result = subprocess.run(list(map(str, args)), input=input, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        (ROOT / 'last-command.log').write_text(result.stdout + result.stderr)
        raise AssertionError('Command failed: ' + str(args[0]) + '; details retained privately in VM')
    return result

def record(message):
    print('PASS:', message, flush=True)

def daemon(operation):
    result = cmd('/bin/bash', APP / 'Contents/Resources/daemon.sh', operation, check=False, timeout=240)
    (ROOT / (operation + '.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, operation + ' failed; private installer log'
    return result.stdout

def client(*args):
    return json.loads(cmd(BASE / 'acceptance-client', *args, timeout=60).stdout)

def wait_ready(mode, seconds=100):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            state = client('state')
            (ROOT / 'last-state.json').write_text(json.dumps(state))
            routing = state['routing']
            if mode != 'direct' and routing['phase'] in ['checking', 'blocked']:
                try:
                    config = controller('configs')
                    if not config.get('tun', {}).get('enable'): continue
                    (ROOT / 'live-config.json').write_text(json.dumps(config))
                    detail = {}
                    for label, args in [('tunnel', ['/sbin/ifconfig', 'utun239']),
                                        ('v6route', ['/sbin/route', '-n', 'get', '-inet6', '2001:db8::1']),
                                        ('v4route', ['/sbin/route', '-n', 'get', '198.51.100.1']),
                                        ('probe', ['/sbin/pfctl', '-a', ANCHOR + '/probe-policy', '-vvsr'])]:
                        detail[label] = cmd(*args, check=False).stdout
                    (ROOT / 'live-details.json').write_text(json.dumps(detail))
                except (AssertionError, ValueError): pass
            if routing['phase'] == 'active' and routing.get('effectiveMode') == mode:
                # Core replies can precede completion of the separate supervisor
                # command. Require the live gate and PF readback as well.
                gate = (SUPPORT / 'Runtime/gate.state').read_text()
                expected = '' if mode == 'direct' else 'anchor "power-guard" out quick all'
                if gate == ('direct' if mode == 'direct' else 'active') and pf() == expected:
                    return
        except (ValueError, AssertionError, KeyError):
            pass
        time.sleep(1)
    raise AssertionError(mode + ' did not become active; private last-state.json')

def pf(path=ANCHOR, option='-sr'):
    return cmd('/sbin/pfctl', '-a', path, option).stdout.strip()

def controller(path, method=None):
    args = ['/usr/bin/curl', '--fail', '--silent', '--show-error', '--max-time', '10', '--unix-socket', SOCKET]
    if method: args += ['-X', method]
    response = cmd(*args, 'http://localhost/' + path).stdout
    return json.loads(response) if response else None

def dns_absent():
    assert 'No such key' in cmd('/usr/sbin/scutil', input='show ' + DNS + '\n').stdout

def direct():
    client('mode', 'direct'); wait_ready('direct')
    assert pf() == ''
    dns_absent()
    assert not (SUPPORT / 'Runtime/ipv6-original.plist').exists()
    record('Direct has no Mimo packet rules, DNS override or new IPv6 preferences journal')

def protected(mode):
    client('mode', mode); wait_ready(mode)
    assert pf() == 'anchor "power-guard" out quick all'
    assert pf(ANCHOR + '/power-guard') == ''
    assert pf(ANCHOR + '/open-policy') == ''
    probe = pf(ANCHOR + '/probe-policy')
    assert 'mimo:probe:proxy' in probe and 'mimo:probe:deny' in probe
    for line in probe.splitlines():
        if line.startswith(('pass ', 'block ')): assert 'label "mimo:' in line
    configs = controller('configs')
    (ROOT / 'config.json').write_text(json.dumps(configs))
    assert configs['ipv6'] is True
    for address in ['198.51.100.1', '2001:db8::1']:
        family = '-inet6' if ':' in address else '-inet'
        assert 'interface: utun239' in cmd('/sbin/route', '-n', 'get', family, address).stdout
    assert 'inet6 fdfe:dcba:9876::1' in cmd('/sbin/ifconfig', 'utun239').stdout
    assert any(r.get('type') == 'IPCIDR' and r.get('payload') == '::/0' and r.get('proxy') == 'REJECT'
               for r in controller('rules')['rules'])
    # gVisor can complete the local TCP handshake before Mihomo evaluates the
    # flow. Require a real TLS/HTTP exchange to fail, not connect(2) alone.
    ipv6 = cmd('/usr/bin/curl', '--noproxy', '*', '--ipv6', '--fail', '--silent',
               '--show-error', '--max-time', '5',
               '--resolve', 'one.one.one.one:443:[2606:4700:4700::1111]',
               'https://one.one.one.one/cdn-cgi/trace', check=False)
    assert ipv6.returncode != 0 and not ipv6.stdout, 'IPv6 transferred application data'
    cmd('/usr/bin/curl', '--fail', '--silent', '--max-time', '15', 'https://example.com')
    record(mode + ': empty active firewall; both TUN routes; IPv6 rejected; HTTPS works')

def magicdns():
    route = cmd('/sbin/route', '-n', 'get', '100.100.100.100').stdout
    native = re.search(r'interface:\s*(utun\d+)', route)[1]
    own = re.search(r'\binet (100\.\d+\.\d+\.\d+)', cmd('/sbin/ifconfig', native).stdout)[1]
    ptr = cmd('/usr/bin/dig', '@100.100.100.100', '-x', own, '+tcp', '+short', '+time=3', '+tries=1').stdout
    name = next(n.rstrip('.') for n in ptr.splitlines() if n.rstrip('.').endswith('.ts.net'))
    for _ in range(3):
        controller('cache/dns/flush', 'POST')
        answer = controller('dns/query?name=' + name + '&type=A')
        assert answer.get('Status') == 0 and any(a.get('data') == own for a in answer.get('Answer', []))
    for protocol in ['+tcp', '+notcp']:
        response = cmd('/usr/bin/dig', '@127.0.0.1', '-p', '1053', name, 'A', protocol, '+time=3', '+tries=1').stdout
        assert 'status: NOERROR' in response and own in response
    assert own in cmd('/usr/bin/dscacheutil', '-q', 'host', '-a', 'name', name).stdout
    record('MagicDNS: three fresh engine queries, TCP/UDP listeners and macOS resolution')

def inactive():
    assert (SUPPORT / 'deactivated').read_text() == 'mimo-inactive-v2\n'
    for job in JOBS: assert cmd('/bin/launchctl', 'print', 'system/' + job, check=False).returncode != 0
    paths = [ANCHOR]
    for path in paths:
        for child in pf(path, '-sAnchors').splitlines():
            child = child.strip()
            if child: paths.append(child if child.startswith(ANCHOR + '/') else path + '/' + child)
    assert all(pf(path) == '' and pf(path, '-sn') == '' for path in paths)
    dns_absent()
    assert '# BEGIN MIMO BOOT GUARD' not in Path('/etc/pf.conf').read_text()
    assert not Path(SOCKET).exists()
    cmd('/usr/bin/curl', '--fail', '--silent', '--max-time', '15', 'https://example.com')
    record('Stop: all jobs/rules/old descendants/DNS/boot guard removed; native HTTPS restored')

def run():
    try:
        info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
        assert (info['CFBundleShortVersionString'], info['CFBundleVersion']) == ('2.0', '6')
        cmd('/usr/bin/codesign', '--verify', '--deep', '--strict', APP)
        daemon('activate'); wait_ready('direct')
        assert Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes() == (APP / 'Contents/MacOS/mimo-core').read_bytes()
        record('Installed sealed build 6 and its production helper match')
        direct(); protected('rule'); magicdns()
        client('refresh'); wait_ready('rule')
        assert pf() == 'anchor "power-guard" out quick all'
        record('Warm verification returns to the empty active firewall')
        protected('global'); direct(); protected('rule')
        cmd('/sbin/pfctl', '-a', ANCHOR + '/old-build/orphan', '-f', '-', input='block return out quick inet6 all\n')
        output = daemon('deactivate')
        for stage in ['firewall_removed', 'resolver_removed', 'tailnet_verified', 'uninstall_completed']:
            assert 'MIMO_CLEANUP ' + stage in output, stage
        inactive()
        record('Cleanup receipts explicitly verify native Tailnet DNS and complete uninstall')
        (ROOT / 'passed').touch()
    finally:
        if not (SUPPORT / 'deactivated').exists(): daemon('deactivate')
        (ROOT / 'done').touch()

def main():
    if sys.argv[1:] == ['start']:
        ROOT.mkdir(mode=0o700, exist_ok=True)
        for marker in ['done', 'passed']: (ROOT / marker).unlink(missing_ok=True)
        with (ROOT / 'results.log').open('w') as log:
            subprocess.Popen(['/usr/bin/python3', __file__, 'run'], stdout=log, stderr=log, start_new_session=True)
        with (ROOT / 'watchdog.log').open('w') as log:
            subprocess.Popen(['/usr/bin/python3', __file__, 'watchdog'], stdout=log, stderr=log, start_new_session=True)
        print('Started isolated VM acceptance with independent cleanup watchdog.')
    elif sys.argv[1:] == ['watchdog']:
        for _ in range(600):
            if (ROOT / 'done').exists(): break
            time.sleep(1)
        else: daemon('deactivate')
    elif sys.argv[1:] == ['run']: run()
    else: raise SystemExit('Usage: release_build6_test.py start|run|watchdog')

if __name__ == '__main__':
    main()
