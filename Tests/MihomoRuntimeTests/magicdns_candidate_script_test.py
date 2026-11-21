#!/usr/bin/env python3
"""VM-only success and restoration tests for the standalone MagicDNS candidate.

Usage: sudo python3 magicdns_candidate_script_test.py SCRIPT ONLINE_PEER_FQDN
Keep the installed build in Rule. No app build or service restart is performed.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=25)


def main():
    assert os.geteuid() == 0, 'Run as root in mimo-vm'
    assert run('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac'), 'VM only'
    assert len(sys.argv) == 3, 'Provide the candidate script and an online peer full name'
    source_path = Path(sys.argv[1])
    source = source_path.read_text()
    hook = 'for my $attempt (1..3) {'
    assert source.count(hook) == 1 and source.count('can_read(45)') == 1
    os.umask(0o077)
    evidence = Path(tempfile.mkdtemp(prefix='mimo-dns-candidate-test-', dir='/var/tmp'))
    print('Private evidence:', evidence, flush=True)
    anchor = 'com.apple/000.mimo'

    def rules(suffix):
        result = run('/sbin/pfctl', '-a', anchor + suffix, '-sr')
        assert result.returncode == 0, result.stderr
        return result.stdout

    checks = []
    cases = [
        ('normal', source),
        ('interrupt', source.replace(hook, "kill 'TERM', $$; sleep 1; " + hook)),
        ('parent-death', source.replace(hook, "kill 'KILL', $$; sleep 1; " + hook)),
        ('watchdog-timeout', source.replace('can_read(45)', 'can_read(1)').replace(hook, 'sleep 20; ' + hook)),
    ]
    for name, text in cases:
        before = {suffix: rules(suffix) for suffix in ['', '/open-policy', '/permission', '/power-guard']}
        assert 'dns-test-' not in before['/open-policy'], 'An earlier temporary test is still present'
        path = evidence / (name + '.pl')
        path.write_text(text)
        result = run('/usr/bin/perl', str(path), sys.argv[2])
        (evidence / (name + '.log')).write_text(result.stdout + result.stderr)
        after = {suffix: rules(suffix) for suffix in before}
        (evidence / (name + '-policies.json')).write_text(json.dumps({'before': before, 'after': after}, indent=2))
        changed = [suffix or 'parent' for suffix in before if after[suffix] != before[suffix]]
        assert not changed, name + ' changed policies: ' + ', '.join(changed)
        if name == 'normal':
            assert result.returncode == 0 and 'PASS: three uncached' in result.stdout and 'RESTORED:' in result.stdout
        else:
            assert result.returncode != 0, 'Successful cleanup masked an interrupted test failure'
        if name in ('parent-death', 'watchdog-timeout'):
            assert 'Watchdog restored' in result.stderr
        checks.append(name + '-restores-policies-and-preserves-permission')
        print('PASS:', checks[-1], flush=True)
        path.unlink()
    (evidence / 'result.json').write_text(json.dumps({
        'scriptSHA256': hashlib.sha256(source_path.read_bytes()).hexdigest(),
        'checks': checks,
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
