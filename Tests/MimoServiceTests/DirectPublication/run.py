#!/usr/bin/env python3
"""Exercise the production Direct PF publication slice with isolated PF I/O.

The real kernel lock/epoch implementation and the exact production release call
and PF commit body are compiled. Only pfctl, owner facts and private file I/O are
substituted. A newer maintenance closure runs after PF commit returns, before the
caller continues—the legitimate independent-process scheduling boundary.
"""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]

def block(s,start):
    b=s.index('{',start);d=1;e=b+1
    while d:
        if s[e]=='{':d+=1
        if s[e]=='}':d-=1
        e+=1
    return s[start:e]

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path)
    a=parser.parse_args();out=a.output.resolve()
    if out.exists() or not out.is_relative_to(ROOT/'.build'):parser.error('new .build directory required')
    out.mkdir(parents=True)
    source=(ROOT/'Sources/MimoService/MimoSystemRuntime.swift').read_text()
    (out/'MimoSystemRuntime.original.swift').write_text(source)
    start=source.index('        _ = try MimoFirewallLock.mutate(revoking: rules ==')
    end=source.index('\n        RuntimeLog.shared.info("mimo_pf_policy_installed"',start)
    commit=source[start:end]
    start=source.index('            try installPF(MimoFirewallPolicy.direct')
    end=source.index('            if uninstalling {',start)
    caller=source[start:end]
    confirm=block(source,source.index('    private func confirmDirectRelease(')).replace('private func','func',1)
    swift='''import Foundation
    enum DaemonFailure: Error { case conflict }
    enum MimoRuntimeError: Error { case unavailable(String) }
    enum MimoRuntime { static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_ROOT"]!) }
    enum MimoFirewallPolicy {
      static let startupBlocking="block",direct="",anchor="test"
      static func isClosedReadback(_ value:String)->Bool { value=="block" }
      static func isVerificationReadback(_ value:String)->Bool { value=="probe" }
    }
    enum MimoPowerGuard { static func revokeOutboundStates() throws {} }
    struct MimoDirectReleaseRequest {}
    typealias Owner=MimoDirectReleaseRequest
    @MainActor enum BoundedProcess {
      static var live=""
      static func run(_ e:String,_ a:[String])->(status:Int32,text:String) { (0,live) }
    }
    @MainActor final class Fixture {
      let directory=MimoRuntime.directory
      var closed=true, maintenanceActive=false
      var gateState:String? { try? String(contentsOf:directory.appendingPathComponent("gate.state"),encoding:.utf8) }
      var afterCommit:(()throws->Void)?
      func validateDirectRelease(_ owner:Owner)throws { if maintenanceActive { throw DaemonFailure.conflict } }
      func command(_ e:String,_ a:[String],input:Data)throws { BoundedProcess.live=String(decoding:input,as:UTF8.self) }
      func writePrivate(_ data:Data,name:String)throws->URL { let p=directory.appendingPathComponent(name);try data.write(to:p);return p }
      func installPF(_ rules:String,requiresRuntimeGroup:Bool,releaseEpoch:String?,maintenanceRelease:Bool,releaseOwner:Owner?)throws {
        let closeOwner:Owner?=nil,bytes=Data(rules.utf8)
    '''+commit+'''
        try afterCommit?()
      }
      '''+confirm+'''
      func release()throws {
        var releasedEpoch:String?
        let releaseEpoch=try String(contentsOf:directory.appendingPathComponent("pf-close.epoch"),encoding:.utf8)
        let maintenanceRecovery=false,uninstalling=false,owner:Owner?=Owner()
    '''+caller+'''
      }
    }
    @main struct Test {
      @MainActor static func main()throws {
        let root=MimoRuntime.directory
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var passed=0
        for scenario in ["current-direct","newer-maintenance","newer-power","changed-rules"] {
          let maintenance=scenario != "current-direct"
          try Data("initial".utf8).write(to:root.appendingPathComponent("pf-close.epoch"))
          try Data("restoring".utf8).write(to:root.appendingPathComponent("gate.state"))
          let fixture=Fixture()
          if maintenance { fixture.afterCommit={
            try MimoFirewallLock.mutate(revoking:scenario != "changed-rules") {
              fixture.maintenanceActive=scenario == "newer-maintenance"
              BoundedProcess.live="block"
              if scenario != "changed-rules" { _=try fixture.writePrivate(Data("blocked".utf8),name:"gate.state") }
            }
          } }
          try fixture.release()
          let marker=try String(contentsOf:root.appendingPathComponent("gate.state"),encoding:.utf8)
          let admitted=(try? fixture.confirmDirectRelease(Owner(),epoch:"initial")) != nil
          let correct=marker==(["newer-maintenance","newer-power"].contains(scenario) ? "blocked":"direct") && admitted == !maintenance
          print("\\(scenario): \\(correct ? "PASS":"FAIL") marker=\\(marker) receipt=\\(admitted)")
          if correct { passed+=1 }
        }
        print("RESULT \\(passed)/4 pass")
        exit(passed==4 ? 0:1)
      }
    }
    '''
    p=out/'test.swift';p.write_text(swift)
    files=[ROOT/'Sources/MimoShared/SingleInstanceLock.swift',ROOT/'Sources/MimoService/MimoFirewallLock.swift',p]
    (out/'source-identity.json').write_text(json.dumps({str(x):hashlib.sha256(x.read_bytes()).hexdigest() for x in files}|{'runtime':hashlib.sha256(source.encode()).hexdigest()},indent=2))
    compile=subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',*map(str,files),'-o',str(out/'test')],capture_output=True,text=True)
    (out/'compile.log').write_text(compile.stdout+compile.stderr)
    if compile.returncode:print(compile.stderr);return compile.returncode
    import os
    test=subprocess.run([str(out/'test')],env=dict(os.environ,FIXTURE_ROOT=str(out/'fixture')),capture_output=True,text=True,timeout=30)
    (out/'test.log').write_text(test.stdout+test.stderr);print(test.stdout+test.stderr);return test.returncode
if __name__=='__main__':sys.exit(main())
