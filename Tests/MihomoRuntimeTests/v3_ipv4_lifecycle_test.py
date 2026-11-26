#!/usr/bin/env python3
"""Installed VM regression for both Direct states after IPv4 approval migration.

Run as root in mimo-vm with current controls and v3_installed_test.py in the
owner-only directory passed as argv[1]. Original settings are restored on success.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import sys
import v3_installed_test as t

ROOT = Path(sys.argv[1])
SUPPORT = Path('/Library/Application Support/Mimo')
checks = []


def check(name, success):
    checks.append(dict(id=name, passed=bool(success)))
    (ROOT / 'direct-lifecycle.json').write_text(json.dumps(checks, indent=2))
    print(name + ': ' + ('PASS' if success else 'FAIL'), flush=True)
    assert success, name


def private_digests():
    data = plistlib.loads((SUPPORT / 'Service/state.plist').read_bytes())
    return {key: hashlib.sha256(str(data.get(key)).encode()).hexdigest()
            for key in ('service.local-ipinfo-token', 'service.local-proxy-passwords')}


def native(label):
    check(label + '-pf-empty', not t.run(['/sbin/pfctl', '-a', t.ANCHOR, '-sr']).stdout.strip())
    check(label + '-dns-released', '1053' not in t.run(['/usr/sbin/scutil', '--dns']).stdout)
    check(label + '-tun-absent', t.run(['/sbin/ifconfig', 'utun239']).returncode != 0)
    value = t.run(['/usr/bin/perl', '/Applications/Mimo.app/Contents/Resources/release-network.pl', '--verify-native'], 30)
    (ROOT / (label + '-native.log')).write_text(value.stdout + value.stderr)
    check(label + '-native-verification', value.returncode == 0)


def main():
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    original = t.state()
    assert not original['hasIPinfoToken'], 'Do not send a saved token during native checks'
    (ROOT / 'before.json').write_text(json.dumps(original))
    secrets = private_digests()
    t.route('direct'); t.wait_active('direct', 60)
    native('managed-direct')
    check('managed-direct-engine-running', t.run(['/bin/launchctl', 'print', 'system/com.mimo.mihomo']).returncode == 0)
    # Lower-level deactivation is the same core-owned operation the dashboard invokes.
    result = t.run(['/bin/bash', '/Applications/Mimo.app/Contents/Resources/daemon.sh', 'deactivate'], 150)
    (ROOT / 'deactivate.log').write_text(result.stdout + result.stderr)
    check('stop-completed', result.returncode == 0)
    native('released-direct')
    check('released-direct-services-absent', all(t.run(['/bin/launchctl', 'print', 'system/com.mimo.' + role]).returncode != 0
        for role in ('core', 'supervisor', 'mihomo', 'pf-boot', 'infrastructure')))
    check('released-direct-monitoring-marker', (SUPPORT / 'deactivated').is_file())
    result = t.run(['/bin/bash', '/Applications/Mimo.app/Contents/Resources/daemon.sh', 'install', '--non-interactive'], 150)
    (ROOT / 'activate.log').write_text(result.stdout + result.stderr)
    check('activate-completed', result.returncode == 0)
    active = t.wait_active('direct', 60)
    services = {item['id']: item['health'] for item in active['routing']['services']}
    check('activate-restores-all-services', all(services.get(role) == 'running' for role in ('core', 'mihomo', 'profileHosting')))
    native('reactivated-direct')
    check('migration-survives-restart', active['settings'] == original['settings'])
    check('credentials-retained', private_digests() == secrets)
    t.request('configureRouting', routing=original['routing']['configuration'])
    restored = t.state()
    check('original-routing-restored', restored['routing']['configuration'] == original['routing']['configuration'])
    check('original-settings-restored', restored['settings'] == original['settings'])


if __name__ == '__main__':
    main()
