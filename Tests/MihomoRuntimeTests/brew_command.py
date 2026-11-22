#!/usr/bin/env python3
"""Guest side of vm-brew.py: ordinary authenticated sudo through askpass."""
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile


def main():
    assert os.getuid() == pwd.getpwnam('mimotest').pw_uid and os.geteuid() != 0
    assert subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model']).startswith(b'VirtualMac')
    value = json.load(sys.stdin)
    arguments = value['arguments']
    assert arguments and arguments[0] in {'install', 'uninstall', 'reinstall', 'upgrade', 'test', 'list', 'info', 'fetch', 'trust', 'untrust'}
    assert all(isinstance(x, str) and '\x00' not in x for x in arguments)
    original_umask = os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='mimo-brew-auth-') as temporary:
        root = Path(temporary)
        secret = root / 'password'
        secret.write_text(value['password'] + '\n')
        askpass = root / 'askpass'
        askpass.write_text('#!/bin/sh\nexec /bin/cat "' + str(secret) + '"\n')
        askpass.chmod(0o700)
        os.umask(original_umask)
        environment = dict(os.environ, SUDO_ASKPASS=str(askpass), HOMEBREW_NO_AUTO_UPDATE='1',
            HOMEBREW_NO_ANALYTICS='1', HOMEBREW_NO_INSTALL_CLEANUP='1',
            PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin')
        try:
            return subprocess.run(['/opt/homebrew/bin/brew', *arguments], env=environment, timeout=480).returncode
        finally:
            subprocess.run(['/usr/bin/sudo', '-k'], check=False)


if __name__ == '__main__':
    sys.exit(main())
