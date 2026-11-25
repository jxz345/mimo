#!/usr/bin/env python3
"""VM-only active-guard regression, with independent recovery and lab containment.

The host must start the closed fixture and install the candidate first. Preserve
the original before.json privately; never run on Delta or a user's physical Mac.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import v3_installed_test as t

ROOT = Path(sys.argv[1])
assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
assert t.run(['/usr/sbin/sysctl', '-n', 'hw.model']).stdout.startswith('VirtualMac')
os.umask(0o077)
assert (ROOT / 'before.json').exists(), 'Save the pre-fixture state first'
log = (ROOT / 'guard-watchdog.log').open('w')
subprocess.Popen(['/usr/bin/python3', str(ROOT / 'v3_fault_watchdog.py'), str(ROOT), str(os.getpid())],
                 stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
stages = []
try:
    t.route('direct'); t.wait_active('direct', 100)
    import v3_fault_traffic_test as ft
    ft.main()
    stages.append({'stage': 'traffic', 'completed': True})
except Exception as error:
    stages.append({'stage': 'traffic', 'completed': False, 'error': str(error)})
    raise
finally:
    (ROOT / 'guard-campaign.json').write_text(json.dumps(stages, indent=2))
    (ROOT / 'guard-campaign.finished').write_text(str(time.time()))
