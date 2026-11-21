#!/usr/bin/env python3
"""Real guest sleep/wake acceptance; restores the unconfigured Direct installation.

Runs only on VirtualMac, schedules its own wake alarm, and never changes persistent
power preferences. An unsupported VM sleep is recorded as incomplete, not a pass.
"""
import datetime
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import tempfile
import time

from upgrade_test import (CORE, SUPERVISOR, ENGINE, RUNTIME, FLAGS, HELPER,
                          read_settings, write_settings, atomic_write)


def run():
    def command(*args, check=True, timeout=25):
        return subprocess.run([str(a) for a in args], capture_output=True, text=True, check=check, timeout=timeout)

    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = read_settings()
    routing = json.loads(original.get('service.routing', b'{}'))
    assert 'service.settings' not in original and not routing.get('proxy') and routing.get('mode', 'direct') == 'direct'
    assert not (RUNTIME / 'qualification.json').exists()
    flags = FLAGS.read_bytes()
    assert all(json.loads(flags).values())
    root = Path(tempfile.mkdtemp(prefix='mimo-sleep-test-', dir='/var/tmp'))
    backup = root / 'private-backup'
    backup.mkdir(mode=0o700)
    (backup / 'settings.plist').write_bytes(plistlib.dumps(original))
    (backup / 'services.json').write_bytes(flags)
    helper = Path(__file__).resolve().parent / 'installation-check'
    passed, alarm, success = [], None, False

    def state(*args):
        return json.loads(command(helper, *args).stdout)

    def wait_state(predicate):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            try:
                value = state()
                if predicate(value):
                    return value
            except (subprocess.SubprocessError, ValueError):
                pass
            time.sleep(0.2)
        raise AssertionError('Service state did not settle')

    def record(name):
        passed.append(name)
        print('PASS:', name, flush=True)

    def sleep_and_observe(name, check_requested):
        nonlocal alarm
        offsets = {p: p.stat().st_size for p in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl')}
        before = command('/usr/bin/pmset', '-g', 'stats').stdout
        alarm = (datetime.datetime.now() + datetime.timedelta(seconds=30)).strftime('%m/%d/%y %H:%M:%S')
        command('/usr/bin/pmset', 'schedule', 'wake', alarm, 'com.mimo.sleep-acceptance')
        print('Sleeping the isolated VM; its wake alarm is scheduled in 30 seconds.', flush=True)
        result = command('/usr/bin/pmset', 'sleepnow', check=False)
        (root / (name + '-sleep-command.txt')).write_text(result.stdout + result.stderr)
        assert result.returncode == 0, 'VM sleep was refused: ' + result.stdout + result.stderr
        deadline = time.time() + 60
        while time.time() < deadline:
            records = []
            for path in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl'):
                with path.open('rb') as stream:
                    stream.seek(offsets.get(path, 0))
                    for line in stream:
                        try:
                            value = json.loads(line)
                            if value['event'] in ('mimo_network_changed', 'refresh_requested', 'mimo_gate_closed'):
                                records.append(value)
                        except (ValueError, KeyError):
                            pass
            woke = any(v['event'] == 'mimo_network_changed' and v['fields'].get('source') == 'wake' for v in records)
            checked = any(v['event'] == 'refresh_requested' and v['fields'].get('trigger') == 'network_configuration' for v in records)
            after = command('/usr/bin/pmset', '-g', 'stats').stdout
            if woke and (checked or not check_requested) and before != after:
                (root / (name + '.json')).write_text(json.dumps({'before': before, 'after': after, 'events': records}, indent=2))
                command('/usr/bin/pmset', 'schedule', 'cancel', 'wake', alarm, 'com.mimo.sleep-acceptance', check=False)
                alarm = None
                record(name)
                return
            time.sleep(0.25)
        (root / (name + '.json')).write_text(json.dumps({'before': before, 'after': after, 'events': records}, indent=2))
        raise AssertionError('Real sleep/wake and observer delivery were not confirmed in this VM')

    try:
        state('core', 'stop')
        settings = dict(original)
        settings['service.settings'] = json.dumps({'provider': 'ipWhois', 'providerPool': ['ipWhois', 'ipapiCo', 'ipapiIs'],
            'refreshInterval': 900, 'allowlist': {'addresses': []},
            'diagnostics': {'includeFullIPAddresses': False, 'retentionDays': 7}, 'tailscaleProviderEnabled': False}).encode()
        settings['service.revision'] = original.get('service.revision', 0) + 1
        write_settings(settings)
        state('core', 'start')
        wait_state(lambda s: s.get('effectiveMode') == 'direct')
        sleep_and_observe('Direct-wake-requests-immediate-IP-check', True)
        assert state().get('effectiveMode') == 'direct'
        with socket.create_connection(('1.1.1.1', 443), timeout=5):
            pass
        record('Direct-connectivity-recovers-after-wake')
        state('core', 'stop')
        settings = read_settings()
        settings['service.routing'] = json.dumps({'mode': 'global', 'mihomoEnabled': True, 'profileHostingEnabled': True}).encode()
        settings['service.revision'] += 1
        write_settings(settings)
        command('/bin/launchctl', 'kickstart', '-k', 'system/' + SUPERVISOR)
        wait_state(lambda s: s['phase'] == 'blocked')
        sleep_and_observe('stopped-core-supervisor-observes-real-wake', False)
        value = state()
        assert value['phase'] == 'blocked' and (RUNTIME / 'gate.state').read_text() == 'blocked'
        assert next(s for s in value['services'] if s['id'] == 'core')['health'] == 'stopped'
        try:
            connection = socket.create_connection(('1.1.1.1', 443), timeout=3)
        except OSError:
            pass
        else:
            connection.close()
            raise AssertionError('Protected wake allowed ordinary public traffic')
        record('protected-wake-retains-blocking-and-core-Stop')
        success = True
    finally:
        if alarm:
            command('/usr/bin/pmset', 'schedule', 'cancel', 'wake', alarm, 'com.mimo.sleep-acceptance', check=False)
        for label in (CORE, ENGINE, SUPERVISOR):
            command('/bin/launchctl', 'bootout', 'system/' + label, check=False)
            deadline = time.monotonic() + 20
            while command('/bin/launchctl', 'print', 'system/' + label, check=False).returncode != 113:
                assert time.monotonic() < deadline
                time.sleep(0.1)
        write_settings(original)
        atomic_write(FLAGS, flags)
        command(HELPER, '--restore-direct-offline')
        command('/bin/launchctl', 'bootstrap', 'system', '/Library/LaunchDaemons/' + SUPERVISOR + '.plist')
        wait_state(lambda s: s.get('effectiveMode') == 'direct')
        record('original-settings-services-and-Direct-restored')
        (root / 'report.json').write_text(json.dumps({'success': success, 'passed': passed,
            'scope': 'Real wake observation and closed-mode recovery; active protected routing remains unqualified'}, indent=2))
        for path in root.iterdir():
            if path.is_file(): path.chmod(0o644)
        root.chmod(0o755)
        print('Evidence:', root, flush=True)


if __name__ == '__main__':
    run()
