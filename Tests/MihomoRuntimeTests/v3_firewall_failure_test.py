#!/usr/bin/env python3
"""Bounded, VM-only PF admission/parser failures on the installed candidate.

Does not disable PF, replace the root ruleset, or simulate a failed kernel ioctl.
The lab containment rule protects only reserved test destinations.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import v3_installed_test as t
from v3_fault_traffic_test import Traffic, approved, containment, LAB

ROOT=Path(sys.argv[1])
RUNTIME=Path('/Library/Application Support/Mimo/Runtime')
GUARD=Path('/Library/Application Support/Mimo/Guard')
RESULTS=[]


def save(row):
    RESULTS.append(row)
    (ROOT/'firewall-failure-results.json').write_text(json.dumps(RESULTS,indent=2))
    print(row['id']+': '+row['result'],flush=True)


def lock_case():
    t.route('rule','dual'); approved('rule','dual')
    traffic=Traffic('pf-held-mutation')
    ready=ROOT/'lock.ready'; ready.unlink(missing_ok=True)
    code='import fcntl,time,pathlib; f=open('+repr(str(RUNTIME/'pf-mutation.lock'))+',"r+"); fcntl.flock(f,fcntl.LOCK_EX); pathlib.Path('+repr(str(ready))+').write_text("ready"); time.sleep(8)'
    holder=subprocess.Popen(['/usr/bin/python3','-c',code],start_new_session=True)
    request=None; response=None; error=None; during=[]
    try:
        deadline=time.monotonic()+5
        while not ready.exists() and time.monotonic()<deadline: time.sleep(.05)
        assert ready.exists(),'Lock holder failed'
        config=t.state()['routing']['configuration']; config['mode']='global'
        request_path=ROOT/'lock-request.json'
        request_path.write_text(json.dumps(dict(command='configureRouting',protocolVersion=8,routing=config)))
        request=subprocess.Popen([t.CONTROLS,'request',str(request_path)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        for _ in range(6):
            live=t.run(['/sbin/pfctl','-a',t.ANCHOR,'-sr'],3)
            marker=(RUNTIME/'gate.state').read_text()
            during.append(dict(marker=marker,actual_closed='mimo:transition:deny' in live.stdout or 'mimo:probe:deny' in live.stdout))
            time.sleep(.6)
        holder.wait(timeout=12)
        out,err=request.communicate(timeout=90)
        response=json.loads(out)
        assert request.returncode==0 and not response.get('failure'),str(response.get('failure'))
        approved('global','dual')
    except Exception as e: error=type(e).__name__+': '+str(e)
    finally:
        if holder.poll() is None: holder.terminate(); holder.wait(timeout=5)
        if request is not None and request.poll() is None: request.terminate(); request.wait(timeout=5)
        packets=traffic.finish()
    false_closed=any(x['marker']=='blocked' and not x['actual_closed'] for x in during)
    save(dict(id='pf-held-mutation',result='PASS' if not error and not packets and not false_closed else 'FAIL',
              error=error,native_attempts=len(packets),false_closed_confirmation=false_closed,
              samples=during,scope='Eight-second external lock hold; effective state after release'))


def parser_case():
    t.route('rule','dual'); approved('rule','dual')
    source=GUARD/'blocking.pf'; installed=Path('/etc/pf.anchors/com.mimo.boot')
    backup=ROOT/'guard-blocking.backup'; backup.write_bytes(source.read_bytes());backup.chmod(0o600)
    assert source.read_bytes()==installed.read_bytes(),'Unexpected independent guard copy'
    restore='import pathlib,time; time.sleep(12); b=pathlib.Path('+repr(str(backup))+').read_bytes()\nfor n in '+repr([str(source),str(installed)])+':\n p=pathlib.Path(n); p.write_bytes(b); p.chmod(0o644)'
    restorer=subprocess.Popen(['/usr/bin/python3','-c',restore],start_new_session=True)
    traffic=Traffic('pf-invalid-guard-input')
    result=None; error=None; observed={}
    try:
        source.write_text('mimo qualification: deliberately invalid PF input\n')
        # Drift only Mimo's expected snapshot; keep the live active policy intact.
        (RUNTIME/'guard.expected').write_text('# mimo:test:expected-policy-drift\n')
        result=t.run(['/usr/bin/perl',str(GUARD/'pf-guard.pl'),'--check'],20)
        (ROOT/'pf-invalid-guard-command.log').write_text(result.stdout+result.stderr)
        validation=t.run(['/sbin/pfctl','-n','-a',t.ANCHOR,'-f',str(installed)],5)
        (ROOT/'pf-invalid-guard-parser.log').write_text(validation.stdout+validation.stderr)
        health=json.loads((GUARD/'health.json').read_text())
        live=t.run(['/sbin/pfctl','-a',t.ANCHOR,'-sr'],3).stdout
        marker=(RUNTIME/'gate.state').read_text()
        observed=dict(status=result.returncode,reported_health=health.get('status'),gate=marker,
                      actual_closed='mimo:transition:deny' in live or 'mimo:probe:deny' in live,
                      parser_rejection_status=validation.returncode,
                      parser_error=validation.returncode!=0 and
                          'Infrastructure command failed: /sbin/pfctl (1)' in result.stderr and
                          installed.read_bytes()==source.read_bytes())
        assert result.returncode!=0 and observed['parser_error'],'Did not reach the real PF parser failure'
        assert not (marker=='blocked' and not observed['actual_closed']),'False closure confirmation'
    except Exception as e: error=type(e).__name__+': '+str(e)
    finally:
        restorer.wait(timeout=15)
        for path in (source,installed):
            path.write_bytes(backup.read_bytes());path.chmod(0o644)
        repair=t.run(['/usr/bin/perl',str(GUARD/'pf-guard.pl'),'--check'],30)
        packets=traffic.finish()
        try:
            t.route('direct');t.wait_active('direct',100)
            t.route('rule','dual');approved('rule','dual')
        except Exception as e: error=(error or '')+' recovery: '+str(e)
    save(dict(id='pf-invalid-guard-input',result='PASS' if not error and not packets else 'FAIL',
              error=error,native_attempts=len(packets),observed=observed,
              scope='Real pfctl parser rejection during independent repair; NOT a kernel load/state-flush failure'))


if __name__=='__main__':
    assert os.geteuid()==0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077);containment()
    try:
        if '--parser-only' not in sys.argv[2:]: lock_case()
        parser_case()
    finally:
        t.route('direct');t.wait_active('direct',100)
        t.run(['/sbin/pfctl','-a',LAB,'-F','rules'])
