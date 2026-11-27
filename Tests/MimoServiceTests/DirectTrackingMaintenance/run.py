#!/usr/bin/env python3
"""Six focused Direct tracking-maintenance controls; no actual PF or networking."""
import argparse,ast,hashlib,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent;BASE=HERE.parent/'NativePolicyReceipts'
p=argparse.ArgumentParser();p.add_argument('output',type=Path);p.add_argument('--only',nargs='+');a=p.parse_args()
out=a.output.resolve();assert out.is_relative_to(ROOT/'.build') and not out.exists();out.mkdir(parents=True);gen=out/'generated';gen.mkdir()
def member(source,name):
 start=source.index(name);brace=source.index('{',start);end=brace+1;depth=1
 while depth:depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
tree=ast.parse((BASE/'run.py').read_text())
def literal(name):
 return next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id==name for t in n.targets))
paths=literal('paths');names=list(literal('names'));source={name:(ROOT/name).read_text() for name in paths}
for name,text in source.items():
 target=out/'original'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text)
model=source['Sources/MimoShared/MimoRouting.swift'];models='\n'.join(member(model,n) for n in ('public enum ProxyMode:','public enum MimoHealthLabel','public enum MimoInfrastructureHealth:','public enum MimoInfrastructureCheckOutcome:','public struct MimoInfrastructureInspection:','public struct MimoInfrastructureStatus:'))
models+='\n'+member(source['Sources/MimoShared/MimoAllowlist.swift'],'public enum IPAddressValidator')+'\n'+member(source['Sources/MimoService/MimoSystemRuntime.swift'],'struct MimoPreparedProbePolicy:')
(gen/'Models.swift').write_text('import Foundation\nimport Darwin\n'+models)
runtime=source['Sources/MimoService/MimoSystemRuntime.swift'];adapter=''
if '    func refreshDirectTracking()' in runtime:
 pass
else:adapter='    func refreshDirectTracking() async throws {}\n'
names=[n for n in names if n!='    private nonisolated func localTCPDestinations()']
stubs=(BASE/'runtime-stubs.swift').read_text().replace('nonisolated var networkReleaseRequested: Bool { false }','nonisolated var networkReleaseRequested: Bool { Inventory.shared.released }')
stubs+='    nonisolated func localTCPDestinations() throws -> [String] { Inventory.shared.snapshot() }\n'
(gen/'Runtime.swift').write_text('import Foundation\n@MainActor final class MimoSystemRuntime {\n'+stubs+adapter+'\n'.join(member(runtime,n) for n in names)+'\n}\n')
(gen/'Fixture.swift').write_text((BASE/'cases.swift').read_text().split('@main\nstruct Tests')[0])
files=[gen/'Models.swift',gen/'Runtime.swift',gen/'Fixture.swift',BASE/'support.swift',HERE/'cases.swift']
for name in paths[1:7]+[paths[-1]]:
 text=source[name].replace('private static var controlReadback:','static var controlReadback:');dest=gen/Path(name).name;dest.write_text(text);files.append(dest)
identities={n:hashlib.sha256(t.encode()).hexdigest() for n,t in source.items()};identities.update({str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [BASE/'run.py',BASE/'cases.swift',BASE/'runtime-stubs.swift',BASE/'support.swift',HERE/'run.py',HERE/'cases.swift']})
(out/'source-identities.json').write_text(json.dumps(identities,indent=2)+'\n');(out/'method.json').write_text(json.dumps({'planned':len(a.only) if a.only else 6,'missing_entry_baseline_adapter':bool(adapter),'scope':'actual extracted maintenance after implementation; real locks/epochs, injected PF/native/local-address facts; no XPC or network calls','baseline_limit':'missing-maintenance no-op adapter models current absent entrypoint; installed L1 is separate causal evidence'},indent=2)+'\n')
r=subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',*map(str,files),'-o',str(out/'tests')],capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode:print(r.stderr[-7000:]);sys.exit(r.returncode)
r=subprocess.run([str(out/'tests'),str(out),*(a.only or [])],capture_output=True,text=True,timeout=35);(out/'test.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);sys.exit(r.returncode)
