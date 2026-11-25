#!/usr/bin/env python3
"""Continue qualification serially after the traffic campaign and its recovery."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

ROOT = Path(sys.argv[1])
assert os.geteuid() == 0 and socket.gethostname().startswith('mimo-vm')
os.umask(0o077)
deadline = time.monotonic() + 2400
while not (ROOT / 'watchdog.finished').exists():
    assert time.monotonic() < deadline, 'Traffic campaign did not finish'
    time.sleep(1)
(ROOT / 'watchdog.finished').unlink()
log = (ROOT / 'continuation-watchdog.log').open('w')
subprocess.Popen(['/usr/bin/python3', str(ROOT / 'v3_fault_watchdog.py'), str(ROOT), str(os.getpid())],
                 stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
stages = []
try:
    for name in ('v3_active_guard_compat_test', 'v3_ipv6_control_test', 'v3_firewall_failure_test', 'v3_package_closure_test'):
        with (ROOT / (name + '.log')).open('w') as output:
            try:
                result = subprocess.run(['/usr/bin/python3', str(ROOT / (name + '.py')), str(ROOT)],
                                        stdout=output, stderr=subprocess.STDOUT, timeout=600)
                status = result.returncode
            except subprocess.TimeoutExpired:
                status = 'TIMEOUT'
        stages.append(dict(stage=name, status=status))
        (ROOT / 'continuation-status.json').write_text(json.dumps(stages, indent=2))
        print(name + ': ' + str(status), flush=True)
        if status != 0: break
finally:
    (ROOT / 'continuation.finished').write_text(str(time.time()))
