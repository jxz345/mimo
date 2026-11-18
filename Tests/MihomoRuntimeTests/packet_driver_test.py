#!/usr/bin/env python3
"""Unprivileged fault checks for the VM packet driver's cleanup boundary."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import packet_test


class PacketDriverTests(unittest.TestCase):
    def test_closing_a_failed_diagnostic_socket_keeps_worker_responsive(self):
        requests = '\n'.join(json.dumps({'operation': 'close', 'key': 'failed-connection'}) for _ in range(2)) + '\n'
        result = subprocess.run([sys.executable, '-c', packet_test.WORKER], input=requests,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(line) for line in result.stdout.splitlines()], [{'ok': True}, {'ok': True}])

    def test_invalid_private_probe_is_rejected_before_reading_or_changing_service_state(self):
        for password in (None, '', 'a' * 48, 'g' * 64):
            with self.subTest(password_length=len(password or '')), tempfile.TemporaryDirectory() as directory:
                configuration = Path(directory) / 'fixture.json'
                configuration.write_text(json.dumps({'probePassword': password}))
                with patch.object(packet_test.os, 'geteuid', return_value=0), \
                     patch.object(packet_test, 'command', return_value=subprocess.CompletedProcess([], 0, 'VirtualMac2,1\n', '')) as command, \
                     patch.object(packet_test, 'read_settings') as settings:
                    with self.assertRaisesRegex(AssertionError, 'probePassword'):
                        packet_test.run(configuration)
                    settings.assert_not_called()
                    self.assertEqual(command.call_count, 1)
                    self.assertTrue(configuration.exists())

    def test_relay_reset_failure_does_not_prevent_network_and_service_restoration(self):
        for failure in ('exit', 'timeout'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'restore-default-relay-region').touch()
                (root / 'pf.token').write_text('12345')
                (root / 'credentials.json').write_text('{}')
                (root / 'profile.yaml').write_text('private fixture')
                calls = []

                def command(*arguments, **options):
                    calls.append(tuple(str(argument) for argument in arguments))
                    if 'force-prefer-derp' in arguments:
                        if failure == 'timeout':
                            raise subprocess.TimeoutExpired(arguments, 20)
                        return subprocess.CompletedProcess(arguments, 1, '', '')
                    return subprocess.CompletedProcess(arguments, 0, '', '')

                with patch.object(packet_test, 'command', side_effect=command):
                    with self.assertRaisesRegex(AssertionError, 'relay preference still needs cleanup'):
                        packet_test.restore(root)
                self.assertIn(('/sbin/pfctl', '-a', packet_test.ANCHOR, '-F', 'rules'), calls)
                self.assertIn(('/sbin/pfctl', '-a', packet_test.ANCHOR + '/native-transport', '-F', 'rules'), calls)
                self.assertIn(('/sbin/pfctl', '-X', '12345'), calls)
                self.assertEqual(calls[-1][:3], ('/bin/launchctl', 'bootstrap', 'system'))
                self.assertTrue((root / 'restore-default-relay-region').exists())
                self.assertFalse((root / 'credentials.json').exists())
                self.assertFalse((root / 'profile.yaml').exists())
                self.assertFalse((root / 'pf.token').exists())

    def test_successful_relay_reset_removes_cleanup_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / 'restore-default-relay-region'
            marker.touch()
            with patch.object(packet_test, 'command', return_value=subprocess.CompletedProcess([], 0, '', '')):
                packet_test.restore(root)
            self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
