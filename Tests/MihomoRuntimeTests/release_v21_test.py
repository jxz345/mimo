#!/usr/bin/env python3
"""Exact release 2.1 VM acceptance. Private state/credentials never leave the VM.
Stage Mimo-2.1.zip and release-v21-controls beside this file. Run as root with start.
The VM must have its established test proxy in saved Mimo settings and no active app.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent
ROOT = Path('/var/root/mimo-v21-acceptance')
APP = Path('/Applications/Mimo.app')
STATE = Path('/Library/Application Support/Mimo/Service/state.plist')
KEYS = ['service.routing', 'service.settings', 'service.local-proxy-passwords', 'service.local-ipinfo-token']


def run(*args, timeout=120, check=True):
    p = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=timeout)
    if check and p.returncode:
        (ROOT / 'command-error.log').write_text(p.stdout + p.stderr)
        raise AssertionError('command failed; private command-error.log')
    return p


def read(action='state', user=None):
    args = [BASE / 'release-v21-controls', action]
    if user:
        args = ['/usr/bin/sudo', '-n', '-H', '-u', user] + args
    response = json.loads(run(*args).stdout)
    assert 'failure' not in response, 'state unavailable'
    return response


def state():
    return read()['state']


def request(command, **fields):
    value = dict(protocolVersion=7, command=command, **fields)
    p = ROOT / 'request.json'
    p.write_text(json.dumps(value)); p.chmod(0o600)
    return json.loads(run(BASE / 'release-v21-controls', 'request', p).stdout)


def change(command, **fields):
    r = request(command, **fields)
    assert 'failure' not in r, 'request failed: ' + command + ' ' + str(r.get('failure'))
    return r['state']


def wait(test, label, seconds=100):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try: s = state()
        except Exception:
            time.sleep(.5); continue
        if test(s):
            return s
        time.sleep(.5)
    (ROOT / 'last-state.json').write_text(json.dumps(s))
    raise AssertionError('timed out: ' + label)


def cleanup():
    if (APP / 'Contents/Resources/daemon.sh').exists():
        for attempt in range(3):
            p = run('/bin/bash', APP / 'Contents/Resources/daemon.sh', 'uninstall', timeout=220, check=False)
            (ROOT / ('cleanup-' + str(attempt) + '.log')).write_text(p.stdout + p.stderr)
            if p.returncode == 0:
                break
            time.sleep(2)
        else:
            raise AssertionError('cleanup failed')
    baseline = ROOT / 'migrated-baseline.plist'
    if baseline.exists() and STATE.exists():
        current = plistlib.loads(STATE.read_bytes()); original = plistlib.loads(baseline.read_bytes())
        for key in KEYS:
            if key in original: current[key] = original[key]
            else: current.pop(key, None)
        routing = json.loads(current['service.routing']); routing['mode'] = 'direct'
        current['service.routing'] = json.dumps(routing).encode()
        current['service.revision'] += 1
        STATE.write_bytes(plistlib.dumps(current, fmt=plistlib.FMT_BINARY)); STATE.chmod(0o600)


def main():
    checks = []
    def passed(name):
        checks.append(name); print('PASS: ' + name, flush=True)
    ok = False
    try:
        assert not APP.exists(), 'remove the previous test app before this isolated run'
        run('/usr/bin/ditto', '-x', '-k', BASE / 'Mimo-2.1.zip', '/Applications')
        info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleVersion'] == '8' and info['CFBundleShortVersionString'] == '2.1'
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', APP)
        p = run('/bin/bash', APP / 'Contents/Resources/daemon.sh', 'install', timeout=240)
        (ROOT / 'install.log').write_text(p.stdout + p.stderr)
        assert hashlib.sha256((APP/'Contents/MacOS/mimo-core').read_bytes()).digest() == hashlib.sha256(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).digest()
        initial = wait(lambda s: s['initialized'] and s['routing']['phase'] == 'active', 'startup Direct')
        baseline = plistlib.loads(STATE.read_bytes())
        (ROOT / 'migrated-baseline.plist').write_bytes(STATE.read_bytes())
        config = initial['routing']['configuration']; entries = config['proxies']
        assert entries and config['activeProxyID'] in [p['id'] for p in entries]
        assert STATE.stat().st_uid == 0 and STATE.stat().st_mode & 0o777 == 0o600
        assert baseline['service.local-credentials.v2.1']
        passed('exact installed 2.1 build 8, startup services, legacy proxy migration, owner-only local storage')
        for user in ['jay', 'mimotest']:
            other = read(user=user)['state']
            assert other['routing']['configuration'] == config
            assert other['revision'] == initial['revision']
        passed('two accounts see identical shared proxy list and revision')
        settings = initial['settings'].copy(); settings['refreshInterval'] = -1
        settings['providerPool'] = ['ipWhois', 'ipapiCo']; settings['provider'] = 'ipWhois'
        change('configure', settings=settings)
        wait(lambda s: s['routing']['phase'] == 'active' and 'ready' in s['status'], 'Direct check')
        for _ in range(2):
            before = state().get('snapshot', {}).get('checkedAt', 0)
            time.sleep(1.1); change('refresh')
            wait(lambda s: s.get('manualRefresh', {}).get('phase') == 'succeeded' and s['snapshot']['checkedAt'] > before, 'fresh manual lookup')
        passed('Never preference and repeated actual manual exit-IP refresh, including successful check timestamps')
        for user in ['jay', 'mimotest']:
            result = run('/usr/bin/sudo', '-n', '-H', '-u', user, APP/'Contents/MacOS/mimo-gui', '--check-service-access', timeout=150)
            assert result.stdout.startswith('PASS: installed-app controls')
        passed('exact signed GUI accesses both installed endpoints from two accounts')
        token = 'mimo-v21-local-test-token'
        change('setToken', token=token)
        assert plistlib.loads(STATE.read_bytes())['service.local-ipinfo-token'] == token
        assert state()['hasIPinfoToken']
        for user in ['jay', 'mimotest']:
            assert token not in json.dumps(read(user=user)) and token not in json.dumps(read('events', user=user))
        before_token_removal = state().get('snapshot', {}).get('checkedAt', 0)
        change('removeToken'); assert not state()['hasIPinfoToken']
        wait(lambda s: 'ready' in s['status'] and s.get('snapshot', {}).get('checkedAt', 0) > before_token_removal,
             'token-removal lookup completion')
        passed('local IPinfo save/remove is shared without disclosure through state or events')
        original_id = config['activeProxyID']; original_entry = next(p for p in entries if p['id'] == original_id)
        proxy = original_entry['proxy'].copy(); proxy['name'] = 'VM 2.1 alternative'
        # Clone only inside the private VM to exercise profile delivery with its established test proxy.
        raw_passwords = json.loads(baseline['service.local-proxy-passwords'])
        passwords = dict(zip(raw_passwords[::2], raw_passwords[1::2])) if isinstance(raw_passwords, list) else raw_passwords
        before = state(); revision = before['revision']
        added = change('saveProxy', proxy=proxy, proxyPassword=passwords.get(original_id, ''))
        new_id = next(p['id'] for p in added['routing']['configuration']['proxies'] if p['proxy']['name'] == proxy['name'])
        assert added['routing']['configuration']['activeProxyID'] == original_id
        assert added['routing']['phase'] == before['routing']['phase']
        assert added.get('snapshot') == before.get('snapshot')
        assert request('selectProxy', proxyID=new_id, expectedRevision=revision).get('failure') == 'conflict'
        passed('inactive add preserves current routing/check; stale account revision rejected')
        selected = change('selectProxy', proxyID=new_id)
        assert selected['routing']['configuration']['mode'] == 'direct'
        route = selected['routing']['configuration'].copy(); route['mode'] = 'rule'
        change('configureRouting', routing=route)
        active = wait(lambda s: s['routing']['phase'] == 'active' and s['routing'].get('effectiveMode') == 'rule', 'Rule with selected local credential')
        passed('selected proxy authenticates from local storage; real Rule profile and exit verification succeed')
        # Edit the active entry in Rule; fresh checkedAt and selected name prove completed preparation.
        before = active['snapshot']['checkedAt']; proxy['name'] = 'VM 2.1 edited'
        change('saveProxy', proxy=proxy, proxyID=new_id)
        active = wait(lambda s: s['routing']['phase'] == 'active' and s['routing'].get('effectiveMode') == 'rule' and s['snapshot']['checkedAt'] > before, 'active proxy reload')
        assert active['routing']['configuration']['proxy']['name'] == proxy['name']
        passed('active proxy edit reloads/verifies while retaining Rule')
        # Inactive edit under an approved protected mode must retain the exact result and phase.
        inactive = original_entry['proxy'].copy(); inactive['name'] = 'VM inactive original'
        before = state(); change('saveProxy', proxy=inactive, proxyID=original_id)
        time.sleep(1)
        after = state(); assert after['routing']['phase'] == 'active' and after['snapshot'] == before['snapshot']
        passed('inactive edit while Rule is active does not reload or run another lookup')
        route = after['routing']['configuration'].copy(); route['mode'] = 'global'
        change('configureRouting', routing=route)
        active = wait(lambda s: s['routing']['phase'] == 'active' and s['routing'].get('effectiveMode') == 'global', 'Global')
        before = active['snapshot']['checkedAt']
        change('selectProxy', proxyID=original_id)
        active = wait(lambda s: s['routing']['phase'] == 'active' and s['routing'].get('effectiveMode') == 'global' and s['snapshot']['checkedAt'] > before, 'Global proxy switch')
        assert active['routing']['configuration']['activeProxyID'] == original_id
        passed('proxy selection reloads/verifies while retaining Global')
        direct = change('selectProxy')
        wait(lambda s: s['routing'].get('effectiveMode') == 'direct', 'None Direct')
        route = direct['routing']['configuration'].copy(); route['mode'] = 'rule'
        assert request('configureRouting', routing=route).get('failure') == 'invalidRequest'
        change('selectProxy', proxyID=new_id)
        change('removeProxy', proxyID=new_id)
        assert state()['routing']['configuration'].get('activeProxyID') is None
        passed('None and active deletion restore Direct; protected mode is rejected without a proxy')
        change('selectProxy', proxyID=original_id)
        before = state(); instance = before['instanceID']
        run('/bin/launchctl', 'kickstart', '-k', 'system/com.mimo.core')
        restored = wait(lambda s: s['instanceID'] != instance and s['routing']['phase'] == 'active', 'core restart')
        assert restored['routing']['configuration']['proxies'] == before['routing']['configuration']['proxies']
        assert restored['routing']['configuration']['activeProxyID'] == original_id and restored['settings']['refreshInterval'] == -1
        passed('shared catalog, selected ID and Never survive core restart without Keychain dependency')
        ok = True
    finally:
        cleanup()
        (ROOT / 'report.json').write_text(json.dumps(dict(passed=ok, checks=checks, cleanup='passed', version='2.1', build='8'), indent=2))
        (ROOT / 'done').touch()


assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
os.umask(0o077); ROOT.mkdir(exist_ok=True)
if sys.argv[1:] == ['start']:
    for n in ['done', 'report.json']: (ROOT/n).unlink(missing_ok=True)
    with (ROOT/'test.log').open('w') as log:
        for action in ['run', 'watchdog']:
            subprocess.Popen([sys.executable, __file__, action], stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    print('Installed 2.1 VM acceptance started.')
elif sys.argv[1:] == ['watchdog']:
    for _ in range(900):
        if (ROOT/'done').exists(): break
        time.sleep(1)
    else: cleanup()
elif sys.argv[1:] == ['run']:
    main()
