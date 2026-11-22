#!/usr/bin/env python3
"""Run real Homebrew as the authorized VM test administrator, never as root.

The existing password travels over SSH stdin. The guest's temporary askpass file
is owner-only, removed on exit, and never appears in argv, logs, or the repository.
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in {'install', 'uninstall', 'reinstall', 'upgrade', 'test', 'list', 'info', 'fetch', 'trust', 'untrust'}:
        sys.exit('Usage: vm-brew.py install|uninstall|reinstall|upgrade|test|list|info|fetch [Homebrew arguments]')
    path = Path.home() / '.config/mimo-vm/test-admin.json'
    info = path.lstat()
    assert stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0
    value = json.loads(path.read_text())
    assert value['host'] == 'mimo-vm-admin' and value['username'] == 'mimotest'
    process = subprocess.run(['/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', 'mimo-vm-admin',
        '/usr/bin/python3 /Users/jay/mimo-tests/runtime/brew_command.py'],
        input=json.dumps({'password': value['password'], 'arguments': sys.argv[1:]}),
        text=True, capture_output=True)
    for output, stream in ((process.stdout, sys.stdout), (process.stderr, sys.stderr)):
        stream.write(output.replace(value['password'], '<redacted>'))
    return process.returncode


if __name__ == '__main__':
    sys.exit(main())
