"""Local controls for the shared installed-workflow communication oracle."""
import unittest
import tempfile
from pathlib import Path
import json
from unittest import mock

from v3_gui_event_audit import audit_gui_events, connected_checkpoint, GUICaseAudit, latest_live_segments

GUI_LOG='/logs/runtime-2026-11-27T07-00-00.000Z-12-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl'
OLD_LOG='/logs/runtime-2026-11-26T07-00-00.000Z-88-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl'
NEW_LOG='/logs/runtime-2026-11-27T07-00-01.000Z-99-cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl'


def event(name='mimo_access_presentation_changed', second=1, pid='12', **fields):
    return dict(event=name, timestamp=f'2026-11-27T07:00:{second:02d}.000Z',
                fields={'processRole':'gui', 'pid':pid, **fields})


class GUIAuditTests(unittest.TestCase):
    def test_valid_single_process(self):
        self.assertTrue(audit_gui_events([event()], expected_pid=12)['passed'])

    def test_no_events_is_not_proof(self):
        self.assertFalse(audit_gui_events([])['passed'])

    def test_non_gui_events_are_not_proof(self):
        self.assertFalse(audit_gui_events([event(processRole='core')])['passed'])

    def test_disconnect_reconnect_still_fails(self):
        result = audit_gui_events([event('daemon_client_disconnected', source='status_probe'),
                                   event('daemon_client_connected', second=6)])
        self.assertFalse(result['passed'])
        self.assertEqual(result['disconnects'][0]['recovery_seconds'], 5)

    def test_multiple_pids_fail(self):
        self.assertFalse(audit_gui_events([event(), event(pid='13')])['passed'])

    def test_replaced_baseline_pid_fails(self):
        self.assertFalse(audit_gui_events([event()], expected_pid=13)['passed'])

    def test_stop_and_restart_are_not_exempt(self):
        for name in ('daemon_client_stopped','app_terminating','process_entered'):
            with self.subTest(event=name):
                self.assertFalse(audit_gui_events([event(), event(name)])['passed'])

    def test_reconnect_other_pid_does_not_close_gap(self):
        result = audit_gui_events([event('daemon_client_disconnected'), event('daemon_client_connected', second=6, pid='13')])
        self.assertIsNone(result['disconnects'][0]['reconnected_at'])

    def test_checkpoint_requires_current_live_pid(self):
        with self.assertRaises(AssertionError):
            connected_checkpoint([event('daemon_client_connected')], ['13'])

    def test_checkpoint_requires_connection_receipt(self):
        with self.assertRaises(AssertionError):
            connected_checkpoint([event()], ['12'])

    def test_checkpoint_rejects_unresolved_disconnect(self):
        with self.assertRaises(AssertionError):
            connected_checkpoint([event('daemon_client_connected'), event('daemon_client_disconnected', second=2)], ['12'])

    def test_checkpoint_rejects_multiple_guis(self):
        with self.assertRaises(AssertionError):
            connected_checkpoint([event('daemon_client_connected')], ['12','13'])

    def test_checkpoint_retains_generation(self):
        proof = connected_checkpoint([event('daemon_client_connected', generation='8')], ['12'])
        self.assertEqual((proof['pid'], proof['generation']), ('12','8'))


class WholeCaseSamplingTests(unittest.TestCase):
    def make(self, root, rows=None, read=None, pids=None):
        rows = [event()] if rows is None else rows
        return GUICaseAudit(Path(root), lambda:{GUI_LOG:(1,10)},
            lambda offset:rows if offset else [event('daemon_client_connected')],
            read or (lambda:None), pids or (lambda:['12']), interval=.01)

    def test_retains_raw_and_sampling_proof(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root).start(); result=audit.finish('test')
            self.assertTrue(result['passed'])
            self.assertTrue(result['state_samples'][0]['passed'])
            self.assertEqual(json.loads((Path(root)/'test-all-raw-events.json').read_text()), [event()])
            self.assertIs(result, audit.finish('test'))

    def test_setup_disconnect_is_not_discarded(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root, rows=[event('daemon_client_disconnected')]).start()
            self.assertFalse(audit.finish('test')['passed'])

    def test_timeout_samples_fail_without_exporting_exception_message(self):
        def failed(): raise TimeoutError('private credential sentinel')
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root).start(); audit.done.set(); audit.worker.join()
            audit.read_state=failed; audit.sample(); result=audit.finish('test')
            self.assertFalse(result['passed'])
            self.assertNotIn('private credential sentinel', json.dumps(result))
            self.assertEqual(result['state_samples'][-1]['error_class'], 'TimeoutError')

    def test_deadline_failure_even_when_rpc_returns(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root).start(); audit.done.set(); audit.worker.join()
            with mock.patch('v3_gui_event_audit.time.monotonic', side_effect=[10,13.001,13.002]):
                audit.sample()
            self.assertFalse(audit.finish('test')['passed'])

    def test_gui_pid_change_fails(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root).start(); audit.done.set(); audit.worker.join()
            audit.process_ids=lambda:['13']; audit.sample()
            self.assertFalse(audit.finish('test')['passed'])

    def test_failure_before_preflight_preserves_events(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root,pids=lambda:[])
            with self.assertRaises(AssertionError): audit.start()
            self.assertFalse(audit.finish('test')['passed'])
            self.assertTrue((Path(root)/'test-all-raw-events.json').exists())

    def test_quiet_gui_requires_live_baseline_samples_and_cursor_coverage(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root,rows=[]).start()
            result=audit.finish('test')
            self.assertTrue(result['passed'])
            self.assertTrue(result['quiet_GUI_covered'])

    def test_quiet_gui_rotated_log_is_unqualified(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root,rows=[]).start()
            audit.cursor=lambda:{GUI_LOG:(2,10)}
            self.assertFalse(audit.finish('test')['passed'])

    def test_slow_pid_query_is_not_rpc_timeout(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root).start(); audit.done.set(); audit.worker.join()
            with mock.patch('v3_gui_event_audit.time.monotonic', side_effect=[10,10.1,13.1]):
                audit.sample()
            self.assertTrue(audit.samples[-1]['passed'])
            self.assertEqual(audit.samples[-1]['rpc_duration_seconds'], .1)

    def test_old_dead_segment_pruning_does_not_fail(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root,rows=[])
            audit.cursor=lambda:{GUI_LOG:(1,10),OLD_LOG:(2,200)}
            audit.start();audit.cursor=lambda:{GUI_LOG:(1,10)}
            self.assertTrue(audit.finish('test')['passed'])

    def test_new_segment_loss_is_unqualified(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root).start();audit.done.set();audit.worker.join()
            audit.cursor=lambda:{GUI_LOG:(1,10),NEW_LOG:(3,50)};audit.track_cursor()
            audit.cursor=lambda:{GUI_LOG:(1,10)}
            self.assertFalse(audit.finish('test')['passed'])

    def test_old_segment_that_grows_becomes_required(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root);audit.cursor=lambda:{GUI_LOG:(1,10),OLD_LOG:(2,200)}
            audit.start();audit.done.set();audit.worker.join()
            audit.cursor=lambda:{GUI_LOG:(1,10),OLD_LOG:(2,300)};audit.track_cursor()
            audit.cursor=lambda:{GUI_LOG:(1,10)}
            self.assertFalse(audit.finish('test')['passed'])

    def test_all_live_roles_are_covered(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root);audit.cursor=lambda:{GUI_LOG:(1,10),OLD_LOG:(2,200)}
            audit.active_process_ids=lambda:['12','88'];audit.start()
            audit.cursor=lambda:{GUI_LOG:(1,10)}
            self.assertFalse(audit.finish('test')['passed'])

    def test_only_latest_segment_per_live_pid_required_at_start(self):
        older=GUI_LOG.replace('07-00-00','06-00-00')
        self.assertEqual(latest_live_segments({GUI_LOG:(1,10),older:(2,200),OLD_LOG:(3,500)},['12']),{GUI_LOG:(1,10)})

    def test_cursor_sampling_exception_cannot_preserve_passed_true(self):
        with tempfile.TemporaryDirectory() as root:
            audit=self.make(root).start();audit.done.set();audit.worker.join()
            def failed(): raise FileNotFoundError('private path')
            audit.cursor=failed;audit.sample()
            self.assertFalse(audit.samples[-1]['passed'])
            self.assertEqual(audit.samples[-1]['error_class'],'FileNotFoundError')
            audit.cursor=lambda:{GUI_LOG:(1,10)}
            self.assertFalse(audit.finish('test')['passed'])


if __name__ == '__main__':
    unittest.main()
