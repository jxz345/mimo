#!/usr/bin/env python3
"""Actual installed PF readback mismatch and route event in mimo-vm."""
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
    flags=json.loads(FLAGS.read_bytes());credential=command(BASE/'acceptance-client','credential-digest').stdout.strip()
    build=json.loads((BASE/'release-build.json').read_text());assert hashlib.sha256(HELPER.read_bytes()).hexdigest()==build['helperSHA256']
    expected=Path('/Library/Application Support/Mimo/Runtime/guard.expected')
    saved=expected.read_bytes();modified=saved+b'\n# Deliberate VM acceptance readback mismatch\n'
    os.umask(0o077);root=Path(tempfile.mkdtemp(prefix='mimo-concurrent-gate-',dir='/var/tmp'));print('Evidence:',root,flush=True)
    passed=[];errors=[];added=False
    def client(*args):return command(BASE/'acceptance-client',*args,timeout=70)
    def active():
        s=json.loads(client('state').stdout)['routing'];return s['phase']=='active' and s.get('effectiveMode')==mode
    def wait(predicate,label):
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            if predicate():return
            time.sleep(.1)
        raise AssertionError(label+' timed out')
    try:
        assert active() and DESTINATION not in command('/usr/sbin/netstat','-rn','-f','inet').stdout
        gateway=re.search(r'gateway: (\S+)',command('/sbin/route','-n','get','default').stdout)[1]
        baseline=offsets(LOGS)
        expected.write_bytes(modified)
        command('/sbin/route','-n','add','-host',DESTINATION,gateway);added=True
        wait(lambda:any(v['event']=='mimo_traffic_opened' for v in events(LOGS,baseline)) and active(),'fallback and fresh verification')
        rows=events(LOGS,baseline);(root/'private-events.json').write_text(json.dumps(rows))
        supervisor=next(v['file'] for v in rows if v['event']=='mimo_traffic_opened')
        ordered=[v for v in rows if v['file']==supervisor];names=[v['event'] for v in ordered]
        fallback=next(i for i,v in enumerate(ordered) if v['event']=='mimo_pf_policy_installed' and v['fields'].get('policy')=='startup')
        probe=names.index('mimo_private_probe_ready');opened=names.index('mimo_traffic_opened')
        assert fallback<probe<opened
        assert names.index('mimo_readiness_passed')<opened and names.index('mimo_exit_ip_approved')<opened
        assert expected.read_bytes()!=modified
        command('/usr/bin/sudo','-n','-u','jay','/usr/bin/curl','--silent','--fail','--noproxy','*','--max-time','8','--head','https://1.1.1.1/')
        passed.append('PF-readback-mismatch-takes-full-blocking-fallback-and-fresh-verification-before-opening')
        print('PASS:',passed[-1],flush=True)
    except Exception as error:errors.append(type(error).__name__+': '+str(error));print('FAIL:',errors[-1],flush=True)
    finally:
        if expected.read_bytes()==modified:expected.write_bytes(saved)
        if added:command('/sbin/route','-n','delete','-host',DESTINATION,check=False)
        try:
            client('refresh');wait(active,'original protected access')
            assert configuration_values(read_settings())==configuration_values(original)
            assert json.loads(FLAGS.read_bytes())==flags
            assert client('credential-digest').stdout.strip()==credential
            passed.append('original-Rule-settings-credential-and-service-intent-restored');print('PASS:',passed[-1],flush=True)
        except Exception as error:errors.append('Restoration: '+str(error))
        (root/'report.json').write_text(json.dumps(dict(success=not errors,passed=passed,errors=errors,packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],scope='Normal installed Release in mimo-vm. Deliberately mismatched root-owned PF readback plus actual route change; no live PF rules were weakened. Saved settings retained.'),indent=2)+'\n')
    return int(bool(errors))
if __name__=='__main__':sys.exit(main())
