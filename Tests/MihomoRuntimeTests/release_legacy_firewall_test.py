#!/usr/bin/env python3
"""Destructive fixture restricted to the runtime VM with Mimo already uninstalled.
Preserves other PF rules/references. Stage release-network.pl beside this file.
"""
import json
import pathlib
import re
import socket
import subprocess

assert socket.gethostname().startswith('mimo-vm'), 'Run only in mimo-vm'
ROOT = 'com.apple/000.mimo'
FOREIGN = 'com.apple/999.mimo-cleanup-test'

def run(*args, input=None, check=True):
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=25)
    if check and result.returncode:
        raise RuntimeError(f'{args}: {result.stderr}{result.stdout}')
    return result

def pf(*args, **kw):
    return run('/sbin/pfctl', *args, **kw)

assert run('/bin/launchctl', 'print', 'system/com.mimo.supervisor', check=False).returncode == 113
assert not pathlib.Path('/Applications/Mimo.app').exists(), 'Do not interrupt a user installation'
def owned_paths():
    paths = [ROOT]
    for path in paths:
        for child in pf('-a', path, '-s', 'Anchors').stdout.splitlines():
            child = child.strip()
            if not child:
                continue
            paths.append(child if child.startswith(ROOT + '/') else path + '/' + child)
    return paths

assert all(not pf('-a', path, '-sr').stdout.strip() for path in owned_paths()), 'Fixture needs empty Mimo policies'
assert not pf('-a', FOREIGN, '-sr').stdout.strip() and not pf('-a', FOREIGN, '-sn').stdout.strip(), 'Never overwrite an existing foreign policy'
root_before = pf('-sr').stdout
conf_before = pathlib.Path('/private/etc/pf.conf').read_bytes()
foreign_token = None
DNS = 'State:/Network/Service/com.mimo.dns/DNS'
FOREIGN_DNS = 'State:/Network/Service/mimo-cleanup-test-foreign/DNS'
def scutil(commands):
    return run('/usr/sbin/scutil', input=commands + '\nquit\n').stdout
assert 'No such key' in scutil('show ' + DNS)
assert 'No such key' in scutil('show ' + FOREIGN_DNS)
try:
    for key in (DNS, FOREIGN_DNS):
        scutil('d.init\nd.add ServerAddresses * 127.0.0.1\nd.add ServerPort # 1053\nd.add SupplementalMatchDomains * cleanup-test.invalid\nset ' + key)
    foreign_dns_before = scutil('show ' + FOREIGN_DNS)
    assert '127.0.0.1' in scutil('show ' + DNS)
    reference = pf('-E')
    foreign_token = re.search(r'Token\s*:\s*(\d+)', reference.stdout + reference.stderr)[1]
    pf('-a', FOREIGN, '-f', '-', input='block return out quick proto tcp from any to 192.0.2.1 port 9\n')
    foreign_before = pf('-a', FOREIGN, '-sr').stdout
    # Old nested policy remains active through an old anchor call. Also seed an
    # unreferenced child, the case a parent-only flush fails to remove.
    pf('-a', ROOT + '/old/nested', '-f', '-', input='block return out quick proto tcp from any to 100.100.100.100 port 53\n')
    pf('-a', ROOT + '/old', '-f', '-', input='anchor "nested" out quick all\n')
    pf('-a', ROOT + '/orphan', '-f', '-', input='block return out quick inet6 all\n')
    pf('-a', ROOT, '-f', '-', input='anchor "old" out quick all\n')
    route = run('/sbin/route', '-n', 'get', '100.100.100.100').stdout
    native = re.search(r'interface:\s*(utun\d+)', route)[1]
    own_ip = re.search(r'\binet (100\.\d+\.\d+\.\d+)', run('/sbin/ifconfig', native).stdout)[1]
    before = run('/usr/bin/dig', '@100.100.100.100', '-x', own_ip, '+tcp', '+time=2', '+tries=1', check=False)
    assert 'status: NOERROR' not in before.stdout, 'Seed must reproduce blocked native DNS'
    print('PASS: legacy firewall fixture blocks native Tailnet DNS')
    candidate = pathlib.Path(__file__).with_name('release-network.pl')
    released = run('/usr/bin/perl', str(candidate))
    print(released.stdout)
    assert 'MIMO_CLEANUP tailnet_verified' in released.stdout
    assert 'No such key' in scutil('show ' + DNS)
    assert scutil('show ' + FOREIGN_DNS) == foreign_dns_before
    print('PASS: persistent old Mimo DNS override removed; unrelated resolver preserved')
    assert all(not pf('-a', path, '-sr').stdout.strip() and not pf('-a', path, '-sn').stdout.strip() for path in owned_paths()), 'Every child policy must be empty'
    assert pf('-a', FOREIGN, '-sr').stdout == foreign_before
    assert pf('-sr').stdout == root_before
    assert pathlib.Path('/private/etc/pf.conf').read_bytes() == conf_before
    assert foreign_token in pf('-s', 'References').stdout
    # Idempotence and post-cleanup system DNS/HTTPS, not a cached engine answer.
    assert 'MIMO_CLEANUP tailnet_verified' in run('/usr/bin/perl', str(candidate)).stdout
    run('/usr/bin/curl', '--fail', '--silent', '--max-time', '10', 'https://example.com')
    print('PASS: old/orphan anchors removed; native DNS and HTTPS restored; unrelated PF rules/reference preserved; second release succeeds')
finally:
    scutil('remove ' + DNS + '\nremove ' + FOREIGN_DNS)
    for path in (ROOT, ROOT + '/old', ROOT + '/old/nested', ROOT + '/orphan', FOREIGN):
        pf('-a', path, '-F', 'rules', check=False)
    if foreign_token:
        pf('-X', foreign_token, check=False)
