#!/usr/bin/env python3
"""Delta-side orchestration for the authorized isolated dual-stack campaign."""
import argparse
import copy
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import time

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = Path(__file__).resolve().parent
SHA = 'ff21dbbad799783de14f4a13684b35531b455beff0335dc2e9d468e5bcbe52bd'
FILES = ['dualstack_fixture.py', 'dualstack_profile_test.py', 'ipv6_global_profile_test.py', 'native_dns_fixture.py']


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, **kwargs)


def admin(*args, **kwargs):
    return run([sys.executable, REPO / 'Scripts/vm-admin.py', *args], **kwargs)


def ssh(*args):
    return run(['/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', 'mimo-vm-admin', shlex.join([str(x) for x in args])])


def private(path, content):
    path.write_text(content)
    path.chmod(0o600)


def fingerprint():
    path = REPO / 'Profiles/mimo-global-ipv6-test.local.yaml'
    return {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mode': stat.S_IMODE(path.stat().st_mode), 'mtime_ns': path.stat().st_mtime_ns}


def addresses():
    text = run(['/sbin/ifconfig', '-a'], text=True).stdout
    current, result = '', {}
    for line in text.splitlines():
        if line and not line[0].isspace():
            current = line.split(':', 1)[0]
        if current == 'bridge100' and line.strip().startswith('inet '):
            result['bridge4'] = line.split()[1]
        if current == 'en0' and line.strip().startswith('inet '):
            result['data4'] = line.split()[1]
        if current == 'bridge100' and line.strip().startswith('inet6 ') and not line.split()[1].startswith('fe80:'):
            result['data6'] = line.split()[1].split('%')[0]
    vm = ssh('/usr/sbin/ipconfig', 'getifaddr', 'en0').stdout.decode().strip()
    result['client4'] = vm
    assert len(result) == 4 and result['bridge4'] != result['data4']
    return result


def certificate(root, addr):
    config = '''[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Mimo temporary dual-stack lab
[ext]
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth
subjectAltName=DNS:*.mimo-lab.test,IP:%s,IP:%s
''' % (addr['data4'], addr['data6'])
    private(root / 'tls.cnf', config)
    run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
         '-config', root / 'tls.cnf', '-keyout', root / 'server.key', '-out', root / 'server.crt'])
    (root / 'server.key').chmod(0o600)


def config_for(template, profile, fixture, ca, guest):
    value = copy.deepcopy(template)
    value['tun']['device'] = 'utun238'
    value['external-controller-unix'] = guest + '/controller.sock'
    value['proxies'][0].update(server=fixture['bridge4'], port=fixture['proxy_port'], **{'ip-version': profile['ip_version']})
    value['dns']['ipv6'] = profile['dns_ipv6']
    if profile['fake_ipv6_pool']:
        value['dns']['fake-ip-range6'] = 'fdfe:dcba:9876:1::/64'
    else:
        value['dns'].pop('fake-ip-range6', None)
    value['dns']['nameserver'] = ['https://' + fixture['data4'] + ':' + str(fixture['https_port']) + '/dns-query#Proxy']
    value['dns']['use-hosts'] = False
    value['dns']['use-system-hosts'] = False
    value['tls'] = {'custom-certifactes': [ca]}
    return value


class Lab:
    def __init__(self, root, templates=False, v3=False):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.root.chmod(0o700)
        self.baseline = fingerprint()
        self.spec = json.loads((REPO / 'Design/MIMO_DUALSTACK_TEST_MATRIX.json').read_text())
        if templates or v3:
            self.spec['status'] = 'template_campaign'
            self.spec['invariants'].update(mode='per_template_variant', rule_count='from_public_template', core_dns_mode='native')
            self.spec['expected_core_counts'] = {'profile_proxy_cells': 24, 'application_cases': 1440,
                                                 'dns_delivery_queries': 1440, 'real_resolver_queries': 240,
                                                 'total_planned_cases': 3120}
            self.spec.pop('results', None)
            self.spec['profiles'] = [
                {'id': 'T' + family + suffix, 'file': 'mimo-template-' + family + suffix.lower() + '.local.yaml',
                 'template': 'mimo-' + ('ipv4' if family == '4' else 'dualstack') + '-template.yaml',
                 'engine_mode': mode, 'dns_ipv6': family == '6', 'fake_ipv6_pool': family == '6',
                 'ip_version': 'ipv4' if family == '4' else 'dual'}
                for family in ('4', '6') for suffix, mode in (('R', 'rule'), ('G', 'global'))]
            self.spec['focused_profiles'] = []
        if v3:
            for profile in self.spec['profiles']:
                profile['template'] = profile['template'].replace('mimo-', 'mimo-v3-')
            self.spec['status'] = 'v3_campaign'
            self.spec['invariants']['core_dns_mode'] = 'disabled'
        self.v3 = v3
        self.template = json.loads(run(['/usr/bin/ruby', '-rjson', '-ryaml', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))',
                                       REPO / 'Profiles/mimo-global-ipv6-test.yaml']).stdout)
        self.addr = addresses()
        self.engine = REPO / ('.build/v3-engine/mihomo-v3.bin' if v3 else '.build/no-ping-repro/mihomo-no-ping')
        self.engine_sha = plistlib.loads((REPO / 'Configuration/MihomoDependency.plist').read_bytes())['architectures']['arm64']['binarySHA256'] if v3 else SHA
        assert hashlib.sha256(self.engine.read_bytes()).hexdigest() == self.engine_sha
        self.id = secrets.token_hex(5)
        self.stage = '/private/tmp/mimo-ds-transfer-' + self.id
        self.guest = '/private/tmp/mimo-dualstack-' + self.id
        private(self.root / ('baseline-' + self.id + '.json'), json.dumps(self.baseline))
        private(self.root / ('addresses-' + self.id + '.json'), json.dumps(self.addr))
        ssh('/bin/mkdir', '-m', '700', self.stage)
        run(['/usr/bin/scp', '-q', self.engine, 'mimo-vm-admin:' + self.stage + '/mihomo-no-ping'])
        admin('/usr/bin/python3', '-c',
              'import pathlib,shutil; p=pathlib.Path(__import__("sys").argv[1]); p.mkdir(mode=0o700); shutil.copy2(__import__("sys").argv[2],p/"mihomo-no-ping"); (p/"mihomo-no-ping").chmod(0o700)',
              self.guest, self.stage + '/mihomo-no-ping')
        self.deadline = time.monotonic() + 21600

    def cell(self, pid, mode, scope):
        assert fingerprint() == self.baseline, 'Working profile changed'
        assert time.monotonic() < self.deadline, 'Whole-run deadline reached'
        profile = next((p for p in self.spec['profiles'] if p['id'] == pid), None)
        diagnostic = None
        if profile is None:
            diagnostic = next(p for p in self.spec['focused_profiles'] if p['id'] == pid)
            profile = dict(next(p for p in self.spec['profiles'] if p['id'] == 'P07'), id=pid, file=diagnostic['file'])
        label = pid + '-' + mode + '-' + scope + '-' + secrets.token_hex(3)
        root = self.root / label
        root.mkdir(mode=0o700)
        guest = self.guest + '/' + label
        certificate(root, self.addr)
        log = (root / 'fixture.log').open('w')
        process = subprocess.Popen([sys.executable, str(SCRIPTS / 'dualstack_fixture.py'), str(root),
                                    self.addr['bridge4'], self.addr['data4'], self.addr['data6'], self.addr['client4'], mode],
                                   stdout=log, stderr=subprocess.STDOUT)
        result = None
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not (root / 'fixture.json').exists():
                assert process.poll() is None, 'Fixture startup failed'
                time.sleep(.05)
            fixture = json.loads((root / 'fixture.json').read_text())
            native_path = self.root / 'native-peer.json'
            if native_path.exists():
                fixture['native_peer'] = json.loads(native_path.read_text())
                private(root / 'fixture.json', json.dumps(fixture))
            template = self.template
            if profile.get('template'):
                source = REPO / 'Profiles' / profile['template']
                template = json.loads(run(['/usr/bin/ruby', '-rjson', '-ryaml', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))', source]).stdout)
                fixture['template_identity'] = {'file': profile['template'], 'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                                                'engine_mode': profile['engine_mode']}
                private(root / 'fixture.json', json.dumps(fixture))
            config = config_for(template, profile, fixture, (root / 'server.crt').read_text(), guest)
            if profile.get('engine_mode'):
                config['mode'] = profile['engine_mode']
            if diagnostic:
                if pid == 'P08':
                    config['proxies'][0]['ip-version'] = 'ipv6-prefer'
                elif pid == 'P09':
                    config['dns']['enhanced-mode'] = 'redir-host'
                    config['dns'].pop('fake-ip-range', None)
                    config['dns'].pop('fake-ip-range6', None)
                elif pid == 'P10':
                    config['tun']['dns-mode'] = 'native'
            private(root / 'config.json', json.dumps(config, indent=2))
            private(REPO / 'Profiles' / profile['file'], '# Lab-only generated variant. Pair with the matching live fixture.\n' + json.dumps(config, indent=2) + '\n')
            private(root / 'matrix.json', json.dumps(self.spec))
            if self.v3 and scope in ('focus-system', 'focus-native-dns'):
                shutil.copy2(REPO / '.build/v3-installed/dns-owner', root / 'dns-owner')
            for name in FILES:
                shutil.copy2(SCRIPTS / name, root / name)
            payload = root / 'payload.tar'
            with tarfile.open(payload, 'w') as archive:
                for name in FILES + ['config.json', 'matrix.json', 'fixture.json', 'server.crt']:
                    archive.add(root / name, arcname=name)
                if (root / 'dns-owner').exists(): archive.add(root / 'dns-owner', arcname='dns-owner')
            run(['/usr/bin/scp', '-q', payload, 'mimo-vm-admin:' + self.stage + '/payload.tar'])
            admin('/usr/bin/python3', '-c',
                  'import pathlib,tarfile,sys; p=pathlib.Path(sys.argv[1]);p.mkdir(mode=0o700);tarfile.open(sys.argv[2]).extractall(p);[(f.chmod(0o600)) for f in p.iterdir()]',
                  guest, self.stage + '/payload.tar')
            if (root / 'dns-owner').exists(): admin('/bin/chmod', '700', guest + '/dns-owner')
            print('RUN ' + label, flush=True)
            selected_engine = self.guest + '/mihomo-no-ping'
            if scope == 'focus-invalid-engine':
                selected_engine = guest + '/rejected-engine'
                admin('/usr/bin/python3', '-c', 'import pathlib,sys;p=pathlib.Path(sys.argv[1]);p.write_text("deliberately invalid test engine\\n");p.chmod(0o600)', selected_engine)
            execution = subprocess.run([sys.executable, str(REPO / 'Scripts/vm-admin.py'), '/usr/bin/env',
                'MIMO_TEST_ENGINE=' + selected_engine, 'MIMO_TEST_ENGINE_SHA256=' + self.engine_sha,
                '/usr/bin/python3', guest + '/dualstack_profile_test.py', guest, pid, mode, scope],
                capture_output=True, text=True, timeout=420)
            private(root / 'vm-command.log', execution.stdout + execution.stderr)
            print(execution.stdout.strip(), flush=True)
            if scope == 'watchdog':
                admin('/usr/bin/python3', '-c',
                      'import json,pathlib,sys,time; p=pathlib.Path(sys.argv[1])/"report.json"; end=time.monotonic()+12\nwhile time.monotonic()<end:\n if p.exists() and json.loads(p.read_text()).get("status")=="complete": break\n time.sleep(.2)\nelse: raise RuntimeError("Watchdog recovery did not complete")', guest)
            admin('/usr/bin/python3', '-c',
                  'import pathlib,tarfile,os,sys; src=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);a=tarfile.open(out,"w:gz");a.add(src,arcname="cell");a.close();s=out.parent.stat();os.chown(out,s.st_uid,s.st_gid);out.chmod(0o600)',
                  guest, self.stage + '/evidence.tar.gz')
            run(['/usr/bin/scp', '-q', 'mimo-vm-admin:' + self.stage + '/evidence.tar.gz', root / 'evidence.tar.gz'])
            with tarfile.open(root / 'evidence.tar.gz') as archive:
                result = json.load(archive.extractfile('cell/report.json'))
            private(root / 'report.json', json.dumps(result, indent=2))
            admin('/usr/bin/python3', '-c', 'import shutil,sys;shutil.rmtree(sys.argv[1])', guest)
            return result
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            log.close()
            (root / 'server.key').unlink(missing_ok=True)
            assert fingerprint() == self.baseline, 'Working profile changed'

    def close(self):
        # Completed cell evidence is on Delta; never remove an active VM cell.
        state = admin('/usr/bin/python3', '-c',
                      'import pathlib,sys,shutil; p=pathlib.Path(sys.argv[1]); children=[x for x in p.iterdir() if x.is_dir()]; print("pending_cells="+str(len(children))); shutil.rmtree(p) if not children else None',
                      self.guest).stdout.decode().strip()
        print('VM cleanup: ' + state, flush=True)
        ssh('/bin/rm', '-rf', self.stage)
        assert fingerprint() == self.baseline


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--cells', required=True, help='Comma-separated P00:S00 pairs, or all')
    parser.add_argument('--scope', default='matrix')
    parser.add_argument('--v3', action='store_true', help='Test v3 canonical renderer and pinned family/probe engine')
    parser.add_argument('--templates', action='store_true', help='Test the final T4R/T4G/T6R/T6G templates instead of historical P00–P10 variants')
    parser.add_argument('--continue-functional', action='store_true', help='Retain assertion failures and test other cells; still stop on infrastructure, cleanup or packet-check failures')
    args = parser.parse_args()
    assert socket.gethostname().split('.')[0] == 'delta'
    os.umask(0o077)
    lab = Lab(args.root, templates=args.templates, v3=args.v3)
    cells = [(p['id'], s['id']) for p in lab.spec['profiles'] for s in lab.spec['proxy_modes']] if args.cells == 'all' else [tuple(x.split(':')) for x in args.cells.split(',')]
    failed = False
    try:
        for pid, mode in cells:
            result = lab.cell(pid, mode, args.scope)
            if not result['passed']:
                failed = True
                if args.continue_functional and not result.get('error') and all(result['checks'].values()) and not result['counts'].get('FAIL_LEAK'):
                    print('Functional assertions retained; continuing independent cells.', flush=True)
                    continue
                print('STOP: failed cell retained; inspect before continuing.', flush=True)
                return 1
    finally:
        lab.close()
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
