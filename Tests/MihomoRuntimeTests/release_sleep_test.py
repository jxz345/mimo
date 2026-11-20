#!/usr/bin/env python3
"""Last acceptance step: request actual macOS sleep in the installed Release VM.

No Tart pause and no signal-injected sleep/wake. Unsupported sleep is incomplete,
not a pass. Restores the original saved configuration and cancels only our alarm.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

from installed_acceptance_test import command
from saved_proxy_test import restore, selected_settings
from upgrade_test import HELPER,STORAGE,FLAGS,RUNTIME,read_settings

BASE=Path(__file__).resolve().parent
OWNER='com.mimo.release-sleep-test'


def run():
    assert os.geteuid()==0 and command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
    observe = '--manual-current' in sys.argv
    original=read_settings();original_mode=json.loads(original['service.routing'])['mode']
    assert original_mode in ('direct','rule','global')
    assert observe or original_mode=='direct'
    build=json.loads((BASE/'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest()==build['helperSHA256']
    root=Path(tempfile.mkdtemp(prefix='mimo-release-sleep-',dir='/var/tmp'));root.chmod(0o700)
    (root/'installed-release').touch();backup=root/'private-backup';backup.mkdir(mode=0o700)
    for src,name in ((HELPER,'mimo-core'),(STORAGE,'state.plist'),(FLAGS,'services.json')):shutil.copyfile(src,backup/name)
    (backup/'credential.digest').write_text(command(BASE/'acceptance-client','credential-digest').stdout.strip())
    guard=None
    if not observe:
        with (root/'watchdog.log').open('w') as log:
            guard=subprocess.Popen([sys.executable,BASE/'saved_proxy_test.py','--watchdog',root,str(os.getpid())],stdout=log,stderr=log,start_new_session=True)
    manual = observe or '--manual' in sys.argv
    completed=[];errors=[];unsupported=False;alarm=None
    def counts(text):
        return {key: int(value) for key, value in re.findall(r'^([^:\n]+):\s*(\d+)$', text, re.M)}
    def client(*args):return json.loads(command(BASE/'acceptance-client',*args,timeout=65).stdout)
    def ready(mode):
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            s=client('state').get('routing',{})
            if s.get('phase')=='active' and s.get('effectiveMode')==mode:return
            time.sleep(.5)
        raise RuntimeError(mode+' did not become active')
    def record(name):completed.append(name);print('PASS:',name,flush=True)
    print('Evidence:',root,flush=True)
    try:
        for mode in ((original_mode,) if observe else ('direct','rule','global')):
            if not observe:client('mode',mode)
            ready(mode)
            before_routing=client('state')['routing']
            before=command('/usr/bin/pmset','-g','stats').stdout
            offsets={p:p.stat().st_size for p in Path('/Library/Logs/ExitIPMonitor').glob('runtime-*.jsonl')}
            if manual:
                print('READY: '+mode+'; use macOS Sleep inside mimo-vm, wake it, then create '+str(root/(mode+'-attempt-complete')),flush=True)
                deadline=time.monotonic()+1200
                while not (root/(mode+'-attempt-complete')).exists():
                    assert time.monotonic()<deadline,'Manual sleep handoff timed out'
                    time.sleep(1)
                result=None
            else:
                alarm=(datetime.datetime.now()+datetime.timedelta(seconds=30)).strftime('%m/%d/%y %H:%M:%S')
                command('/usr/bin/pmset','schedule','wake',alarm,OWNER)
                result=command('/usr/bin/pmset','sleepnow',check=False,timeout=75)
            after=command('/usr/bin/pmset','-g','stats').stdout
            (root/(mode+'-sleep.json')).write_text(json.dumps(dict(before=before,after=after,manual=manual,
                exit=result.returncode if result else None,stdout=result.stdout if result else '',stderr=result.stderr if result else '')))
            if (result and result.returncode) or (manual and counts(after).get('Sleep Count',0)<=counts(before).get('Sleep Count',0)):
                unsupported=True;errors.append('Manual attempt did not increase macOS Sleep Count' if manual else 'macOS refused real sleep with exit '+str(result.returncode))
                print('INCOMPLETE: actual macOS sleep was not observed; no synthetic substitute will be used',flush=True)
                break
            deadline=time.monotonic()+60;woke=False
            while time.monotonic()<deadline:
                records=[]
                for p in Path('/Library/Logs/ExitIPMonitor').glob('runtime-*.jsonl'):
                    with p.open('rb') as stream:
                        stream.seek(offsets.get(p,0))
                        for line in stream:
                            try:records.append(json.loads(line))
                            except ValueError:pass
                (root/(mode+'-events.json')).write_text(json.dumps(records))
                after=command('/usr/bin/pmset','-g','stats').stdout
                woke=(counts(after).get('Sleep Count',0)>counts(before).get('Sleep Count',0)
                    and counts(after).get('User Wake Count',0)>counts(before).get('User Wake Count',0)
                    and any(v['event']=='mimo_network_changed' and v['fields'].get('source')=='wake' for v in records))
                if woke:break
                time.sleep(.5)
            assert woke,'No real sleep/wake counters and wake event'
            preparation='mimo_direct_sleep_prepared' if mode=='direct' else 'mimo_sleep_guard_closed'
            assert any(v['event']==preparation for v in records),'No successful pre-sleep preparation event'
            assert not any(v['event']=='mimo_sleep_guard_failed' for v in records),'Pre-sleep guard failed'
            ready(mode)
            if mode!='direct':
                recovered=client('state')['routing']
                assert recovered.get('verification')!=before_routing.get('verification'),'Protected recovery reused pre-sleep verification'
                assert recovered['observedIP']['checkedAt']>before_routing['observedIP']['checkedAt'],'No fresh approved IP check after sleep'
            command('/usr/bin/sudo','-n','-u','jay','/usr/bin/curl','--silent','--fail','--noproxy','*',
                    '--max-time','15','--head','https://one.one.one.one/')
            record(mode+'-real-sleep-wake-and-mode-recovery')
            if alarm:command('/usr/bin/pmset','schedule','cancel','wake',alarm,OWNER,check=False);alarm=None
    except Exception as exc:errors.append(str(exc))
    finally:
        if alarm:command('/usr/bin/pmset','schedule','cancel','wake',alarm,OWNER,check=False)
        if observe:
            # This path only reads the running application and waits for a human
            # sleep attempt. Do not restart services or replace a user's mode.
            try:
                assert selected_settings(read_settings())==selected_settings(original)
                assert json.loads(FLAGS.read_bytes())==json.loads((backup/'services.json').read_bytes())
                assert command(BASE/'acceptance-client','credential-digest').stdout.strip()==(backup/'credential.digest').read_text()
                record('original-saved-mode-configuration-credentials-and-service-intent-retained')
            except Exception as exc:errors.append('Final read-only configuration check: '+str(exc))
        else:
            restore(root);guard.wait(timeout=8);record('original-Direct-configuration-and-credentials-restored')
        (root/'report.json').write_text(json.dumps(dict(success=not errors,unsupported=unsupported,passed=completed,errors=errors,
            packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],syntheticPowerEvents=False,
            mode=original_mode if observe else 'direct-rule-global',readOnlyObserver=observe,
            scope=('Human macOS Sleep attempt' if manual else 'Actual pmset sleep request')+' in Apple VirtualMac; executed after other tests; not a continuous packet-boundary proof'),indent=2)+'\n')
    return 0 if not errors else 2 if unsupported else 1


if __name__=='__main__':sys.exit(run())
