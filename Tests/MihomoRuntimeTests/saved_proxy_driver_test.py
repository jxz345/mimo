#!/usr/bin/env python3
"""Unprivileged fault checks for saved-configuration acceptance recovery."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import saved_proxy_test


class SavedProxyDriverTests(unittest.TestCase):
    def test_native_reconnect_failure_cannot_prevent_production_direct_recovery(self):
        for failure in ('exit', 'timeout'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                backup = root / 'private-backup'
                backup.mkdir()
                original = {'service.routing': json.dumps({'mode': 'direct'})}
                (backup / 'state.plist').write_bytes(plistlib.dumps(original))
                (backup / 'services.json').write_text('{"core":true}')
                (backup / 'mimo-core').write_bytes(b'normal helper')
                (backup / 'credential.digest').write_text('unchanged fixture digest')
                (root / 'restore-native-up').touch()
                runtime = root / 'runtime'
                runtime.mkdir()
                (runtime / 'gate.state').write_text('blocked')
                helper = root / 'mimo-core'
                helper.write_bytes(b'acceptance helper')
                calls = []

                def start():
                    calls.append('start-production')
                    (runtime / 'gate.state').write_text('direct')

                def command(*arguments, **options):
                    if arguments[-1] == 'up':
                        self.assertIn('start-production', calls)
                        self.assertEqual(helper.read_bytes(), b'normal helper')
                        self.assertEqual((runtime / 'gate.state').read_text(), 'direct')
                        if failure == 'timeout':
                            raise subprocess.TimeoutExpired(arguments, 45)
                        raise subprocess.CalledProcessError(1, arguments)
                    if arguments[-1] == 'credential-digest':
                        output = 'unchanged fixture digest'
                    else:
                        state = {'phase': 'active', 'effectiveMode': 'direct'}
                        output = json.dumps({'routing': state} if arguments[-1] == 'core-state' else state)
                    return subprocess.CompletedProcess(arguments, 0, output, '')

                with patch.multiple(saved_proxy_test, RUNTIME=runtime, HELPER=helper,
                                    STORAGE=root / 'state.plist', FLAGS=root / 'services.json'), \
                     patch.object(saved_proxy_test, 'stop_jobs'), \
                     patch.object(saved_proxy_test, 'start_jobs', side_effect=start), \
                     patch.object(saved_proxy_test, 'read_settings', return_value=original), \
                     patch.object(saved_proxy_test, 'atomic_write', side_effect=lambda path, data: path.write_bytes(data)), \
                     patch.object(saved_proxy_test, 'replace_helper', side_effect=lambda source: shutil.copyfile(source, helper)), \
                     patch.object(saved_proxy_test, 'command', side_effect=command):
                    with self.assertRaises(subprocess.SubprocessError):
                        saved_proxy_test.restore(root)
                self.assertEqual(plistlib.loads((root / 'state.plist').read_bytes()), original)
                self.assertTrue((root / 'restore-native-up').exists(), 'unfinished native recovery must remain retryable')
                self.assertFalse((root / 'cleanup-complete').exists())


if __name__ == '__main__':
    unittest.main()
