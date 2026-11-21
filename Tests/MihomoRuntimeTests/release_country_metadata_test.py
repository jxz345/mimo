#!/usr/bin/env python3
"""Focused installed-release check in mimo-vm: real proxy/route, no fault campaign.

Country-response edge cases are covered separately with provider fixtures. This
checks that one real verification settles, that its own mutations do not keep
rechecking in this VM, and that an ordinary account can read supervisor causes.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import DESTINATION, LOGS, offsets, events
from upgrade_test import FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent
ROOT = Path('/Users/jay/mimo-tests/country-fix')


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    os.umask(0o077)
    saved = read_settings()
    original_mode = json.loads(saved['service.routing'])['mode']
    before_install = plistlib.loads((ROOT/'private-before/state.plist').read_bytes())
    assert configuration_values(saved) == configuration_values(before_install)
    original_flags = json.loads(FLAGS.read_bytes())
    passed = []
    added = False

    def client(*args):
        return command(BASE/'acceptance-client', *args, timeout=60)

    credential = client('credential-digest').stdout.strip()

    def state():
        return json.loads(client('state').stdout)

    def active(mode):
        value = state()
        routing = value['routing']
        return (routing['phase'] == 'active' and routing.get('effectiveMode') == mode
                and not routing.get('backgroundVerification') and 'ready' in value['status'])

    def wait(predicate, label, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.2)
        raise AssertionError(label + ' timed out')

    def record(name):
        passed.append(name)
        print('PASS:', name, flush=True)

    gateway = re.search(r'gateway: (\S+)', command('/sbin/route', '-n', 'get', 'default').stdout)[1]
    assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
    try:
        assert HELPER.read_bytes() == Path('/Applications/Mimo.app/Contents/MacOS/mimo-core').read_bytes()
        command('/usr/bin/codesign', '--verify', '--deep', '--strict', '/Applications/Mimo.app')
        record('installed-package-signature-helper-and-saved-configuration-match')
        client('mode', 'rule')
        wait(lambda: active('rule'), 'saved-proxy Rule verification')
        record('Rule-verifies-saved-proxy-and-allowlist')
        baseline = offsets(LOGS)
        time.sleep(20)
        rows = events(LOGS, baseline)
        assert not any(v['event'] in ('mimo_network_changed', 'mimo_gate_closed') for v in rows), 'unexpected idle recheck'
        assert active('rule')
        record('Rule-stays-open-without-self-triggered-cycle-for-20-seconds')

        baseline = offsets(LOGS)
        command('/sbin/route', '-n', 'add', '-host', DESTINATION, gateway)
        added = True
        wait(lambda: any(v['event'] == 'mimo_network_changed' for v in events(LOGS, baseline)), 'real route trigger')
        wait(lambda: active('rule') and any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, baseline)), 'route check recovery')
        settled = offsets(LOGS)
        time.sleep(20)
        assert not any(v['event'] in ('mimo_network_changed', 'mimo_gate_closed') for v in events(LOGS, settled)), 'verification retriggered itself'
        assert active('rule')
        record('real-route-block-check-open-settles-without-feedback-cycle')
        rows = events(LOGS, baseline)
        trigger = next(v for v in rows if v['event'] == 'mimo_network_changed')
        assert trigger['fields'].get('source') == 'route' and 'route added on ' in trigger['fields'].get('detail', '')
        read = command('/usr/bin/sudo', '-n', '-H', '-u', 'jay', ROOT/'supervisor-events')
        visible = json.loads(read.stdout)
        assert any('Check trigger' in line and 'route added on ' in line for line in visible)
        record('ordinary-account-event-log-exposes-specific-supervisor-trigger')

        # A second external event while preparation is running must join one
        # follow-up rather than cancelling/restarting the in-flight work.
        cleanup_baseline = offsets(LOGS)
        command('/sbin/route', '-n', 'delete', '-host', DESTINATION)
        added = False
        wait(lambda: active('rule') and any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, cleanup_baseline)), 'route deletion recovery')
        baseline = offsets(LOGS)
        command('/sbin/route', '-n', 'add', '-host', DESTINATION, gateway)
        added = True
        wait(lambda: any(v['event'] == 'mimo_parallel_preparation_started' for v in events(LOGS, baseline)), 'in-flight preparation')
        command('/sbin/route', '-n', 'delete', '-host', DESTINATION)
        added = False
        wait(lambda: any(v['event'] == 'mimo_cycle_event_deferred' for v in events(LOGS, baseline)), 'deferred external event')
        wait(lambda: active('rule') and any(v['event'] == 'mimo_traffic_opened' for v in events(LOGS, baseline)), 'fresh follow-up opening')
        rows = events(LOGS, baseline)
        followups = [v for v in rows if v['event'] == 'mimo_network_changed' and v['fields'].get('source') == 'deferred_events']
        assert len(followups) == 1, 'external event did not coalesce to one follow-up'
        assert sum(v['event'] == 'mimo_traffic_opened' for v in rows) == 1, 'stale cycle opened traffic'
        record('external-change-during-cycle-holds-PF-for-one-fresh-follow-up')

        baseline = offsets(LOGS)
        command('/sbin/route', '-n', 'add', '-host', DESTINATION, gateway)
        added = True
        wait(lambda: any(v['event'] == 'mimo_parallel_preparation_started' for v in events(LOGS, baseline)), 'preparation before human control')
        client('mode', 'direct')
        wait(lambda: active('direct'), 'queued Direct command')
        rows = events(LOGS, baseline)
        assert any(v['event'] == 'mimo_control_queued' for v in rows), 'human control did not wait'
        assert any(v['event'] == 'mimo_control_resumed' for v in rows), 'human control did not resume'
        assert any(v['event'] == 'mimo_traffic_opened' for v in rows), 'Direct interrupted the protected cycle'
        record('human-Direct-selection-waits-for-protected-cycle-to-finish')

        baseline = offsets(LOGS)
        command('/sbin/route', '-n', 'delete', '-host', DESTINATION)
        added = False
        time.sleep(5)
        rows = events(LOGS, baseline)
        assert any(v['event'] == 'mimo_direct_event_ignored' for v in rows)
        assert not any(v['event'] in ('mimo_gate_closed', 'mimo_network_changed') for v in rows)
        assert not any(v['event'] == 'refresh_requested' and v['fields'].get('trigger') in ('network_configuration', 'route_change') for v in rows)
        assert active('direct')
        record('Direct-route-event-causes-neither-blocking-nor-IP-check')
    finally:
        if added:
            command('/sbin/route', '-n', 'delete', '-host', DESTINATION, check=False)
        client('mode', original_mode)
        wait(lambda: active(original_mode), 'original mode restoration')
        assert configuration_values(read_settings()) == configuration_values(saved)
        assert json.loads(FLAGS.read_bytes()) == original_flags
        assert client('credential-digest').stdout.strip() == credential
        record('original-mode-proxy-allowlist-credential-and-service-intent-restored')
        summary = {'checks': passed, 'environment': 'mimo-vm',
                   'helperSHA256': hashlib.sha256(HELPER.read_bytes()).hexdigest(),
                   'scope': 'Installed normal release, saved real proxy and one real route change; geography edge cases tested separately. Physical-Mac feedback loop not yet observed with this build.'}
        (ROOT/'installed-summary.json').write_text(json.dumps(summary, indent=2)+'\n')


if __name__ == '__main__':
    main()
