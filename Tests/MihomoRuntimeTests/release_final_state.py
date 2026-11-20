#!/usr/bin/env python3
"""Read-only final restoration check after installed-Release VM acceptance."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import sys
import tempfile

from installed_acceptance_test import command
from saved_proxy_test import selected_settings
from upgrade_test import CORE, SUPERVISOR, ENGINE, RUNTIME, STORAGE, FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent
APP = Path('/Applications/Mimo.app')


def configuration_values(value):
    # GUI saves can re-encode identical JSON with a different key order and
    # legitimately advance the conflict revision. Compare every configuration
    # value, not the serialization order of nested Codable JSON data.
    result = selected_settings(value)
    result.pop('service.revision', None)
    for key, item in result.items():
        if isinstance(item, (str, bytes)):
            try:
                result[key] = json.loads(item)
            except ValueError:
                pass
    return result


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = Path(sys.argv[1]) / 'private-backup'
    expected_native = sys.argv[2] if len(sys.argv) > 2 else 'Running'
    assert expected_native in ('Running', 'Stopped')
    assert original.parent.parent == Path('/var/tmp') and original.stat().st_uid == 0
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-release-final-', dir='/var/tmp'))
    checks = []

    def record(name):
        checks.append(name)
        print('PASS:', name, flush=True)

    manifest = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == manifest['helperSHA256']
    assert HELPER.read_bytes() == (APP / 'Contents/MacOS/mimo-core').read_bytes()
    assert hashlib.sha256((APP / 'Contents/MacOS/mimo-gui').read_bytes()).hexdigest() == manifest['guiSHA256']
    command('/usr/bin/codesign', '--verify', '--deep', '--strict', APP)
    record('normal-Release-app-helper-and-signature-match-tested-package')

    saved = plistlib.loads((original / 'state.plist').read_bytes())
    current = read_settings()
    assert configuration_values(current) == configuration_values(saved)
    assert current['service.revision'] >= saved['service.revision']
    assert json.loads(FLAGS.read_bytes()) == json.loads((original / 'services.json').read_bytes())
    assert command(BASE / 'acceptance-client', 'credential-digest').stdout.strip() == (original / 'credential.digest').read_text()
    record('original-saved-proxy-allowlist-password-and-service-intent-retained')

    state = json.loads(command(BASE / 'installation-check', 'core-state').stdout)
    supervisor = json.loads(command(BASE / 'installation-check').stdout)
    for value in (state['routing'], supervisor):
        assert value['phase'] == 'active' and value['effectiveMode'] == 'direct'
    assert (RUNTIME / 'gate.state').read_text() == 'direct'
    assert not state.get('allowlistEventID') and 'notAllowed' not in state.get('authorizationState', {})
    record('both-live-services-confirm-Direct-without-allowlist-rejection')
    assert supervisor['infrastructure']['pf'] == 'healthy'
    assert supervisor['infrastructure']['launchd'] == 'healthy'
    for label in (CORE, SUPERVISOR, ENGINE, 'com.mimo.pf-boot', 'com.mimo.infrastructure'):
        command('/bin/launchctl', 'print', 'system/' + label)
    assert 'IPv6: Off' in command('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
    record('PF-launchd-and-IPv4-only-policy-healthy')

    command('/usr/bin/sudo', '-n', '-H', '-u', 'jay', '/usr/bin/curl', '--fail', '--silent', '--noproxy', '*',
            '--max-time', '15', '--head', 'https://one.one.one.one/')
    native = command('/usr/bin/sudo', '-n', '-H', '-u', 'jay',
                     '/Applications/Tailscale.app/Contents/MacOS/Tailscale', 'status', '--json')
    assert json.loads(native.stdout)['BackendState'] == expected_native
    if expected_native == 'Stopped':
        assert not state['settings']['tailscaleProviderEnabled']
        assert state['routing'].get('tailnetExpected') is False
    record('ordinary-user-HTTPS-and-original-Tailscale-' + expected_native + '-state-restored')

    info = json.loads(command('/usr/bin/sudo', '-n', '-H', '-u', 'jay', '/opt/homebrew/bin/brew',
                              'info', '--json=v2', 'jxz345/tap/mihomo@1.19.34').stdout)
    assert info['formulae'][0]['installed'][0]['installed_on_request']
    record('original-explicit-mihomo-install-intent-restored')
    for marker in ('maintenance', 'qualification.json'):
        assert not (RUNTIME / marker).exists()
    for label in ('com.mimo.release-boot-test', 'com.mimo.infrastructure-acceptance'):
        assert not (Path('/Library/LaunchDaemons') / (label + '.plist')).exists()
        assert command('/bin/launchctl', 'print', 'system/' + label, check=False).returncode == 113
    assert not any(v.pw_name.startswith('_mimoaccept_') for v in pwd.getpwall())
    assert 'com.mimo.release-sleep-test' not in command('/usr/bin/pmset', '-g', 'sched').stdout
    assert '198.51.100.254' not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
    processes = command('/bin/ps', '-axo', 'command=').stdout
    assert not any('/usr/sbin/tcpdump ' in line and '/var/tmp/mimo-' in line for line in processes.splitlines())
    record('temporary-test-jobs-routes-captures-account-and-wake-alarm-removed')
    (root / 'report.json').write_text(json.dumps(dict(success=True, passed=checks,
        packageSHA256=manifest['packageSHA256'], helperSHA256=manifest['helperSHA256'],
        scope='Read-only final installed Release and restoration checks in mimo-vm'), indent=2) + '\n')
    print('Evidence:', root, flush=True)


if __name__ == '__main__':
    main()
