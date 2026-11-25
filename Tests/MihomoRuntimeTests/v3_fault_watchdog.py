#!/usr/bin/env python3
"""Independent VM recovery for the bounded failure-traffic campaign."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

root=Path(sys.argv[1]); parent=int(sys.argv[2])
assert os.geteuid()==0 and socket.gethostname().startswith('mimo-vm')
duration=int(sys.argv[3]) if len(sys.argv)>3 else 2400
assert 60<=duration<=7200, 'Recovery deadline must remain bounded'
deadline=time.monotonic()+duration
while time.monotonic()<deadline:
    try: os.kill(parent,0)
    except ProcessLookupError: break
    time.sleep(1)
else:
    (root/'watchdog-timeout.json').write_text(json.dumps({'at':time.time(),'duration_seconds':duration}))
    os.kill(parent,signal.SIGTERM)
    # Give the human-operated observer time to stop packet capture and restore
    # its saved configuration before independent emergency recovery changes PF.
    if len(sys.argv)>3:
        for _ in range(120):
            if (root/'restored.json').exists(): break
            try: os.kill(parent,0)
            except ProcessLookupError: break
            time.sleep(1)

for pid in json.loads((root/'stalled.json').read_text()) if (root/'stalled.json').exists() else []:
    try: os.kill(pid,signal.SIGCONT)
    except ProcessLookupError: pass
for args in json.loads((root/'routes.json').read_text()) if (root/'routes.json').exists() else []:
    subprocess.run(['/sbin/route','-n','delete',*args],capture_output=True,timeout=5)
sys.argv=['watchdog',str(root)];sys.path.insert(0,str(root))
import v3_installed_test as t
try:
    t.route('direct');t.wait_active('direct',100)
finally:
    t.run(['/sbin/pfctl','-a','com.apple/999.mimo-qualification','-F','rules'])
    (root/'watchdog.finished').write_text(str(time.time()))
