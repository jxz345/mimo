#!/usr/bin/env python3
"""Delta orchestrator: installed dual-stack approval must fail as a whole.

Requires the closed, explicitly trusted fixture and VM console helper. No real
proxy credentials are read/exported. The fixture cannot forward to the Internet.
"""
import json
from pathlib import Path
import subprocess
import sys
import urllib.request

FIXTURE_ROOT = Path(sys.argv[1])
GUEST_ROOT = sys.argv[2]
REPO = Path(__file__).resolve().parents[2]
fixture = json.loads((FIXTURE_ROOT / 'fixture.json').read_text())
results = []


def control(mode):
    payload = json.dumps({'mode': mode, 'disconnect': True}).encode()
    request = urllib.request.Request(
        'http://' + fixture['bridge4'] + ':' + str(fixture['control_port']) + '/',
        data=payload, headers={'Authorization': 'Bearer ' + fixture['token'],
                               'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=5) as response:
        assert response.status == 204


PREFIX = '''
import sys, time, json, os, socket
sys.argv = ['paired', ROOT]
sys.path.insert(0, ROOT)
import v3_installed_test as t
assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
assert t.state()['routing']['configuration']['proxy']['name'] == 'V3 local qualification'
def blocked():
    deadline = time.monotonic() + 65
    while time.monotonic() < deadline:
        r = t.state()['routing']
        if r['phase'] == 'blocked' and not r.get('effectiveMode'):
            assert 'block drop out quick all label "mimo:transition:deny"' in t.run(['/sbin/pfctl','-a',t.ANCHOR,'-sr']).stdout
            return
        time.sleep(.5)
    raise AssertionError('Expected paired denial: ' + r['reason'])
def approved():
    r = t.wait_active('global', 65)['routing']
    obs = r['exitObservations']
    assert obs['ipv4']['ipAddress'] == '203.0.113.10'
    assert obs['ipv6']['ipAddress'] == '2001:db8::10'
    assert t.active_guard(t.run(['/sbin/pfctl','-a',t.ANCHOR,'-sr']).stdout)
    return obs['verification']['id']
'''


def guest(code):
    script = 'ROOT = ' + repr(GUEST_ROOT) + '\n' + PREFIX + code
    result = subprocess.run([sys.executable, str(REPO / 'Scripts/vm-console-admin.py'),
                             '/usr/bin/python3', '-c', script],
                            capture_output=True, text=True, timeout=160)
    if result.returncode:
        raise AssertionError(result.stdout[-1400:] + result.stderr[-1400:])
    return result.stdout.strip()


def check(name, code):
    try:
        guest(code)
    except Exception:
        results.append({'id': name, 'passed': False})
        raise
    else:
        results.append({'id': name, 'passed': True})
        print(name + ': PASS', flush=True)
    finally:
        (FIXTURE_ROOT / 'paired-failure.json').write_text(json.dumps(results, indent=2))


def main():
    try:
        control('S00')
        check('paired-baseline', "t.route('global','dual'); s=t.state()['settings']; s.update(provider='ipapiCo',providerPool=['ipapiCo']); t.request('configure',settings=s); approved()")
        control('S01')
        check('paired-ipv6-refusal-denied', "t.request('refresh'); blocked()")
        listeners = "assert all(t.run(['/usr/bin/nc','-G','2','-z','127.0.0.1',str(p)],4).returncode != 0 for p in (7890,1053))"
        check('paired-ipv6-refusal-public-listeners-closed', 'blocked(); ' + listeners)
        control('S00')
        # Refresh bypasses the minimum request gap, not a provider's cooldown.
        # Exercise normal recovery through another eligible fixture provider.
        check('paired-refusal-cooldown-retained', "t.request('refresh'); blocked(); d=t.state()['cooldowns']; c=dict(zip(d[::2],d[1::2])); assert c['ipapiCo'] > time.time()-978307200")
        check('paired-ipv6-refusal-recovered', "s=t.state()['settings']; s.update(provider='ipapiIs',providerPool=['ipapiIs']); t.request('configure',settings=s); approved()")
        check('paired-ipv6-not-allowlisted-denied', "s=t.state()['settings']; s['allowlist']={'addresses':['203.0.113.10']}; t.request('configure',settings=s); blocked()")
        check('paired-ipv6-not-allowlisted-public-listeners-closed', 'blocked(); ' + listeners)
        check('paired-allowlist-recovered', "s=t.state()['settings']; s['allowlist']={'addresses':['203.0.113.10','2001:db8::10']}; t.request('configure',settings=s); approved()")
    finally:
        control('S00')
        check('paired-final-direct', "t.route('direct'); t.wait_active('direct'); assert not t.run(['/sbin/pfctl','-a',t.ANCHOR,'-sr']).stdout.strip(); assert '1053' not in t.run(['/usr/sbin/scutil','--dns']).stdout")


if __name__ == '__main__': main()
