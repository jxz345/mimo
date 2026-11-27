#!/usr/bin/env python3
"""Real observer deferral/classification and power fence with immutable OS facts.
No watcher is started; only snapshot reads and owned tunnel index lookup are
substituted. Retained route/config callbacks and their classification are real.
"""
from pathlib import Path
import sys,json,hashlib,subprocess,os
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
out=Path(sys.argv[1]).resolve();assert out.is_relative_to(ROOT/'.build') and not out.exists();out.mkdir(parents=True);gen=out/'generated';gen.mkdir()
def body(s,name,value):
 a=s.index(name);b=s.index('{',a);end=b+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[:b+1]+value+s[end-1:]
s=(ROOT/'Sources/MimoService/MimoNetworkObserver.swift').read_text()
for name,value in [('private func currentTunnelSignature()', 'return ObserverFacts.shared.signature'),('private func interfaces()', 'return ObserverFacts.shared.interfaces'),('private func currentDNS()', 'return ObserverFacts.shared.dns'),('private func globals()', 'return [:]'),('private func externalDNS()', 'return [:]'),('private func rememberTunnelIndex()', 'return')]:s=body(s,name,'\n'+value+'\n')
s+='''
extension MimoNetworkObserver {
 func testSeed(){otherInterfaces=interfaces();globalConfiguration=globals();externalDNSConfiguration=externalDNS()}
 var testPending:Int {pendingProfileEvents.count}
 func testConfiguration(_ keys:[String],early:MimoEarlyNetworkEvent?){configurationChanged(keys,privateKeys:[],early:early)}
 func testRoute(_ events:[RouteChangeObserver.Change],early:MimoEarlyNetworkEvent?){routesChanged(events,receivedAt:.now,early:early)}
}
''';(gen/'MimoNetworkObserver.swift').write_text(s)
(gen/'BoundedProcess.swift').write_text('''import Foundation
enum BoundedProcess {static func run(_ e:String,_ a:[String],timeout:TimeInterval=2,captureError:Bool=false,input:Data?=nil,outputLimit:Int=65536)->(text:String,status:Int32) {fatalError("External command forbidden")}}''')
files=sorted((ROOT/'Sources/MimoShared').glob('*.swift'))+sorted((ROOT/'Sources/MimoCore').glob('*.swift'))+[p for p in sorted((ROOT/'Sources/MimoService').glob('*.swift')) if p.name not in {'BoundedProcess.swift','MimoNetworkObserver.swift'}]+sorted(gen.glob('*.swift'))+[HERE/'cases.swift']
(out/'sources.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
r=subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-D','MIMO_SERVICE_TEST',*map(str,files),'-o',str(out/'test')],capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode:print(r.stderr[-10000:]);sys.exit(r.returncode)
r=subprocess.run([str(out/'test'),str(out/'results.json')],env=dict(os.environ,MIMO_LOG_DIRECTORY=str(out/'runtime')),capture_output=True,text=True,timeout=60);(out/'test.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);sys.exit(r.returncode)
