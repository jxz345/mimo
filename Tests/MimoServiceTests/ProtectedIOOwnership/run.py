#!/usr/bin/env python3
"""Execute real protected PF transaction/lease/fence code with isolated kernel I/O.
Only subprocess outcomes, saved settings, kernel identity facts and fixed storage
paths are replaced. No actual PF, network configuration or service is touched.
"""
from pathlib import Path
import sys,json,hashlib,subprocess,os
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
out=Path(sys.argv[1]).resolve();assert out.is_relative_to(ROOT/'.build') and not out.exists();out.mkdir(parents=True);gen=out/'generated';gen.mkdir()
def body(s,name,value):
 a=s.index(name);b=s.index('{',a);end=b+1;depth=1
 while depth:
  depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[:b+1]+value+s[end-1:]
io=(ROOT/'Sources/MimoService/MimoProtectedIO.swift').read_text().replace('private let directory = MimoRuntime.directory','private var directory: URL { ProtectedIOFixture.shared.directory }')
io=body(io,'    func check(_ lease:', '\ntry lease.check()\n')
io=body(io,'    private func validateGroup(', '\nguard ProtectedIOFixture.shared.validGroup else {throw DaemonFailure.conflict}\n')
io=body(io,'    private func allowed(', '\nguard ProtectedIOFixture.shared.allowed else {throw DaemonFailure.conflict}\n')
io=body(io,'    func runningProcess()', '\nreturn getpid()\n')
io=body(io,'    private func write(', '\ntry data.write(to: directory.appendingPathComponent(name),options:.atomic)\n')
io=body(io,'    private func command(', '\ntry ProtectedIOFixture.shared.command(tool,arguments,input:input)\n')
io=io.replace('if_nametoindex(MihomoProfile.tunnelDevice) != 0','true')
io=io.replace('try MimoPowerGuard.revokeOutboundStates()', '/* isolated state revocation */')
# The hook is after the actual PF transaction returns and before the power fence
# completes. It models an independent classifier/maintenance writer at precisely
# that existing boundary; no actor suspension is inserted or reordered.
io=io.replace('''            }
        }
        try check(lease)
        } catch {''','''            }
            ProtectedIOFixture.shared.afterCommit?()
        }
        try check(lease)
        } catch {''',1)
(gen/'MimoProtectedIO.swift').write_text(io)
lock=(ROOT/'Sources/MimoService/MimoFirewallLock.swift').read_text().replace('MimoRuntime.directory','ProtectedIOFixture.shared.directory');(gen/'MimoFirewallLock.swift').write_text(lock)
dns=(ROOT/'Sources/MimoService/MimoProtectedDNSIO.swift').read_text();dns=body(dns,'    static func matches(', '\nreturn ProtectedIOFixture.shared.dnsMatches\n');(gen/'MimoProtectedDNSIO.swift').write_text(dns)
(gen/'BoundedProcess.swift').write_text('''import Foundation
enum BoundedProcess {static func run(_ e:String,_ a:[String],timeout:TimeInterval=2,captureError:Bool=false,input:Data?=nil,outputLimit:Int=65536)->(text:String,status:Int32) {ProtectedIOFixture.shared.run(e,a)}}''')
policy=(ROOT/'Sources/MimoShared/MimoFirewallPolicy.swift').read_text().replace('private static var controlReadback','static var controlReadback');(gen/'MimoFirewallPolicy.swift').write_text(policy)
exclude={'MimoFirewallPolicy.swift','MimoProtectedIO.swift','MimoFirewallLock.swift','MimoProtectedDNSIO.swift','BoundedProcess.swift'}
files=[p for p in sorted((ROOT/'Sources/MimoShared').glob('*.swift')) if p.name not in exclude]+sorted((ROOT/'Sources/MimoCore').glob('*.swift'))+[p for p in sorted((ROOT/'Sources/MimoService').glob('*.swift')) if p.name not in exclude]+sorted(gen.glob('*.swift'))+[HERE/'cases.swift']
(out/'sources.json').write_text(json.dumps({str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
r=subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-D','MIMO_SERVICE_TEST',*map(str,files),'-o',str(out/'test')],capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode:print(r.stderr[-10000:]);sys.exit(r.returncode)
r=subprocess.run([str(out/'test'),str(out/'results.json')],env=dict(os.environ,MIMO_LOG_DIRECTORY=str(out/'runtime')),capture_output=True,text=True,timeout=60);(out/'test.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);sys.exit(r.returncode)
