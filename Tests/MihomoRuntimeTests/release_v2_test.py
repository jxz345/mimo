#!/usr/bin/env python3
"""Installed 2.0 acceptance in mimo-vm. Private backups/logs never leave the VM.

Stage the release package and release-controls-v2 beside this file. Run prepare,
test, and restore as root. Restoration also runs after a failed test.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pty
import re
import select
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import time
import uuid

BASE = Path(__file__).resolve().parent
ROOT = Path('/var/root/mimo-v2-build5-acceptance')
APP = Path('/Applications/Mimo.app')
SUPPORT = Path('/Library/Application Support/Mimo')
STATE = SUPPORT / 'Service/state.plist'
FLAGS = SUPPORT / 'Runtime/services.json'
HELPER = Path('/Library/PrivilegedHelperTools/mimo-core')
JOBS = ['com.mimo.infrastructure', 'com.mimo.pf-boot', 'com.mimo.core', 'com.mimo.mihomo', 'com.mimo.supervisor']
SOCKET = str(SUPPORT / 'Mihomo/controller.sock')
FOREIGN = 'com.apple/999.mimo-v2-acceptance'


def cmd(*args, check=True, input=None, timeout=180):
    value = subprocess.run(list(map(str, args)), input=input, text=True, capture_output=True, timeout=timeout)
    if check and value.returncode:
        (ROOT / 'last-command.log').write_text(value.stdout + value.stderr)
        raise AssertionError('Command failed: ' + str(args[0]) + '; private last-command.log')
    return value


def installer(operation, answer=None):
    argv = ['/bin/bash', str(APP / 'Contents/Resources/daemon.sh'), operation]
    if answer is None:
        result = cmd(*argv, check=False, timeout=240)
        (ROOT / (operation + '.log')).write_text(result.stdout + result.stderr)
        assert result.returncode == 0, operation + ' failed; private installer log'
        return
    # Exercise the real terminal confirmation; consent covers only our test engine.
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(argv[0], argv)
    output = b''; sent = False; deadline = time.monotonic() + 240; status = None
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], .2)[0]:
                try: block = os.read(fd, 65536)
                except OSError: block = b''
                output += block
                if b'[y/N]' in output and not sent:
                    os.write(fd, (answer + '\n').encode()); sent = True
            ended, status = os.waitpid(pid, os.WNOHANG)
            if ended: break
        else:
            os.kill(pid, signal.SIGTERM); os.waitpid(pid, 0)
            raise AssertionError('Installer confirmation timeout')
    finally:
        os.close(fd)
        (ROOT / ('confirmation-' + answer + '.log')).write_bytes(output)
    assert sent, 'Installer did not ask before takeover'
    assert os.waitstatus_to_exitcode(status) == (0 if answer == 'y' else 130)


def client(*args):
    return json.loads(cmd(BASE / 'release-controls-v2', *args, timeout=90).stdout)


def wait(predicate, label, seconds=100):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            if predicate(): return
        except (KeyError, ValueError, AssertionError, OSError):
            pass
        time.sleep(.5)
    raise AssertionError(label + ' timed out')


def ready(mode):
    def check():
        state = client('core')['state']['routing']
        return state['phase'] == 'active' and state.get('effectiveMode') == mode
    wait(check, mode + ' active')


def mode(value):
    assert client('mode', value).get('failure') is None
    ready(value)


def controller(path):
    return json.loads(cmd('/usr/bin/curl', '--fail', '--silent', '--max-time', '10', '--unix-socket', SOCKET,
                          'http://localhost/' + path).stdout)


def inactive():
    assert (SUPPORT / 'deactivated').read_text() == 'mimo-inactive-v2\n'
    assert (SUPPORT / 'deactivated').stat().st_uid == 0
    for job in JOBS:
        assert cmd('/bin/launchctl', 'print', 'system/' + job, check=False).returncode != 0, job
    for path in [HELPER, Path('/Library/PrivilegedHelperTools/mimo-manage'), Path(SOCKET),
                 SUPPORT / 'Runtime/mihomo', SUPPORT / 'Runtime/ipv6-original.plist']:
        assert not path.exists(), str(path)
    assert not cmd('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout.strip()
    assert '# BEGIN MIMO BOOT GUARD' not in Path('/etc/pf.conf').read_text()
    assert 'No such key' in cmd('/usr/sbin/scutil', input='show State:/Network/Service/com.mimo.dns/DNS\n').stdout
    assert cmd('/sbin/ifconfig', 'utun239', check=False).returncode != 0
    for transport in [socket.SOCK_STREAM, socket.SOCK_DGRAM]:
        for port in [7890, 1053, 18766]:
            with socket.socket(socket.AF_INET, transport) as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(('127.0.0.1', port))


def restore():
    if not (ROOT / 'baseline.app').exists(): return
    if APP.exists():
        installer('deactivate')
        shutil.rmtree(APP)
    cmd('/usr/bin/ditto', '--noextattr', '--norsrc', ROOT / 'baseline.app', APP)
    for source, target in [('state.plist', STATE), ('services.json', FLAGS)]:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / source, target); target.chmod(0o600)
    installer('install')
    (SUPPORT / 'deactivated').unlink(missing_ok=True)
    cmd('/sbin/pfctl', '-a', FOREIGN, '-F', 'rules', check=False)
    if (ROOT / 'pf-token').exists():
        cmd('/sbin/pfctl', '-X', (ROOT / 'pf-token').read_text(), check=False)
    (ROOT / 'restored').touch()
    print('RESTORED: original app, settings, services and networking.', flush=True)


def prepare():
    if ROOT.exists():
        assert (ROOT / 'restored').exists(), 'Restore the previous attempt first'
        (ROOT / 'restored').unlink()
    else:
        ROOT.mkdir(mode=0o700)
        cmd('/usr/bin/ditto', '--noextattr', '--norsrc', APP, ROOT / 'baseline.app')
        shutil.copyfile(STATE, ROOT / 'state.plist'); shutil.copyfile(FLAGS, ROOT / 'services.json')
        shutil.copyfile(SUPPORT / 'Runtime/mihomo', ROOT / 'verge-mihomo')
    (ROOT / 'verge-mihomo').chmod(0o755)
    (SUPPORT / 'deactivated').unlink(missing_ok=True)  # baseline build 4 predates receipts
    result = cmd('/usr/sbin/installer', '-pkg', BASE / 'Mimo-2.0.pkg', '-target', '/', check=False, timeout=360)
    (ROOT / 'package-install.log').write_text(result.stdout + result.stderr)
    assert result.returncode == 0, 'Package install failed; private log'
    print('PASS: package upgraded the installed build 4 app.', flush=True)


def apply(blocks):
    path = ROOT / 'bypass.json'; path.write_text(json.dumps(blocks))
    result = client('bypass', path)
    assert result.get('failure') is None


def tls_request(host):
    # Real SOCKS TCP and TLS + HTTP; inspect the live connection, not rendered rules.
    connection = socket.create_connection(('127.0.0.1', 7890), timeout=15)
    def receive(n):
        data = b''
        while len(data) < n:
            block = connection.recv(n - len(data)); assert block
            data += block
        return data
    connection.sendall(b'\x05\x01\x00'); assert receive(2) == b'\x05\x00'
    name = host.encode(); connection.sendall(b'\x05\x01\x00\x03' + bytes([len(name)]) + name + b'\x01\xbb')
    header = receive(4); assert header[1] == 0
    receive(4 if header[3] == 1 else 16 if header[3] == 4 else receive(1)[0]); receive(2)
    secure = ssl.create_default_context().wrap_socket(connection, server_hostname=host)
    try:
        secure.sendall(('GET / HTTP/1.1\r\nHost: ' + host + '\r\nConnection: keep-alive\r\n\r\n').encode())
        response = secure.recv(4096); assert response.startswith(b'HTTP/1.1 ')
        rows = controller('connections')['connections']
        row = next(r for r in rows if r['metadata'].get('host') == host and
                   str(r['metadata'].get('sourcePort')) == str(secure.getsockname()[1]))
        return row['chains'], row['rule']
    finally:
        secure.close()


def test():
    passed = []; competitor = None
    def record(label): passed.append(label); print('PASS:', label, flush=True)
    try:
        info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
        assert (info['CFBundleShortVersionString'], info['CFBundleVersion']) == ('2.0', '5')
        assert HELPER.read_bytes() == (APP / 'Contents/MacOS/mimo-core').read_bytes()
        cmd('/usr/bin/codesign', '--verify', '--deep', '--strict', APP)
        record('Version 2.0 build 5 app, installed helper and sealed signature match')
        mode('rule')
        cmd('/sbin/pfctl', '-a', FOREIGN, '-f', '-', input='block return out quick inet to 198.51.100.253\n')
        token = re.search(r'Token\s*:\s*(\d+)', cmd('/sbin/pfctl', '-E').stderr).group(1)
        (ROOT / 'pf-token').write_text(token)
        # The absence of a controller must not prevent installer-owned recovery.
        Path(SOCKET).unlink()
        installer('deactivate'); inactive()
        assert '198.51.100.253' in cmd('/sbin/pfctl', '-a', FOREIGN, '-sr').stdout
        assert token in cmd('/sbin/pfctl', '-s', 'References').stdout
        record('Full cleanup from Rule without controller removes all five jobs and releases networking; foreign PF survives')
        removed_app = ROOT / 'removed.app'; APP.rename(removed_app)
        cmd('/usr/bin/curl', '--fail', '--silent', '--max-time', '20', 'https://example.com/')
        inactive(); removed_app.rename(APP)
        record('App can be removed after Stop while native HTTPS still works')
        # Fail at two real installer boundaries, after mutation has begun. The
        # packaged source and runtime are unchanged; only command failure is injected.
        for boundary in ['--begin-maintenance', '--prepare-runtime']:
            fault = ROOT / 'fail-activation.sh'
            fault.write_text('source "/Applications/Mimo.app/Contents/Resources/daemon.sh"\n'
                'run() {\n'
                '  if [ "${2:-}" = "' + boundary + '" ]; then\n'
                '    bounded_command 20 "$1" "$@" || return $?\n'
                '    return 77\n'
                '  fi\n'
                '  bounded_command 20 "$1" "$@"\n'
                '}\nmain activate\n')
            failure = cmd('/bin/bash', fault, check=False, timeout=240)
            (ROOT / ('fault-' + boundary + '.log')).write_text(failure.stdout + failure.stderr)
            assert failure.returncode != 0 and 'previous files and loaded services were restored' in failure.stderr
            inactive()
            cmd('/usr/bin/curl', '--fail', '--silent', '--max-time', '20', 'https://example.com/')
        record('Early and late activation failures restore full inactive networking and retain recovery settings')
        (ROOT / 'other.yaml').write_text('mixed-port: 7890\nallow-lan: false\nmode: rule\nrules:\n  - MATCH,DIRECT\n')
        log = open(ROOT / 'other-engine.log', 'w')
        competitor = subprocess.Popen([str(ROOT / 'verge-mihomo'), '-d', str(ROOT / 'other'), '-f', str(ROOT / 'other.yaml')], stdout=log, stderr=log)
        time.sleep(2)
        cmd('/usr/bin/curl', '--fail', '--silent', '--max-time', '20', '--socks5-hostname', '127.0.0.1:7890', 'https://example.com/')
        installer('install')
        assert competitor.poll() is None and not HELPER.exists()
        record('Reinstall preserves full inactive state without taking over the other engine')
        installer('activate', 'n'); assert competitor.poll() is None
        assert (SUPPORT / 'deactivated').exists()
        record('Another real mihomo serves HTTPS after cleanup; declining takeover preserves it')
        installer('activate', 'y'); competitor.wait(timeout=10); competitor = None; ready('direct')
        assert not (SUPPORT / 'deactivated').exists()
        assert all(json.loads(FLAGS.read_text()).get(k) for k in ['core', 'engine', 'profile'])
        record('Confirmed takeover stops only the fixture engine and activates all Mimo services in Direct')
        for selected in ['global', 'direct']:
            mode(selected); installer('deactivate'); inactive(); installer('activate'); ready('direct')
            record('Full cleanup and activation succeed from ' + selected)
        mode('rule')
        block = {'id': str(uuid.uuid4()), 'name': 'Release routing proof', 'enabled': True,
                 'domains': [{'domain': 'example.com', 'match': 'exact'}]}
        apply([]); ready('rule')
        chains, _ = tls_request('example.com'); assert 'DIRECT' not in chains
        apply([block]); ready('rule')
        chains, rule = tls_request('example.com'); assert chains == ['DIRECT'] and rule == 'Domain'
        record('Applying an exact bypass reloads Rule and real TLS/HTTP changes from proxy to DIRECT')
        block['enabled'] = False; apply([block]); ready('rule')
        assert 'DIRECT' not in tls_request('example.com')[0]
        record('Disabling the block returns new real connections to the proxy')
        mode('global'); before = controller('rules')
        block['enabled'] = True; block['domains'][0]['match'] = 'suffix'; apply([block]); ready('global')
        assert controller('rules') == before and 'DIRECT' not in tls_request('example.com')[0]
        mode('rule'); assert tls_request('example.com')[0] == ['DIRECT']
        record('Global save leaves live rules and proxy routing unchanged; next Rule uses saved suffix bypass')
        # Preserve native tailnet rules and exercise the live resolver after Rule edits.
        native = json.loads(cmd('/usr/bin/sudo', '-n', '-u', 'jay', '/Applications/Tailscale.app/Contents/MacOS/Tailscale', 'status', '--json').stdout)
        peer = next(p for p in native['Peer'].values() if p.get('Online'))
        answer = controller('dns/query?name=' + peer['DNSName'].rstrip('.') + '&type=A')
        assert answer.get('Status') == 0 and any(a.get('data') in peer['TailscaleIPs'] for a in answer.get('Answer', []))
        record('Native MagicDNS still resolves after bypass updates and mode changes')
    finally:
        if competitor is not None and competitor.poll() is None:
            competitor.terminate(); competitor.wait(timeout=10)
        if (ROOT / 'removed.app').exists() and not APP.exists(): (ROOT / 'removed.app').rename(APP)
        (ROOT / 'evidence.json').write_text(json.dumps({'checks': passed}, indent=2) + '\n')
        restore()


def reboot_stop():
    installer('deactivate'); inactive()
    (ROOT / 'boot-before').write_text(cmd('/usr/sbin/sysctl', '-n', 'kern.boottime').stdout)
    print('PASS: fully inactive before VM reboot.', flush=True)


def reboot_check():
    try:
        assert cmd('/usr/sbin/sysctl', '-n', 'kern.boottime').stdout != (ROOT / 'boot-before').read_text()
        inactive()
        cmd('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--fail', '--silent', '--max-time', '20', 'https://example.com/')
        installer('activate'); ready('direct')
        checks = ['Actual VM reboot preserves full inactivity and releases all listeners/network controls',
                  'Ordinary-user HTTPS works after reboot; explicit activation restores Direct services']
        (ROOT / 'reboot-evidence.json').write_text(json.dumps({'checks': checks}, indent=2) + '\n')
        for check in checks: print('PASS:', check, flush=True)
    finally:
        restore()


if __name__ == '__main__':
    assert os.geteuid() == 0
    assert subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model']).startswith(b'VirtualMac')
    os.umask(0o077)
    {'prepare': prepare, 'test': test, 'restore': restore,
     'reboot-stop': reboot_stop, 'reboot-check': reboot_check}[sys.argv[1]]()
