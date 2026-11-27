"""Read-only test harness log reader controls; no installed services touched."""
import ast
import json
import os
from pathlib import Path
import tempfile
import unittest


def reader(name, paths):
    source=Path(__file__).with_name('v3_service_command_test.py').read_text()
    function=next(node for node in ast.parse(source).body if isinstance(node,ast.FunctionDef) and node.name==name)
    namespace=dict(logfiles=lambda:paths,json=json,os=os)
    exec(compile(ast.Module(body=[function],type_ignores=[]),'<isolated-event-reader>','exec'),namespace)
    return namespace[name]


class EventReaderTests(unittest.TestCase):
    def test_cursor_skips_segment_removed_after_listing(self):
        with tempfile.TemporaryDirectory() as directory:
            missing=Path(directory)/'pruned.jsonl'
            self.assertEqual(reader('cursor',[missing])(),{})

    def test_events_skip_segment_removed_before_open(self):
        with tempfile.TemporaryDirectory() as directory:
            missing=Path(directory)/'pruned.jsonl'
            self.assertEqual(reader('events',[missing])({}),[])

    def test_open_handle_retains_tail_after_unlink(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'segment.jsonl';path.write_text('{"event":"old"}\n{"event":"new"}\n')
            stat=path.stat()
            class RemovedAfterOpen:
                def __str__(self):return str(path)
                def stat(self):return path.stat()
                def open(self):
                    stream=path.open();path.unlink();return stream
            result=reader('events',[RemovedAfterOpen()])({str(path):(stat.st_ino,len('{"event":"old"}\n'))})
            self.assertEqual(result,[dict(event='new')])

    def test_permission_failure_is_not_hidden(self):
        class Denied:
            def open(self):raise PermissionError('private path')
        with self.assertRaises(PermissionError):reader('events',[Denied()])({})


if __name__=='__main__':unittest.main()
