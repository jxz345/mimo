#!/usr/bin/env python3
"""VM-only PF/launchd fault tests, uninstall/reinstall, and optional real reboot.

Preserves private settings in a root-only evidence directory. The boot worker
restores the helper even if an assertion fails; no production qualification is
created. Network mutations are refused outside an Apple VirtualMac guest.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

SUPPORT = Path('/Library/Application Support/Mimo')
RUNTIME = SUPPORT / 'Runtime'
GUARD = Path('/Library/Application Support/Mimo/Guard')
HELPER = Path('/Library/PrivilegedHelperTools/mimo-core')
SUPERVISOR = 'com.mimo.supervisor'
CORE = 'com.mimo.core'
ENGINE = 'com.mimo.mihomo'
HEALTH = 'com.mimo.infrastructure'
BOOT = 'com.mimo.pf-boot'
WORKER = 'com.mimo.infrastructure-acceptance'
WORKER_PLIST = Path('/Library/LaunchDaemons') / (WORKER + '.plist')
CLIENT = Path('/Users/jay/mimo-tests/release/installation-check')
STORAGE = SUPPORT / 'Service/state.plist'
EVIDENCE = None
PASSED = []
MUTATED = False


def command(*args, timeout=35, check=True):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    with (EVIDENCE / 'commands.log').open('a') as f:
        # Arguments are fixed test commands, never profile contents/passwords.
        f.write('COMMAND ' + ' '.join(str(a) for a in args) + '\n' + result.stdout + result.stderr)
    if check and result.returncode:
        raise RuntimeError('Command failed: ' + str(args[0]) + ' (see private commands.log)')
    return result


def wait(predicate, name, timeout=65):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                passed(name)
                return
        except (OSError, ValueError, subprocess.TimeoutExpired, RuntimeError):
            pass
        time.sleep(0.5)
    raise AssertionError(name + ' timed out')


def passed(name):
    PASSED.append(name)
    print('PASS:', name, flush=True)


def job(label):
    result = command('/bin/launchctl', 'print', 'system/' + label, check=False)
    if result.returncode == 113:
        return None
    if result.returncode:
        raise RuntimeError('Cannot inspect launchd')
    return result.stdout


def state(*args):
    return json.loads(command(CLIENT, *args).stdout)


def direct():
    value = state()
    return value['phase'] == 'active' and value.get('effectiveMode') == 'direct' and (RUNTIME / 'gate.state').read_text() == 'direct'


def atomic_write(path, data, mode=0o600):
    fd, temp = tempfile.mkstemp(prefix='.infrastructure-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def root_lock():
    f = (RUNTIME / 'firewall.lock').open('a+b')
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def saved_configuration(data):
    return {k: v for k, v in plistlib.loads(data).items() if k.startswith('service.')}


def restore_configuration():
    original = plistlib.loads((EVIDENCE / 'original-settings.plist').read_bytes())
    current = plistlib.loads(STORAGE.read_bytes())
    # Restoring the user's configuration must not refund consumed lookup quota.
    original.update({k: v for k, v in current.items() if not k.startswith('service.')})
    atomic_write(STORAGE, plistlib.dumps(original, fmt=plistlib.FMT_BINARY))


def report(success, **extra):
    (EVIDENCE / 'report.json').write_text(json.dumps(dict(success=success, checks=PASSED,
        releaseQualificationGranted=False, **extra), indent=2) + '\n')


def restore_saved():
    for label in (CORE, ENGINE, SUPERVISOR):
        command('/bin/launchctl', 'bootout', 'system/' + label, check=False)
    time.sleep(1)
    with (STORAGE.parent / 'instance.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        restore_configuration()
    atomic_write(RUNTIME / 'services.json', (EVIDENCE / 'original-services.json').read_bytes())


def boot_worker(root):
    global EVIDENCE, PASSED
    EVIDENCE = root
    plan = json.loads((root / 'boot-plan.json').read_text())
    PASSED = plan['checks']
    error = None
    try:
        before = plan['boot']
        current = command('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid').stdout.strip()
        assert current != before
        wait(lambda: (GUARD / 'boot.id').read_text() == current, 'independent-guard-ran-after-real-reboot')
        assert not HELPER.exists(), 'Main helper must still be unavailable'
        for label in (CORE, SUPERVISOR, ENGINE):
            assert 'state = running' not in (job(label) or '')
        passed('core-supervisor-and-mihomo-unavailable')
        assert 'Status: Enabled' in command('/sbin/pfctl', '-s', 'info').stdout
        actual = command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout
        assert 'block drop out quick all' in actual
        passed('PF-enabled-with-blocking-anchor-without-main-helper')
        # Probes target a known numeric public endpoint; no DNS failure can be
        # mistaken for the required IPv4 block.
        for _ in range(3):
            try:
                with socket.create_connection(('1.1.1.1', 443), timeout=2):
                    raise AssertionError('Public TCP connected while main helpers were absent')
            except (TimeoutError, OSError):
                pass
        passed('public-IPv4-blocked-without-Mimo-or-mihomo')
        (RUNTIME / 'maintenance').unlink(missing_ok=True)
        wait(lambda: json.loads((GUARD / 'health.json').read_text()).get('launchd') == 'unavailable', 'missing-helper-is-reported-by-independent-monitor')
    except Exception as exc:
        error = str(exc)
    finally:
        atomic_write(RUNTIME / 'maintenance', b'')
        if not HELPER.exists():
            os.replace(root / 'boot-helper', HELPER)
        try:
            command(HELPER, '--begin-maintenance')
            restore_saved()
            (RUNTIME / 'maintenance').unlink()
            command('/bin/launchctl', 'enable', 'system/' + SUPERVISOR)
            command('/bin/launchctl', 'bootstrap', 'system', '/Library/LaunchDaemons/' + SUPERVISOR + '.plist', check=False)
            wait(direct, 'original-Direct-restored-after-boot-test')
            assert saved_configuration(STORAGE.read_bytes()) == saved_configuration((root / 'original-settings.plist').read_bytes())
            assert (RUNTIME / 'services.json').read_bytes() == (root / 'original-services.json').read_bytes()
            passed('original-settings-and-service-intent-retained')
        except Exception as exc:
            error = (error or '') + '; restoration: ' + str(exc)
        report(error is None, rebootTested=True, error=error, bootProtectionFromFirstPacket=False)
        WORKER_PLIST.unlink(missing_ok=True)
        command('/bin/launchctl', 'bootout', 'system/' + WORKER, check=False)


def main(app, reboot):
    global EVIDENCE, MUTATED
    EVIDENCE = Path(tempfile.mkdtemp(prefix='mimo-infrastructure-test-', dir='/var/tmp'))
    os.chmod(EVIDENCE, 0o700)
    print('Evidence:', EVIDENCE, flush=True)
    shutil.copyfile(STORAGE, EVIDENCE / 'original-settings.plist')
    shutil.copyfile(RUNTIME / 'services.json', EVIDENCE / 'original-services.json')
    original_pf = Path('/etc/pf.conf').read_bytes()
    (EVIDENCE / 'original-pf.conf').write_bytes(original_pf)
    assert command(HELPER, '--installation-mode').stdout.strip() == 'direct', 'Test expects the existing Direct baseline'
    installer = app / 'Contents/Resources/daemon.sh'
    MUTATED = True
    command('/usr/bin/env', 'SUDO_USER=jay', '/bin/bash', installer, 'install', timeout=200)
    wait(direct, 'candidate-install-restores-Direct')
    wait(lambda: state().get('infrastructure', {}).get('pf') == 'healthy' and state().get('infrastructure', {}).get('launchd') == 'healthy', 'PF-and-launchd-health-published-over-XPC')
    for label in (BOOT, HEALTH):
        assert job(label) is not None
    passed('independent-boot-and-health-jobs-registered')
    assert Path('/etc/pf.anchors/com.mimo.boot').read_text() == command(HELPER, '--print-startup-firewall').stdout
    assert 'load anchor "com.apple/000.mimo" from "/etc/pf.anchors/com.mimo.boot"' in Path('/etc/pf.conf').read_text()
    passed('persistent-policy-matches-startup-firewall')
    command('/usr/sbin/networksetup', '-setv6automatic', 'Ethernet')
    wait(lambda: 'IPv6: Off' in command('/usr/sbin/networksetup', '-getinfo', 'Ethernet').stdout, 'reenabled-IPv6-is-disabled-after-network-change')
    wait(direct, 'Direct-recovers-after-IPv6-policy-repair')
    with root_lock():
        command('/sbin/pfctl', '-d')
    wait(lambda: 'Status: Enabled' in command('/sbin/pfctl', '-s', 'info').stdout, 'disabled-PF-is-reenabled')
    wait(direct, 'Direct-recovers-after-PF-repair')
    with root_lock():
        command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-F', 'rules')
    wait(lambda: bool(command('/sbin/pfctl', '-a', 'com.apple/000.mimo', '-sr').stdout.strip()), 'deleted-PF-anchor-is-restored')
    wait(direct, 'Direct-recovers-after-anchor-repair')
    with root_lock():
        Path('/etc/pf.anchors/com.mimo.boot').unlink()
        config = Path('/etc/pf.conf')
        text = config.read_text()
        begin = text.index('# BEGIN MIMO BOOT GUARD\n')
        end = text.index('# END MIMO BOOT GUARD\n') + len('# END MIMO BOOT GUARD\n')
        atomic_write(config, (text[:begin] + text[end:]).encode(), 0o644)
    wait(lambda: Path('/etc/pf.anchors/com.mimo.boot').exists() and '# BEGIN MIMO BOOT GUARD' in Path('/etc/pf.conf').read_text(), 'deleted-persistent-PF-policy-is-repaired')
    for label in (ENGINE, CORE, SUPERVISOR, HEALTH, BOOT):
        command('/bin/launchctl', 'disable', 'system/' + label)
        command('/bin/launchctl', 'bootout', 'system/' + label, check=False)
        wait(lambda label=label: job(label) is not None, 'missing-job-restored-' + label)
        wait(direct, 'Direct-recovers-' + label)
    engine_plist = SUPPORT / 'LaunchDaemons' / (ENGINE + '.plist')
    data = plistlib.loads(engine_plist.read_bytes())
    data['KeepAlive'] = False
    atomic_write(engine_plist, plistlib.dumps(data), 0o644)
    wait(lambda: plistlib.loads(engine_plist.read_bytes())['KeepAlive'] is True, 'damaged-engine-startup-plist-repaired')
    wait(direct, 'Direct-recovers-after-plist-repair')
    state('core', 'stop'); state('mihomo', 'stop')
    time.sleep(22)
    assert job(CORE) is None and job(ENGINE) is None
    passed('saved-Stop-choices-survive-health-repairs')
    state('mihomo', 'start'); state('core', 'start')
    wait(direct, 'explicit-Start-recovers')
    reference = command('/sbin/pfctl', '-E')
    token = re.search(r'Token\s*:\s*(\d+)', reference.stdout + reference.stderr).group(1)
    (EVIDENCE / 'test-pf-reference').write_text(token)
    command('/bin/bash', installer, 'uninstall', timeout=180)
    assert '# BEGIN MIMO BOOT GUARD' not in Path('/etc/pf.conf').read_text()
    for label in (BOOT, HEALTH, CORE, ENGINE, SUPERVISOR):
        assert job(label) is None
    assert not Path('/etc/pf.anchors/com.mimo.boot').exists()
    references = command('/sbin/pfctl', '-s', 'References').stdout
    assert re.search(r'^\d+\s+\S+\s+' + re.escape(token) + r'\s', references, re.M)
    assert 'Status: Enabled' in command('/sbin/pfctl', '-s', 'info').stdout
    command('/sbin/pfctl', '-X', token)
    (EVIDENCE / 'test-pf-reference').unlink()
    expected_pf = re.sub(rb'# BEGIN MIMO BOOT GUARD\nload anchor "com.apple/000.mimo" from "/etc/pf.anchors/com.mimo.boot"\n# END MIMO BOOT GUARD\n?', b'', original_pf)
    assert Path('/etc/pf.conf').read_bytes() == expected_pf
    passed('uninstall-preserves-unrelated-PF-configuration-and-owner')
    with socket.create_connection(('1.1.1.1', 443), timeout=5):
        pass
    passed('uninstall-removes-independent-policy-and-restores-network')
    # Restore the saved source state before reinstall, preserving user settings.
    restore_configuration()
    atomic_write(RUNTIME / 'services.json', (EVIDENCE / 'original-services.json').read_bytes())
    command('/usr/bin/env', 'SUDO_USER=jay', '/bin/bash', installer, 'install', timeout=200)
    wait(direct, 'reinstall-restores-original-Direct')
    if not reboot:
        report(True, rebootTested=False)
        return
    atomic_write(RUNTIME / 'maintenance', b'')
    for label in (CORE, ENGINE, SUPERVISOR):
        command('/bin/launchctl', 'bootout', 'system/' + label, check=False)
    time.sleep(1)
    os.replace(HELPER, EVIDENCE / 'boot-helper')
    shutil.copyfile(Path(__file__), EVIDENCE / 'worker.py')
    os.chmod(EVIDENCE / 'worker.py', 0o600)
    (EVIDENCE / 'boot-plan.json').write_text(json.dumps(dict(checks=PASSED, boot=command('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid').stdout.strip())))
    atomic_write(WORKER_PLIST, plistlib.dumps(dict(Label=WORKER, ProgramArguments=['/usr/bin/python3', str(EVIDENCE / 'worker.py'), '--boot-worker', str(EVIDENCE)], RunAtLoad=True, StandardOutPath=str(EVIDENCE / 'boot.log'), StandardErrorPath=str(EVIDENCE / 'boot.log'))), 0o644)
    # Do not bootstrap the worker in the current boot.
    print('Rebooting once with the Mimo helper unavailable. The boot worker will restore it.', flush=True)
    command('/sbin/shutdown', '-r', 'now')


if __name__ == '__main__':
    if os.geteuid() != 0 or not subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).startswith('VirtualMac'):
        sys.exit('This test requires root inside the isolated Apple VirtualMac guest.')
    if len(sys.argv) == 3 and sys.argv[1] == '--boot-worker':
        boot_worker(Path(sys.argv[2]))
    elif len(sys.argv) in (2, 3):
        try:
            main(Path(sys.argv[1]).resolve(), '--reboot' in sys.argv[2:])
        except Exception as exc:
            recovery_error = None
            if MUTATED:
                try:
                    if not HELPER.exists() and (EVIDENCE / 'boot-helper').exists():
                        os.replace(EVIDENCE / 'boot-helper', HELPER)
                    WORKER_PLIST.unlink(missing_ok=True)
                    atomic_write(RUNTIME / 'maintenance', b'')
                    restore_saved()
                    command(HELPER, '--restore-direct-offline', timeout=45)
                    (RUNTIME / 'maintenance').unlink()
                    command('/bin/launchctl', 'enable', 'system/' + SUPERVISOR)
                    command('/bin/launchctl', 'bootstrap', 'system', '/Library/LaunchDaemons/' + SUPERVISOR + '.plist', check=False)
                    wait(direct, 'failure-cleanup-restores-original-Direct')
                    if (EVIDENCE / 'test-pf-reference').exists():
                        command('/sbin/pfctl', '-X', (EVIDENCE / 'test-pf-reference').read_text(), check=False)
                        (EVIDENCE / 'test-pf-reference').unlink()
                except Exception as recovery:
                    recovery_error = str(recovery)
            if EVIDENCE:
                report(False, error=str(exc), recoveryError=recovery_error)
            raise
    else:
        sys.exit('Usage: infrastructure_test.py /path/to/Mimo.app [--reboot]')
