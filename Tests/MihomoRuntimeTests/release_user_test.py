#!/usr/bin/env python3
"""Unprivileged reads and authorization checks for the installed Release in VM.

Runs real public XPC clients as both existing administrators and a temporary
standard account with login disabled. Removes only that test account afterward.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import subprocess
import tempfile
import time

BASE=Path(__file__).resolve().parent
CORE='com.example.exitipmonitor.daemon'
SUPERVISOR='com.example.exitipmonitor.supervisor'
ENGINE='com.example.exitipmonitor.mihomo'


def run():
    assert os.geteuid()==0
    assert subprocess.check_output(['/usr/sbin/sysctl','-n','hw.model']).startswith(b'VirtualMac')
    root=Path(tempfile.mkdtemp(prefix='mimo-release-user-',dir='/var/tmp'));root.chmod(0o700)
    completed=[]
    def command(*args,check=True):
        return subprocess.run([str(x) for x in args],text=True,capture_output=True,timeout=35,check=check)
    def record(name):
        completed.append(name);print('PASS:',name,flush=True)
    def state(user,*args,check=True):
        return command('/usr/bin/sudo','-n','-u',user,BASE/'installation-check',*args,check=check)
    def pid(label):
        text=command('/bin/launchctl','print','system/'+label).stdout
        return next(line.strip() for line in text.splitlines() if line.strip().startswith('pid = '))
    before={k:pid(k) for k in (CORE,SUPERVISOR,ENGINE)}
    values=[]
    # A real standard UID exercises kernel XPC peer credentials, without opening
    # login access or changing membership of either existing account.
    standard='_mimoaccept_'+root.name.rsplit('-',1)[-1]
    account='/Users/'+standard
    used={entry.pw_uid for entry in pwd.getpwall()}
    uid=next(value for value in range(600,1000) if value not in used)
    created=False
    try:
        command('/usr/bin/dscl','.', '-read',account,check=False)
        assert command('/usr/bin/dscl','.', '-read',account,check=False).returncode!=0
        command('/usr/bin/dscl','.', '-create',account);created=True
        for key,value in [('UniqueID',str(uid)),('PrimaryGroupID','20'),('UserShell','/usr/bin/false'),
                          ('NFSHomeDirectory','/var/empty'),('IsHidden','1'),('AuthenticationAuthority',';DisabledUser;')]:
            command('/usr/bin/dscl','.', '-create',account,key,value)
        assert 'admin' not in command('/usr/bin/id','-Gn',standard).stdout.split()
        for user in ('jay','mimotest',standard):
            response=state(user,'core-state');v=json.loads(response.stdout)
            (root/(('standard' if user==standard else user)+'-state.json')).write_text(response.stdout);values.append(v)
            assert v['routing']['effectiveMode']=='direct'
            record(('standard' if user==standard else user)+'-unprivileged-client-reads-shared-Direct-state')
            # Both accounts are administrators, but group membership alone must not
            # substitute for the explicit Authorization Services right.
            denied=state(user,'core','stop',check=False)
            (root/(('standard' if user==standard else user)+'-unauthorized-command.log')).write_text(denied.stdout+denied.stderr)
            assert denied.returncode!=0 and 'unauthorized' in (denied.stdout+denied.stderr).lower()
            record(('standard' if user==standard else user)+'-unauthenticated-service-change-denied')
        assert all(v['settings']==values[0]['settings'] and v['revision']==values[0]['revision'] for v in values)
        assert all(v['routing']['configuration']==values[0]['routing']['configuration'] for v in values)
        assert before=={k:pid(k) for k in before}
        record('all-three-accounts-share-configuration-and-one-machine-service-set')
    finally:
        if created:
            command('/usr/bin/dscl','.', '-delete',account)
            assert command('/usr/bin/dscl','.', '-read',account,check=False).returncode!=0
            record('temporary-standard-account-removed')
    manifest=json.loads((BASE/'release-build.json').read_text())
    assert hashlib.sha256(Path('/Library/PrivilegedHelperTools/mimo-core').read_bytes()).hexdigest()==manifest['helperSHA256']
    (root/'report.json').write_text(json.dumps(dict(success=True,passed=completed,helperSHA256=manifest['helperSHA256'],
        scope='Actual unprivileged processes for two existing admin accounts and one temporary standard account. Does not claim GUI fast-user switching.'),indent=2)+'\n')
    print('Evidence:',root,flush=True)


if __name__=='__main__':run()
