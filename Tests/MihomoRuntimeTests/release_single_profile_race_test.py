#!/usr/bin/env python3
"""Real in-flight route/Direct changes against the installed VM Release."""
import hashlib,json,os,re,sys,tempfile,time
from pathlib import Path
from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS,offsets,events,DESTINATION
from upgrade_test import FLAGS,HELPER,read_settings
BASE=Path(__file__).resolve().parent

def main():
    assert os.geteuid()==0 and command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
    original=read_settings();mode=json.loads(original['service.routing'])['mode'];assert mode in ('rule','global')
    flags=FLAGS.read_bytes();credential=command(BASE/'acceptance-client','credential-digest').stdout.strip()
    build=json.loads((BASE/'release-build.json').read_text());assert hashlib.sha256(HELPER.read_bytes()).hexdigest()==build['helperSHA256']
    os.umask(0o077);root=Path(tempfile.mkdtemp(prefix='mimo-single-profile-race-',dir='/var/tmp'));print('Evidence:',root,flush=True)
    passed=[];errors=[];added=False
    def client(*args):return command(BASE/'acceptance-client',*args,timeout=70)
    def active(expected):
        s=json.loads(client('state').stdout)['routing'];return s['phase']=='active' and s.get('effectiveMode')==expected
    def wait(predicate,label):
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            if predicate():return
            time.sleep(.1)
        raise AssertionError(label+' timed out')
    def record(label):passed.append(label);print('PASS:',label,flush=True)
    def https():command('/usr/bin/sudo','-n','-u','jay','/usr/bin/curl','--silent','--fail','--noproxy','*','--max-time','8','--head','https://1.1.1.1/')
    try:
        wait(lambda:active(mode),'original mode')
        assert DESTINATION not in command('/usr/sbin/netstat','-rn','-f','inet').stdout
        gateway=re.search(r'gateway: (\S+)',command('/sbin/route','-n','get','default').stdout)[1]
        baseline=offsets(LOGS)
        command('/sbin/route','-n','add','-host',DESTINATION,gateway);added=True
        wait(lambda:any(v['event']=='mimo_parallel_preparation_started' for v in events(LOGS,baseline)),'parallel preparation')
        before_direct=events(LOGS,baseline)
        assert not any(v['event']=='mimo_private_probe_ready' for v in before_direct), 'Early Direct test missed the preparation window'
        client('mode','direct');wait(lambda:active('direct'),'Direct during blocking')
        command('/sbin/route','-n','delete','-host',DESTINATION);added=False
        time.sleep(4);assert active('direct');https()
        rows=events(LOGS,baseline)
        supervisor=next(v['file'] for v in rows if v['event']=='mimo_direct_restored')
        ordered=[v for v in rows if v['file']==supervisor];start=max(i for i,v in enumerate(ordered) if v['event']=='mimo_direct_restored')
        assert not any(v['event'] in ('mimo_gate_closed','mimo_traffic_opened') for v in ordered[start+1:])
        record('Direct-during-parallel-preparation-cancels-late-work-and-keeps-IPv4-open')
        client('mode',mode);wait(lambda:active(mode),'protected mode after early Direct')
        for direct in (False,True):
            baseline=offsets(LOGS)
            command('/sbin/route','-n','add','-host',DESTINATION,gateway);added=True
            wait(lambda:any(v['event']=='mimo_private_probe_ready' for v in events(LOGS,baseline)),'first private probe')
            if direct:
                client('mode','direct');wait(lambda:active('direct'),'Direct transition')
            command('/sbin/route','-n','delete','-host',DESTINATION);added=False
            if direct:
                time.sleep(4);assert active('direct');https()
                rows=events(LOGS,baseline)
                supervisor=next(v['file'] for v in rows if v['event']=='mimo_direct_restored')
                ordered=[v for v in rows if v['file']==supervisor];start=max(i for i,v in enumerate(ordered) if v['event']=='mimo_direct_restored')
                assert not any(v['event'] in ('mimo_gate_closed','mimo_traffic_opened') for v in ordered[start+1:])
                record('Direct-during-private-probe-rejects-late-protected-work-and-keeps-IPv4-open')
            else:
                wait(lambda:sum(v['event']=='mimo_network_changed' and v['fields'].get('source')=='route' for v in events(LOGS,baseline))>=2 and active(mode),'superseding route recovery')
                rows=events(LOGS,baseline);supervisor=next(v['file'] for v in rows if v['event']=='mimo_network_changed')
                ordered=[v for v in rows if v['file']==supervisor];start=max(i for i,v in enumerate(ordered) if v['event']=='mimo_network_changed' and v['fields'].get('source')=='route')
                tail=ordered[start+1:];names=[v['event'] for v in tail]
                assert names.index('mimo_private_probe_ready')<names.index('mimo_traffic_opened')
                attempt=next(v['fields']['attempt'] for v in tail if v['event']=='mimo_private_probe_ready')
                for kind in ('mimo_readiness_passed','mimo_exit_ip_approved'):
                    assert any(v['event']==kind and v['fields']['attempt']==attempt for v in tail[:names.index('mimo_traffic_opened')])
                https();record('route-change-during-private-probe-requires-new-IP-and-readiness-before-opening')
            (root/('direct-private-events.json' if direct else 'route-private-events.json')).write_text(json.dumps(rows))
    except Exception as error:errors.append(type(error).__name__+': '+str(error));print('FAIL:',errors[-1],flush=True)
    finally:
        if added:command('/sbin/route','-n','delete','-host',DESTINATION,check=False)
        try:
            if json.loads(read_settings()['service.routing'])['mode']!=mode:client('mode',mode)
            if not active(mode):client('refresh')
            wait(lambda:active(mode),'original mode restored')
            assert configuration_values(read_settings())==configuration_values(original) and json.loads(FLAGS.read_bytes())==json.loads(flags)
            assert client('credential-digest').stdout.strip()==credential, 'Credential changed'
            record('original-mode-settings-password-and-service-intent-restored')
        except Exception as error:errors.append('Restoration: '+str(error))
        (root/'report.json').write_text(json.dumps(dict(success=not errors,passed=passed,errors=errors,packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],scope='Normal installed Release in mimo-vm; actual kernel route and mode changes during private probing, ordinary-user HTTPS and exact restoration. No synthetic events.'),indent=2)+'\n')
    return int(bool(errors))
if __name__=='__main__':sys.exit(main())
