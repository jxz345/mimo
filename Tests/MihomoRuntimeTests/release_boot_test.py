#!/usr/bin/env python3
"""Reboot the exact installed Release with the user's saved Rule or Global proxy.

No replacement runtime, invented credentials, new approved IPs or synthetic
power events. Root-only evidence and an independent restoration watchdog retain
the original Direct configuration. Capture coverage starts at the boot worker;
it cannot prove protection earlier in the boot sequence.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback

from installed_acceptance_test import command
from saved_proxy_test import restore
from upgrade_test import HELPER, STORAGE, FLAGS, RUNTIME, read_settings

JOB = 'com.mimo.release-boot-test'
PLIST = Path('/Library/LaunchDaemons') / (JOB + '.plist')
BASE = Path(__file__).resolve().parent
GUI = Path('/Applications/Mimo.app/Contents/MacOS/mimo-gui')


def boot_id():
    return command('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid').stdout.strip()


def client(*args):
    return json.loads(command(BASE/'acceptance-client', *args, timeout=65).stdout)


def wait_mode(mode, root):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            value = client('state')
            (root/'last-state.json').write_text(json.dumps(value))
            s = value.get('routing', {})
            if s.get('phase') == 'active' and s.get('effectiveMode') == mode:
                return s
        except (subprocess.SubprocessError, ValueError):
            pass
        time.sleep(.5)
    raise RuntimeError(mode + ' did not recover after a fresh check')


def watcher(root):
    with (root/'watchdog.log').open('a') as log:
        return subprocess.Popen([sys.executable, BASE/'saved_proxy_test.py', '--watchdog', root, str(os.getpid())],
                                stdout=log, stderr=log, start_new_session=True)


def prepare(mode):
    assert not PLIST.exists(), 'Finish the earlier boot worker first'
    original = read_settings()
    routing = json.loads(original['service.routing'])
    assert routing['mode'] == 'direct' and routing.get('proxy')
    approved = json.loads(original['service.settings'])['allowlist']['addresses']
    assert approved
    build = json.loads((BASE/'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    assert HELPER.read_bytes() == Path('/Applications/Mimo.app/Contents/MacOS/mimo-core').read_bytes()
    assert hashlib.sha256(GUI.read_bytes()).hexdigest() == build['guiSHA256']
    root = Path(tempfile.mkdtemp(prefix='mimo-release-boot-', dir='/var/tmp'))
    root.chmod(0o700)
    (root/'installed-release').touch()
    backup = root/'private-backup'; backup.mkdir(mode=0o700)
    for source, name in ((HELPER, 'mimo-core'), (STORAGE, 'state.plist'), (FLAGS, 'services.json')):
        shutil.copyfile(source, backup/name)
    (backup/'credential.digest').write_text(command(BASE/'acceptance-client', 'credential-digest').stdout.strip())
    worker = root/'worker'; worker.mkdir(mode=0o700)
    for name in ('release_boot_test.py', 'saved_proxy_test.py', 'installed_acceptance_test.py', 'upgrade_test.py',
                 'packet_test.py', 'acceptance-client', 'installation-check'):
        shutil.copyfile(BASE/name, worker/name); (worker/name).chmod(0o700)
    armed = False
    guard = watcher(root)
    try:
        client('mode', mode)
        s = wait_mode(mode, root)
        assert s['observedIP']['address'] in approved
        (root/'context.json').write_text(json.dumps(dict(mode=mode, previousBoot=boot_id(), approved=approved,
            helperSHA256=build['helperSHA256'], packageSHA256=build['packageSHA256'],
            guiSHA256=build['guiSHA256'],
            logs={str(p): p.stat().st_size for p in Path('/Library/Logs/ExitIPMonitor').glob('runtime-*.jsonl')})))
        # A login item or restored session may launch the GUI again. Exercise
        # actual GUI unavailability without changing that user's preference.
        # The original executable is moved back by both cleanup and watchdog.
        os.replace(GUI, root/'boot-gui')
        command('/usr/bin/pkill', '-x', 'mimo-gui', check=False)
        PLIST.write_bytes(plistlib.dumps(dict(Label=JOB, ProgramArguments=['/usr/bin/python3', str(worker/'release_boot_test.py'),
            '--worker', str(root)], RunAtLoad=True, StandardOutPath=str(root/'worker.log'), StandardErrorPath=str(root/'worker.log'))))
        PLIST.chmod(0o644)
        print('PASS: saved-real-' + mode + '-verified-before-reboot', flush=True)
        print('Evidence:', root, flush=True)
        guard.terminate(); guard.wait(timeout=5)
        command('/sbin/shutdown', '-r', 'now')
        armed = True
    finally:
        if not armed:
            restore(root); guard.wait(timeout=5); PLIST.unlink(missing_ok=True)


def worker(root):
    context = json.loads((root/'context.json').read_text())
    passed, errors = [], []
    mode = context['mode']
    capture = probe = None
    guard = watcher(root)
    capture_start = time.time()
    protected_end = None
    packets = []
    def record(name):
        passed.append(name); print('PASS:', name, flush=True)
    try:
        assert boot_id() != context['previousBoot']
        record('actual-macOS-reboot-confirmed')
        assert not GUI.exists() and (root/'boot-gui').exists()
        assert command('/usr/bin/pgrep', '-x', 'mimo-gui', check=False).returncode == 1
        record('startup-with-GUI-executable-unavailable-and-login-preference-unchanged')
        with (root/'capture.log').open('w') as log:
            capture = subprocess.Popen(['/usr/sbin/tcpdump', '-n', '-U', '-i', 'pktap,en0', '-w', str(root/'traffic.pcap'),
                'dst host 1.1.1.1 and tcp dst port 443'], stdout=log, stderr=log)
        deadline = time.monotonic()+8
        while 'listening on' not in (root/'capture.log').read_text():
            assert capture.poll() is None and time.monotonic()<deadline
            time.sleep(.1)
        account = pwd.getpwnam('jay')
        def identity():
            os.setgroups([]); os.setgid(account.pw_gid); os.setuid(account.pw_uid)
        probe = subprocess.Popen([sys.executable, '-u', '-c',
            'import socket,time\nwhile True:\n try:\n  s=socket.create_connection(("1.1.1.1",443),timeout=.4);s.close()\n except OSError:pass\n time.sleep(.1)'],
            preexec_fn=identity, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        s = wait_mode(mode, root)
        assert s['observedIP']['address'] in context['approved']
        assert (RUNTIME/'gate.state').read_text() == 'active'
        record('saved-' + mode + '-recovered-with-user-approved-exit')
        assert 'IPv6: Off' in command('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
        assert 'Status: Enabled' in command('/sbin/pfctl', '-s', 'info').stdout
        assert Path('/Library/Application Support/Mimo/Guard/boot.id').read_text() == boot_id()
        record('independent-boot-guard-and-IPv4-policy-active')
        records = []
        for path in Path('/Library/Logs/ExitIPMonitor').glob('runtime-*.jsonl'):
            with path.open('rb') as stream:
                stream.seek(context['logs'].get(str(path), 0))
                for line in stream:
                    try: records.append(json.loads(line))
                    except ValueError: pass
        (root/'startup-events.json').write_text(json.dumps(records))
        names = [r['event'] for r in records]
        assert names.index('mimo_private_probe_ready') < names.index('mimo_traffic_opened')
        record('fresh-private-probe-precedes-opening-after-reboot')
        assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == context['helperSHA256']
        assert not (RUNTIME/'qualification.json').exists()
        record('unchanged-normal-Release-helper')
        time.sleep(3)
        protected_end = time.time()
    except BaseException as exc:
        errors.append(type(exc).__name__ + ': ' + str(exc)); (root/'failure.txt').write_text(traceback.format_exc())
    finally:
        try:
            # The same ordinary process supplies a Direct positive control after
            # restoration, proving capture attribution without changing PF rules.
            restore(root)
            guard.wait(timeout=8)
            record('original-Direct-settings-service-intent-and-password-restored')
            assert hashlib.sha256(GUI.read_bytes()).hexdigest() == context['guiSHA256']
            command('/usr/bin/codesign', '--verify', '--deep', '--strict', '/Applications/Mimo.app')
            record('original-GUI-executable-and-app-signature-restored')
            if probe and probe.poll() is None: time.sleep(3)
            if probe and probe.poll() is None: probe.terminate(); probe.wait(timeout=5)
            if capture and capture.poll() is None:
                capture.send_signal(signal.SIGINT); capture.wait(timeout=5)
                text = command('/usr/sbin/tcpdump', '-tt', '-nn', '-k', 'NP', '-r', root/'traffic.pcap').stdout
                packets = [line for line in text.splitlines() if re.search(r':'+str(probe.pid)+r'[,)]', line)]
                (root/'ordinary-packets.txt').write_text('\n'.join(packets))
                if protected_end:
                    before = [line for line in packets if float(line.split()[0]) <= protected_end]
                    after = [line for line in packets if float(line.split()[0]) > protected_end]
                    assert after, 'Missing Direct capture positive control'
                    record('same-user-process-Direct-capture-positive-control')
                    assert not before, 'Ordinary public packets escaped during captured protected boot'
                    record('no-direct-ordinary-packets-during-captured-protected-startup')
        except BaseException as exc:
            errors.append('Cleanup/capture: ' + str(exc))
        finally:
            for p in (probe, capture):
                if p and p.poll() is None: p.terminate(); p.wait(timeout=5)
            PLIST.unlink(missing_ok=True)
            (root/'report.json').write_text(json.dumps(dict(success=not errors, mode=mode, passed=passed, errors=errors,
                helperSHA256=context['helperSHA256'], packageSHA256=context['packageSHA256'],
                captureStartedAt=capture_start, protectedCaptureEndedAt=protected_end,
                firstPacketBootProtectionProven=False, scope='Normal installed Release helper; actual saved proxy; real reboot with GUI executable temporarily unavailable; capture starts at launchd worker'), indent=2)+'\n')
            print('RESULT:', 'PASS' if not errors else 'FAIL', flush=True)
            command('/bin/launchctl', 'bootout', 'system/'+JOB, check=False)


if __name__ == '__main__':
    assert os.geteuid()==0 and command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    os.umask(0o077)
    if len(sys.argv)==3 and sys.argv[1]=='--worker': worker(Path(sys.argv[2]))
    elif len(sys.argv)==2 and sys.argv[1] in ('rule', 'global'): prepare(sys.argv[1])
    else: sys.exit('Usage: release_boot_test.py rule|global')
