#!/usr/bin/env python3
"""Read-only lifecycle assertions around real Homebrew commands in mimo-vm.

Brew itself runs as its existing owner jay. No Homebrew permissions, receipt
flags, system settings or user proxy credentials are edited by this checker.
"""
import hashlib,json,os
from pathlib import Path
import plistlib,shutil,subprocess,sys,tempfile
from installed_acceptance_test import command
from release_final_state import configuration_values
from upgrade_test import HELPER,STORAGE,FLAGS,RUNTIME,read_settings

BASE=Path(__file__).resolve().parent
APP=Path('/Applications/Mimo.app')
LABELS=('com.mimo.core','com.mimo.supervisor','com.mimo.mihomo','com.mimo.pf-boot','com.mimo.infrastructure')


def run():
    assert os.geteuid()==0 and command('/usr/sbin/sysctl','-n','hw.model').stdout.startswith('VirtualMac')
    op=sys.argv[1]
    if op=='prepare':
        assert json.loads(read_settings()['service.routing'])['mode']=='direct'
        root=Path(tempfile.mkdtemp(prefix='mimo-release-brew-',dir='/var/tmp'));root.chmod(0o700)
        for src,name in ((STORAGE,'state.plist'),(FLAGS,'services.json'),(RUNTIME/'ipv6-original.plist','ipv6-original.plist')):shutil.copyfile(src,root/name)
        (root/'credential.digest').write_text(command(BASE/'acceptance-client','credential-digest').stdout.strip())
        (root/'checks.json').write_text('[]')
        (BASE/'brew-evidence-path').write_text(str(root)+'\n')
        print('Evidence:',root,flush=True);return
    root=Path((BASE/'brew-evidence-path').read_text().strip())
    assert root.parent==Path('/var/tmp') and root.stat().st_uid==0 and root.stat().st_mode & 0o077==0
    passed=json.loads((root/'checks.json').read_text())
    def record(name):passed.append(name);print('PASS:',name,flush=True)
    original = plistlib.loads((root/'state.plist').read_bytes())
    current = read_settings()
    assert configuration_values(current) == configuration_values(original)
    assert current['service.revision'] >= original['service.revision']
    assert command(BASE/'acceptance-client','credential-digest').stdout.strip()==(root/'credential.digest').read_text()
    record(op+'-retains-saved-configuration-and-Keychain-password')
    if op=='uninstalled':
        assert not APP.exists() and not HELPER.exists() and not (RUNTIME/'mihomo').exists()
        assert not Path('/Library/PrivilegedHelperTools/mimo-manage').exists()
        assert not Path('/Library/Application Support/Mimo/Mihomo/blocking.yaml').exists()
        for label in LABELS:assert command('/bin/launchctl','print','system/'+label,check=False).returncode==113,label
        assert '# BEGIN MIMO BOOT GUARD' not in Path('/etc/pf.conf').read_text()
        assert not Path('/etc/pf.anchors/com.mimo.boot').exists()
        assert not command('/sbin/pfctl','-a','com.apple/000.mimo','-sr').stdout.strip()
        record('brew-uninstall-removes-app-runtime-jobs-and-persistent-PF-policy')
        original=plistlib.loads((root/'ipv6-original.plist').read_bytes())
        network=plistlib.loads(Path('/Library/Preferences/SystemConfiguration/preferences.plist').read_bytes())['NetworkServices']
        for key,enabled in original.items():
            if key in network and 'IPv6' in network[key]:assert (not bool(network[key]['IPv6'].get('__INACTIVE__',0)))==enabled
        record('brew-uninstall-restores-original-IPv6-enabled-flags')
        command('/usr/bin/sudo','-n','-u','jay','/usr/bin/curl','--fail','--silent','--noproxy','*','--max-time','15','--head','https://one.one.one.one/')
        record('brew-uninstall-restores-ordinary-user-HTTPS')
    elif op=='installed':
        build=json.loads((BASE/'release-build.json').read_text())
        assert hashlib.sha256(HELPER.read_bytes()).hexdigest()==build['helperSHA256']
        assert HELPER.read_bytes()==(APP/'Contents/MacOS/mimo-core').read_bytes()
        command('/usr/bin/codesign','--verify','--deep','--strict',APP)
        s=json.loads(command(BASE/'installation-check').stdout)
        assert s.get('phase')=='active' and s.get('effectiveMode')=='direct'
        assert all(command('/bin/launchctl','print','system/'+v,check=False).returncode==0 for v in LABELS)
        assert 'IPv6: Off' in command('/usr/sbin/networksetup','-getinfo','Ethernet').stdout
        assert json.loads(FLAGS.read_bytes())==json.loads((root/'services.json').read_bytes())
        record('brew-installed-Release-helper-signature-Direct-and-service-intent-confirmed')
    else:raise ValueError(op)
    (root/'checks.json').write_text(json.dumps(passed,indent=2)+'\n')


if __name__=='__main__':run()
