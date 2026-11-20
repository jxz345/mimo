#!/usr/bin/env python3
"""Installed VM regression for reduced recheck transactions; restores saved Rule/Global."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events
from upgrade_test import FLAGS, HELPER, ENGINE, read_settings

BASE = Path(__file__).resolve().parent


def main():
    controller_only = sys.argv[1:] == ["--controller-only"]
    assert sys.argv[1:] in ([], ["--controller-only"])
    assert os.geteuid() == 0
    assert command('/usr/sbin/sysctl', '-n', 'hw.model').stdout.startswith('VirtualMac')
    original = read_settings(); flags = FLAGS.read_bytes()
    mode = json.loads(original['service.routing'])['mode']
    assert mode in ('rule', 'global')
    approved = json.loads(original['service.settings'])['allowlist']['addresses']; assert approved
    credential = command(BASE / 'acceptance-client', 'credential-digest').stdout.strip()
    build = json.loads((BASE / 'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='mimo-reverify-safety-', dir='/var/tmp'))
    print('Evidence:',root,flush=True)
    passed = []; errors = []; stopped = None; guard = None

    def client(*args, check=True):
        return command(BASE / 'acceptance-client', *args, timeout=70, check=check)

    def state(): return json.loads(client('state').stdout)['routing']

    def wait(predicate):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            value = state()
            if predicate(value): return value
            time.sleep(.3)
        raise AssertionError('Expected routing state did not arrive')

    def active(v): return v['phase'] == 'active' and v.get('effectiveMode') == mode

    def https(allowed):
        r = command('/usr/bin/sudo','-n','-u','jay','/usr/bin/curl','--silent','--fail','--noproxy','*',
                    '--max-time','4','--head','https://1.1.1.1/',check=False)
        assert (r.returncode == 0) == allowed, 'Ordinary-user HTTPS disagrees with expected access'

    def record(name): passed.append(name); print('PASS:',name,flush=True)

    try:
        wait(active); https(True)
        if not controller_only:
            for addresses,label in (([], 'empty'), (['192.0.2.254'], 'mismatching')):
                client('allow',*addresses)
                wait(lambda v:v['phase'] == 'blocked' and bool(v.get('blockingIP')))
                https(False)
                record(label+'-allowlist-blocks-after-fresh-IP')
            client('allow',*approved); wait(active); https(True)
            record('original-allowlist-recovers-with-fresh-approval')
        job = command('/bin/launchctl','print','system/'+ENGINE).stdout
        stopped = int(re.search(r'^\s*pid = (\d+)$',job,re.M)[1])
        identity = hashlib.sha256(command('/bin/ps','-p',str(stopped),'-o','lstart=,command=').stdout.encode()).hexdigest()
        # Independent bounded cleanup survives this driver's termination. Only
        # resume the exact same process identity, never a reused PID.
        code = 'import hashlib,os,signal,subprocess,sys,time; time.sleep(60); p=int(sys.argv[1]); v=subprocess.run(["/bin/ps","-p",str(p),"-o","lstart=,command="],capture_output=True,text=True); match=hashlib.sha256(v.stdout.encode()).hexdigest()==sys.argv[2]; os.kill(p,signal.SIGCONT) if match else None'
        guard = subprocess.Popen(['/usr/bin/python3','-c',code,str(stopped),identity],start_new_session=True)
        os.kill(stopped,signal.SIGSTOP)
        wait(lambda v:v['phase'] in ('blocked','unavailable'))
        baseline = offsets(LOGS)
        client('refresh',check=False)
        # Refresh schedules work and returns immediately. Observe the actual
        # attempt and its bounded controller failure, not the RPC return time.
        deadline = time.monotonic()+25
        while time.monotonic()<deadline:
            rows = events(LOGS,baseline)
            prepared = next((i for i,v in enumerate(rows) if v['event']=='mimo_gate_closed' and v['fields'].get('reason')=='Validating the protected profile.'),None)
            if prepared is not None and any(v['event']=='mimo_gate_closed' and 'curl' in v['fields'].get('reason','') for v in rows[prepared+1:]):break
            time.sleep(.2)
        else:raise AssertionError('No completed stalled-controller preparation was observed')
        (root/'controller-stalled-private-events.json').write_text(json.dumps(rows))
        assert any(v['event'] == 'mimo_gate_closed' and v['fields'].get('reason') == 'Validating the protected profile.' for v in rows), 'The stalled-controller test did not reach preparation'
        assert not any(v['event'] in ('mimo_private_probe_ready','mimo_traffic_opened') for v in rows), 'Failed controller cleanup proceeded to probing/opening'
        assert not active(state())
        https(False)
        record('actual-stalled-controller-cannot-prepare-probe-or-open')
        os.kill(stopped,signal.SIGCONT); stopped = None
        guard.terminate(); guard.wait(); guard = None
        client('refresh'); wait(active); https(True)
        record('controller-resume-requires-fresh-approval-and-recovers')
    except Exception as exc:
        errors.append(type(exc).__name__+': '+str(exc))
        print('FAIL:',errors[-1],flush=True)
    finally:
        if stopped is not None:
            try: os.kill(stopped,signal.SIGCONT)
            except ProcessLookupError: pass
        if guard is not None: guard.terminate(); guard.wait()
        try:
            current = read_settings()
            if json.loads(current['service.settings'])['allowlist']['addresses'] != approved: client('allow',*approved)
            if not active(state()): client('refresh')
            wait(active)
            assert configuration_values(read_settings()) == configuration_values(original)
            assert FLAGS.read_bytes() == flags
            assert client('credential-digest').stdout.strip() == credential
            record('original-protected-mode-configuration-credentials-and-service-intent-restored')
        except Exception as exc: errors.append('Restoration: '+type(exc).__name__+': '+str(exc))
        (root/'report.json').write_text(json.dumps(dict(success=not errors,passed=passed,errors=errors,mode=mode,
            packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],
            scope='Installed normal Release in mimo-vm; real allowlist rejection, suspended/resumed mihomo controller, ordinary-user HTTPS and restoration. No synthetic events or helper replacement.'),indent=2)+'\n')
    return 1 if errors else 0


if __name__ == '__main__': sys.exit(main())
