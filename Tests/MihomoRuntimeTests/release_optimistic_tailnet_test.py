#!/usr/bin/env python3
"""Use an existing online peer from the VM; never configure or run commands on it."""
import hashlib, json, os, re, sys, tempfile, time
from pathlib import Path
from installed_acceptance_test import command
from release_final_state import configuration_values
from upgrade_test import FLAGS, HELPER, read_settings
BASE = Path(__file__).resolve().parent
CLI = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'

def main():
    assert os.geteuid() == 0 and command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
    build=json.loads((BASE/'release-build.json').read_text())
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest()==build['helperSHA256']
    original=read_settings(); flags=json.loads(FLAGS.read_bytes())
    mode=json.loads(original['service.routing'])['mode']; assert mode in ('rule','global')
    def client(*args): return command(BASE/'acceptance-client',*args,timeout=75)
    credential=client('credential-digest').stdout.strip()
    os.umask(0o077); root=Path(tempfile.mkdtemp(prefix='mimo-optimistic-tailnet-',dir='/var/tmp'))
    print('Evidence:',root,flush=True)
    passed=[];errors=[]
    def verified(expected):
        deadline=time.monotonic()+100
        while time.monotonic()<deadline:
            v=json.loads(client('state').stdout)['routing']
            if v['phase']=='active' and v.get('effectiveMode')==expected and not v.get('backgroundVerification'): return
            time.sleep(.2)
        raise AssertionError('Protected verification timed out')
    def record(label): passed.append(label);print('PASS:',label,flush=True)
    try:
        status=json.loads(command(CLI,'status','--json').stdout)
        assert status.get('BackendState')=='Running','Native Tailscale is not running'
        peers=[p for p in status.get('Peer',{}).values() if p.get('Online')]
        addresses=[ip for p in peers for ip in p.get('TailscaleIPs',[]) if ':' not in ip]
        assert addresses,'No existing online IPv4 peer'
        peer=addresses[0]
        for selected in ('rule','global'):
            client('mode',selected);verified(selected)
            result=command(CLI,'ping','--tsmp','--c','3','--timeout','5s',peer,check=False,timeout=20)
            (root/(selected+'-private-tsmp.txt')).write_text(result.stdout+result.stderr)
            assert result.returncode==0,'Existing-peer TSMP failed in '+selected
            result=command('/usr/bin/sudo','-n','-u','jay','/sbin/ping','-c','3','-W','2000',peer,check=False,timeout=15)
            (root/(selected+'-private-ping.txt')).write_text(result.stdout+result.stderr)
            assert result.returncode==0,'Ordinary-user existing-peer IPv4 ping failed in '+selected
            record(selected+'-existing-peer-native-and-ordinary-IPv4-reachable')
    except Exception as error:
        (root/'private-failure.txt').write_text(str(error))
        errors.append(type(error).__name__+': '+re.sub(r'\b(?:\d{1,3}\.){3}\d{1,3}\b','[IPv4]',str(error)));print('FAIL:',errors[-1],flush=True)
    finally:
        try:
            if json.loads(read_settings()['service.routing'])['mode']!=mode:client('mode',mode)
            verified(mode)
            assert configuration_values(read_settings())==configuration_values(original)
            assert json.loads(FLAGS.read_bytes())==flags
            assert client('credential-digest').stdout.strip()==credential
            record('original-mode-settings-credential-and-service-intent-restored')
        except Exception as error:errors.append('Restoration: '+str(error))
        (root/'report.json').write_text(json.dumps(dict(success=not errors,passed=passed,errors=errors,
            packageSHA256=build['packageSHA256'],helperSHA256=build['helperSHA256'],
            scope='mimo-vm originates native TSMP and ordinary-user IPv4 ICMP to one existing online peer. No Delta/peer settings or processes changed. Not forced-DERP reconnect or UDP echo qualification.'),indent=2)+'\n')
    return int(bool(errors))
if __name__=='__main__':sys.exit(main())
