#!/usr/bin/env python3
"""Serial continuation after the first fault campaign and its watchdog finish."""
import itertools
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

ROOT=Path(sys.argv[1])
assert os.geteuid()==0 and socket.gethostname().startswith('mimo-vm')
os.umask(0o077)
deadline=time.monotonic()+900
while not (ROOT/'watchdog.finished').exists():
    assert time.monotonic()<deadline,'Previous campaign did not finish'
    time.sleep(1)
(ROOT/'watchdog.finished').unlink()
log=(ROOT/'continuation-watchdog.log').open('w')
subprocess.Popen(['/usr/bin/python3',str(ROOT/'v3_fault_watchdog.py'),str(ROOT),str(os.getpid())],
                 stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
import v3_installed_test as t
import v3_fault_traffic_test as ft
status=[]


def record(name,code):
    status.append(dict(stage=name,status=code))
    (ROOT/'continuation-status.json').write_text(json.dumps(status,indent=2))
    print(name+': '+str(code),flush=True)


try:
    archive=ROOT/'preliminary-core-resume';archive.mkdir(exist_ok=True)
    for p in ROOT.glob('*-core-stall-*'): shutil.move(str(p),archive/p.name)
    ft.save=lambda:(ROOT/'core-resume-results.json').write_text(json.dumps(ft.RESULTS,indent=2))
    ft.containment()
    try:
        for family,mode in itertools.product(('ipv4','dual'),('rule','global')):
            ft.run_case(family,mode,'core-stall')
        record('core-resume',0)
    except Exception as e:
        record('core-resume',type(e).__name__+': '+str(e))
    finally:
        t.route('direct');t.wait_active('direct',100)
        t.run(['/sbin/pfctl','-a',ft.LAB,'-F','rules'])
    for name in ('v3_ipv6_control_test','v3_firewall_failure_test','v3_package_closure_test'):
        with (ROOT/(name+'.log')).open('w') as output:
            try:
                result=subprocess.run(['/usr/bin/python3',str(ROOT/(name+'.py')),str(ROOT)],
                                      stdout=output,stderr=subprocess.STDOUT,timeout=600)
                record(name,result.returncode)
            except subprocess.TimeoutExpired: record(name,'TIMEOUT')
finally:
    (ROOT/'continuation.finished').write_text(str(time.time()))
