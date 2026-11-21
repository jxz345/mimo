#!/usr/bin/env python3
"""Observe the installed release in Rule for two minutes in mimo-vm, then restore configuration."""
import json, os, plistlib, sys, time
from pathlib import Path
BASE=Path('/Users/jay/mimo-tests/event-log/source/Tests/MihomoRuntimeTests')
sys.path.insert(0,str(BASE))
from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events
from upgrade_test import FLAGS, HELPER, read_settings
ROOT=Path('/Users/jay/mimo-tests/event-log')
assert os.geteuid()==0
assert command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
os.umask(0o077)
saved=read_settings(); original_mode=json.loads(saved['service.routing'])['mode']
assert configuration_values(saved)==configuration_values(plistlib.loads((ROOT/'private-before/state.plist').read_bytes()))
flags=FLAGS.read_bytes()
def client(*args): return command(BASE/'acceptance-client',*args,timeout=75)
def state(): return json.loads(client('state').stdout)
def wait_active(mode):
    end=time.monotonic()+60
    while time.monotonic()<end:
        value=state(); r=value['routing']
        if r['phase']=='active' and r.get('effectiveMode')==mode and not r.get('backgroundVerification') and 'ready' in value['status']: return
        time.sleep(.25)
    raise AssertionError('Timed out waiting for active '+mode)
credential=client('credential-digest').stdout.strip()
summary={'environment':'mimo-vm','durationSeconds':120,'checks':[]}
try:
    assert HELPER.read_bytes()==Path('/Applications/Mimo.app/Contents/MacOS/mimo-core').read_bytes()
    command('/usr/bin/codesign','--verify','--deep','--strict','/Applications/Mimo.app')
    client('mode','rule'); wait_active('rule')
    baseline=offsets(LOGS)
    print('Rule is verified; beginning 120-second idle observation.',flush=True)
    for elapsed in (30,60,90,120):
        time.sleep(30)
        rows=events(LOGS,baseline)
        names=('mimo_network_changed','mimo_gate_closed','mimo_verification_audit_failed','mimo_liveness_lost')
        transitions=[r for r in rows if r['event'] in names]
        print('Observation:',elapsed,'seconds;',len(transitions),'new trigger/closure/audit records',flush=True)
    summary['triggerCounts']={name:sum(r['event']==name for r in rows) for name in names}
    summary['sources']=[r.get('fields',{}).get('source') for r in rows if r['event']=='mimo_network_changed']
    (ROOT/'private-observation-records.json').write_text(json.dumps(rows))
    assert not transitions,'Rule cycled during idle observation; private records retained'
    wait_active('rule')
    summary['checks'].append('Rule stayed active for 120 seconds with no new cycle in this VM')
    print('PASS: no idle Rule cycle in 120 seconds',flush=True)
finally:
    client('mode',original_mode); wait_active(original_mode)
    assert configuration_values(read_settings())==configuration_values(saved)
    assert json.loads(FLAGS.read_bytes())==json.loads(flags)
    assert client('credential-digest').stdout.strip()==credential
    summary['checks'].append('Original mode, proxy, allowlist, credential and service intent restored')
    (ROOT/'observation-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('PASS: original configuration and service intent restored',flush=True)
