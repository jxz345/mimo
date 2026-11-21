#!/usr/bin/env python3
"""VM-only: real launchd KeepAlive, terminal confirmation, cancellation and installer continuation.

Pass --install to exercise the complete standalone repair against the existing sealed app.
No third-party software is installed; fixtures are tiny sleeping processes named mihomo.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import pty
import re
import select
import signal
import subprocess
import tempfile
import time
import uuid


def command(*args, check=True):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=30, check=check)


def terminal(args, answer, expected, log):
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(args[0], args)
    output = bytearray()
    replied = False
    deadline = time.monotonic() + 180
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    chunk = os.read(fd, 16384)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
                if b'[y/N] ' in output and not replied:
                    assert expected.encode() in output, output.decode(errors='replace')[-3000:]
                    os.write(fd, (answer + '\n').encode())
                    replied = True
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                pid = None
                break
        else:
            raise AssertionError('Installer timed out')
        if pid is not None:
            _, status = os.waitpid(pid, 0)
            pid = None
        assert replied, 'No terminal confirmation; see ' + str(log)
        return os.waitstatus_to_exitcode(status), output.decode(errors='replace')
    finally:
        log.write_bytes(output)
        os.close(fd)
        if pid is not None:
            os.killpg(pid, signal.SIGTERM)
            os.waitpid(pid, 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    repo = Path(__file__).resolve().parents[2]
    installer = repo / 'Sources/MimoDaemon/daemon.sh'
    root = Path(tempfile.mkdtemp(prefix='mimo-conflict-test-', dir='/var/tmp')).resolve()
    root.chmod(0o755)
    executable = root / 'mihomo'
    subprocess.run(['/usr/bin/clang', '-x', 'c', '-', '-o', str(executable)],
                   input='#include <unistd.h>\nint main(void) { sleep(600); return 0; }\n',
                   text=True, capture_output=True, timeout=30, check=True)
    label = 'org.mimotest.engine-conflict.' + uuid.uuid4().hex
    plist = root / 'engine.plist'
    plist.write_bytes(plistlib.dumps({'Label': label, 'ProgramArguments': [str(executable), '600'],
                                     'RunAtLoad': True, 'KeepAlive': True}))
    plist.chmod(0o644)
    helper = root / 'check.sh'
    helper.write_text('#!/bin/bash\nsource "$1"\ncheck_engine_conflicts\n')
    jobs = ['com.mimo.core', 'com.mimo.supervisor', 'com.mimo.mihomo']
    def job_pid(target):
        out = command('/bin/launchctl', 'print', target).stdout
        return int(re.search(r'^\s*pid = (\d+)$', out, re.M).group(1))
    def baseline():
        return {job: job_pid('system/' + job) for job in jobs}
    before = baseline()
    app = Path('/Applications/Mimo.app')
    files = [app / 'Contents/MacOS/mimo-core', app / 'Contents/Resources/daemon.sh',
             Path('/Library/PrivilegedHelperTools/mimo-core')]
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    targets = ['system/' + label]
    standalone = None
    try:
        command('/bin/launchctl', 'bootstrap', 'system', plist)
        time.sleep(0.5)
        engine_pid = job_pid(targets[0])
        check = ['/bin/bash', str(helper), str(installer)]
        code, out = terminal(check, 'n', targets[0], root / 'cancel.log')
        assert code == 130 and job_pid(targets[0]) == engine_pid
        assert baseline() == before
        print('PASS: terminal cancellation preserves KeepAlive engine and all Mimo jobs', flush=True)
        code, out = terminal(check, 'y', targets[0], root / 'approve.log')
        assert code == 0, out[-3000:]
        assert command('/bin/launchctl', 'print', targets[0], check=False).returncode != 0
        time.sleep(2)
        assert command('/bin/ps', '-p', engine_pid, check=False).returncode != 0
        assert plist.exists() and baseline() == before
        assert re.search(re.escape('"' + label + '"') + r' => (?:true|disabled)',
                         command('/bin/launchctl', 'print-disabled', 'system').stdout)
        print('PASS: approved system KeepAlive job stays stopped with automatic startup disabled', flush=True)
        uid = command('/usr/bin/id', '-u', 'jay').stdout.strip()
        target = 'gui/' + uid + '/' + label
        targets.append(target)
        command('/bin/launchctl', 'bootstrap', 'gui/' + uid, plist)
        time.sleep(0.5)
        code, out = terminal(check, 'y', target, root / 'user-agent.log')
        assert code == 0, out[-3000:]
        assert command('/bin/launchctl', 'print', target, check=False).returncode != 0
        assert re.search(re.escape('"' + label + '"') + r' => (?:true|disabled)',
                         command('/bin/launchctl', 'print-disabled', 'gui/' + uid).stdout)
        print('PASS: approved per-user KeepAlive agent is identified and unloaded', flush=True)
        command('/bin/launchctl', 'enable', targets[0])
        command('/bin/launchctl', 'bootstrap', 'system', plist)
        time.sleep(0.5)
        code, out = terminal(['/bin/launchctl', 'asuser', uid, *check], 'y', targets[0], root / 'gui-context.log')
        assert code == 0, out[-3000:]
        assert command('/bin/launchctl', 'print', targets[0], check=False).returncode != 0
        print('PASS: a root installer in the GUI bootstrap context still removes the system job', flush=True)
        standalone = subprocess.Popen([str(executable), '600'])
        time.sleep(0.2)
        code, out = terminal(check, 'y', str(standalone.pid), root / 'standalone.log')
        assert code == 0, out[-3000:]
        standalone.wait(timeout=5)
        standalone = None
        assert baseline() == before
        print('PASS: approved standalone process exits without affecting Mimo', flush=True)
        if args.install:
            command('/bin/launchctl', 'enable', targets[0])
            command('/bin/launchctl', 'bootstrap', 'system', plist)
            time.sleep(0.5)
            install = ['/bin/bash', str(installer), 'install', '--app', str(app)]
            code, out = terminal(install, 'n', targets[0], root / 'install-cancel.log')
            assert code == 130, out[-3000:]
            assert baseline() == before
            assert hashes == {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
            print('PASS: real staged installer cancellation preserves existing installation', flush=True)
            code, out = terminal(install, 'y', targets[0], root / 'install-approve.log')
            assert code == 0, out[-4000:]
            assert 'Competing engines stopped. Continuing' in out
            assert 'Mimo supervisor, core and pinned mihomo installed.' in out
            assert hashes == {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
            baseline()
            command('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
            print('PASS: standalone installer stops the fixture and completes service repair; sealed app unchanged', flush=True)
    finally:
        if standalone is not None:
            standalone.terminate()
            standalone.wait(timeout=5)
        for target in targets:
            command('/bin/launchctl', 'enable', target, check=False)
            command('/bin/launchctl', 'bootout', target, check=False)
        print('Evidence:', root, flush=True)


if __name__ == '__main__':
    main()
