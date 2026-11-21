#!/usr/bin/env python3
"""Focused real-VM assertions for the v1.0 namespace migration.

Run as root with OP BASELINE; BASELINE is an earlier release_brew_state.py
private evidence directory. Output contains only check names, never user data.
Place new acceptance-client and installation-check in ./helpers first.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent
ROOT = Path('/Library/Application Support/Mimo')
OLD = Path('/Library/Application Support/ExitIPMonitor')
APP = Path('/Applications/Mimo.app')
LABELS = ('com.mimo.core', 'com.mimo.supervisor', 'com.mimo.mihomo', 'com.mimo.pf-boot', 'com.mimo.infrastructure')
OLD_LABELS = ('com.example.exitipmonitor.daemon', 'com.example.exitipmonitor.supervisor', 'com.example.exitipmonitor.mihomo')


def run(*args, check=True):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, timeout=50)
    if check and result.returncode:
        raise AssertionError('Command failed: ' + Path(args[0]).name)
    return result


def record(name):
    print('PASS: ' + name, flush=True)


def settings(path):
    value = plistlib.loads(path.read_bytes())
    result = {k: v for k, v in value.items() if k.startswith('service.') and k != 'service.revision'}
    for key, item in result.items():
        if isinstance(item, (str, bytes)):
            try:
                result[key] = json.loads(item)
            except ValueError:
                pass
    return result


def state():
    return json.loads(run(BASE/'helpers/installation-check').stdout)


def wait_mode(mode):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        value = state()
        if value.get('phase') == 'active' and value.get('effectiveMode') == mode and not value.get('backgroundVerification'):
            return value
        time.sleep(0.25)
    raise AssertionError('Mode did not become active: ' + mode)


def main():
    assert os.geteuid() == 0
    assert run('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    operation, baseline_text = sys.argv[1:]
    baseline = Path(baseline_text)
    assert baseline.parent == Path('/var/tmp') and baseline.stat().st_uid == 0
    assert baseline.stat().st_mode & 0o077 == 0
    assert settings(ROOT/'Service/state.plist') == settings(baseline/'state.plist')
    assert run(BASE/'helpers/acceptance-client', 'credential-digest').stdout.strip() == (baseline/'credential.digest').read_text().strip()
    assert json.loads((ROOT/'Runtime/services.json').read_bytes()) == json.loads((baseline/'services.json').read_bytes())
    record(operation + '-retains-proxy-allowlist-credentials-and-service-intent')
    assert not OLD.exists()
    assert not Path('/Library/Logs/ExitIPMonitor').exists()
    for label in OLD_LABELS:
        assert run('/bin/launchctl', 'print', 'system/'+label, check=False).returncode == 113
        assert not Path('/Library/LaunchDaemons', label+'.plist').exists()
    assert run('/usr/bin/security', 'authorizationdb', 'read', 'com.example.exitipmonitor.configure', check=False).returncode != 0
    for account in ('ipinfo-lite-token', 'mimo-machine-proxy-password'):
        assert run('/usr/bin/security', 'find-generic-password', '-s', 'com.example.exitipmonitor.daemon',
                   '-a', account, '/Library/Keychains/System.keychain', check=False).returncode == 44
    legacy = run('/bin/launchctl', 'asuser', '501', '/usr/bin/sudo', '-n', '-H', '-u', 'jay', '--',
                 BASE/'LegacyProbe/Mimo.app/Contents/MacOS/mimo-gui', '--login-item-status').stdout.strip()
    assert legacy in ('notRegistered; saved=unset', 'notFound; saved=unset')
    record('old-storage-jobs-right-and-enabled-login-registration-retired')
    if operation in ('installed', 'fresh'):
        info = plistlib.loads((APP/'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] == 'com.mimo' and info['CFBundleShortVersionString'] == '1.0'
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', APP)
        assert (APP/'Contents/MacOS/mimo-core').read_bytes() == Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()
        for label in LABELS:
            run('/bin/launchctl', 'print', 'system/'+label)
        current = wait_mode('direct')
        assert current['infrastructure']['pf'] == 'healthy' and current['infrastructure']['launchd'] == 'healthy'
        assert 'IPv6: Off' in run('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout
        assert plistlib.loads((ROOT/'Runtime/ipv6-original.plist').read_bytes()) == plistlib.loads((baseline/'ipv6-original.plist').read_bytes())
        record('new-app-service-identities-signature-PF-launchd-and-IPv4-policy-healthy')
        if operation == 'fresh':
            assert not Path('/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage').exists()
            assert not Path('/etc/sudoers.d/exitipmonitor-service').exists()
            record('fresh-install-has-no-legacy-manager-or-removal-grant')
        else:
            bridge = Path('/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage')
            assert '# Mimo legacy uninstall bridge' in bridge.read_text()
            record('cached-Homebrew-hook-has-fixed-uninstall-only-bridge')
            try:
                run(BASE/'helpers/acceptance-client', 'mode', 'rule')
                current = wait_mode('rule')
                approved = settings(baseline/'state.plist')['service.settings']['allowlist']['addresses']
                assert current['observedIP']['address'] in approved
                run(BASE/'helpers/acceptance-client', 'check-private-profile')
                record('Rule-approves-real-saved-proxy-and-private-profile-after-migration')
            finally:
                run(BASE/'helpers/acceptance-client', 'mode', 'direct')
                wait_mode('direct')
            record('Direct-recovered-after-protected-check')
    elif operation == 'uninstalled':
        assert not APP.exists()
        for label in LABELS:
            assert run('/bin/launchctl', 'print', 'system/'+label, check=False).returncode == 113
            assert not Path('/Library/LaunchDaemons', label+'.plist').exists()
        for name in ('mimo-core', 'mimo-manage', 'MimoUninstaller.app', 'com.example.exitipmonitor.manage'):
            assert not Path('/Library/PrivilegedHelperTools', name).exists()
        for name in ('mimo-service', 'exitipmonitor-service'):
            assert not Path('/etc/sudoers.d', name).exists()
        assert '# BEGIN MIMO BOOT GUARD' not in Path('/etc/pf.conf').read_text()
        assert not Path('/etc/pf.anchors/com.mimo.boot').exists()
        assert not run('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout.strip()
        assert not (ROOT/'Guard').exists() and not (ROOT/'Mihomo').exists()
        assert set(p.name for p in (ROOT/'Runtime').iterdir()) == {'services.json'}
        assert set(p.name for p in (ROOT/'Service').iterdir()) == {'state.plist'}
        record('uninstall-removes-app-owned-jobs-helpers-PF-runtime-and-compatibility-bridge')
        original = plistlib.loads((baseline/'ipv6-original.plist').read_bytes())
        network = plistlib.loads(Path('/Library/Preferences/SystemConfiguration/preferences.plist').read_bytes())['NetworkServices']
        for key, enabled in original.items():
            if key in network and 'IPv6' in network[key]:
                assert (not bool(network[key]['IPv6'].get('__INACTIVE__', 0))) == enabled
        run('/usr/bin/sudo', '-n', '-H', '-u', 'jay', '/usr/bin/curl', '--fail', '--silent', '--noproxy', '*', '--max-time', '15', '--head', 'https://one.one.one.one/')
        record('uninstall-restores-original-IPv6-flags-and-ordinary-user-HTTPS')
    else:
        raise AssertionError('Unknown operation')


if __name__ == '__main__':
    main()
