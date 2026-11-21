#!/usr/bin/env python3
"""Root assertions and recovery for the isolated Homebrew acceptance test."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import stat
import subprocess
import sys
import tempfile

from upgrade_test import CORE, ENGINE, SUPERVISOR, RUNTIME, STORAGE, FLAGS, HELPER, MANAGER, APP, read_settings, atomic_write

LOCKS = Path('/opt/homebrew/var/homebrew/locks')
BREW_DIRECTORIES = [Path('/opt/homebrew') / relative for relative in (
    '', 'etc/bash_completion.d', 'share/doc', 'share/fish', 'share/fish/vendor_completions.d',
    'share/man', 'share/man/man1', 'share/zsh', 'share/zsh/site-functions', 'var/homebrew/locks',
    'var/homebrew/tmp')]


def call(*args, check=True):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=180, check=check)


def state(*args):
    return json.loads(call(Path(__file__).parent / 'installation-check', *args).stdout)


def main():
    assert os.geteuid() == 0
    assert call('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    operation = sys.argv[1]
    if operation == 'prepare':
        original = read_settings()
        assert 'service.settings' not in original
        assert json.loads(original.get('service.routing', b'{}')).get('mode', 'direct') == 'direct'
        assert state()['effectiveMode'] == 'direct'
        assert not (RUNTIME / 'qualification.json').exists()
        assert not Path('/Applications/Mimo.app').exists()
        root = Path(tempfile.mkdtemp(prefix='mimo-brew-test-', dir='/var/tmp'))
        (root / 'state.plist').write_bytes(STORAGE.read_bytes())
        (root / 'services.json').write_bytes(FLAGS.read_bytes())
        (root / 'locks.json').write_text(json.dumps({'mode': stat.S_IMODE(LOCKS.stat().st_mode),
            'files': [p.name for p in LOCKS.iterdir()]}))
        (root / 'permissions.json').write_text(json.dumps({str(path): stat.S_IMODE(path.stat().st_mode)
            for path in BREW_DIRECTORIES}))
        lock_metadata = {}
        for name in {'mihomo@1.19.34.formula.lock', 'mimo.cask.lock', 'mimo.cask.lock',
                     *(p.name for p in LOCKS.glob('*.download.lock'))}:
            path = LOCKS / name
            if path.exists():
                info = path.stat()
                lock_metadata[name] = [info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)]
                os.chown(path, info.st_uid, 80)
                path.chmod(0o664)
        (root / 'lock-metadata.json').write_text(json.dumps(lock_metadata))
        # This existing administrator needs to create its own Homebrew lockfiles;
        # the normal brew owner is jay. Restore the directory mode afterwards.
        for path in BREW_DIRECTORIES:
            assert path.stat().st_gid == 80 and not path.is_symlink()
            path.chmod(path.stat().st_mode | stat.S_IWGRP)
        call(MANAGER, 'uninstall')
        ipv6 = call('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
        (root / 'ipv6-before.txt').write_text(next(line for line in ipv6.splitlines() if line.startswith('IPv6:')))
        print(json.dumps({'evidence': str(root)}))
        return
    root = Path(sys.argv[2])
    assert root.parent == Path('/var/tmp') and root.name.startswith('mimo-brew-test-')
    assert root.stat().st_uid == 0 and stat.S_IMODE(root.stat().st_mode) == 0o700
    if operation == 'installed':
        result = state()
        assert result['effectiveMode'] == 'direct'
        expected = 'stopped' if len(sys.argv) > 3 and sys.argv[3] == 'stopped' else 'running'
        assert next(s for s in result['services'] if s['id'] == 'core')['health'] == expected
        assert hashlib.sha256(HELPER.read_bytes()).digest() == hashlib.sha256(Path('/Applications/Mimo.app/Contents/MacOS/mimo-core').read_bytes()).digest()
        assert hashlib.sha256((RUNTIME / 'mihomo').read_bytes()).hexdigest() == 'a55a9073f9b7b1fa596a82c034d2dae3407ec34732102b6e42c5513ce3033f34'
        call('/usr/bin/codesign', '--verify', '--deep', '--strict', '/Applications/Mimo.app')
        assert 'IPv6: Off' in call('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
        assert (RUNTIME / 'ipv6-original.plist').exists()
        rules = call('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout
        assert 'block' in rules and 'inet6' in rules
    elif operation == 'uninstalled':
        assert not Path('/Applications/Mimo.app').exists()
        assert not HELPER.exists() and not MANAGER.exists() and not (RUNTIME / 'mihomo').exists()
        for name in ('candidate.yaml', 'blocking.yaml', 'reload.json', 'controller.sock', 'guard.pf', 'native-transport.pf'):
            assert not (RUNTIME / name).exists(), 'Generated runtime artifact retained: ' + name
        for label in (CORE, ENGINE, SUPERVISOR):
            assert call('/bin/launchctl', 'print', 'system/' + label, check=False).returncode == 113
        assert not call('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout.strip()
        assert 'port     : 1053' not in call('/usr/sbin/scutil', '--dns').stdout
        assert not (RUNTIME / 'ipv6-original.plist').exists()
        ipv6 = call('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
        assert (root / 'ipv6-before.txt').read_text() in ipv6
        saved = plistlib.loads((root / 'state.plist').read_bytes())
        current = read_settings()
        for key in ('service.settings', 'service.routing'):
            assert saved.get(key) == current.get(key), key + ' was not retained'
        call('/usr/bin/sudo', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail', '--max-time', '15', '--noproxy', '*', '--head', 'https://github.com/robots.txt')
    elif operation == 'dependency-absent':
        assert not Path('/opt/homebrew/Cellar/mihomo@1.19.34').exists()
        assert not Path('/opt/homebrew/opt/mihomo@1.19.34').exists()
        assert not Path('/opt/homebrew/bin/mihomo').exists()
    elif operation == 'restore':
        if MANAGER.exists():
            call(MANAGER, 'uninstall')
        atomic_write(STORAGE, (root / 'state.plist').read_bytes())
        atomic_write(FLAGS, (root / 'services.json').read_bytes())
        locks = json.loads((root / 'locks.json').read_text())
        account = pwd.getpwnam('jay')
        for path in LOCKS.iterdir():
            if path.name not in locks['files'] and path.is_file() and not path.is_symlink():
                os.chown(path, account.pw_uid, 80)
                path.chmod(0o644)
        LOCKS.chmod(locks['mode'])
        if (root / 'lock-metadata.json').exists():
            for name, (uid, gid, mode) in json.loads((root / 'lock-metadata.json').read_text()).items():
                path = LOCKS / name
                if path.exists():
                    os.chown(path, uid, gid)
                    path.chmod(mode)
        if (root / 'permissions.json').exists():
            for path, mode in json.loads((root / 'permissions.json').read_text()).items():
                Path(path).chmod(mode)
        call('/usr/bin/env', 'SUDO_USER=jay', '/bin/bash', APP / 'Contents/Resources/daemon.sh', 'install')
        assert state()['effectiveMode'] == 'direct'
        assert not (RUNTIME / 'qualification.json').exists()
    else:
        raise AssertionError('Unknown test operation')
    print('PASS:', operation)


if __name__ == '__main__':
    main()
