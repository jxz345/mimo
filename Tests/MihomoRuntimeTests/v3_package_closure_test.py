#!/usr/bin/env python3
"""Final local Release package/service coexistence on the disposable VM.

Only this script's dummy listener may be stopped. Interactive CLI consent is
exercised through a real PTY; no GUI confirmation is bypassed or mocked.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pty
import select
import signal
import socket
import subprocess
import sys
import time
import v3_installed_test as t

ROOT=Path(sys.argv[1])
APP=Path('/Applications/Mimo.app')
SCRIPT=str(APP/'Contents/Resources/daemon.sh')
FOREIGN='com.apple/998.qualification-foreign'
LEGACY='com.apple/000.mimo/v3-closure-legacy'
RESULTS=[]


def record(name,ok,**details):
    RESULTS.append(dict(id=name,result='PASS' if ok else 'FAIL',**details))
    (ROOT/'package-results.json').write_text(json.dumps(RESULTS,indent=2))
    print(name+': '+RESULTS[-1]['result'],flush=True)
    assert ok,name


def healthy():
    deadline=time.monotonic()+110
    while time.monotonic()<deadline:
        try:
            r=t.state()['routing']; c=t.api('/version')
            if (r['phase']=='active' and r.get('effectiveMode')=='direct'
                and all(s['health']=='running' for s in r['services'])
                and not t.run(['/sbin/pfctl','-a',t.ANCHOR,'-sr']).stdout.strip()
                and c['version']=='v1.19.34-mimo-v3.2'): return True
        except Exception: pass
        time.sleep(.5)
    return False


def release(operation):
    r=t.run(['/bin/bash',SCRIPT,operation],240)
    (ROOT/('package-'+operation+'.log')).write_text(r.stdout+r.stderr)
    labels=('core','supervisor','mihomo','pf-boot','infrastructure')
    clean=r.returncode==0 and all(t.run(['/bin/launchctl','print','system/com.mimo.'+s]).returncode!=0 for s in labels)
    for anchor in (t.ANCHOR,LEGACY):
        clean &= all(not t.run(['/sbin/pfctl','-a',anchor,q]).stdout.strip() for q in ('-sr','-sn','-sT'))
    clean &= '1053' not in t.run(['/usr/sbin/scutil','--dns']).stdout
    clean &= t.run(['/sbin/ifconfig','utun239']).returncode!=0
    native=t.run(['/usr/bin/perl',str(APP/'Contents/Resources/release-network.pl'),'--verify-native'],30)
    (ROOT/('package-'+operation+'-native.log')).write_text(native.stdout+native.stderr)
    return clean and native.returncode==0


def approved_install(dummy_pid):
    pid,fd=pty.fork()
    if pid==0: os.execv('/bin/bash',['/bin/bash',SCRIPT,'install'])
    log=bytearray();approved=False;deadline=time.monotonic()+240;status=None
    try:
        while time.monotonic()<deadline:
            if select.select([fd],[],[],.2)[0]:
                try: part=os.read(fd,65536)
                except OSError: break
                if not part: break
                log.extend(part)
                if b'Stop these engines and continue installing Mimo? [y/N]' in log and not approved:
                    # Confirm exactly the test-owned process. Unexpected conflicts
                    # are refused, even though this is an isolated test machine.
                    text=log.decode(errors='replace')
                    descriptions=[line for line in text.splitlines() if '(PID ' in line]
                    exact=descriptions and all('(PID '+str(dummy_pid)+')' in line for line in descriptions)
                    os.write(fd,b'y\n' if exact else b'n\n');approved=bool(exact)
            done,candidate_status=os.waitpid(pid,os.WNOHANG)
            if done: status=candidate_status;break
        if status is None:
            done,status=os.waitpid(pid,os.WNOHANG)
            if not done: os.kill(pid,signal.SIGTERM);_,status=os.waitpid(pid,0)
    finally: os.close(fd)
    (ROOT/'package-approved-install.log').write_bytes(log)
    return approved and os.waitstatus_to_exitcode(status)==0


def main():
    assert os.geteuid()==0 and socket.gethostname().startswith('mimo-vm')
    os.umask(0o077)
    info=plistlib.loads((APP/'Contents/Info.plist').read_bytes())
    engine=Path('/Library/Application Support/Mimo/Runtime/mihomo')
    engine_sha=hashlib.sha256(engine.read_bytes()).hexdigest()
    signature=t.run(['/usr/bin/codesign','--verify','--deep','--strict',str(APP)])
    record('release-package-identity',info['CFBundleShortVersionString']=='3.0' and info['CFBundleVersion']=='8'
           and signature.returncode==0 and engine_sha=='6925603de8a31decb3919c607a97cee2845afc5ea70aa4c2797620e775f143ca',
           version=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],engine_sha256=engine_sha)
    record('release-package-upgrade', 'The upgrade was successful.' in (ROOT/'package-install.log').read_text() and healthy())
    assert not t.run(['/sbin/pfctl','-a',FOREIGN,'-sr']).stdout.strip()
    foreign='block drop out quick inet from any to 198.51.100.254 label "fixture:foreign:v3"\n'
    subprocess.run(['/sbin/pfctl','-a',FOREIGN,'-f','-'],input=foreign,text=True,capture_output=True,check=True)
    legacy='table <mimo_legacy_test> persist { 198.51.100.1 }\npass out quick inet from any to <mimo_legacy_test>\n'
    subprocess.run(['/sbin/pfctl','-a',LEGACY,'-f','-'],input=legacy,text=True,capture_output=True,check=True)
    dummy=None
    try:
        clean=release('deactivate')
        record('release-cleans-legacy-preserves-foreign',clean and 'fixture:foreign:v3' in t.run(['/sbin/pfctl','-a',FOREIGN,'-sr']).stdout)
        code='import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",7890)); s.listen(); time.sleep(300)'
        dummy=subprocess.Popen(['/usr/bin/python3','-c',code],start_new_session=True)
        time.sleep(.5);assert dummy.poll() is None,'Dummy port unavailable'
        refused=t.run(['/bin/bash',SCRIPT,'install','--non-interactive'],90)
        (ROOT/'package-conflict-refusal.log').write_text(refused.stdout+refused.stderr)
        record('occupied-port-refusal',refused.returncode==130 and dummy.poll() is None and '[MIMO_INSTALL_CANCELLED]' in refused.stdout+refused.stderr)
        accepted=approved_install(dummy.pid)
        dummy.wait(timeout=10)
        record('explicit-fixture-takeover',accepted and dummy.returncode==-signal.SIGTERM and healthy(),scope='Real terminal consent, test-owned standalone listener only')
        record('reinstall-after-release',healthy() and not Path('/Library/Application Support/Mimo/deactivated').exists())
        record('release-package-uninstall',release('uninstall') and 'fixture:foreign:v3' in t.run(['/sbin/pfctl','-a',FOREIGN,'-sr']).stdout)
        candidate = ROOT / 'candidate.pkg'
        package = str(candidate) if candidate.exists() else '/private/tmp/Mimo-v3-closure.pkg'
        install=t.run(['/usr/sbin/installer','-pkg',package,'-target','/'],240)
        (ROOT/'package-final-install.log').write_text(install.stdout+install.stderr)
        record('release-package-final-healthy',install.returncode==0 and healthy())
    finally:
        if dummy is not None and dummy.poll() is None: dummy.terminate();dummy.wait(timeout=5)
        t.run(['/sbin/pfctl','-a',FOREIGN,'-F','rules'])


if __name__=='__main__': main()
