#!/usr/bin/env python3
"""Two installed VM cases: warm opening under lifecycle contention, real repair."""
import fcntl,hashlib,json,os,re,subprocess,sys,tempfile,time
from pathlib import Path
from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS,offsets,events,DESTINATION
from upgrade_test import FLAGS,HELPER,RUNTIME,ENGINE,read_settings
from monotonic_uptime import uptime_ms
BASE=Path(__file__).resolve().parent

def main():
    assert os.geteuid()==0 and command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
    build=json.loads((BASE/'release-build.json').read_text());assert hashlib.sha256(HELPER.read_bytes()).hexdigest()==build['helperSHA256']
    original=read_settings();flags=json.loads(FLAGS.read_bytes());mode=json.loads(original['service.routing'])['mode'];assert mode in ('rule','global')
    def client(*args):return command(BASE/'acceptance-client',*args,timeout=50)
    credential=client('credential-digest').stdout.strip();os.umask(0o077)
    root=Path(tempfile.mkdtemp(prefix='mimo-pf-only-',dir='/var/tmp'));print('Evidence:',root,flush=True)
    passed=[];errors=[];trials=[];fd=None;added=False;checker=None
    def active():
        v=json.loads(client('state').stdout)['routing'];return v['phase']=='active' and v.get('effectiveMode')==mode and not v.get('backgroundVerification')
    def wait(fn,label,seconds=60):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            if fn():return
            time.sleep(.03)
        raise AssertionError(label+' timed out')
    def record(label):passed.append(label);print('PASS:',label,flush=True)
    def route(add):command('/sbin/route','-n','add' if add else 'delete','-host',DESTINATION,*([gateway] if add else []))
    try:
        wait(active,'initial verified mode');assert DESTINATION not in command('/usr/sbin/netstat','-rn','-f','inet').stdout
        gateway=re.search(r'gateway: (\S+)',command('/sbin/route','-n','get','default').stdout)[1]
        fd=os.open(str(RUNTIME/'firewall.lock'),os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600);fcntl.flock(fd,fcntl.LOCK_EX)
        baseline=offsets(LOGS);started=uptime_ms();route(True);added=True
        wait(lambda:any(v['event']=='mimo_background_audit_passed' for v in events(LOGS,baseline)) and active(),'opening and audit while lifecycle lock stays held',9)
        observed=(uptime_ms()-started)/1000;rows=events(LOGS,baseline);stages=[v['fields'] for v in rows if v['event']=='mimo_transition_timing']
        assert not any(v['stage']=='grant_lifecycle_lock' for v in stages)
        assert any(v['event']=='mimo_traffic_opened' and v['fields'].get('optimistic')=='true' for v in rows)
        opening=next(v for v in stages if v['stage']=='open_gate');audit=next(v for v in stages if v['stage']=='background_audit')
        assert sum(v['stage']=='barrier_and_confirmation' for v in stages)==1
        trials.append(dict(event='route-added-with-lifecycle-lock-held',eventRequestedUptimeMS=started,firewallOpenSeconds=round((int(opening['end_uptime_ms'])-started)/1000,3),verifiedSeconds=round((int(audit['end_uptime_ms'])-started)/1000,3),verifiedObservedSeconds=round(observed,3),stages=stages))
        (root/'contention-private-events.json').write_text(json.dumps(rows))
        record('optimistic-opening-and-full-audit-finish-while-lifecycle-lock-is-held')
        os.close(fd);fd=None;removed=offsets(LOGS);route(False);added=False
        wait(lambda:any(v['event']=='mimo_traffic_opened' for v in events(LOGS,removed)) and active(),'route removal recovery')
        # Actual launchd disabled override; running engine is kept until the
        # independent checker evaluates the real job and repairs the override.
        marker=RUNTIME/'infrastructure-repair';assert not marker.exists()
        baseline=offsets(LOGS)
        command('/bin/launchctl','disable','system/'+ENGINE)
        output=open(root/'repair-private-output.txt','w')
        checker=subprocess.Popen(['/usr/bin/perl','/Library/Application Support/Mimo/Guard/pf-guard.pl','--check'],stdout=output,stderr=subprocess.STDOUT)
        wait(marker.exists,'independent job repair marker',20);marked=uptime_ms();route(True);added=True
        cleared=None
        while checker.poll() is None:
            if not marker.exists() and cleared is None:cleared=uptime_ms()
            time.sleep(.003)
        output.close();assert checker.returncode==0;checker=None
        assert not marker.exists();cleared=cleared or uptime_ms()
        wait(lambda:any(v['event']=='mimo_traffic_opened' for v in events(LOGS,baseline)) and active(),'fresh recovery after real launchd repair')
        rows=events(LOGS,baseline);spans=[v['fields'] for v in rows if v['event']=='mimo_transition_timing']
        assert not any(marked<=int(v['end_uptime_ms'])<cleared-20 for v in spans if v['stage']=='open_gate'), 'Opened while infrastructure repair marker was present'
        assert any(v['event']=='mimo_traffic_opened' and v['fields'].get('optimistic')=='false' for v in rows)
        assert not re.search(r'"'+re.escape(ENGINE)+r'"\s*=>\s*(?:true|disabled)\b',command('/bin/launchctl','print-disabled','system').stdout)
        command('/usr/bin/sudo','-n','-u','jay','/usr/bin/curl','--silent','--fail','--noproxy','*','--max-time','8','--head','https://1.1.1.1/')
        (root/'repair-private-events.json').write_text(json.dumps(rows))
        record('actual-launchd-repair-inhibits-opening-and-recovers-through-full-verification')
    except Exception as error:errors.append(type(error).__name__+': '+str(error));print('FAIL:',errors[-1],flush=True)
    finally:
        if fd is not None:os.close(fd)
        if checker is not None:
            try:checker.wait(timeout=25)
            except subprocess.TimeoutExpired:checker.terminate();checker.wait(timeout=5)
        command('/bin/launchctl','enable','system/'+ENGINE,check=False)
        if added:route(False)
        try:
            client('refresh');wait(active,'restored mode')
            assert configuration_values(read_settings())==configuration_values(original)
            assert json.loads(FLAGS.read_bytes())==flags
            assert client('credential-digest').stdout.strip()==credential
            assert not (RUNTIME/'infrastructure-repair').exists()
            record('original-mode-configuration-credential-and-service-intent-restored')
        except Exception as error:errors.append('Restoration: '+str(error))
        (root/'report.json').write_text(json.dumps(dict(success=not errors,passed=passed,errors=errors,trials=trials,packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],scope='Two focused installed Release cases in mimo-vm: real cross-process lock contention and launchd override repair; no replacement helper, synthetic events or broad suite.'),indent=2)+'\n')
    return int(bool(errors))
if __name__=='__main__':sys.exit(main())
