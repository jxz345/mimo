import Foundation
import CryptoKit
import Darwin

final class PreparationRuntime: @unchecked Sendable {
    nonisolated(unsafe) static var shared = PreparationRuntime()
    var maintenanceActive=false,networkReleaseRequested=false,closed=false
    var gateState:String?="direct",nativeReleaseIssue:String?
    var protectedDNSConfigurationMatches=true
    let readinessChecks=MimoReadinessChecks()
    var scenario="fast",installDelay:TimeInterval=0.02,loadDelay:TimeInterval=0.02
    let lock=NSLock()
    var storedEvents:[String]=[]
    var started=DispatchSemaphore(value:0)
    var signalOnLoad=false
    func note(_ event:String) { lock.withLock { storedEvents.append(event) } }
    var events:[String] { lock.withLock { storedEvents } }
    let candidate=ClashProxySettings(name:"Isolated",type:.socks5,server:"192.0.2.1",port:1080)
    let receipt=MimoReadinessReceipt(process:1,profileDigest:Data("isolated".utf8),checkedAt:.now)
    func savedAllowlist() throws -> AllowedIPList { .init(addresses:["203.0.113.10"]) }
    func acceptBaseline(_ r:MimoReadinessReceipt)throws {}
    func confirmReadiness(_ r:MimoReadinessReceipt)throws {}
    func receiptMatchesLoadedProfile(_ r:MimoReadinessReceipt)->Bool {true}
    func restoreDirect()throws { closed=false;gateState="direct";note("direct-restored") }
    func restoreDirectOnline()async throws { try restoreDirect() }
    func holdApplicationGate()throws {closed=true;gateState="blocked";note("hold")}
    func disconnectFlows()throws {note("disconnect")}
    func closeGate(endpoints:[String]=[],proxyPort:Int?=nil)throws {closed=true;gateState="blocked";note("close")}
    func revokeBaseline(){}
    func openGate(receipt:MimoReadinessReceipt)throws {closed=false;gateState="active";note("open")}
    func infrastructureStatus(generation:UInt64?=nil)->MimoInfrastructureStatus { .init(pf:.healthy,launchd:.healthy,checkedAt:Date(timeIntervalSince1970:1700000000)) }
    func requestApplicationGate()->MimoGateRequest {MimoGateRequest()}
    func confirmApplicationGate(_ t:MimoGateRequest)async throws {try await Task.sleep(for:.milliseconds(100));closed=true;gateState="blocked"}
    func cachedProbePolicy(endpoints:[String],proxyPort:Int?,mode:ProxyMode)throws->MimoPreparedProbePolicy? {policy()}
    func prepareProbePolicy(endpoints:[String],proxyPort:Int?,mode:ProxyMode)async throws->MimoPreparedProbePolicy {policy()}
    func policy()->MimoPreparedProbePolicy {.init(rules:"fixture",group:0,activeRules:"active",nativeInterfaces:[],nativeEgress:.init())}
    func checkInstallation()throws {}
    func savedBypassBlocks()throws->[MimoBypassBlock] {[]}
    func nativeDNSRules()throws->[MimoPrivateDNSRule] {[]}
    func requestConnectionCleanup()->MimoGateRequest {MimoGateRequest()}
    func confirmConnectionCleanup(_ t:MimoGateRequest)async throws {}
    func savedProxy(configuration:MimoConfiguration,revision:Int)throws->ClashProxySettings {candidate}
    func canReuseProfile(_ p:String)->Bool {false}
    func installProbePolicy(_ p:MimoPreparedProbePolicy)throws {note("install-start");if !signalOnLoad {started.signal()};Thread.sleep(forTimeInterval:installDelay);note("install-end")}
    func prepareHostnameBootstrap()throws {fatalError("Literal fixture must not enter hostname bootstrap")}
    func permitPrivateProbe()throws {Thread.sleep(forTimeInterval:scenario=="fast" ? 0.02:0.2);note("permit")}
    func loadProfile(_ p:String)throws {note("load-start");if signalOnLoad {started.signal()};Thread.sleep(forTimeInterval:loadDelay);note("load-end");if scenario=="failure" {throw MimoRuntimeError.unavailable("Injected profile failure")}}
    func configureProtectedDNS()throws {}
    func startReadiness(profile:String,proxy:ClashProxySettings,installation:Task<Void,Error>,recordTiming:Bool=true)throws->Task<MimoReadinessReceipt,Error> {let r=MimoReadinessReceipt(process:1,profileDigest:Data(SHA256.hash(data:Data(profile.utf8))),checkedAt:.now);return Task {r}}
}
struct NoCredentials:CredentialBackend {func read(account:String)throws->String? {nil};func save(_ v:String,account:String)throws {};func delete(account:String)throws {}}
func wait(_ semaphore:DispatchSemaphore)->Bool {semaphore.wait(timeout: .now()+10) == .success}
struct ResultRow:Codable {let mode:String,family:String,scenario:String;let passed:Bool,rpcPassed:Bool,terminalCorrect:Bool;let duration:Double;let events:[String]}
@main struct Tests {
 @MainActor static func main()async throws {
  let destination=URL(fileURLWithPath:CommandLine.arguments[1]);var results:[ResultRow]=[]
  let shutdownOnly=CommandLine.arguments.contains("--shutdown-only")
  let scenarios=shutdownOnly ? ["shutdown"]:["combined","single-load","failure","direct","power","replacement","shutdown"]
  for mode in [ProxyMode.rule,.global] {for family in [MimoNetworkFamily.ipv4,.dual] {for scenario in scenarios {
   let runtime=PreparationRuntime();PreparationRuntime.shared=runtime;runtime.scenario=scenario
   runtime.installDelay=scenario=="combined" ? 1.4:0.02
   runtime.loadDelay=scenario=="fast" ? 0.02:scenario=="combined" ? 2.4:3.8
   runtime.signalOnLoad=scenario != "combined" && scenario != "fast"
   let supervisor=MimoSupervisor();supervisor.qualificationInitialDirect()
   let store=try FilePreferenceStorage(url:destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".plist"))
   let service=try DaemonService(storage:store,observeSystem:false,credentials:NoCredentials())
   let listener=NSXPCListener.anonymous();listener.delegate=service;listener.resume();let endpoint=listener.endpoint
   let sl=NSXPCListener.anonymous();sl.delegate=supervisor;sl.resume();let se=sl.endpoint
   var config=MimoConfiguration();config.mode=mode;config.networkFamily=family;config.proxy=MimoProxy(runtime.candidate)
   var prep=MimoSupervisorRequest(.prepare);prep.configuration=config;prep.revision=1;prep.networkGeneration=1;prep.allowlist=try runtime.savedAllowlist()
   var command=DaemonRequest(.supervisor);command.supervisor=prep
   let probe=Task.detached {()->(Bool,Double) in
    guard wait(runtime.started) else{return(false,-1)}
    let start=Date()
    do {
     let a=try await DaemonRPC.call(DaemonRequest(.state),connection:NSXPCConnection(listenerEndpoint:endpoint),timeout:3)
     var q=DaemonRequest(.supervisor);q.supervisor=MimoSupervisorRequest(.state)
     let b=try await DaemonRPC.call(q,connection:NSXPCConnection(listenerEndpoint:se),timeout:3)
     q.supervisor?.includeEvents=true
     let c=try await DaemonRPC.call(q,connection:NSXPCConnection(listenerEndpoint:se),timeout:3)
     q.supervisor=MimoSupervisorRequest(.heartbeat)
     let d=await supervisor.handle(q,uid:0,pid:getpid()+100)
     return(a.state != nil && b.routing != nil && c.failure==nil && d.routing != nil,Date().timeIntervalSince(start))
    } catch{return(false,Date().timeIntervalSince(start))}
   }
   let follower:Task<Void,Never>?
   if scenario=="power" {
    let fence=supervisor.qualificationPowerFence
    follower=Task.detached {while !runtime.events.contains("load-start") {try? await Task.sleep(for:.milliseconds(1))};_ = try? fence.sleep {runtime.note("power-closed");runtime.closed=true}}
   } else if scenario=="direct" {
    var direct=config;direct.mode = .direct
    var m=MimoSupervisorRequest(.direct);m.configuration=direct
    var q=DaemonRequest(.supervisor);q.supervisor=m
    let directRequest=q
    follower=Task.detached {while !runtime.events.contains("load-start") {try? await Task.sleep(for:.milliseconds(1))};_ = await supervisor.handle(directRequest,uid:0,pid:getpid()+100)}
   } else if scenario=="shutdown" {
    follower=Task.detached {
     while !runtime.events.contains("load-start") {try? await Task.sleep(for:.milliseconds(1))}
     await supervisor.stop()
     var late = DaemonRequest(.supervisor);late.supervisor=MimoSupervisorRequest(.prepare)
     let rejected = await supervisor.handle(late,uid:0,pid:getpid()+100)
     runtime.note(rejected.failure == .unavailable ? "late-command-rejected":"late-command-accepted")
     await supervisor.drainInfrastructure()
     runtime.note("shutdown-drained")
    }
   } else if scenario=="replacement" {
    var replacement=command;replacement.supervisor?.revision=2
    let replacementRequest=replacement
    follower=Task.detached {while !runtime.events.contains("load-start") {try? await Task.sleep(for:.milliseconds(1))};_ = await supervisor.handle(replacementRequest,uid:0,pid:getpid()+100)}
   } else {follower=nil}
   let response=await supervisor.handle(command,uid:0,pid:getpid()+100)
   await follower?.value
   let (rpc,duration)=await probe.value
   let phase=supervisor.qualificationState.phase
   let shutdownJoined = scenario != "shutdown" || (runtime.events.contains("late-command-rejected") && (runtime.events.firstIndex(of:"shutdown-drained") ?? -1) > (runtime.events.firstIndex(of:"load-end") ?? Int.max) && (runtime.events.firstIndex(of:"shutdown-drained") ?? -1) > (runtime.events.firstIndex(of:"observer-end") ?? Int.max))
   let ownership = shutdownJoined && (scenario=="replacement" ? runtime.events.filter {$0=="load-start" || $0=="load-end"} == ["load-start","load-end","load-start","load-end"] : true)
   let observerOrder:Bool
   if ["failure","power","direct","shutdown"].contains(scenario) {observerOrder=runtime.events.contains("observer-end")}
   else {observerOrder=(runtime.events.lastIndex(of:"observer-end") ?? -1) > (runtime.events.lastIndex(of:"dns-installed") ?? Int.max)}
   let terminal=ownership && observerOrder && (scenario=="direct" ? phase == .active && runtime.events.last=="direct-restored" : ["failure","power","shutdown"].contains(scenario) ? phase == .blocked : phase == .checking)
   let row=ResultRow(mode:mode.rawValue,family:family.rawValue,scenario:scenario,passed:rpc && terminal,rpcPassed:rpc,terminalCorrect:terminal,duration:duration,events:runtime.events)
   results.append(row);print(String(data:try JSONEncoder().encode(row),encoding:.utf8)!)
   listener.invalidate();sl.invalidate()
  }}}
  if !shutdownOnly {for mode in [ProxyMode.rule,.global] {for family in [MimoNetworkFamily.ipv4,.dual] {
   let runtime=PreparationRuntime();PreparationRuntime.shared=runtime
   let supervisor=MimoSupervisor();supervisor.qualificationInitialDirect()
   var configuration=MimoConfiguration();configuration.mode=mode;configuration.networkFamily=family;configuration.proxy=MimoProxy(runtime.candidate)
   supervisor.qualificationPendingApproval(configuration)
   runtime.closed=false;runtime.gateState="active"
   var message=MimoSupervisorRequest(.updatePolicy);message.allowlist=AllowedIPList(addresses:["203.0.113.11"])
   var request=DaemonRequest(.supervisor);request.supervisor=message
   let result=await supervisor.handle(request,uid:0,pid:getpid()+100)
   let correct=result.routing?.phase == .blocked && result.routing?.blockingIP?.address == "203.0.113.10" && runtime.closed
   results.append(.init(mode:mode.rawValue,family:family.rawValue,scenario:"pending-policy-revoke",passed:correct,rpcPassed:true,terminalCorrect:correct,duration:0,events:runtime.events))
   print("pending-policy-revoke \(mode.rawValue)/\(family.rawValue) \(correct ? "PASS":"FAIL")")
  }}}
  try JSONEncoder().encode(results).write(to:destination)
  let passed=results.filter(\.passed).count;print("RESULT \(passed)/\(results.count) pass");exit(passed==results.count ? 0:1)
 }
}
