#!/usr/bin/env python3
"""Installed Release: real native-writer contention, audit deadline and Direct.
No test hooks or runtime replacement. Private settings/events stay in the VM.
"""
import fcntl, hashlib, json, os, re, sys, tempfile, threading, time
from pathlib import Path
from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS, offsets, events, DESTINATION
from upgrade_test import FLAGS, HELPER, RUNTIME, read_settings
from monotonic_uptime import uptime_ms
BASE = Path(__file__).resolve().parent
ANCHOR = 'com.apple/000.mimo'


def main():
    assert os.geteuid() == 0 and command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
    original = read_settings(); flags = json.loads(FLAGS.read_bytes())
    mode = json.loads(original['service.routing'])['mode']; assert mode in ('rule','global')
    build = json.loads((BASE/'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == build['helperSHA256']
    credential = command(BASE/'acceptance-client','credential-digest').stdout.strip()
    os.umask(0o077); root = Path(tempfile.mkdtemp(prefix='mimo-optimistic-audit-',dir='/var/tmp'))
    print('Evidence:',root,flush=True)
    passed=[]; errors=[]; traces=[]; added=False; holder=None
    def client(*args): return command(BASE/'acceptance-client',*args,timeout=75)
    def state(): return json.loads(client('state').stdout)['routing']
    def active(expected=mode, verified=True):
        v=state(); return v['phase']=='active' and v.get('effectiveMode')==expected and (not verified or v.get('backgroundVerification') is not True)
    def wait(test,label,seconds=90):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            if test(): return
            time.sleep(.03)
        raise AssertionError(label+' timed out')
    def record(label): passed.append(label); print('PASS:',label,flush=True)
    def https(allow):
        r=command('/usr/bin/sudo','-n','-u','jay','/usr/bin/curl','--silent','--fail','--noproxy','*','--max-time','8' if allow else '3','--head','https://1.1.1.1/',check=False)
        assert (r.returncode==0)==allow, 'Ordinary HTTPS access disagrees (expected='+str(allow)+', curl status='+str(r.returncode)+')'
    class HoldAfterOpen:
        def __init__(self, baseline):
            self.stop=threading.Event(); self.held=threading.Event(); self.error=None
            self.thread=threading.Thread(target=self.run,args=(baseline,),daemon=True); self.thread.start()
        def run(self, baseline):
            fd=None
            try:
                deadline=time.monotonic()+25
                while not self.stop.is_set() and time.monotonic()<deadline:
                    if any(v['event']=='mimo_traffic_opened' and v['fields'].get('optimistic')=='true' for v in events(LOGS,baseline)):
                        fd=os.open(str(RUNTIME/'native-transport.lock'),os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
                        fcntl.flock(fd,fcntl.LOCK_EX); self.held.set()
                        self.stop.wait(20); return
                    time.sleep(.005)
                if not self.stop.is_set(): raise AssertionError('No optimistic opening observed for lock acquisition')
            except Exception as error: self.error=str(error)
            finally:
                if fd is not None: os.close(fd)
        def release(self): self.stop.set(); self.thread.join(timeout=22); assert not self.thread.is_alive()
    try:
        wait(active,'original qualified baseline'); https(True)
        assert DESTINATION not in command('/usr/sbin/netstat','-rn','-f','inet').stdout
        gateway=re.search(r'gateway: (\S+)',command('/sbin/route','-n','get','default').stdout)[1]
        for direct in (False,True):
            wait(active,'qualified baseline'); time.sleep(.5)
            baseline=offsets(LOGS); holder=HoldAfterOpen(baseline)
            started=uptime_ms()
            command('/sbin/route','-n','add','-host',DESTINATION,gateway);added=True
            wait(lambda:any(v['event']=='mimo_traffic_opened' and v['fields'].get('optimistic')=='true' for v in events(LOGS,baseline)),'optimistic open',30)
            assert holder.held.wait(timeout=1) and holder.error is None
            # The core receives the supervisor approval before its next shared
            # snapshot is observable over XPC; a log event is not that boundary.
            wait(lambda: state().get("backgroundVerification") is True,
                "shared allowed/background-verification state", 1.5)
            assert state()["phase"] == "active"
            if direct:
                client('mode','direct'); wait(lambda:active('direct'),'Direct during pending audit')
                holder.release();holder=None
                command('/sbin/route','-n','delete','-host',DESTINATION);added=False
                time.sleep(4); assert active('direct');https(True)
                rows=events(LOGS,baseline); index=max(i for i,v in enumerate(rows) if v['event']=='mimo_direct_restored')
                assert not any(v['event'] in ('mimo_background_audit_timeout','mimo_gate_closed','mimo_traffic_opened') for v in rows[index+1:])
                record('Direct-cancels-audit-deadline-and-survives-native-cleanup-failure')
                client('mode',mode);wait(active,'original mode after Direct')
            else:
                wait(lambda:any(v['event']=='mimo_background_audit_timeout' for v in events(LOGS,baseline)),'independent audit timeout',8)
                wait(lambda:state()['phase'] in ('blocked','unavailable'),'audit timeout published')
                https(False)
                rows=events(LOGS,baseline)
                assert not any(v['event']=='mimo_audit_deadline_close_failed' for v in rows), 'Independent deadline failed its PF close'
                stages=[v['fields'] for v in rows if v['event']=='mimo_transition_timing']
                opened=next(v for v in stages if v['stage']=='open_gate')
                closed=next(v for v in stages if v['stage']=='audit_timeout_block')
                traces.append(dict(openSeconds=round((int(opened['end_uptime_ms'])-started)/1000,3),
                    timeoutRequestedAfterOpenSeconds=round((int(closed['start_uptime_ms'])-int(opened['end_uptime_ms']))/1000,3),
                    blockCompletedAfterOpenSeconds=round((int(closed['end_uptime_ms'])-int(opened['end_uptime_ms']))/1000,3)))
                record('pending-full-audit-times-out-and-blocks-ordinary-HTTPS')
                holder.release();holder=None
                recovered=offsets(LOGS);wait(active,'automatic full recovery',100)
                recovered_rows=events(LOGS,recovered)
                assert any(v['event']=='mimo_traffic_opened' and v['fields'].get('optimistic')=='false' for v in recovered_rows)
                https(True);record('audit-timeout-requires-full-recovery-before-next-opening')
                command('/sbin/route','-n','delete','-host',DESTINATION);added=False
                wait(active,'route removal verified');time.sleep(5)
            (root/('direct-private-events.json' if direct else 'timeout-private-events.json')).write_text(json.dumps(events(LOGS,baseline)))
        # Change a real runtime field after fresh-IP approval. This bypasses
        # the intended profile without changing saved settings or the probe.
        wait(active,'qualified before runtime drift');baseline=offsets(LOGS)
        changed=threading.Event(); drift_errors=[]
        def drift():
            try:
                deadline=time.monotonic()+20
                while time.monotonic()<deadline:
                    if any(v['event']=='mimo_exit_ip_approved' for v in events(LOGS,baseline)):
                        command('/usr/bin/curl','--silent','--fail','--max-time','2','--unix-socket',
                            '/Library/Application Support/Mimo/Mihomo/controller.sock','-X','PATCH',
                            '-H','Content-Type: application/json','--data','{"mixed-port":7892}','http://localhost/configs')
                        changed.set();return
                    time.sleep(.005)
                raise AssertionError('No approval before runtime drift')
            except Exception as error: drift_errors.append(str(error))
        drift_thread=threading.Thread(target=drift,daemon=True);drift_thread.start()
        command('/sbin/route','-n','add','-host',DESTINATION,gateway);added=True
        wait(lambda:any(v['event']=='mimo_background_audit_failed' for v in events(LOGS,baseline)),'real runtime drift rejected',30)
        drift_thread.join(timeout=3);assert changed.is_set() and not drift_errors
        rows=events(LOGS,baseline);names=[v['event'] for v in rows]
        assert names.index('mimo_traffic_opened')<names.index('mimo_background_audit_failed')
        https(False);record('real-controller-drift-fails-background-audit-after-opening-and-blocks')
        (root/'runtime-drift-private-events.json').write_text(json.dumps(rows))
        recovered=offsets(LOGS);wait(active,'full recovery from runtime drift',100)
        assert any(v['event']=='mimo_traffic_opened' and v['fields'].get('optimistic')=='false' for v in events(LOGS,recovered))
        record('runtime-drift-repaired-by-full-verification-without-manual-refresh')
        command('/sbin/route','-n','delete','-host',DESTINATION);added=False
        wait(active,'verified route removal after runtime drift');time.sleep(5)
        # Actual loss of a grant/permit policy must deny by parent fallback.
        for child in ('permission','open-policy'):
            wait(active,'qualified before removal');baseline=offsets(LOGS)
            command('/sbin/pfctl','-a',ANCHOR+'/'+child,'-F','rules')
            https(False)
            record('missing-'+child+'-denies-public-traffic')
            client('refresh');wait(active,'missing child repaired',100)
        assert configuration_values(read_settings())==configuration_values(original)
    except Exception as error:
        errors.append(type(error).__name__+': '+str(error));print('FAIL:',errors[-1],flush=True)
    finally:
        if holder is not None: holder.release()
        if added: command('/sbin/route','-n','delete','-host',DESTINATION,check=False)
        try:
            if json.loads(read_settings()['service.routing'])['mode']!=mode:client('mode',mode)
            if not active(): client('refresh')
            wait(active,'restored original mode',100)
            assert configuration_values(read_settings())==configuration_values(original)
            assert json.loads(FLAGS.read_bytes())==flags
            assert client('credential-digest').stdout.strip()==credential
            record('original-mode-configuration-credential-and-service-intent-restored')
        except Exception as error: errors.append('Restoration: '+str(error))
        (root/'report.json').write_text(json.dumps(dict(success=not errors,passed=passed,errors=errors,trials=traces,
            packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],
            scope='Actual installed Release in mimo-vm, real host routes and native-writer lock contention, explicit Direct, missing PF grant/policy, ordinary-user HTTPS. No synthetic events or replacement helper.'),indent=2)+'\n')
    return int(bool(errors))
if __name__=='__main__':sys.exit(main())
