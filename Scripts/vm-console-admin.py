#!/usr/bin/env python3
"""Run a VM test command through Tart's local guest agent, outside the PF path.

Uses the same dedicated local administrator as vm-admin.py. Credentials are sent
only to su/sudo prompts in the guest PTY; they are never arguments or log output.
"""
import json
import os
from pathlib import Path
import pty
import select
import shlex
import stat
import subprocess
import sys
import termios
import time


def main():
    if len(sys.argv) < 2 or not sys.argv[1].startswith('/'):
        sys.exit('Usage: vm-console-admin.py /absolute/guest/executable [arguments...]')
    path = Path.home() / '.config/mimo-vm/test-admin.json'
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        sys.exit('Unsafe VM credential file')
    value = json.loads(path.read_text())
    if value.get('host') != 'mimo-vm-admin' or value.get('username') != 'mimotest':
        sys.exit('Unexpected VM administrator configuration')
    command = shlex.join(['/usr/bin/sudo', '-k', '-S', '-p', 'MIMO_SUDO:', '--', *sys.argv[1:]])
    master, slave = pty.openpty()
    attributes = termios.tcgetattr(slave)
    attributes[3] &= ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, attributes)
    child = subprocess.Popen(['tart', 'exec', '-i', '-t', 'mimo-test-macos', '/usr/bin/su',
                              'mimotest', '-c', command], stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = bytearray()
    sent = 0
    deadline = time.monotonic() + 180
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    part = os.read(master, 65536)
                except OSError:
                    break
                if not part:
                    break
                output.extend(part)
                prompt = b'Password:' if sent == 0 else b'MIMO_SUDO:'
                if sent < 2 and prompt in output:
                    output = output.split(prompt, 1)[1]
                    os.write(master, (value['password'] + '\n').encode())
                    sent += 1
            elif child.poll() is not None:
                break
        if child.poll() is None:
            child.terminate()
        child.wait(timeout=5)
        text = output.decode(errors='replace').replace(value['password'], '<redacted>')
        print(text.strip())
        return child.returncode
    finally:
        os.close(master)


if __name__ == '__main__':
    sys.exit(main())
