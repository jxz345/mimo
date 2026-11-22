#!/usr/bin/env python3
"""VM-only check of an actual Homebrew installation, closed gate and uninstall.

Stage beside release_build6_test.py. Start as the authorized mimotest sudo user
after Homebrew installs the candidate cask. No test credential is persisted here.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import release_build6_test as test

ROOT = Path('/var/root/mimo-build6-brew')


def run():
    assert os.environ.get('SUDO_USER') == 'mimotest'
    try:
        test.daemon('activate')
        test.wait_ready('direct')
        # This test targets removal while Rule is closed, including an exit-IP
        # provider outage. Active-mode connectivity is covered by the separate
        # installed acceptance and must not gate this cleanup scenario.
        test.client('mode', 'rule')
        # Hold an actual closed transition so the independent health scanner
        # cannot reopen it while egress and brew cleanup are being checked.
        test.cmd('/Library/PrivilegedHelperTools/mimo-core', '--begin-maintenance')
        barrier = test.pf() + test.pf(test.ANCHOR + '/power-guard')
        assert 'mimo:transition:deny' in barrier
        for address in ['1.1.1.1', '[2606:4700:4700::1111]']:
            r = test.cmd('/usr/bin/curl', '--noproxy', '*', '--silent', '--fail',
                         '--max-time', '3', '--resolve', 'one.one.one.one:443:' + address,
                         'https://one.one.one.one/cdn-cgi/trace', check=False)
            assert r.returncode != 0 and not r.stdout
        dns = test.cmd('/usr/bin/dig', '@1.1.1.1', 'example.com', 'A', '+notcp',
                       '+time=2', '+tries=1', check=False)
        assert 'status: NOERROR' not in dns.stdout
        test.record('Closed transition denies IPv4/IPv6 HTTPS and public UDP DNS')
        test.cmd('/sbin/pfctl', '-a', test.ANCHOR + '/old-build/orphan', '-f', '-',
                 input='block return out quick inet6 all\n')
        environment = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1',
                           HOMEBREW_NO_ANALYTICS='1', HOMEBREW_NO_INSTALL_CLEANUP='1')
        with (ROOT / 'uninstall.log').open('w') as log:
            result = subprocess.run(['/usr/bin/sudo', '-H', '-u', 'mimotest',
                '/opt/homebrew/bin/brew', 'uninstall', '--cask', 'jxz345/tap/mimo'],
                env=environment, stdout=log, stderr=log, timeout=240)
        assert result.returncode == 0, 'Homebrew uninstall failed; private uninstall.log'
        assert not test.APP.exists()
        assert not Path('/Library/PrivilegedHelperTools/mimo-core').exists()
        assert not Path('/Library/PrivilegedHelperTools/mimo-manage').exists()
        # Uninstall removes the inactive receipt as well as installed services.
        for job in test.JOBS:
            assert test.cmd('/bin/launchctl', 'print', 'system/' + job, check=False).returncode != 0
        paths = [test.ANCHOR]
        for path in paths:
            for child in test.pf(path, '-sAnchors').splitlines():
                child = child.strip()
                if child:
                    paths.append(child if child.startswith(test.ANCHOR + '/') else path + '/' + child)
        assert all(test.pf(path) == '' and test.pf(path, '-sn') == '' for path in paths)
        test.dns_absent()
        assert '# BEGIN MIMO BOOT GUARD' not in Path('/etc/pf.conf').read_text()
        assert not Path(test.SOCKET).exists()
        test.cmd('/usr/bin/curl', '--noproxy', '*', '--fail', '--silent',
                 '--max-time', '15', 'https://example.com')
        output = (ROOT / 'uninstall.log').read_text()
        for stage in ['firewall_removed', 'resolver_removed', 'tailnet_verified', 'uninstall_completed']:
            assert 'MIMO_CLEANUP ' + stage in output
        test.record('Actual brew uninstall from closed Rule removes app, helpers, all jobs, old PF children and DNS; native HTTPS/Tailnet DNS restored')
        (ROOT / 'passed').touch()
    finally:
        if Path('/Library/PrivilegedHelperTools/mimo-manage').exists():
            test.daemon('deactivate')
        (ROOT / 'done').touch()


if sys.argv[1:] == ['start']:
    ROOT.mkdir(mode=0o700, exist_ok=True)
    for marker in ['done', 'passed']:
        (ROOT / marker).unlink(missing_ok=True)
    with (ROOT / 'results.log').open('w') as log:
        subprocess.Popen(['/usr/bin/python3', __file__, 'run'], stdout=log, stderr=log, start_new_session=True)
        subprocess.Popen(['/usr/bin/python3', __file__, 'watchdog'], stdout=log, stderr=log, start_new_session=True)
    print('Started VM Homebrew acceptance with cleanup watchdog.')
elif sys.argv[1:] == ['watchdog']:
    for _ in range(480):
        if (ROOT / 'done').exists():
            break
        time.sleep(1)
    else:
        test.daemon('deactivate')
elif sys.argv[1:] == ['run']:
    run()
else:
    raise SystemExit('Usage: release_build6_brew_test.py start|run|watchdog')
