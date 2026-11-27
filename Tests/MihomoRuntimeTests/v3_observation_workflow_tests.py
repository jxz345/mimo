"""Local whole-workflow oracle regressions; never contacts a VM or service."""
import ast
import collections
import hashlib
import json
from pathlib import Path
import types
import unittest
import uuid

from v3_gui_event_audit import audit_gui_events


# Allowlisted events from archived false PASS6064fa5d (core40872d29), not a
# fabricated disconnect. Full logs remain private; these fields contain no IPs,
# credentials, hostnames or message text.
ARCHIVED_GUI = [
    dict(event='daemon_client_disconnected', timestamp='2026-11-27T07:02:54.584Z',
         fields=dict(processRole='gui', pid='76548', generation='2', source='status_probe')),
    dict(event='daemon_client_disconnected', timestamp='2026-11-27T07:03:01.867Z',
         fields=dict(processRole='gui', pid='76548', generation='4', source='status_probe')),
    dict(event='daemon_client_connected', timestamp='2026-11-27T07:03:06.175Z',
         fields=dict(processRole='gui', pid='76548', generation='5')),
]


class MemoryPath:
    def __init__(self, *args): pass
    def read_bytes(self): return b'isolated-oracle-test'
    def exists(self): return False


class Clock:
    value = 0
    def monotonic(self): return self.value
    def sleep(self, duration): self.value += duration


def run_observe(gui_rows):
    source = Path(__file__).with_name('v3_observation_test.py').read_text()
    function = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == 'observe')
    state = dict(routing=dict(phase='active', effectiveMode='direct', configuration=dict(mode='direct', networkFamily='ipv4')),
                 status=['ready'], snapshot='new')
    rows = [dict(event='lookup_finished'),dict(event='lookup_http_request')] + gui_rows
    cursor = iter((1,2))
    saved = {}
    gui_result = audit_gui_events(gui_rows, expected_pid='76548')
    fake_audit = types.SimpleNamespace(finish=lambda evidence_id:dict(
        passed=gui_result['passed'], event_audit=gui_result,
        state_samples=[dict(passed=True)], checkpoint=dict(pid='76548'), failures=[]))
    namespace = dict(uuid=uuid, time=Clock(), collections=collections, hashlib=hashlib, Path=MemoryPath,
        json=json, REPORT=MemoryPath(), GUI_AUDIT=fake_audit,
        fingerprint=lambda:dict(epoch=1, policy='', engine=1, peers=[2,3]),
        stable_fingerprint=lambda value:value,
        t=types.SimpleNamespace(state=lambda:state),
        service=types.SimpleNamespace(cursor=lambda:next(cursor), events=lambda offset:rows if offset==1 else [], FORBIDDEN=set()),
        healthy_state=lambda *args:state, save=lambda name,value:saved.update({name:value}),
        print=lambda *args,**kwargs:None)
    exec(compile(ast.Module(body=[function], type_ignores=[]), '<isolated-observe>', 'exec'), namespace)
    try:
        namespace['observe']('archived-communication', lambda:None, 'direct', preserve=False)
    except AssertionError:
        pass
    return saved['report.json'][-1]


class WorkflowOracleTests(unittest.TestCase):
    def test_archived_info_disconnects_cannot_pass_workflow(self):
        result = run_observe(ARCHIVED_GUI)
        self.assertFalse(result['passed'], 'Whole-case workflow ignored archived info-level GUI disconnects')

    def test_clean_stable_gui_workflow_passes(self):
        result = run_observe([dict(event='mimo_access_presentation_changed',
            fields=dict(processRole='gui',pid='76548'),timestamp='2026-11-27T07:00:00Z')])
        self.assertTrue(result['passed'])

    def test_missing_gui_is_not_qualification(self):
        self.assertFalse(run_observe([])['passed'])

    def test_preparation_failure_keeps_whole_case_evidence(self):
        trace=[]; saved={}
        class Audit:
            result=None
            def __init__(self,*args,**kwargs): pass
            def start(self): trace.append('cursor-and-connected-preflight'); return self
            def finish(self,evidence):
                trace.append('retain-all-events')
                self.result=dict(passed=True,event_audit=dict(disconnects=[]))
                return self.result
        def failed():
            trace.append('setup'); raise RuntimeError('private sentinel')
        function=next(n for n in ast.parse(Path(__file__).with_name('v3_observation_test.py').read_text()).body
                      if isinstance(n,ast.FunctionDef) and n.name=='audited_main')
        namespace=dict(ACTION='case', GUI_AUDIT=None, GUICaseAudit=Audit,
            os=types.SimpleNamespace(geteuid=lambda:0,umask=lambda _:None),
            socket=types.SimpleNamespace(gethostname=lambda:'mimo-vm-test'),
            ROOT=types.SimpleNamespace(stat=lambda:types.SimpleNamespace(st_uid=0,st_mode=0o700)),
            service=types.SimpleNamespace(cursor=None,events=None),read_only_state_probe=None,gui_process_ids=None,active_mimo_process_ids=None,
            main=failed,uuid=uuid,hashlib=hashlib,Path=MemoryPath,json=json,
            save=lambda name,value:saved.update({name:value}),print=lambda *args,**kwargs:None)
        exec(compile(ast.Module(body=[function],type_ignores=[]),'<isolated-main>','exec'),namespace)
        with self.assertRaises(RuntimeError):namespace['audited_main']()
        self.assertEqual(trace,['cursor-and-connected-preflight','setup','retain-all-events'])
        report=next(iter(saved.values()))
        self.assertFalse(report['passed'])
        self.assertEqual(report['failure_class'],'RuntimeError')
        self.assertNotIn('private sentinel',json.dumps(report))

    def test_scoped_dns_never_mutates_hosts(self):
        import sys
        from unittest.mock import patch
        function=next(n for n in ast.parse(Path(__file__).with_name('v3_observation_test.py').read_text()).body
                      if isinstance(n,ast.FunctionDef) and n.name=='native_hosts')
        class ExistingPath(MemoryPath):
            def __truediv__(self,name):return self
            def exists(self):return True
            def write_bytes(self,value):raise AssertionError('Scoped fixture must not write hosts')
        verified=[]
        module=types.SimpleNamespace(verify=lambda root,fixture:verified.append(True))
        namespace=dict(ROOT=ExistingPath(),Path=ExistingPath,F={'protected_provider_ingress':'proxy_configured_dns'})
        exec(compile(ast.Module(body=[function],type_ignores=[]),'<isolated-host-check>','exec'),namespace)
        with patch.dict(sys.modules,{'v3_native_provider_dns':module}):
            namespace['native_hosts'](True);namespace['native_hosts'](False)
        self.assertEqual(verified,[True,True])


if __name__ == '__main__':
    unittest.main()
