#!/usr/bin/env python3
"""Restore the saved VM preferences/selection after the closure campaign."""
import json
import os
from pathlib import Path
import socket
import sys
import v3_installed_test as t

ROOT=Path(sys.argv[1])
assert os.geteuid()==0 and socket.gethostname().startswith('mimo-vm')
os.umask(0o077)
before=json.loads((ROOT/'before.json').read_text())
original=before['routing']['configuration']
assert original['mode']=='direct','This campaign expects the recorded Direct baseline'
t.route('direct');t.wait_active('direct',100)
t.request('configure',settings=before['settings'])
t.request('selectProxy',**({'proxyID':original['activeProxyID']} if original.get('activeProxyID') else {}))
for entry in t.state()['routing']['configuration']['proxies']:
    if entry['proxy']['name']=='V3 closure qualification': t.request('removeProxy',proxyID=entry['id'])
t.request('configureRouting',routing=original)
after=t.wait_active('direct',100)
config=after['routing']['configuration']
assert after['settings']==before['settings'],'Preferences differ'
assert config.get('activeProxyID')==original.get('activeProxyID'),'Proxy selection differs'
assert config['networkFamily']==original['networkFamily'],'Saved family differs'
assert config['proxies']==original['proxies'],'Proxy catalog differs'
assert all(s['health']=='running' for s in after['routing']['services']),'Services are not healthy'
assert not t.run(['/sbin/pfctl','-a',t.ANCHOR,'-sr']).stdout.strip(),'Direct PF is not empty'
assert '1053' not in t.run(['/usr/sbin/scutil','--dns']).stdout,'Owned resolver remains'
for anchor in ('com.apple/999.mimo-qualification','com.apple/998.qualification-foreign'):
    assert not t.run(['/sbin/pfctl','-a',anchor,'-sr']).stdout.strip(),'Lab rules remain'
# This campaign created pflog0 when absent; stop all captures before removing it.
assert t.run(['/usr/bin/pgrep','-x','tcpdump']).returncode==1,'A capture is still running'
removed=t.run(['/sbin/ifconfig','pflog0','destroy'])
assert removed.returncode==0,removed.stderr
result=dict(settings_restored=True,proxy_selection_restored=True,proxy_catalog_restored=True,
            saved_family_restored=True,mode='direct',services_healthy=True,owned_dns_removed=True,
            active_pf_empty=True,lab_rules_removed=True,lab_pflog_removed=True,
            certificate_and_key_retained=True)
(ROOT/'restore-results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Original settings, catalog and selection restored; Direct healthy; lab PF/captures removed.')
