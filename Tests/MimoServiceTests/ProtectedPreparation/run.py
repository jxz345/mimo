#!/usr/bin/env python3
"""Run real supervisor and protected I/O scheduling with isolated external effects.
The 20 reproduced slow-preparation failures retain their original timing and RPC
oracles. Four replacement races and four pending-policy controls cover newly
introduced ownership boundaries; source identities/diffs remain in each run.
"""
from pathlib import Path
import sys,hashlib,json,subprocess,difflib,os
ROOT=Path(__file__).resolve().parents[3];OWN=ROOT/'.build/observation-parallel/protected-preparation-repro'; HERE=Path(__file__).resolve().parent
out=Path(sys.argv[1]).resolve();assert out.is_relative_to(ROOT/'.build') and not out.exists();out.mkdir(parents=True);gen=out/'generated';gen.mkdir()
def replacebody(s,name,value):
 start=s.index(name);brace=s.index('{',start);end=brace+1;depth=1
 while depth:
  if s[end]=='{':depth+=1
  elif s[end]=='}':depth-=1
  end+=1
 return s[:brace+1]+value+s[end-1:]
original=(ROOT/'Sources/MimoService/MimoSupervisor.swift').read_text();s=original
members=['maintenanceActive','networkReleaseRequested','savedAllowlist','acceptBaseline','confirmReadiness','receiptMatchesLoadedProfile','restoreDirect','restoreDirectOnline','holdApplicationGate','disconnectFlows','closeGate','closed','gateState','protectedDNSConfigurationMatches','nativeReleaseIssue','revokeBaseline','openGate','infrastructureStatus','requestApplicationGate','confirmApplicationGate','cachedProbePolicy','prepareProbePolicy','checkInstallation','savedBypassBlocks','nativeDNSRules','requestConnectionCleanup','confirmConnectionCleanup','savedProxy','canReuseProfile','installProbePolicy','prepareHostnameBootstrap','permitPrivateProbe','loadProfile','configureProtectedDNS','startReadiness','readinessChecks']
import re
for member in members:
 s,n=re.subn(r'\b(?:self\.)?runtime\.'+member+r'\b','PreparationRuntime.shared.'+member,s);
# Detached closures capture the same isolated external boundary object, not a new actor.
s=s.replace('let runtime = self.runtime','let runtime = PreparationRuntime.shared')
for member in ['installProbePolicyOnline','prepareHostnameBootstrapOnline','permitPrivateProbeOnline','holdApplicationGateOnline','loadProtectedProfile','configureProtectedDNSOnline','confirmReadinessOnline']:
 s=s.replace('runtime.'+member,'self.runtime.'+member)
# Within detached closures shared singleton must not require MainActor access.
s=s.replace('try PreparationRuntime.shared.checkInstallation()','try runtime.checkInstallation()').replace('runtime.PreparationRuntime','runtime')
# Capture and pass runtime at all detached references generated above.
for member in ['readinessChecks','prepareProbePolicy','savedProxy']:
 s=s.replace('PreparationRuntime.shared.'+member,'runtime.'+member)
for member in ['networkObserver','powerGuard','sessionObserver']:
 s=re.sub(r'\b(?:self\.)?'+member+r'\.isRunning\b','true',s)
s=s.replace('networkObserver.setProxyEndpoint(nil)','PreparationRuntime.shared.note("endpoint-cleared")')
s=s.replace('networkObserver.setProxyEndpoint(address)','PreparationRuntime.shared.note("endpoint-set")')
s=replacebody(s,'    private func probePassword() throws -> String {','\n        return String(repeating:"a",count:64)\n    ')
s+='''\nextension MimoSupervisor {
 var qualificationPowerFence:MimoPowerFence { powerGuard.fence }
 var qualificationState:MimoRoutingState { policy.state }
 func qualificationInitialDirect() {
  policy.directRestored(configuration:MimoConfiguration()); configurationKnown=true; cachedServices=(.now,[])
  runtime.profileWillChange = {PreparationRuntime.shared.note("observer-begin")}
  runtime.profileDidChangeOnline = {PreparationRuntime.shared.note("observer-end")}
 }
 func qualificationPendingApproval(_ configuration:MimoConfiguration) {
  let check=policy.begin(configuration:configuration,revision:1,networkGeneration:1);policy.checking(check)
  policy.waitingForReadiness(address:"203.0.113.10",verification:check)
  activeProtectedLease=runtime.beginProtectedIO(configuration:configuration,revision:1)
 }
}
'''
(gen/'MimoSupervisor.swift').write_text(s);(out/'MimoSupervisor.original.swift').write_text(original);(out/'instrumentation.diff').write_text(''.join(difflib.unified_diff(original.splitlines(True),s.splitlines(True))))
runtime=(ROOT/'Sources/MimoService/MimoSystemRuntime.swift').read_text()
r=runtime.replace('    fileprivate let','    let')
r=r.replace('private(set) var closed = false', 'var closed: Bool { get { PreparationRuntime.shared.closed } set { PreparationRuntime.shared.closed = newValue } }')
r=replacebody(r,'private nonisolated var group:', '\n        return 0\n    ')
r=replacebody(r,'    func requestApplicationGate()', '\nreturn PreparationRuntime.shared.requestApplicationGate()\n')
r=replacebody(r,'    func confirmApplicationGate(', '\ntry await PreparationRuntime.shared.confirmApplicationGate(token)\n')
r=replacebody(r,'private nonisolated func secureController()', '\n        return\n    ')
r=replacebody(r,'nonisolated static func processLivenessFailure(', '\n        return nil\n    ')
(gen/'MimoSystemRuntime.swift').write_text(r)
io=(ROOT/'Sources/MimoService/MimoProtectedIO.swift').read_text()
io=replacebody(io,'    func check(_ lease:', '\n        try lease.check()\n    ')
io=replacebody(io,'    func install(', '\n        try check(lease); try PreparationRuntime.shared.installProbePolicy(policy); try check(lease); return MimoPFCommitReceipt(closeEpoch:"fixture",enableToken:nil)\n    ')
io=replacebody(io,'    func loadProfile(', '\n        try check(lease); try PreparationRuntime.shared.loadProfile(profile); try check(lease); return MimoLoadedProfileReceipt(process:1,identity:"fixture",digest:Data(SHA256.hash(data:Data(profile.utf8))))\n    ')
io=replacebody(io,'    func permit(', '\n        try check(lease); return try fence.activate(epoch:powerEpoch) {try check(lease); try PreparationRuntime.shared.permitPrivateProbe(); try check(lease); return "fixture"}\n    ')
io=replacebody(io,'    func grant(', '\n        try check(lease); try fence.completeCycle(epoch:powerEpoch) {try PreparationRuntime.shared.openGate(receipt:readiness)}\n    ')
io=replacebody(io,'    func close(', '\n        try PreparationRuntime.shared.holdApplicationGate()\n    ')
io=replacebody(io,'    func runningProcess()', '\n        return 1\n    ')
(gen/'MimoProtectedIO.swift').write_text(io)
dns=(ROOT/'Sources/MimoService/MimoProtectedDNSIO.swift').read_text()
dns=replacebody(dns,'    func install(', '\n        try check(); PreparationRuntime.shared.note("dns-installed"); return try PropertyListSerialization.data(fromPropertyList:["ServerAddresses":["127.0.0.1"]], format:.binary,options:0)\n    ')
dns=replacebody(dns,'    static func matches(', '\n        return true\n    ')
(gen/'MimoProtectedDNSIO.swift').write_text(dns)
(gen/'BoundedProcess.swift').write_text('''import Foundation
enum BoundedProcess { static func run(_ e:String,_ a:[String],timeout:TimeInterval=2,captureError:Bool=false,input:Data?=nil,outputLimit:Int=65536)->(text:String,status:Int32) { fatalError("External subprocess forbidden") } }
''')
files=sorted((ROOT/'Sources/MimoShared').glob('*.swift'))+sorted((ROOT/'Sources/MimoCore').glob('*.swift'))+[p for p in sorted((ROOT/'Sources/MimoService').glob('*.swift')) if p.name not in ['MimoSupervisor.swift','MimoSystemRuntime.swift','BoundedProcess.swift','MimoProtectedIO.swift','MimoProtectedDNSIO.swift']]+sorted(gen.glob('*.swift'))+[HERE/'cases.swift']
(out/'sources.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}|{'original_supervisor':hashlib.sha256(original.encode()).hexdigest(),'original_runtime':hashlib.sha256(runtime.encode()).hexdigest()},indent=2))
compile=subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-D','MIMO_SERVICE_TEST',*map(str,files),'-o',str(out/'test')],capture_output=True,text=True)
(out/'compile.log').write_text(compile.stdout+compile.stderr)
if compile.returncode:print(compile.stderr[-10000:]);sys.exit(compile.returncode)
test=subprocess.run([str(out/'test'),str(out/'results.json'),*sys.argv[2:]],env=dict(os.environ,MIMO_LOG_DIRECTORY=str(out/'runtime')),capture_output=True,text=True,timeout=240)
(out/'test.log').write_text(test.stdout+test.stderr);print(test.stdout+test.stderr);sys.exit(test.returncode)
