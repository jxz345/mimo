#!/usr/bin/env python3
"""VM-only relay diagnosis. Never qualifies a runtime or changes saved networking.

Compare a warm native connection with repeated forced IPv4 relay reconnects
behind the closed production guard. Retain native observations, packet captures
and actual loaded rules on failure. The independent watchdog restores Direct.
"""
import grp
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

from packet_test import ANCHOR, command, restore
from upgrade_test import CORE, ENGINE, SUPERVISOR, RUNTIME, read_settings


def run():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = read_settings()
    assert 'service.settings' not in original
    assert json.loads(original.get('service.routing', b'{}')).get('mode', 'direct') == 'direct'
    assert not (RUNTIME / 'qualification.json').exists()
    root = Path(tempfile.mkdtemp(prefix='mimo-relay-test-', dir='/var/tmp'))
    base = Path(__file__).resolve().parent
    peer = sys.argv[1]
    assert ipaddress.ip_address(peer) in ipaddress.ip_network('100.64.0.0/10')
    observer = watcher = capture = None
    result = {}

    def cli(*args):
        return command('/usr/bin/sudo', '-n', '-u', 'jay', '/Applications/Tailscale.app/Contents/MacOS/Tailscale', *args, check=False)

    def ping(label):
        result[label + '-start'] = time.time()
        for attempt in range(6):
            reply = cli('ping', '--c=1', '--until-direct=false', '--timeout=3s', peer)
            with (root / (label + '.txt')).open('a') as stream:
                stream.write(reply.stdout + reply.stderr)
            if reply.returncode == 0 and 'via DERP(' in reply.stdout:
                result[label] = True
                print(label + ': relay works', flush=True)
                return
        result[label] = False
        for suffix, args in (
            ('guard', ('/sbin/pfctl', '-a', ANCHOR, '-vvsr')),
            ('transport', ('/sbin/pfctl', '-a', ANCHOR + '/native-transport', '-vvsr')),
            ('sockets', ('/usr/sbin/lsof', '-nP', '-iTCP', '-sTCP:^CLOSED')),
            ('route', ('/sbin/route', '-n', 'get', peer)),
        ):
            reply = command(*args, check=False)
            (root / (label + '-' + suffix + '.txt')).write_text(reply.stdout + reply.stderr)
        print(label + ': relay failed', flush=True)

    def policy(path):
        command('/sbin/pfctl', '-a', ANCHOR, '-f', path)

    def interrupt(signum, frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    try:
        assert 'IPv6: Off' in command('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
        ping('Direct-baseline')
        assert result['Direct-baseline'], 'Direct peer baseline is unavailable'
        with (root / 'watchdog.log').open('w') as log:
            watcher = subprocess.Popen([sys.executable, base / 'packet_test.py', 'watchdog', root, str(os.getpid())], stdout=log, stderr=log)
        for label in (CORE, ENGINE, SUPERVISOR):
            command('/bin/launchctl', 'bootout', 'system/' + label, check=False)
        command(base / 'render-profiles', 'closed-runtime-policy', root / 'closed.pf')
        rules = (root / 'closed.pf').read_text().replace('pass out quick to { 10.0.0.0/8',
            'block return out quick proto udp group != ' + str(grp.getgrnam('_mimo').gr_gid) + '\npass out quick to { 10.0.0.0/8')
        (root / 'closed.pf').write_text(rules)
        with (root / 'native.log').open('w') as log:
            observer = subprocess.Popen([base / 'native-transport-check', 'serve-transport', root, root / 'provider.stopped', '--trace'], stdout=log, stderr=log)
        (root / 'native.pid').write_text(str(observer.pid))
        # Discover infrastructure while Direct is still available, then close.
        time.sleep(25)
        assert observer.poll() is None
        policy(root / 'closed.pf')
        enabled = command('/sbin/pfctl', '-E')
        token = re.search(r'Token\s*:\s*(\d+)', enabled.stdout + enabled.stderr)
        assert token
        (root / 'pf.token').write_text(token[1])
        command('/sbin/pfctl', '-k', '0.0.0.0/0')
        command('/sbin/pfctl', '-k', '::/0')
        with (root / 'relay-capture.log').open('w') as log:
            capture = subprocess.Popen(['/usr/sbin/tcpdump', '-n', '-U', '-i', 'pktap,en0',
                '-w', str(root / 'relay.pcap'), 'tcp port 443 or udp port 41641'], stdout=log, stderr=log)
        ping('warm-connection')
        for cycle in range(1, 4):
            assert cli('debug', 'break-derp-conns').returncode == 0
            ping('reconnect-' + str(cycle))
        assert cli('down').returncode == 0
        assert cli('up').returncode == 0
        ping('native-down-up-without-TUN')
        assert all(result.get(label) for label in ('warm-connection', 'reconnect-1', 'reconnect-2', 'reconnect-3', 'native-down-up-without-TUN'))
    finally:
        if capture is not None:
            capture.send_signal(signal.SIGINT)
            capture.wait(timeout=5)
        if observer is not None:
            observer.terminate()
            observer.wait(timeout=5)
        restore(root)
        cli('up')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            state = command(base / 'installation-check', check=False)
            if state.returncode == 0 and json.loads(state.stdout).get('effectiveMode') == 'direct':
                break
            time.sleep(0.5)
        else:
            raise AssertionError('Direct did not recover')
        result['restored-direct'] = True
        (root / 'report.json').write_text(json.dumps(result, indent=2))
        (root / 'cleanup-complete').touch()
        if watcher is not None:
            watcher.wait(timeout=3)
        print('Evidence:', root, flush=True)


if __name__ == '__main__':
    run()
