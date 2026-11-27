#!/usr/bin/env python3
"""Isolated real GUI intent/state controls; only the external RPC is replaced."""
import argparse,hashlib,json,os,subprocess,sys,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('output',type=Path);p.add_argument('--source-root',type=Path,default=ROOT);p.add_argument('--only',action='append',default=[]);a=p.parse_args()
out=a.output.resolve();source=a.source_root.resolve();assert out.is_relative_to(ROOT/'.build') and not out.exists();out.mkdir(parents=True,mode=0o700)
files=[p for folder in ('MimoShared','MimoCore','MimoApp') for p in sorted((source/'Sources'/folder).glob('*.swift'))]
identity={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files};generated=[]
for file in files:
 value=file.read_text();target=out/file.name
 if file.name=='PublicIPMonitor.swift':
  old='try await DaemonRPC.call(request, timeout: 75, serviceLabel: serviceLabel)'
  assert value.count(old)==1;value=value.replace(old,'try await RapidTransport.shared.call(request)')
  value+='\n'+(HERE/'monitor-access.swift').read_text().replace('MODE_GATE','canChangeModes' if 'var canChangeModes:' in value else 'canChangeSharedSettings')
 target.write_text(value);generated.append(str(target))
identity.update({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.glob('*.swift')})
(out/'source-identity.json').write_text(json.dumps(identity,indent=2)+'\n')
c=subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-D','MIMO_TEST_HOST',*generated,str(HERE/'cases.swift'),'-o',str(out/'tests')],cwd=ROOT,capture_output=True,text=True);(out/'compile.log').write_text(c.stdout+c.stderr)
if c.returncode:print((c.stdout+c.stderr)[-6000:]);sys.exit(c.returncode)
env=dict(os.environ,MIMO_TEST_APP_GROUP='group.com.mimo.tests.'+uuid.uuid4().hex,MIMO_LOG_DIRECTORY=str(out/'logs'))
r=subprocess.run([str(out/'tests'),str(out),*a.only],cwd=ROOT,env=env,capture_output=True,text=True,timeout=90);(out/'test.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);sys.exit(r.returncode)
