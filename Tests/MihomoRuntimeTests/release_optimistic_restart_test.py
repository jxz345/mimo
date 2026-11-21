#!/usr/bin/env python3
"""A real engine restart replaces PF independently of the supervisor's cache."""
import hashlib,json,os,sys,tempfile,time
from pathlib import Path
from installed_acceptance_test import command
from release_final_state import configuration_values
from release_network_progress_test import LOGS,offsets,events
from upgrade_test import FLAGS,HELPER,read_settings
BASE=Path(__file__).resolve().parent

def main():
    assert os.geteuid()==0 and command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
    build=json.loads((BASE/'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest()==build['helperSHA256']
    original=read_settings();flags=json.loads(FLAGS.read_bytes());mode=json.loads(original['service.routing'])['mode']
    def client(*args):return command(BASE/'acceptance-client',*args,timeout=75)
    credential=client('credential-digest').stdout.strip()
    os.umask(0o077);root=Path(tempfile.mkdtemp(prefix='mimo-optimistic-restart-',dir='/var/tmp'));print('Evidence:',root,flush=True)
    passed=[];errors=[]
    def wait(expected):
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            v=json.loads(client('state').stdout)['routing']
            if v['phase']=='active' and v.get('effectiveMode')==expected and not v.get('backgroundVerification'):return
            time.sleep(.2)
        raise AssertionError('Engine restart recovery timed out')
    def record(label):passed.append(label);print('PASS:',label,flush=True)
    try:
        client('mode','global');wait('global');baseline=offsets(LOGS)
        command(BASE/'installation-check','mihomo','restart');client('refresh');wait('global')
        rows=events(LOGS,baseline);(root/'private-events.json').write_text(json.dumps(rows))
        assert any(v['event']=='mimo_final_profile_loaded' for v in rows)
        assert any(v['event']=='mimo_traffic_opened' and v['fields'].get('optimistic')=='false' for v in rows)
        parent=command('/sbin/pfctl','-a','com.apple/000.mimo','-sr').stdout
        assert 'anchor "permission"' in parent
        record('engine-startup-parent-invalidates-cached-policy-and-requires-full-verification')
        command('/usr/bin/sudo','-n','-u','jay','/usr/bin/curl','--silent','--fail','--noproxy','*','--max-time','8','--head','https://1.1.1.1/')
        record('Global-ordinary-HTTPS-recovers-after-real-engine-Restart')
    except Exception as error:errors.append(type(error).__name__+': '+str(error));print('FAIL:',errors[-1],flush=True)
    finally:
        try:
            if json.loads(read_settings()['service.routing'])['mode']!=mode:client('mode',mode)
            wait(mode)
            assert configuration_values(read_settings())==configuration_values(original)
            assert json.loads(FLAGS.read_bytes())==flags
            assert client('credential-digest').stdout.strip()==credential
            record('original-mode-settings-credential-and-service-intent-restored')
        except Exception as error:errors.append('Restoration: '+str(error))
        (root/'report.json').write_text(json.dumps(dict(success=not errors,passed=passed,errors=errors,packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],scope='Normal installed arm64 Release in mimo-vm, real saved proxy, actual Global engine Restart and ordinary-user HTTPS; no runtime substitution.'),indent=2)+'\n')
    return int(bool(errors))
if __name__=='__main__':sys.exit(main())
