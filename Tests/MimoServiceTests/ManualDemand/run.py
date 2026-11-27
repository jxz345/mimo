#!/usr/bin/env python3
"""Manual-demand ownership controls. No VM, network or PF calls."""
import argparse,hashlib,json,os,subprocess,sys,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('output',type=Path);p.add_argument('--source-root',type=Path,default=ROOT);p.add_argument('--only',action='append',default=[]);a=p.parse_args()
out=a.output.resolve();source_root=a.source_root.resolve();assert out.is_relative_to(ROOT/'.build') and not out.exists();out.mkdir(parents=True,mode=0o700)
sources=[p for folder in ('MimoShared','MimoCore','MimoService') for p in sorted((source_root/'Sources'/folder).glob('*.swift'))];assert len(sources)>=80
identities={str(p.relative_to(source_root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
generated=[]
for source in sources:
 target=out/source.name;value=source.read_text()
 target.write_text(value);generated.append(target)
identities.update({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (HERE/'cases.swift',)})
(out/'source-identity.json').write_text(json.dumps(identities,indent=2)+'\n')
command=['xcrun','swiftc','-swift-version','6','-parse-as-library','-D','MIMO_SERVICE_TEST',*map(str,generated),str(HERE/'cases.swift'),'-o',str(out/'manual-demand-tests')]
c=subprocess.run(command,cwd=ROOT,capture_output=True,text=True);(out/'compile.log').write_text(c.stdout+c.stderr)
if c.returncode:print((c.stdout+c.stderr)[-5000:]);sys.exit(c.returncode)
env=dict(os.environ,MIMO_LOG_DIRECTORY=str(out/'logs'),MIMO_TEST_APP_GROUP='group.com.mimo.tests.'+uuid.uuid4().hex)
r=subprocess.run([str(out/'manual-demand-tests'),str(out),*a.only],cwd=ROOT,env=env,capture_output=True,text=True,timeout=60);(out/'test.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);sys.exit(r.returncode)
