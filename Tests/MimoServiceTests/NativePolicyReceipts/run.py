#!/usr/bin/env python3
"""New native-policy receipt/actor controls; actual runtime methods, isolated OS facts.

Only selected production members are compiled. Native process/PF command facts
are substituted; actor boundaries, real flock/epoch files, policy renderers,
receipt validation and status projection execute unchanged. No host PF/XPC/VPN
calls. --compile-only prepares without executing; the worker runs the ten cases.
"""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('output',type=Path);p.add_argument('--compile-only',action='store_true');p.add_argument('--only',nargs='+');a=p.parse_args()
out=a.output.resolve();assert out.is_relative_to(ROOT/'.build') and not out.exists();out.mkdir(parents=True,mode=0o700)
gen=out/'generated';gen.mkdir()
def member(source,name):
 start=source.index(name);brace=source.index('{',start);end=brace+1;depth=1
 while depth:depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
paths=['Sources/MimoService/MimoSystemRuntime.swift','Sources/MimoService/MimoFirewallLock.swift','Sources/MimoService/MimoBlockingWorkQueue.swift','Sources/MimoService/MimoPFHealthReceipt.swift','Sources/MimoShared/SingleInstanceLock.swift','Sources/MimoShared/MimoFirewallPolicy.swift','Sources/MimoShared/MimoNativeEgress.swift','Sources/MimoShared/MimoRouting.swift','Sources/MimoShared/MimoAllowlist.swift','Sources/MimoService/MimoNativePolicyUpdate.swift']
original={name:(ROOT/name).read_text() for name in paths}
for name,text in original.items():
 dest=out/'original'/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(text)
model=original['Sources/MimoShared/MimoRouting.swift']
models='\n'.join(member(model,name) for name in ('public enum ProxyMode:','public enum MimoHealthLabel','public enum MimoInfrastructureHealth:','public enum MimoInfrastructureCheckOutcome:','public struct MimoInfrastructureInspection:','public struct MimoInfrastructureStatus:'))
models+='\n'+member(original['Sources/MimoShared/MimoAllowlist.swift'],'public enum IPAddressValidator')
models+='\n'+member(original['Sources/MimoService/MimoSystemRuntime.swift'],'struct MimoPreparedProbePolicy:')
(gen/'Models.swift').write_text('import Foundation\nimport Darwin\n'+models+'\n')
runtime=original['Sources/MimoService/MimoSystemRuntime.swift']
names=('    func auditPolicies()','    func refreshBlockedNativeTransport()','    func infrastructureStatus(','    private func pfHealthReceiptIsCurrent(','    var gateState:', '    func refreshDirectTracking()', '    private nonisolated func localTCPDestinations()', '    private nonisolated func prepareDirectTrackingUpdate(', '    func cancelNativePolicyUpdates()', '    func drainNativePolicyUpdates()', '    private func updateNativePolicy(', '    private func nativePolicyWork<', '    private nonisolated static func nativePolicyMilliseconds(', '    private nonisolated func nativePolicyScope(', '    private nonisolated func prepareNativePolicyUpdate(', '    private nonisolated func validateNativePolicyScope(', '    private nonisolated func commitNativePolicyUpdate(')
methods='\n'.join(member(runtime,name) for name in names)
(gen/'Runtime.swift').write_text('import Foundation\n@MainActor final class MimoSystemRuntime {\n'+(HERE/'runtime-stubs.swift').read_text()+methods+'\n}\n')
files=[gen/'Models.swift',gen/'Runtime.swift',HERE/'support.swift',HERE/'cases.swift']
for name in paths[1:7]+[paths[-1]]:
 text=original[name]
 if name.endswith('MimoFirewallPolicy.swift'):
  # Read-only access for the PF canonicalization fake; no rule changes.
  text=text.replace('private static var controlReadback:','static var controlReadback:')
 dest=gen/Path(name).name;dest.write_text(text);files.append(dest)
identities={name:hashlib.sha256(text.encode()).hexdigest() for name,text in original.items()}
identities.update({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.glob('*') if p.is_file()})
(out/'source-identities.json').write_text(json.dumps(identities,indent=2)+'\n')
(out/'method.json').write_text(json.dumps({'production_members':list(names),'real':'MainActor scheduling, blocking work queue, flock, mutation/close epochs, native rules, health receipt checks and status projection','mocked':'PF command/readback text, signed-native snapshot, sandbox paths, OS boot identity/file ownership; no actual PF or XPC','contention_scope':'MainActor state/Direct-intent callback admission availability; not a full daemon RPC or physical Direct switch','planned':10},indent=2)+'\n')
r=subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',*map(str,files),'-o',str(out/'tests')],capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode:print(r.stderr[-9000:]);sys.exit(r.returncode)
if a.compile_only:print('Compile-only PASS;0/10 controls executed.');sys.exit(0)
r=subprocess.run([str(out/'tests'),str(out),*(a.only or [])],capture_output=True,text=True,timeout=45);(out/'test.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);sys.exit(r.returncode)
