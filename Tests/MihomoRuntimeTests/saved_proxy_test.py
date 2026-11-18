#!/usr/bin/env python3
"""VM-only integration against a user's explicitly saved proxy and allowlist.

Never reads/exports the saved password, never approves a newly observed IP,
never creates qualification.json, and restores the production helper plus the
original configuration in Direct. Captures and snapshots stay root-only in VM.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from upgrade_test import CORE, SUPERVISOR, ENGINE, RUNTIME, STORAGE, FLAGS, HELPER, read_settings, atomic_write
from installed_acceptance_test import command, stop_jobs, start_jobs, replace_helper

CONTROLLER = '/Library/Application Support/Mimo/Mihomo/controller.sock'
WORKER = r'''
import json,socket,ssl,struct,sys
connections={}
for line in sys.stdin:
 v=json.loads(line); key=v.get('key','default');s=None
 try:
  op=v['op']
  if op=='udp':
   s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(4)
   packet=struct.pack('!6H',0x4142,0x0100,1,0,0,0)+b'\x07example\x03com\x00'+struct.pack('!2H',1,1)
   s.sendto(packet,(v.get('host','8.8.8.8'),53));reply=s.recv(2048)
   assert reply[:2]==packet[:2] and reply[2]&128
  elif op=='ipv6':
   s=socket.socket(socket.AF_INET6,socket.SOCK_STREAM);s.settimeout(3);s.connect(('2606:4700:4700::1111',443))
  elif op in ('https','existing'):
   if op=='existing':s=connections.pop(key)
   else:
    s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.settimeout(5)
    if v.get('mixed'):
     s.connect(('127.0.0.1',7890));s.sendall(b'CONNECT 1.1.1.1:443 HTTP/1.1\r\nHost: 1.1.1.1:443\r\n\r\n')
     h=b''
     while b'\r\n\r\n' not in h:
      c=s.recv(1);assert c;h+=c
     assert b' 200 ' in h
    else:s.connect(('1.1.1.1',443))
    s=ssl.create_default_context().wrap_socket(s,server_hostname='one.one.one.one')
   s.sendall(b'HEAD / HTTP/1.1\r\nHost: one.one.one.one\r\nConnection: keep-alive\r\n\r\n')
   h=b''
   while b'\r\n\r\n' not in h:
    c=s.recv(1);assert c;h+=c
   assert h.startswith(b'HTTP/') and h.split()[1][:1] in (b'2',b'3')
   if v.get('keep'):connections[key]=s;s=None
  else:raise AssertionError('Unknown operation')
  print(json.dumps({'ok':True}),flush=True)
 except (OSError,AssertionError,KeyError) as e:print(json.dumps({'ok':False,'error':type(e).__name__}),flush=True)
 finally:
  if s is not None:s.close()
'''


def selected_settings(value):
    return {k:v for k,v in value.items() if k.startswith('service.')}


def restored_settings(original, current):
    # Keep the user's exact saved configuration and retain all spent lookup budget.
    return {**original, **{k:v for k,v in current.items() if not k.startswith('service.')}}


def restore(root):
    with (root/'restore.lock').open('a+b') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        if (root/'cleanup-complete').exists():return
        marker=root/'capture.pid'
        if marker.exists():
            pid=int(marker.read_text())
            running=command('/bin/ps','-p',pid,'-o','command=',check=False).stdout
            if running.startswith('/usr/sbin/tcpdump ') and str(root/'traffic.pcap') in running:
                try:os.kill(pid,signal.SIGINT)
                except ProcessLookupError:pass
            marker.unlink()
        marker=root/'stopped-core.pid'
        if marker.exists():
            pid=int(marker.read_text());live=command('/bin/launchctl','print','system/'+CORE,check=False).stdout
            if ('pid = '+str(pid)+'\n') in live:
                try:os.kill(pid,signal.SIGCONT)
                except ProcessLookupError:pass
            marker.unlink()
        if (root/'test-route').exists():
            command('/sbin/route','-n','delete','-host','198.51.100.254',check=False)
            (root/'test-route').unlink()
        stop_jobs()
        original=plistlib.loads((root/'private-backup/state.plist').read_bytes())
        # Retain consumed lookup budget/cooldowns rather than resetting quotas.
        original=restored_settings(original,read_settings())
        atomic_write(STORAGE,plistlib.dumps(original,fmt=plistlib.FMT_BINARY))
        atomic_write(FLAGS,(root/'private-backup/services.json').read_bytes())
        replace_helper(root/'private-backup/mimo-core')
        start_jobs()
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            # The previous gate file survives replacement. Wait for both live
            # services, after startup has loaded the blocking engine and then
            # restored Direct, before disarming the independent watchdog.
            ready=False
            try:
                client=Path(__file__).parent/'installation-check'
                core=json.loads(command(client,'core-state',timeout=15).stdout)
                supervisor=json.loads(command(client,timeout=25).stdout)
                states=[core.get('routing',{}),supervisor]
                ready=all(s.get('phase')=='active' and s.get('effectiveMode')=='direct' for s in states)
            except (subprocess.CalledProcessError,subprocess.TimeoutExpired,ValueError):pass
            if ready and (RUNTIME/'gate.state').exists() and (RUNTIME/'gate.state').read_text()=='direct':
                assert selected_settings(read_settings())==selected_settings(original)
                assert hashlib.sha256(HELPER.read_bytes()).digest()==hashlib.sha256((root/'private-backup/mimo-core').read_bytes()).digest()
                digest=command(Path(__file__).parent/'acceptance-client','credential-digest').stdout.strip()
                assert digest==(root/'private-backup/credential.digest').read_text()
                assert not (RUNTIME/'qualification.json').exists()
                (root/'cleanup-complete').touch()
                return
            time.sleep(.25)
        raise RuntimeError('Production Direct restoration did not complete')


def watchdog(root,parent):
    deadline=time.monotonic()+1800
    while not (root/'cleanup-complete').exists():
        try:os.kill(parent,0)
        except ProcessLookupError:break
        if time.monotonic()>=deadline:
            os.kill(parent,signal.SIGTERM)
            end=time.monotonic()+60
            while time.monotonic()<end and not (root/'cleanup-complete').exists():time.sleep(.25)
            break
        time.sleep(.5)
    if not (root/'cleanup-complete').exists():restore(root)


def run(direct_only=False,features=False):
    assert os.geteuid()==0 and command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
    base=Path(__file__).resolve().parent
    original=read_settings();routing=json.loads(original['service.routing']);settings=json.loads(original['service.settings'])
    assert routing['mode']=='direct' and routing.get('proxy') and settings['allowlist']['addresses']
    approved=settings['allowlist']['addresses'];proxy=routing['proxy']
    ipaddress.IPv4Address(proxy['server'])
    assert not (RUNTIME/'qualification.json').exists()
    assert all(json.loads(FLAGS.read_bytes()).get(k) for k in ('core','engine','profile'))
    assert 'VM-only acceptance runtime' in command(base/'mimo-core-vm-acceptance','--vm-acceptance-status').stdout
    build=json.loads((base/'acceptance-build.json').read_text())
    assert hashlib.sha256((base/'mimo-core-vm-acceptance').read_bytes()).hexdigest()==build['helperSHA256']
    assert hashlib.sha256(Path(__file__).read_bytes()).hexdigest()==build['inputs']['Tests/MihomoRuntimeTests/saved_proxy_test.py']
    root=Path(tempfile.mkdtemp(prefix='mimo-saved-proxy-',dir='/var/tmp'));root.chmod(0o700)
    backup=root/'private-backup';backup.mkdir(mode=0o700)
    for source,name in [(HELPER,'mimo-core'),(STORAGE,'state.plist'),(FLAGS,'services.json')]:shutil.copyfile(source,backup/name)
    (backup/'credential.digest').write_text(command(base/'acceptance-client','credential-digest').stdout.strip())
    (root/'original-proxy.json').write_text(json.dumps(proxy));(root/'acceptance-build.json').write_text(json.dumps(build))
    completed=[];failures=[];capture=None;worker=None;watcher=None;phases=[];engine_pids=set();success=False
    print('Evidence:',root,flush=True)

    def record(name):completed.append(name);print('PASS:',name,flush=True)
    def client(*args):return json.loads(command(base/'acceptance-client',*args,timeout=70).stdout)
    def supervisor(*args):return json.loads(command(base/'installation-check',*args,timeout=40).stdout)
    def active(mode):return lambda s:s.get('phase')=='active' and s.get('effectiveMode')==mode and (RUNTIME/'gate.state').read_text()==('direct' if mode=='direct' else 'active')
    def blocked(s):return s.get('phase')=='blocked' and not s.get('effectiveMode') and (RUNTIME/'gate.state').read_text()=='blocked'
    def wait_for(predicate,name,timeout=75,whole=False):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            try:
                value=client('state');(root/'last-state.json').write_text(json.dumps(value))
                if predicate(value if whole else value.get('routing',{})):record(name);return value
            except (subprocess.CalledProcessError,subprocess.TimeoutExpired):pass
            time.sleep(.5)
        raise RuntimeError(name+' timed out; private VM state retained')
    def request(op,**kwargs):
        worker.stdin.write(json.dumps(dict(op=op,**kwargs))+'\n');worker.stdin.flush()
        return json.loads(worker.stdout.readline())['ok']
    def pid(label):
        v=command('/bin/launchctl','print','system/'+label,check=False).stdout
        return next((int(x.strip()[6:]) for x in v.splitlines() if x.strip().startswith('pid = ')),None)
    @contextmanager
    def packets(name,expression,empty=True):
        subjects={worker.pid};engine=pid(ENGINE)
        if engine:engine_pids.add(engine)
        subjects.update(engine_pids);started=time.time()
        try:yield subjects
        finally:phases.append(dict(name=name,expression=expression,empty=empty,started=started,ended=time.time(),subjects=sorted(subjects)))
    def deny(name):
        with packets(name,'dst host 1.1.1.1 or dst host 8.8.8.8 or ip6'):
            assert not request('https'),name+' allowed ordinary HTTPS'
            assert not request('https',mixed=True),name+' allowed local proxy HTTPS'
            assert not request('udp'),name+' allowed ordinary DNS/UDP'
            assert not request('ipv6'),name+' allowed IPv6'
        record(name+'-denies-HTTPS-mixed-UDP-and-IPv6')
    def traffic(mode):
        with packets(mode+'-application-traffic','dst host 1.1.1.1 or dst host 8.8.8.8 or ip6'):
            assert request('https',key='persistent',keep=True),'Ordinary TLS/HTTPS failed'
            assert request('https',mixed=True),'Local proxy TLS/HTTPS failed'
            assert not request('ipv6'),'IPv6 unexpectedly connected'
            udp=request('udp')
        if udp:record(mode+'-IPv4-TCP-UDP-HTTPS-and-IPv6-denial')
        else:failures.append(mode+'-UDP-DNS-no-response');print('FAIL:',failures[-1],flush=True)
        # Public domain exceptions are Direct in Rule and proxied in Global.
        with packets(mode+'-public-domain-routing','tcp dst port 443 or udp dst port 53',empty=mode=='global') as subjects:
            p=subprocess.Popen(['/usr/bin/curl','--silent','--fail','--noproxy','*','--max-time','20','--head','https://github.com/robots.txt'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,preexec_fn=identity)
            subjects.add(p.pid);out,err=p.communicate(timeout=25)
            assert p.returncode==0,'Ordinary system DNS/HTTPS failed'
        record(mode+'-system-DNS-and-public-domain-routing')
        command(base/'acceptance-client','check-private-profile')
        record(mode+'-in-memory-profile-matches-saved-credential')
        assert request('existing',key='persistent',keep=True),'Existing HTTPS connection was not usable before revocation'
        record(mode+'-existing-HTTPS-positive-control')
    def refresh_active(name):
        client('refresh');return wait_for(active('global'),name)
    def provider_cycle(mode):
        for operation in ['start','stop','start']:
            client('tailnet',operation)
            expected='running' if operation=='start' else 'stopped'
            wait_for(lambda s:active(mode)(s) and any(v['id']=='tailnetProvider' and v['health']==expected for v in s['services']),
                mode+'-tailnet-'+operation+'-preserves-public-access')
            response=command('/usr/bin/curl','--silent','--fail','--noproxy','*','--max-time','3','http://127.0.0.1:18766/provider.yaml',check=False)
            assert (response.returncode==0 and 'proxies:' in response.stdout) if operation=='start' else response.returncode!=0
        record(mode+'-tailnet-loopback-endpoint-follows-Start-Stop-Restart')
        client('tailnet','start' if settings.get('tailscaleProviderEnabled') else 'stop')
    def event_offsets():return {p:p.stat().st_size for p in Path('/Library/Logs/ExitIPMonitor').glob('runtime-*.jsonl')}
    def events(offsets):
        records=[]
        for p in Path('/Library/Logs/ExitIPMonitor').glob('runtime-*.jsonl'):
            with p.open('rb') as stream:
                stream.seek(offsets.get(p,0))
                for line in stream:
                    try:records.append(json.loads(line))
                    except ValueError:pass
        return records
    def wait_event(offsets,predicate,name,timeout=20):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            found=events(offsets)
            if predicate(found):record(name);return found
            time.sleep(.2)
        raise RuntimeError(name+' timed out')
    def closed_event(records):return any(r['event']=='mimo_gate_closed' and r['fields'].get('confirmed')=='true' for r in records)
    def interrupted(signum,frame):raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
    account=pwd.getpwnam('jay')
    def identity():os.setgroups([]);os.setgid(account.pw_gid);os.setuid(account.pw_uid)
    with (root/'watchdog.log').open('w') as log:watcher=subprocess.Popen([sys.executable,__file__,'--watchdog',str(root),str(os.getpid())],stdout=log,stderr=log,start_new_session=True)
    try:
        # Wait for core XPC readiness after deployment, not a stale gate.state file.
        wait_for(active('direct'),'production-core-ready-before-mode-change')
        # Verify the actual production qualification boundary before swapping helpers.
        client('mode','rule');wait_for(lambda v:blocked(v.get('routing',{})) and 'not qualified' in json.dumps(v.get('status',{})),
            'production-build-keeps-Rule-blocked',whole=True)
        record('production-build-explains-qualification-boundary')
        client('mode','direct');wait_for(active('direct'),'production-Direct-recovers')
        if features:
            client('mode','global');wait_for(lambda v:blocked(v.get('routing',{})) and 'not qualified' in json.dumps(v.get('status',{})),
                'production-build-keeps-Global-blocked',whole=True)
            client('mode','direct');wait_for(active('direct'),'production-Global-to-Direct-recovers')
            command(base/'acceptance-client','check-blocking-profile');record('production-Open-profile-matches-blocking-runtime')
            for service in ['profileHosting','mihomo','core']:
                supervisor(service,'stop');assert active('direct')(supervisor())
                record('production-Direct-'+service+'-Stop-keeps-traffic-open')
                supervisor(service,'start');wait_for(active('direct'),'production-Direct-'+service+'-Start-recovers')
                supervisor(service,'restart');wait_for(active('direct'),'production-Direct-'+service+'-Restart-recovers')
            provider_cycle('direct')
        stop_jobs();replace_helper(base/'mimo-core-vm-acceptance')
        with (root/'capture.log').open('w') as log:
            capture=subprocess.Popen(['/usr/sbin/tcpdump','-n','-U','-i','pktap,en0','-w',str(root/'traffic.pcap'),f'(tcp dst port 443 or udp dst port 53 or ip6) and not (host {proxy["server"]} and port {proxy["port"]})'],stdout=log,stderr=log)
        (root/'capture.pid').write_text(str(capture.pid))
        deadline=time.monotonic()+5
        while 'listening on' not in (root/'capture.log').read_text():
            assert capture.poll() is None and time.monotonic()<deadline;time.sleep(.1)
        start_jobs();wait_for(active('direct'),'test-helper-starts-with-Direct')
        worker=subprocess.Popen([sys.executable,'-u','-c',WORKER],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,preexec_fn=identity)
        with packets('Direct-positive-control','dst host 1.1.1.1 and tcp dst port 443',empty=False):assert request('https')
        record('Direct-ordinary-HTTPS-positive-control')
        if direct_only:
            def direct_without_warning(v):
                return active('direct')(v['routing']) and 'notAllowed' not in v.get('authorizationState',{}) and not v.get('allowlistEventID') and v.get('status')=={'ready':{}}
            client('refresh');wait_for(direct_without_warning,'Direct-refresh-skips-allowlist-and-warning',whole=True)
            client('allow','203.0.113.254');wait_for(direct_without_warning,'Direct-mismatching-list-remains-allowed-without-warning',whole=True)
            client('mode','rule')
            value=wait_for(lambda v:blocked(v['routing']) and bool(v['routing'].get('blockingIP')) and 'notAllowed' in v.get('authorizationState',{}) and bool(v.get('allowlistEventID')),
                'Rule-mismatch-still-publishes-rejected-IP-and-warning',whole=True)
            assert value['routing']['blockingIP']['address'] in approved
            deny('Rule-mismatch-regression')
            client('mode','direct')
            wait_for(lambda v:active('direct')(v['routing']) and 'notAllowed' not in v.get('authorizationState',{}) and not v.get('allowlistEventID'),
                'Direct-selection-clears-Rule-warning-immediately',whole=True)
            client('refresh');wait_for(direct_without_warning,'Direct-fresh-IP-monitoring-remains-enabled',whole=True)
            assert request('https') and not request('ipv6')
            record('Direct-IPv4-works-with-no-allowlist-approval')
        else:
            client('allow');client('mode','rule')
            value=wait_for(lambda s:blocked(s) and bool(s.get('blockingIP')),'Rule-empty-allowlist-observes-exit-but-blocks')
            observed=value['routing']['blockingIP']['address']
            if observed not in approved:raise RuntimeError('Proxy exit does not match the user-approved allowlist; no IP was added')
            record('real-proxy-exit-matches-user-approved-IPv4');deny('empty-allowlist')
            client('allow',*approved);wait_for(active('rule'),'Rule-opens-after-approved-check');traffic('rule')
            client('allow','203.0.113.254')
            assert not request('existing',key='persistent'),'Revocation retained an existing HTTPS connection'
            record('allowlist-revocation-closes-existing-HTTPS')
            wait_for(lambda s:blocked(s) and s.get('blockingIP',{}).get('address')==observed,'wrong-allowlist-shows-triggering-IP');deny('wrong-allowlist')
            client('allow',*approved);wait_for(active('rule'),'Rule-recovers-with-original-allowlist')
            client('mode','global');wait_for(active('global'),'Global-opens-after-fresh-check');traffic('global')
            client('allow');wait_for(lambda s:blocked(s) and bool(s.get('blockingIP')),'Global-empty-allowlist-blocks');deny('Global-empty-allowlist')
            client('allow',*approved);wait_for(active('global'),'Global-recovers-with-original-allowlist')
            for name,changed in [('bad-username',dict(proxy,username='mimo-invalid-test-user')),('unavailable-proxy',dict(proxy,server='127.0.0.1',port=9))]:
                path=root/(name+'.json');path.write_text(json.dumps(changed));client('proxy-metadata',path)
                wait_for(blocked,name+'-blocks');deny(name)
                client('proxy-metadata',root/'original-proxy.json');wait_for(active('global'),name+'-recovers-with-saved-proxy')
            offsets=event_offsets();supervisor('profileHosting','restart');wait_for(blocked,'manual-Reload-closes-protected-access')
            refresh_active('manual-Reload-reverifies-Global')
            records=events(offsets);assert closed_event(records) and any(r['event']=='mimo_private_probe_ready' for r in records)
            record('reload-regenerates-before-protected-traffic')
            command(base/'acceptance-client','check-private-profile')
            # Repeat the engine cycle: launchctl can acknowledge a new process
            # before its Unix controller is ready for the immediate refresh.
            for service in ['profileHosting','mihomo','mihomo','core']:
                supervisor(service,'stop');s=supervisor();assert blocked(s)
                record(service+'-Stop-preserves-Global-and-closes-gate');deny(service+'-Stop')
                supervisor(service,'start')
                if service!='core':client('refresh')
                wait_for(active('global'),service+'-Start-reverifies')
            offsets=event_offsets();core_pid=pid(CORE);assert core_pid
            (root/'stopped-core.pid').write_text(str(core_pid));os.kill(core_pid,signal.SIGSTOP)
            try:
                deadline=time.monotonic()+15
                while not blocked(supervisor()):assert time.monotonic()<deadline;time.sleep(.25)
                record('unresponsive-core-closes-gate');deny('unresponsive-core')
            finally:os.kill(core_pid,signal.SIGCONT);(root/'stopped-core.pid').unlink()
            refresh_active('core-resume-reverifies-Global')
            for label,name in [(CORE,'core-crash'),(ENGINE,'engine-crash')]:
                offsets=event_offsets();old=pid(label);assert old;os.kill(old,signal.SIGKILL)
                wait_event(offsets,closed_event,name+'-closes-gate')
                deadline=time.monotonic()+30
                while pid(label) in (None,old):assert time.monotonic()<deadline;time.sleep(.25)
                refresh_active(name+'-fresh-verification-recovers')
            offsets=event_offsets();command('/usr/bin/curl','--silent','--fail','--max-time','3','--unix-socket',CONTROLLER,'-X','PATCH','http://localhost/configs','--header','Content-Type: application/json','--data-binary','{"mixed-port":0}')
            wait_event(offsets,closed_event,'controller-mismatch-closes-gate');refresh_active('controller-mismatch-recovery-revalidates')
            offsets=event_offsets();(root/'test-route').touch()
            command('/sbin/route','-n','add','-host','198.51.100.254','192.168.64.1')
            try:wait_event(offsets,lambda rows:closed_event(rows) and any(r['event']=='refresh_requested' and r['fields'].get('trigger')=='network_configuration' for r in rows),'network-change-immediately-closes-and-checks')
            finally:command('/sbin/route','-n','delete','-host','198.51.100.254');(root/'test-route').unlink()
            refresh_active('network-change-reverifies-Global')
            if features:
                provider_cycle('global')
                assert request('https') and not request('ipv6')
                record('Global-provider-cycle-retains-IPv4-and-IPv6-denial')
                for service in ['mihomo','mihomo','core']:
                    supervisor(service,'restart')
                    if service!='core':client('refresh')
                    wait_for(active('global'),service+'-Restart-reverifies-Global')
            for _ in range(2):
                supervisor('profileHosting','restart');refresh_active('repeated-Reload-remains-verifiable')
            client('mode','direct');wait_for(active('direct'),'explicit-Direct-recovers')
            with packets('Direct-restored-traffic','dst host 1.1.1.1 and tcp dst port 443',empty=False):assert request('https')
            assert not request('ipv6');record('Direct-restores-IPv4-and-retains-IPv6-denial')
            capture.send_signal(signal.SIGINT);capture.wait(timeout=5);capture=None
            (root/'capture-phases.json').write_text(json.dumps(phases))
            for phase in phases:
                output=command('/usr/sbin/tcpdump','-tt','-nn','-k','NP','-r',root/'traffic.pcap',phase['expression']).stdout
                selected=[line for line in output.splitlines() if line and phase['started']<=float(line.split()[0])<=phase['ended'] and any(re.search(r':'+str(pid)+r'[,)]',line) for pid in phase['subjects'])]
                (root/(phase['name']+'.packets.txt')).write_text('\n'.join(selected))
                assert (not selected) if phase['empty'] else bool(selected),phase['name']+' failed packet expectation'
            record('continuous-capture-confirms-denied-and-proxied-traffic-boundaries')
        success=not failures
    except Exception as error:
        failures.append(str(error));print('FAIL:',str(error),flush=True)
    finally:
        (root/'capture-phases.json').write_text(json.dumps(phases))
        try:
            if capture and capture.poll() is None:capture.send_signal(signal.SIGINT);capture.wait(timeout=5)
            if worker and worker.poll() is None:worker.terminate();worker.wait(timeout=5)
        finally:
            restore(root);record('production-helper-user-configuration-and-password-restored-in-Direct')
        if watcher:watcher.wait(timeout=5)
        report={'success':success,'passed':completed,'failures':failures,'helperSHA256':build['helperSHA256'],'scope':'Saved user proxy in isolated VM; not release qualification','privateEvidence':True,'focus':'Direct allowlist regression' if direct_only else 'feature audit' if features else 'full'}
        (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
        print('RESULT:', 'PASS' if success else 'FAIL',flush=True)
    return 0 if success else 1


if __name__=='__main__':
    if len(sys.argv)==4 and sys.argv[1]=='--watchdog':watchdog(Path(sys.argv[2]),int(sys.argv[3]))
    elif len(sys.argv)==1:sys.exit(run())
    elif sys.argv[1:]==['--direct-allowlist']:sys.exit(run(direct_only=True))
    elif sys.argv[1:]==['--features']:sys.exit(run(features=True))
    else:sys.exit('Usage: saved_proxy_test.py [--direct-allowlist | --features]')
