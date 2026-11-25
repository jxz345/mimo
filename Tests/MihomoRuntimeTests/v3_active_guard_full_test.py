#!/usr/bin/env python3
"""Serialize the installed candidate checks after a confirmed package upgrade."""
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
deadline = time.monotonic() + 240
while 'The upgrade was successful.' not in (ROOT / 'package-install.log').read_text():
    assert time.monotonic() < deadline, 'Installation did not complete successfully'
    time.sleep(1)

for script, output in [('v3_active_guard_compat_test', 'compat-preflight.log'),
                       ('v3_active_guard_campaign', 'campaign.log'),
                       ('v3_active_guard_continuation', 'continuation.log')]:
    print('Starting ' + script, flush=True)
    with (ROOT / output).open('w') as log:
        result = subprocess.run(['/usr/bin/python3', str(ROOT / (script + '.py')), str(ROOT)],
                                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=2600)
    assert result.returncode == 0, script + ' failed; inspect ' + output
    if script == 'v3_active_guard_compat_test':
        rows = json.loads((ROOT / 'compat-results.json').read_text())
        (ROOT / 'compat-preflight-results.json').write_text(json.dumps(rows, indent=2))
        assert len(rows) == 17 and all(row['result'] == 'PASS' for row in rows), 'Native compatibility preflight failed'
    print('Finished ' + script, flush=True)
(ROOT / 'full-campaign.finished').write_text(str(time.time()))
