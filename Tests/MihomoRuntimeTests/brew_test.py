#!/usr/bin/env python3
"""Run from Delta: install/reinstall/uninstall the published Mimo Homebrew cask.

Requires the expected public tap commit and release checksum. Downloads through
Homebrew from GitHub; never substitutes a local archive or edits the tapped cask.
Restores the original manual installation, settings and formula ownership.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]
GUEST = '/Users/jay/mimo-tests/runtime/'
CASK = 'jxz345/tap/mimo'
FORMULA = 'jxz345/tap/mihomo@1.19.34'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tap-commit', required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--version', default='1.0')
    args = parser.parse_args()
    assert len(args.tap_commit) == 40 and all(c in '0123456789abcdef' for c in args.tap_commit)
    assert len(args.sha256) == 64 and all(c in '0123456789abcdef' for c in args.sha256)
    evidence = Path(tempfile.mkdtemp(prefix='brew-', dir=REPO / '.build/mihomo-runtime-tests/evidence'))
    root = None
    passed = []
    success = False
    failure = None
    cleanup_errors = []

    def command(label, args, check=True):
        result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=600, cwd=REPO)
        (evidence / (label + '.log')).write_text(result.stdout + result.stderr)
        if check and result.returncode:
            raise RuntimeError(label + ' failed; see ' + str(evidence / (label + '.log')))
        return result

    def admin(label, *args):
        return command(label, [sys.executable, REPO / 'Scripts/vm-admin.py', *args])

    def brew(label, *args, check=True):
        return command(label, [sys.executable, REPO / 'Scripts/vm-brew.py', *args], check=check)

    def verify(label, operation, *args):
        admin(label, '/usr/bin/python3', GUEST + 'brew_state.py', operation, root, *args)
        passed.append(label)
        print('PASS:', label, flush=True)

    try:
        inspection = command('verify-published-tap', ['/usr/bin/ssh', 'mimo-vm',
            "git -C /opt/homebrew/Library/Taps/jxz345/homebrew-tap rev-parse HEAD"])
        assert inspection.stdout.strip() == args.tap_commit, 'VM tap differs from the published commit'
        clean = command('verify-clean-tap', ['/usr/bin/ssh', 'mimo-vm',
            "git -C /opt/homebrew/Library/Taps/jxz345/homebrew-tap status --porcelain"])
        assert not clean.stdout.strip(), 'Published tap must have no local modifications'
        result = admin('prepare', '/usr/bin/python3', GUEST + 'brew_state.py', 'prepare')
        root = json.loads(result.stdout)['evidence']
        command('remove-original-formula', ['/usr/bin/ssh', 'mimo-vm',
            'HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 /opt/homebrew/bin/brew uninstall --formula ' + FORMULA])
        for kind, token in (('--cask', CASK), ('--formula', FORMULA)):
            brew('trust-' + kind[2:], 'trust', kind, token)
        # Homebrew must be able to inspect the VM's only unrelated formula
        # during its normal autoremove pass. It was explicitly installed.
        brew('trust-existing-guest-agent', 'trust', '--formula', 'openai/tools/tart-guest-agent')
        info = json.loads(brew('published-cask-info', 'info', '--json=v2', '--cask', CASK).stdout)['casks'][0]
        expected_url = 'https://github.com/jxz345/mimo/releases/download/v' + args.version + '/Mimo-' + args.version + '.zip'
        assert info['version'] == args.version and info['sha256'] == args.sha256 and info['url'] == expected_url
        brew('download-published-release', 'fetch', '--force', '--cask', CASK)
        passed.append('published-tap-version-checksum-and-GitHub-download-verified')
        print('PASS: published-tap-version-checksum-and-GitHub-download-verified', flush=True)
        brew('install-with-missing-dependency', 'install', '--cask', CASK)
        verify('brew-install-with-dependency-restores-Direct', 'installed')
        brew('formula-test', 'test', FORMULA)
        passed.append('brew-pinned-formula-test')
        print('PASS: brew-pinned-formula-test', flush=True)
        admin('stop-core', GUEST + 'installation-check', 'core', 'stop')
        brew('reinstall-stopped', 'reinstall', '--cask', CASK)
        verify('brew-reinstall-retains-stopped-core', 'installed', 'stopped')
        admin('start-core', GUEST + 'installation-check', 'core', 'start')
        brew('uninstall-cask', 'uninstall', '--cask', CASK)
        verify('brew-uninstall-removes-services-restores-network-retains-settings', 'uninstalled')
        verify('brew-cask-uninstall-autoremoves-unneeded-mihomo', 'dependency-absent')
        # Also cover an explicitly requested engine: this must survive app
        # removal, then be removable through a separate formula uninstall.
        brew('trust-formula-again', 'trust', '--formula', FORMULA)
        brew('install-explicit-dependency', 'install', '--formula', FORMULA)
        brew('trust-cask-again', 'trust', '--cask', CASK)
        brew('install-again', 'install', '--cask', CASK)
        verify('brew-reinstall-after-full-removal-restores-Direct', 'installed')
        brew('final-uninstall-cask', 'uninstall', '--cask', CASK)
        verify('brew-second-uninstall-restores-network', 'uninstalled')
        assert 'mihomo@1.19.34 1.19.34' in brew('explicit-dependency-retained', 'list', '--versions', FORMULA).stdout
        passed.append('brew-cask-uninstall-retains-explicit-mihomo')
        print('PASS: brew-cask-uninstall-retains-explicit-mihomo', flush=True)
        brew('final-uninstall-formula', 'uninstall', '--formula', FORMULA)
        verify('brew-second-dependency-uninstall-removes-binary', 'dependency-absent')
        success = True
    except Exception as error:
        failure = str(error)
        print('FAIL:', failure, flush=True)
    finally:
        if root is not None:
            # Each cleanup is attempted even if a preceding Homebrew command failed.
            brew('cleanup-cask', 'uninstall', '--cask', CASK, check=False)
            brew('cleanup-formula', 'uninstall', '--formula', FORMULA, check=False)
            recovery = [
                ('trust-original-formula', ['/usr/bin/ssh', 'mimo-vm',
                    'HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew trust --formula ' + FORMULA]),
                ('restore-original-formula', ['/usr/bin/ssh', 'mimo-vm',
                    'HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 /opt/homebrew/bin/brew install --formula ' + FORMULA]),
                ('restore-manual-installation', [sys.executable, REPO / 'Scripts/vm-admin.py',
                    '/usr/bin/python3', GUEST + 'brew_state.py', 'restore', root]),
            ]
            for label, arguments in recovery:
                try:
                    command(label, arguments)
                except Exception as error:
                    cleanup_errors.append(str(error))
            if not cleanup_errors:
                passed.append('original-manual-installation-and-Direct-restored')
                print('PASS: original-manual-installation-and-Direct-restored', flush=True)
            for kind, token in (('--cask', CASK), ('--formula', FORMULA)):
                brew('untrust-' + kind[2:], 'untrust', kind, token, check=False)
            brew('untrust-existing-guest-agent', 'untrust', '--formula', 'openai/tools/tart-guest-agent', check=False)
        success = success and not cleanup_errors
        (evidence / 'report.json').write_text(json.dumps({'success': success, 'passed': passed,
            'failure': failure, 'cleanupErrors': cleanup_errors,
            'guestBackup': root, 'tapCommit': args.tap_commit, 'version': args.version, 'sha256': args.sha256,
            'scope': 'Published jxz345/tap/mimo cask and GitHub release download; protected packet qualification is separate.'}, indent=2))
        print('Evidence:', evidence, flush=True)
    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
