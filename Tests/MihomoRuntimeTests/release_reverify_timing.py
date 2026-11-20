#!/usr/bin/env python3
"""Time actual installed Rule/Global rechecks after real kernel route changes.

Preserves current mode/settings. No event injection, mock proxy or helper swap.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import traceback

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events, DESTINATION
from upgrade_test import FLAGS, HELPER, read_settings

BASE = Path(__file__).resolve().parent


def main():
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = read_settings(); flags = FLAGS.read_bytes()
    mode = json.loads(original['service.routing'])['mode']
    assert mode in ('rule', 'global')
    credential = command(BASE / 'acceptance-client', 'credential-digest').stdout.strip()
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    assert DESTINATION not in command('/usr/sbin/netstat', '-rn', '-f', 'inet').stdout
    gateway = re.search(r'gateway: (\S+)', command('/sbin/route', '-n', 'get', 'default').stdout)[1]
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-reverify-timing-', dir='/var/tmp'))
    print('Evidence:', root, flush=True)
    trials = []; errors = []; added = False

    def state():
        return json.loads(command(BASE / 'acceptance-client', 'state').stdout)['routing']

    def active():
        value = state()
        return value['phase'] == 'active' and value.get('effectiveMode') == mode

    try:
        assert active(), 'Original saved mode is not active before the trial'
        for add in (True, False):
            baseline = offsets(LOGS)
            started = time.monotonic()
            if add:
                command('/sbin/route', '-n', 'add', '-host', DESTINATION, gateway); added = True
            else:
                command('/sbin/route', '-n', 'delete', '-host', DESTINATION); added = False
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                rows = events(LOGS, baseline)
                notification = next((v for v in rows if v['event'] == 'mimo_network_changed' and v['fields'].get('source') == 'route'), None)
                if notification:
                    ordered = [v for v in rows if v['file'] == notification['file']]
                    if any(v['event'] == 'mimo_traffic_opened' for v in ordered) and active(): break
                time.sleep(.1)
            else: raise AssertionError('No route-change verification completed')
            elapsed = time.monotonic() - started
            label = 'route-added' if add else 'route-removed'
            (root / (label + '-private-events.json')).write_text(json.dumps(rows))
            names = [v['event'] for v in ordered]
            probe = names.index('mimo_private_probe_ready'); opened = names.index('mimo_traffic_opened')
            assert probe < opened, 'Opening preceded the new private probe'
            assert any(v['event'] == 'mimo_gate_closed' and v['fields'].get('confirmed') == 'true' for v in ordered[:probe]), 'No confirmed close before probe'
            assert not any(v.get('level') == 'error' for v in ordered[:opened + 1]), 'Supervisor reported an error before opening'
            command('/usr/bin/sudo', '-n', '-u', 'jay', '/usr/bin/curl', '--silent', '--fail', '--noproxy', '*',
                    '--max-time', '10', '--head', 'https://one.one.one.one/')
            trial = dict(event=label,seconds=round(elapsed,3),confirmedCloseBeforeProbeBeforeOpen=True,
                         fullCloseCount=names[:opened + 1].count('mimo_gate_closed'),
                         privateProbeCount=names[:opened + 1].count('mimo_private_probe_ready'),
                         stages=[v['fields'] for v in rows if v['event'] == 'mimo_transition_timing'])
            trials.append(trial)
            print('PASS:',label,round(elapsed,3),'seconds;',trial['fullCloseCount'],'full closes',flush=True)
            # Allow configd's delayed DNS notifications to settle between trials.
            time.sleep(4)
        assert configuration_values(read_settings()) == configuration_values(original)
        assert FLAGS.read_bytes() == flags
        assert command(BASE / 'acceptance-client', 'credential-digest').stdout.strip() == credential
    except Exception as exc:
        errors.append(type(exc).__name__ + ': ' + str(exc))
        (root / 'private-error.txt').write_text(traceback.format_exc())
        print('FAIL:',type(exc).__name__,str(exc),flush=True)
    finally:
        if added: command('/sbin/route', '-n', 'delete', '-host', DESTINATION, check=False)
        report = dict(success=not errors,mode=mode,trials=trials,errors=errors,
                      packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],
                      scope='Actual kernel host-route add/remove, saved proxy and ordinary-user HTTPS in mimo-vm; not a physical sleep/unlock or continuous packet test')
        (root / 'report.json').write_text(json.dumps(report,indent=2)+'\n')
    return 1 if errors else 0


if __name__ == '__main__': sys.exit(main())
