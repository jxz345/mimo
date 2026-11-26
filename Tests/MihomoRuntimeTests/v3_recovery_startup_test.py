#!/usr/bin/env python3
"""Installed VM recovery matrix after supervisor restart with a rejected exit.

Uses the existing proxy and rejected allowlist; never approves an address or
changes credentials. Restores the original routing configuration on exit.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controls', required=True)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    root = Path(args.output_dir)
    root.mkdir(mode=0o700, parents=True, exist_ok=False)

    def state():
        r = subprocess.run([args.controls], text=True, capture_output=True, timeout=15)
        assert r.returncode == 0, 'State unavailable'
        return json.loads(r.stdout)['state']

    def request(command, **fields):
        path = root / 'request.json'
        path.write_text(json.dumps(dict(command=command, protocolVersion=8, **fields)))
        r = subprocess.run([args.controls, 'request', str(path)], text=True, capture_output=True, timeout=90)
        assert r.returncode == 0 and not json.loads(r.stdout).get('failure'), command + ' failed'

    def wait(predicate):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            value = state()
            if predicate(value):
                return value
            time.sleep(.5)
        raise AssertionError('Expected settled state not reached')

    def rejected(v):
        return v['routing']['phase'] == 'blocked' and v['routing'].get('blockingIP') and 'ready' in v['status']

    def direct():
        cfg = state()['routing']['configuration']
        cfg['mode'] = 'direct'
        request('configureRouting', routing=cfg)
        wait(lambda v: v['routing']['phase'] == 'active' and v['routing'].get('effectiveMode') == 'direct')

    original = state()
    assert original['routing']['configuration']['proxy'], 'Requires existing proxy'
    assert not original['settings']['allowlist']['addresses'], 'Requires intentionally empty test allowlist'
    (root / 'before.json').write_text(json.dumps(original))
    reports = []
    try:
        for mode in ('rule', 'global'):
            for family in ('ipv4', 'dual'):
                direct()
                cfg = state()['routing']['configuration']
                cfg.update(mode=mode, networkFamily=family)
                request('configureRouting', routing=cfg)
                wait(rejected)
                before_restart = state()['routing']['blockingIP']
                subprocess.run(['/bin/launchctl', 'kickstart', '-k', 'system/com.mimo.supervisor'], check=True)
                restarted = wait(lambda v: rejected(v) and v['routing']['blockingIP'] != before_restart)
                output = root / (mode + '-' + family + '.json')
                result = subprocess.run([sys.executable, str(Path(__file__).with_name('v3_rejected_exit_stability_test.py')),
                    '--controls', args.controls, '--output', str(output), '--seconds', '35'], capture_output=True, text=True)
                (root / (mode + '-' + family + '.log')).write_text(result.stdout + result.stderr)
                assert result.returncode == 0, mode + '/' + family + ' stability failed'
                # An explicit retry must still run despite a settled denial.
                previous = state()['routing']['blockingIP']
                request('refresh')
                fresh = wait(lambda v: rejected(v) and v['routing']['blockingIP'] != previous)
                report = json.loads(output.read_text())
                report['manual_retry_completed'] = True
                report['same_core_across_supervisor_restart'] = restarted['instanceID'] == fresh['instanceID'] == original['instanceID']
                direct()
                report['direct_recovery_completed'] = True
                report['settings_unchanged'] = state()['settings'] == original['settings']
                assert report['same_core_across_supervisor_restart'] and report['settings_unchanged']
                reports.append(report)
                (root / 'matrix.json').write_text(json.dumps(reports, indent=2))
                print('PASS:', mode, family, 'restart, 35s stability, manual retry, Direct recovery', flush=True)
    finally:
        request('configureRouting', routing=original['routing']['configuration'])
        restored = state()
        assert restored['routing']['configuration'] == original['routing']['configuration']
        assert restored['settings'] == original['settings']
        print('Original routing/settings restored', flush=True)


if __name__ == '__main__':
    main()
