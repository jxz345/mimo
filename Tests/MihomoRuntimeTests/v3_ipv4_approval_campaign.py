#!/usr/bin/env python3
"""Delta/mimo-vm installed IPv4 approval qualification; owner-only output.

Requires trusted closed-fixture TLS and /var/tmp/mimo-ipv4-controls compiled from
the current shared sources. Final Global/Dual cell pauses at ui-ready for native
inspection; create ui-continue in that private cell directory to resume.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import time

os.umask(0o077)
repo = Path(__file__).resolve().parents[2]
harness = repo / 'Tests/MihomoRuntimeTests/v3_blocked_retry_test.py'
tls = Path.home() / '.config/mimo-vm/qualification-tls'
summary = []
run_name = sys.argv[1] if len(sys.argv) > 1 else 'ipv4-approval'
assert run_name.replace('-', '').isalnum()

def admin(*args, timeout=175):
    p = subprocess.run([sys.executable, str(repo / 'Scripts/vm-console-admin.py'), *args],
                       capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, p.stdout[-1200:] + p.stderr[-1200:]
    return p.stdout.strip()

for mode, family in [('rule', 'ipv4'), ('global', 'ipv4'), ('rule', 'dual'), ('global', 'dual')]:
    name = run_name + '-' + mode + '-' + family
    root = repo / '.build' / name
    guest_root = '/var/tmp/mimo-' + name
    root.mkdir(mode=0o700)
    fixture = root / 'fixture'
    fixture.mkdir(mode=0o700)
    for file in ['server.crt', 'server.key']:
        (fixture / file).symlink_to(tls / file)
    log = (root / 'fixture.log').open('w')
    proc = subprocess.Popen([sys.executable, str(harness), str(fixture), 'fixture',
                             '192.168.64.1', '192.168.235.89',
                             'fd11:43d5:4bfa:7aaa:88a:ca6e:ee74:81be', '192.168.64.2'],
                            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    (root / 'fixture.pid').write_text(str(proc.pid))
    try:
        for _ in range(100):
            if (fixture / 'fixture.json').exists(): break
            assert proc.poll() is None, 'Fixture stopped; see private log'
            time.sleep(.1)
        data = json.loads((fixture / 'fixture.json').read_text())
        data.update(test_provider='ipinfoLite', test_mode=mode, test_family=family,
                    test_ipv4_approval=True, test_proxy_mode='S04', test_dns_fault='nodata6',
                    ui_checkpoint=(mode == 'global' and family == 'dual'))
        (fixture / 'fixture.json').write_text(json.dumps(data))
        positive = subprocess.run(['/usr/bin/curl', '--fail', '-sS', '--max-time', '8',
                                   '--cacert', str(fixture / 'server.crt'), '--socks5',
                                   data['bridge4'] + ':' + str(data['proxy_port']),
                                   '--resolve', 'v4.api.ipinfo.io:443:' + data['data4'],
                                   'https://v4.api.ipinfo.io/'], capture_output=True, text=True)
        assert positive.returncode == 0 and json.loads(positive.stdout)['ip'] == '203.0.113.10'
        payload = {file.name: base64.b64encode(file.read_bytes()).decode() for file in
                   [harness, harness.parent / 'v3_installed_test.py', fixture / 'fixture.json']}
        setup = '''import base64, json, os, shutil, plistlib, hashlib
from pathlib import Path
os.umask(0o077)
root = Path(%r); root.mkdir(mode=0o700)
shutil.copy2('/var/tmp/mimo-ipv4-controls', root / 'controls'); (root / 'controls').chmod(0o700)
for name, value in %r.items(): (root / name).write_bytes(base64.b64decode(value))
identity = plistlib.loads(Path('/Applications/Mimo.app/Contents/Info.plist').read_bytes())
assert identity['CFBundleVersion'] == '11'
print(json.dumps(dict(version=identity['CFBundleShortVersionString'],build=identity['CFBundleVersion'],
 core_sha256=hashlib.sha256(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).hexdigest())))
''' % (guest_root, payload)
        identity = json.loads(admin('/usr/bin/python3', '-c', setup).splitlines()[-1])
        (root / 'installed-identity.json').write_text(json.dumps(identity))
        print('START ' + mode + '/' + family, flush=True)
        result = subprocess.run([sys.executable, str(harness), str(root), guest_root])
        summary.append(dict(mode=mode, family=family, exit_code=result.returncode))
        (repo / '.build/ipv4-approval-summary.json').write_text(json.dumps(summary, indent=2))
        assert result.returncode == 0, 'Campaign failed; stop before further mutations'
        print('DONE ' + mode + '/' + family, flush=True)
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        log.close()
