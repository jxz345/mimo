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
import traceback

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
  if op=='peer':
   s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM if v['udp'] else socket.SOCK_STREAM);s.settimeout(4)
   s.connect((v['host'],v['port']))
   if v.get('existingService')=='SSH':assert not v['udp'] and s.recv(255).startswith(b'SSH-')
   else:
    payload=('mimo-peer-'+v['token']+'-saved-proxy-check').encode()
    s.sendall(payload);assert s.recv(512)==payload
  elif op=='udp':
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
        # A boot fault may deliberately make only the GUI unavailable. Its
        # original file must also be restored by the independent watchdog.
        held_gui=root/'boot-gui'
        if held_gui.exists():
            gui=Path('/Applications/Mimo.app/Contents/MacOS/mimo-gui')
            assert not gui.exists(), 'GUI changed during the boot test; retain both files for review'
            os.replace(held_gui,gui)
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
        installed = (root/'installed-release').exists()
        if installed:
            command(HELPER, '--begin-maintenance')
        stop_jobs()
        original=plistlib.loads((root/'private-backup/state.plist').read_bytes())
        # The old core can outlive launchd's removal acknowledgement briefly.
        with (STORAGE.parent/'instance.lock').open('a+b') as state_lock:
            fcntl.flock(state_lock,fcntl.LOCK_EX)
            # Retain consumed lookup budget/cooldowns rather than resetting quotas.
            original=restored_settings(original,read_settings())
            atomic_write(STORAGE,plistlib.dumps(original,fmt=plistlib.FMT_BINARY))
        atomic_write(FLAGS,(root/'private-backup/services.json').read_bytes())
        if not installed:
            replace_helper(root/'private-backup/mimo-core')
        else:
            assert HELPER.read_bytes() == (root/'private-backup/mimo-core').read_bytes()
            (RUNTIME/'maintenance').unlink(missing_ok=True)
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
                # Native reconnection can itself need public access. Recover
                # the production helper and Direct before attempting it, so a
                # failed native CLI cannot strand the VM behind the test gate.
                if (root/'restore-native-up').exists():
                    command('/usr/bin/sudo','-n','-u','jay','/Applications/Tailscale.app/Contents/MacOS/Tailscale','up')
                    (root/'restore-native-up').unlink()
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


def run(direct_only=False,features=False,power=False,relay=None,installed=False,faults_only=False):
    assert os.geteuid()==0 and command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
    base=Path(__file__).resolve().parent
    original=read_settings();routing=json.loads(original['service.routing']);settings=json.loads(original['service.settings'])
    assert routing['mode']=='direct' and routing.get('proxy') and settings['allowlist']['addresses']
    approved=settings['allowlist']['addresses'];proxy=routing['proxy']
    if relay:
        peer=json.loads(relay.read_text())['peer']
        assert len(peer['addresses'])==1 and ipaddress.IPv4Address(peer['addresses'][0]) in ipaddress.IPv4Network('100.64.0.0/10')
        if installed and peer.get('existingService')=='SSH':assert peer['port']==22
        else:assert peer['port']==18889 and re.fullmatch('[0-9a-f]{64}',peer['token'])
    ipaddress.IPv4Address(proxy['server'])
    assert not (RUNTIME/'qualification.json').exists()
    assert all(json.loads(FLAGS.read_bytes()).get(k) for k in ('core','engine','profile'))
    build=json.loads((base/('release-build.json' if installed else 'acceptance-build.json')).read_text())
    if installed:
        assert not power, 'Real Release acceptance must not inject power events'
        app_helper=Path('/Applications/Mimo.app/Contents/MacOS/mimo-core')
        assert app_helper.read_bytes()==HELPER.read_bytes(), 'Installed helper differs from the packaged application'
        assert b'VM-only acceptance runtime' not in HELPER.read_bytes()
        assert hashlib.sha256(HELPER.read_bytes()).hexdigest()==build['helperSHA256']
    else:
        assert 'VM-only acceptance runtime' in command(base/'mimo-core-vm-acceptance','--vm-acceptance-status').stdout
        assert hashlib.sha256((base/'mimo-core-vm-acceptance').read_bytes()).hexdigest()==build['helperSHA256']
    assert hashlib.sha256(Path(__file__).read_bytes()).hexdigest()==build['inputs']['Tests/MihomoRuntimeTests/saved_proxy_test.py']
    root=Path(tempfile.mkdtemp(prefix='mimo-saved-proxy-',dir='/var/tmp'));root.chmod(0o700)
    if installed:(root/'installed-release').touch()
    shutil.copyfile(__file__,root/'driver.py')
    backup=root/'private-backup';backup.mkdir(mode=0o700)
    for source,name in [(HELPER,'mimo-core'),(STORAGE,'state.plist'),(FLAGS,'services.json')]:shutil.copyfile(source,backup/name)
    (backup/'credential.digest').write_text(command(base/'acceptance-client','credential-digest').stdout.strip())
    (root/'original-proxy.json').write_text(json.dumps(proxy));(root/'acceptance-build.json').write_text(json.dumps(build))
    completed=[];failures=[];capture=None;worker=None;watcher=None;phases=[];engine_pids=set();success=False
    print('Evidence:',root,flush=True)

    def record(name):completed.append(name);print('PASS:',name,flush=True)
    def client(*args):
        try:
            return json.loads(command(base/'acceptance-client',*args,timeout=70).stdout)
        except subprocess.CalledProcessError as error:
            (root/'client-failure.json').write_text(json.dumps(dict(operation=args[0], code=error.returncode,
                stdout=error.stdout, stderr=error.stderr)))
            raise RuntimeError('acceptance-client '+str(args[0])+' failed with exit '+str(error.returncode)+'; private diagnostics retained') from error
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
    def stable_public(mode,name):
        # Native down/up finishes before configd delivers all interface/DNS
        # notifications. Establish a quiet, working baseline before attributing
        # a subsequent failure to the independent provider Stop/Start action.
        deadline=time.monotonic()+90;since=None;offsets=event_offsets()
        while time.monotonic()<deadline:
            state=supervisor();now=time.monotonic()
            (root/'last-supervisor.json').write_text(json.dumps(state))
            changes=any(r['event']=='mimo_network_changed' for r in events(offsets))
            offsets=event_offsets()
            if not changes and active(mode)(state) and request('https'):
                if since is None:since=now
                if now-since>=5:record(name);return
            else:since=None
            time.sleep(.5)
        raise RuntimeError(name+' timed out; no stable verified public connection')
    def require_public(mode,label):
        state=supervisor();(root/(label+'-supervisor.json')).write_text(json.dumps(state))
        assert active(mode)(state),label+' changed public routing phase: '+str(state.get('phase'))+'; '+str(state.get('reason'))
        assert request('https'),label+' interrupted ordinary HTTPS'
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
    def freeze_engine():
        engine_pid=pid(ENGINE);assert engine_pid
        os.kill(engine_pid,signal.SIGSTOP)
        try:
            # A frozen controller cannot acknowledge connection cleanup. Mimo
            # conservatively reports unavailable even after PF closes; do not
            # mistake that diagnostic distinction for an open firewall.
            value=wait_for(lambda s:s.get('phase') in ('blocked','unavailable') and not s.get('effectiveMode')
                and (RUNTIME/'gate.state').read_text()=='blocked','unresponsive-engine-closes-gate',timeout=45)
            (root/'engine-suspension-state.json').write_text(json.dumps(value))
            deny('unresponsive-engine')
        finally:
            os.kill(engine_pid,signal.SIGCONT)
        refresh_active('engine-resume-reverifies-Global')
    def crash_services(cases):
        for label,name in cases:
            offsets=event_offsets();old=pid(label);assert old;os.kill(old,signal.SIGKILL)
            wait_event(offsets,lambda rows:closed_event(rows) or (label==SUPERVISOR and any(r['event']=='mimo_startup_guard_closed' and r['fields'].get('confirmed')=='true' for r in rows)),name+'-closes-gate')
            deadline=time.monotonic()+30
            while pid(label) in (None,old):assert time.monotonic()<deadline;time.sleep(.25)
            refresh_active(name+'-fresh-verification-recovers')
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
    def event_offsets():return {p:p.stat().st_size for p in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl')}
    def events(offsets):
        records=[]
        for p in Path('/Library/Logs/Mimo').glob('runtime-*.jsonl'):
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
    def native(*args):
        return command('/usr/bin/sudo','-n','-u','jay','/Applications/Tailscale.app/Contents/MacOS/Tailscale',*args,check=False)
    def relay_peer(label,require_relay=True):
        deadline=time.monotonic()+35;attempts=[]
        while time.monotonic()<deadline:
            reply=native('ping','--c=1','--until-direct=false','--timeout=3s',peer['addresses'][0])
            with (root/(label+'-ping.txt')).open('a') as stream:stream.write(reply.stdout+reply.stderr)
            ping=reply.returncode==0 and (not require_relay or 'via DERP(' in reply.stdout)
            tcp=peer_request(False)
            udp=None if peer.get('existingService')=='SSH' else peer_request(True)
            attempts.append({'time':time.time(),'ping':ping,'TCP':tcp,'UDP':udp})
            (root/(label+'.json')).write_text(json.dumps(attempts))
            if ping and tcp and (udp is None or udp):record(label+('-ping-and-existing-SSH' if udp is None else '-ping-TCP-UDP'));return
        for kind in ['metrics','daemon-goroutines']:
            r=native('debug',kind);(root/(label+'-'+kind+'.txt')).write_text(r.stdout+r.stderr)
        for kind,args in [('guard',('/sbin/pfctl','-a','com.apple/000.mimo','-vvsr')),
                          ('native',('/sbin/pfctl','-a','com.apple/000.mimo/native-transport','-vvsr')),
                          ('sockets',('/usr/sbin/lsof','-nP','-iTCP','-sTCP:^CLOSED')),
                          ('route',('/sbin/route','-n','get',peer['addresses'][0]))]:
            r=command(*args,check=False);(root/(label+'-'+kind+'.txt')).write_text(r.stdout+r.stderr)
        raise RuntimeError(label+' relay did not recover; private diagnostics retained')
    def peer_request(udp):
        return request('peer',host=peer['addresses'][0],port=peer['port'],token=peer.get('token',''),udp=udp,existingService=peer.get('existingService'))
    def interrupted(signum,frame):raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
    account=pwd.getpwnam('jay')
    def identity():os.setgroups([]);os.setgid(account.pw_gid);os.setuid(account.pw_uid)
    with (root/'watchdog.log').open('w') as log:watcher=subprocess.Popen([sys.executable,__file__,'--watchdog',str(root),str(os.getpid())],stdout=log,stderr=log,start_new_session=True)
    try:
        # Wait for core XPC readiness after deployment, not a stale gate.state file.
        wait_for(active('direct'),'production-core-ready-before-mode-change')
        if not installed:
            # Historical helper tests only; the normal Release no longer has this gate.
            client('mode','rule');wait_for(lambda v:blocked(v.get('routing',{})) and 'not qualified' in json.dumps(v.get('status',{})),
                'production-build-keeps-Rule-blocked',whole=True)
            record('production-build-explains-qualification-boundary')
            client('mode','direct');wait_for(active('direct'),'production-Direct-recovers')
        if features:
            if not installed:
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
        if not installed:
            stop_jobs();replace_helper(base/'mimo-core-vm-acceptance')
        with (root/'capture.log').open('w') as log:
            capture=subprocess.Popen(['/usr/sbin/tcpdump','-n','-U','-i','pktap,en0','-w',str(root/'traffic.pcap'),f'(tcp dst port 443 or udp dst port 53 or ip6) and not (host {proxy["server"]} and port {proxy["port"]})'],stdout=log,stderr=log)
        (root/'capture.pid').write_text(str(capture.pid))
        deadline=time.monotonic()+5
        while 'listening on' not in (root/'capture.log').read_text():
            assert capture.poll() is None and time.monotonic()<deadline;time.sleep(.1)
        if not installed:start_jobs()
        wait_for(active('direct'),'installed-Release-ready-in-Direct' if installed else 'test-helper-starts-with-Direct')
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
        elif faults_only:
            client('mode','global');wait_for(active('global'),'additional-faults-Global-verified')
            traffic('global')
            freeze_engine()
            crash_services([(SUPERVISOR,'supervisor-crash')])
            assert request('https') and request('udp') and not request('ipv6')
            record('additional-faults-IPv4-restored-and-IPv6-denied')
            client('mode','direct');wait_for(active('direct'),'additional-faults-Direct-recovery')
        elif relay:
            status=json.loads(native('status','--json').stdout)
            assert status['BackendState']=='Running'
            relay_peer('Direct-peer-baseline',require_relay=False)
            client('tailnet','start')
            for mode in ['rule','global']:
                client('mode',mode);wait_for(active(mode),mode+'-relay-public-access-approved')
                traffic(mode);relay_peer(mode+'-warm-relay')
                for cycle in range(1,6):
                    assert native('debug','break-derp-conns').returncode==0
                    relay_peer(mode+'-relay-reconnect-'+str(cycle))
                (root/'restore-native-up').touch()
                try:
                    assert native('down').returncode==0
                    assert native('up').returncode==0
                finally:
                    assert native('up').returncode==0
                    (root/'restore-native-up').unlink()
                client('refresh');wait_for(active(mode),mode+'-native-restart-reverified')
                relay_peer(mode+'-native-down-up')
                stable_public(mode,mode+'-native-network-settled-before-provider-controls')
                client('tailnet','stop')
                require_public(mode,mode+'-provider-Stop')
                assert not peer_request(False),mode+' provider Stop retained peer TCP access'
                if peer.get('existingService')!='SSH':assert not peer_request(True),mode+' provider Stop retained peer UDP access'
                record(mode+'-provider-Stop-blocks-peer-without-closing-approved-public-access')
                for operation in ['start','restart']:
                    # Match the dashboard's Restart: commit Stop, then Start
                    # with the resulting revision. There is no restart setting.
                    if operation=='restart':client('tailnet','stop')
                    client('tailnet','start')
                    require_public(mode,mode+'-provider-'+operation)
                    relay_peer(mode+'-provider-'+operation)
            client('mode','direct');wait_for(active('direct'),'relay-test-restores-Direct')
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
            if power:
                for mode in ['rule','global']:
                    client('mode',mode);wait_for(active(mode),mode+'-power-baseline')
                    assert request('https',key='power',keep=True)
                    offsets=event_offsets();supervisor_pid=pid(SUPERVISOR);core_pid=pid(CORE)
                    assert supervisor_pid and core_pid
                    (root/'stopped-core.pid').write_text(str(core_pid));os.kill(core_pid,signal.SIGSTOP)
                    try:
                        os.kill(supervisor_pid,signal.SIGUSR1)
                        rows=wait_event(offsets,lambda r:any(v['event']=='mimo_vm_power_acknowledged' for v in r),mode+'-injected-sleep-acknowledged-after-guard')
                        names=[r['event'] for r in rows]
                        assert names.index('mimo_sleep_guard_closed')<names.index('mimo_vm_power_acknowledged')
                        assert not request('existing',key='power')
                        deny(mode+'-injected-sleep-with-core-suspended')
                        os.kill(supervisor_pid,signal.SIGUSR2)
                        wait_event(offsets,lambda r:any(v['event']=='mimo_network_changed' and v['fields'].get('source')=='wake' for v in r),mode+'-injected-wake-observed-with-core-suspended')
                        deny(mode+'-injected-wake-awaits-fresh-core-verification')
                    finally:
                        os.kill(core_pid,signal.SIGCONT);(root/'stopped-core.pid').unlink()
                        os.kill(supervisor_pid,signal.SIGUSR2)
                    client('refresh');wait_for(active(mode),mode+'-fresh-check-releases-sleep-barrier')
                    assert request('https') and not request('ipv6')
                client('mode','global');wait_for(active('global'),'power-tests-restore-Global')
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
            if installed and features:freeze_engine()
            crashes=[(CORE,'core-crash'),(ENGINE,'engine-crash')]
            if installed and features:crashes.append((SUPERVISOR,'supervisor-crash'))
            crash_services(crashes)
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
        (root/'failure-traceback.txt').write_text(traceback.format_exc())
        detail=str(error) or type(error).__name__
        failures.append(detail);print('FAIL:',detail,flush=True)
    finally:
        (root/'capture-phases.json').write_text(json.dumps(phases))
        try:
            if capture and capture.poll() is None:capture.send_signal(signal.SIGINT);capture.wait(timeout=5)
            if worker and worker.poll() is None:worker.terminate();worker.wait(timeout=5)
        finally:
            restore(root);record('production-helper-user-configuration-and-password-restored-in-Direct')
        if watcher:watcher.wait(timeout=5)
        report={'success':success,'passed':completed,'failures':failures,'helperSHA256':build['helperSHA256'],'scope':'Saved user proxy in isolated VM; not release qualification','privateEvidence':True,'focus':'engine hang and supervisor crash' if faults_only else 'saved-proxy native relay' if relay else 'injected power events (not physical sleep)' if power else 'Direct allowlist regression' if direct_only else 'feature audit' if features else 'full'}
        if installed:
            report.update(scope='Exact installed arm64 Release package in mimo-vm, saved real proxy, ordinary user traffic and physical-interface packet capture', runtimeReplaced=False, syntheticPowerEvents=False, packageSHA256=build['packageSHA256'])
            if relay and peer.get('existingService')=='SSH':
                report.update(peerService='Existing SSH service; no peer configuration changed', peerUDPTested=False)
        (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
        print('RESULT:', 'PASS' if success else 'FAIL',flush=True)
    return 0 if success else 1


if __name__=='__main__':
    if len(sys.argv)==4 and sys.argv[1]=='--watchdog':watchdog(Path(sys.argv[2]),int(sys.argv[3]))
    elif len(sys.argv)==1:sys.exit(run())
    elif sys.argv[1:]==['--direct-allowlist']:sys.exit(run(direct_only=True))
    elif sys.argv[1:]==['--features']:sys.exit(run(features=True))
    elif sys.argv[1:]==['--installed-features']:sys.exit(run(features=True,installed=True))
    elif sys.argv[1:]==['--installed-faults']:sys.exit(run(faults_only=True,installed=True))
    elif sys.argv[1:]==['--installed-direct']:sys.exit(run(direct_only=True,installed=True))
    elif len(sys.argv)==3 and sys.argv[1]=='--installed-relay-existing':sys.exit(run(relay=Path(sys.argv[2]),installed=True))
    elif sys.argv[1:]==['--power']:sys.exit(run(power=True))
    elif len(sys.argv)==3 and sys.argv[1]=='--relay':sys.exit(run(relay=Path(sys.argv[2])))
    else:sys.exit('Usage: saved_proxy_test.py [--direct-allowlist | --features | --power | --relay FIXTURE]')
