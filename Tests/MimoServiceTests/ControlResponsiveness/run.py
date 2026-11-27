#!/usr/bin/env python3
"""Compile the real supervisor with isolated runtime boundaries; never use PF/DNS.

This test executes production Direct, Stop and queued protected handlers with
real anonymous-XPC state/event requests and the GUI's three-second deadline.
Only external runtime effects/readiness facts are substituted; production actor,
lock, ordering and cancellation boundaries remain intact. Slow external work and
an independently held real power fence must not starve state or heartbeat. The
generated source, instrumentation diff and hashes stay in the ignored output.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    parser.add_argument('--supervisor-source',type=Path,help='Preserved historical supervisor for fail-first evidence')
    args=parser.parse_args()
    out=args.output.resolve()
    if not out.is_relative_to(ROOT/'.build') or out.exists():
        parser.error('Choose a new output directory under this repository .build')
    out.mkdir(parents=True)
    generated=out/'generated';generated.mkdir()
    source=args.supervisor_source or ROOT/'Sources/MimoService/MimoSupervisor.swift'
    original=source.read_text();text=original
    (out/'MimoSupervisor.original.swift').write_text(original)
    replacements={}
    for member in ['maintenanceActive','networkReleaseRequested','savedAllowlist','acceptBaseline','confirmReadiness',
                   'acceptBaselineOnline','confirmReadinessOnline','openGateOnline','holdApplicationGateOnline',
                   'receiptMatchesLoadedProfile','restoreDirect','restoreDirectOnline','holdApplicationGate','disconnectFlows',
                   'closeGate','closed','gateState','protectedDNSConfigurationMatches','nativeReleaseIssue','revokeBaseline','openGate','infrastructureStatus',
                   'servicePreferences','saveServicePreferences','persistDirectRecovery','releaseNetworking']:
        text,count=re.subn(r'\b(?:self\.)?runtime\.'+member+r'\b','ControlRuntime.shared.'+member,text)
        if not count and (member == 'restoreDirectOnline' or member in ('acceptBaseline','confirmReadiness','openGate','acceptBaselineOnline','confirmReadinessOnline','openGateOnline','holdApplicationGateOnline')):
            continue # Keep exact historical synchronous and current asynchronous boundaries.
        assert count,member
        replacements[member]=count
    for member in ['networkObserver','powerGuard','sessionObserver']:
        text,count=re.subn(r'\b(?:self\.)?'+member+r'\.isRunning\b','true',text)
        assert count,member
        replacements[member+'.isRunning']=count
    assert text.count('networkObserver.setProxyEndpoint(nil)')==2
    text=text.replace('networkObserver.setProxyEndpoint(nil)','ControlRuntime.shared.events.append("native observer endpoint cleared")')
    # A synchronous marker identifies the actual await; it adds no suspension.
    old='let receipt = try await readinessCheck.value'
    new='do { receipt = try await readinessCheck.value }'
    if old in text:
        assert text.count(old)==1
        text=text.replace(old,'qualificationAwaitingReadiness = true\n                '+old)
    else:
        assert text.count(new)==1
        text=text.replace(new,'qualificationAwaitingReadiness = true\n                '+new)
    declaration='private let runtime = MimoSystemRuntime()'
    assert text.count(declaration)==1
    text=text.replace(declaration,declaration+'\n    var qualificationAwaitingReadiness = false\n    var qualificationOnReadinessTail: (() -> Void)?\n    var qualificationOnReadinessFailureTail: (() -> Void)?')
    # Reuse the production MainActor wrapper when seeding already-prepared
    # state. Its async/sync boundaries and cancellation checks are unchanged.
    start=text.index('readinessCheck = Task { [weak self] in')
    brace=text.index('{',start);depth=1;end=brace+1
    while depth:
        if text[end]=='{':depth+=1
        elif text[end]=='}':depth-=1
        end+=1
    wrapper=text[start:end]
    assert wrapper.count('return receipt')==1 and wrapper.count('throw error')==1
    wrapper=wrapper.replace('return receipt','self.qualificationOnReadinessTail?()\n                            return receipt')
    wrapper=wrapper.replace('throw error','self.qualificationOnReadinessFailureTail?()\n                            throw error')
    access=(HERE/'supervisor-access.swift').read_text().replace('__READINESS_WRAPPER__',wrapper)
    has_lease='private var activeProtectedLease:' in original
    access=access.replace('__PROTECTED_LEASE_SEED__', 'activeProtectedLease = MimoProtectedLease(configuration: configuration, revision: 1)' if has_lease else '')
    access=access.replace('__PROTECTED_LEASE_CAPTURE__', 'let lease = activeProtectedLease!' if has_lease else '')
    assert replacements.get('acceptBaseline',0)+replacements.get('acceptBaselineOnline',0)>0
    assert replacements.get('confirmReadiness',0)+replacements.get('confirmReadinessOnline',0)>0
    assert replacements.get('openGate',0)+replacements.get('openGateOnline',0)>0
    text+='\n'+access
    (generated/'MimoSupervisor.swift').write_text(text)
    (out/'instrumentation.diff').write_text(''.join(difflib.unified_diff(original.splitlines(True),text.splitlines(True),fromfile='original/MimoSupervisor.swift',tofile='generated/MimoSupervisor.swift')))
    (generated/'BoundedProcess.swift').write_text('''import Foundation
enum BoundedProcess {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2,
                    captureError: Bool = false, input: Data? = nil,
                    outputLimit: Int = 65536) -> (text: String, status: Int32) {
        fatalError("Isolated supervisor test attempted an external subprocess")
    }
}
''')
    production=sorted((ROOT/'Sources/MimoShared').glob('*.swift'))+sorted((ROOT/'Sources/MimoCore').glob('*.swift'))+[
        p for p in sorted((ROOT/'Sources/MimoService').glob('*.swift')) if p.name not in ('MimoSupervisor.swift','BoundedProcess.swift')]
    files=production+sorted(generated.glob('*.swift'))+[HERE/'cases.swift']
    hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in production}
    hashes['tested_supervisor']=hashlib.sha256(original.encode()).hexdigest()
    (out/'source-identity.json').write_text(json.dumps({'created_epoch':time.time(),'sources':hashes,'runtime_hook_replacements':replacements},indent=2)+'\n')
    command=['xcrun','swiftc','-swift-version','6','-parse-as-library','-D','MIMO_SERVICE_TEST',*[str(p) for p in files],'-o',str(out/'control-responsiveness-tests')]
    compiled=subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
    (out/'compile.log').write_text(compiled.stdout+compiled.stderr)
    if compiled.returncode:
        print((compiled.stdout+compiled.stderr)[-6000:]);return compiled.returncode
    import os
    environment=dict(os.environ,MIMO_LOG_DIRECTORY=str(out/'runtime'))
    tested=subprocess.run([str(out/'control-responsiveness-tests'),str(out/'results.json')],cwd=ROOT,
        env=environment,capture_output=True,text=True,timeout=240)
    (out/'test.log').write_text(tested.stdout+tested.stderr)
    print(tested.stdout)
    if tested.stderr:print(tested.stderr,file=sys.stderr)
    return tested.returncode


if __name__=='__main__':sys.exit(main())
