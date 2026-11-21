#!/usr/bin/env python3
"""Focused real-VM removal assertions; invoke after Homebrew uninstall.

Keep a verified test copy of Mimo.app outside Applications before removal and
pass its path here. It only queries ServiceManagement in each account; this
script neither installs services nor changes system/login preferences.
"""
import os
from pathlib import Path
import subprocess
import sys


def command(*args):
    return subprocess.run([str(arg) for arg in args], capture_output=True, text=True, timeout=25)


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/scutil', '--get', 'LocalHostName').stdout.strip() == 'mimo-vm'
    probe = Path(sys.argv[1]) / 'Contents/MacOS/mimo-gui'
    assert probe.is_file() and probe.stat().st_uid == 0
    root = Path('/Library/Application Support/Mimo')
    assert not Path('/Applications/Mimo.app').exists()
    processes = command('/bin/ps', '-axo', 'comm=')
    assert processes.returncode == 0
    assert not any(Path(line.strip()).name in ('mimo-gui', 'mimo-core')
                   or line.strip().endswith(('/Runtime/mihomo', '/Mihomo/mihomo')) for line in processes.stdout.splitlines())
    assert command('/usr/bin/dscl', '.', '-read', '/Groups/_mimo').returncode != 0
    assert command('/usr/bin/security', 'authorizationdb', 'read', 'com.mimo.configure').returncode != 0
    print('PASS: app-processes-private-group-and-installer-authorization-right-removed', flush=True)
    for path in [Path('/Library/PrivilegedHelperTools/MimoUninstaller.app'), root/'LaunchDaemons', root/'TailscaleVerge',
                 root/'installed-app', root/'command-support.sh', root/'cleanup-installation.sh',
                 Path('/Library/Application Support/Mimo/Guard'),
                 Path('/Library/Application Support/Mimo/Mihomo')]:
        assert not path.exists(), str(path)
    assert set(p.name for p in (root/'Runtime').iterdir()) == {'services.json'}
    assert set(p.name for p in (root/'Service').iterdir()) == {'state.plist'}
    print('PASS: runtime-secrets-caches-cleanup-copy-and-installer-staging-removed', flush=True)
    users = command('/usr/bin/dscl', '/Search', '-list', '/Users', 'UniqueID')
    assert users.returncode == 0
    count = 0
    for line in users.stdout.splitlines():
        name, uid = line.split()
        if not 500 <= int(uid) < 65534:
            continue
        result = command('/bin/launchctl', 'asuser', uid, '/usr/bin/sudo', '-n', '-H', '-u', name,
                         '--', probe, '--login-item-status')
        assert result.returncode == 0, name
        assert result.stdout.strip() in ('notFound; saved=unset', 'notRegistered; saved=unset'), name
        count += 1
    assert count >= 2
    print(f'PASS: login-items-unregistered-and-preferences-cleared-for-{count}-accounts', flush=True)


if __name__ == '__main__':
    main()
