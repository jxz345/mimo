import AppKit
import Foundation

@MainActor final class RapidTransport {
    static var shared = RapidTransport()
    var requests: [DaemonRequest] = []
    var pending: [Int: CheckedContinuation<DaemonResponse, Error>] = [:]
    func call(_ request: DaemonRequest) async throws -> DaemonResponse {
        let index=requests.count; requests.append(request)
        return try await withCheckedThrowingContinuation { pending[index]=$0 }
    }
    func reply(_ index: Int, state: DaemonState? = nil, outcome: MimoControlOutcome? = nil) {
        var response=DaemonResponse(state:state);response.controlOutcome=outcome
        pending.removeValue(forKey:index)?.resume(returning:response)
    }
    func fail(_ index: Int) { pending.removeValue(forKey:index)?.resume(throwing:DaemonFailure.unavailable) }
    func finish() { for index in Array(pending.keys) { reply(index, outcome:.cancelled) } }
}
private struct Failure: Error { let message:String }
private func check(_ condition:Bool,_ message:String) throws { if !condition { throw Failure(message:message) } }
@MainActor private func settle() async { for _ in 0..<8 { await Task.yield() };try? await Task.sleep(for:.milliseconds(15)) }
private func state(_ instance:UUID=UUID(), revision:Int=4, sequence:UInt64=1, mode:ProxyMode = .rule, reason:String="current") throws -> DaemonState {
    var presentation=UserPresentationPreferences();presentation.imported=true
    var value=DaemonState(instanceID:instance,build:"isolated",initialized:true,revision:revision,settings:MachineSettings(),presentation:presentation,snapshot:nil,status:.ready,indicators:MonitorIndicatorState(),authorizationState:.unavailable,providerHealth:[:],budget:LookupBudget(),nextProvider:.ipWhois,cooldowns:[:],hasIPinfoToken:false)
    var routing=MimoRoutingState();routing.configuration.mode=mode;routing.phase = .active;routing.effectiveMode=mode;routing.reason=reason;value.routing=routing
    var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any];object["stateSequence"]=sequence
    return try JSONDecoder().decode(DaemonState.self,from:JSONSerialization.data(withJSONObject:object))
}
@MainActor private func fixture() throws -> PublicIPMonitor {
    RapidTransport.shared=RapidTransport()
    let monitor=PublicIPMonitor(subscribe:{_ in {}},readStatus:{_,_,_ in throw DaemonFailure.unavailable},readDeactivation:{false})
    monitor.receive(try state());return monitor
}
@MainActor private func modeRequest(_ monitor:PublicIPMonitor,_ mode:ProxyMode) throws -> DaemonRequest {
    var request=DaemonRequest(.configureRouting);var routing=monitor.routingState.configuration;routing.mode=mode;request.routing=routing
    var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any];object["requestedMode"]=mode.rawValue
    return try JSONDecoder().decode(DaemonRequest.self,from:JSONSerialization.data(withJSONObject:object))
}
@main private struct RapidStateTests {
    struct Result:Codable { let name:String;let passed:Bool;let failures:[String] }
    @MainActor static func main() async throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);var results:[Result]=[]
        let cases:[(String,@MainActor () async throws -> Void)] = [
            ("mode-intents-stamp-issuance-and-independent-streams",{
                let first=try fixture();defer{RapidTransport.shared.finish()}
                first.setMode(.global);first.setMode(.direct);await settle()
                try check(RapidTransport.shared.requests.count==2,"Rapid issued clicks did not both reach transport")
                func stamp(_ request:DaemonRequest) throws -> (String,UInt64)? {
                    let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any]
                    guard let intent=object["modeIntent"] as? [String:Any],let stream=intent["stream"] as? String,let sequence=intent["sequence"] as? NSNumber else{return nil}
                    return(stream,sequence.uint64Value)
                }
                let a=try stamp(RapidTransport.shared.requests[0]);let b=try stamp(RapidTransport.shared.requests[1])
                RapidTransport.shared.finish();await settle()
                let second=try fixture();second.setMode(.global);await settle()
                let c=try stamp(RapidTransport.shared.requests[0])
                try check(a != nil && b != nil && c != nil,"GUI mode request lacked issued-order stamp")
                try check(a!.0==b!.0 && a!.1>0 && b!.1>a!.1 && c!.0 != a!.0,"GUI issuance ordering or stream independence was lost")
            }),
            ("same-window-latest-mode-reaches-core",{
                let m=try fixture();defer{RapidTransport.shared.finish()}
                m.setMode(.global);await settle();m.setMode(.direct);await settle()
                try check(RapidTransport.shared.requests.count==2,"Second mode click was dropped while first RPC waited")
                let payload=try JSONSerialization.jsonObject(with:JSONEncoder().encode(RapidTransport.shared.requests[1])) as! [String:Any]
                try check(payload["requestedMode"] as? String == "direct","Mode button did not send an explicit narrow intent")
            }),
            ("mode-busy-lasts-until-last-reply",{
                let m=try fixture();defer{RapidTransport.shared.finish()}
                m.setMode(.global);await settle();m.setMode(.direct);await settle()
                try check(RapidTransport.shared.requests.count==2,"Two pending RPCs were not admitted")
                RapidTransport.shared.reply(0,outcome:.superseded);await settle()
                try check(m.isChangingSettings && !m.canChangeSharedSettings && m.rapidModeGate,"First reply prematurely cleared busy state or disabled remaining mode intents")
                RapidTransport.shared.reply(1,outcome:.applied);await settle()
                try check(!m.isChangingSettings && m.canChangeSharedSettings,"Final reply did not release editing")
            }),
            ("non-mode-and-service-operations-remain-serialized",{
                let m=try fixture();defer{RapidTransport.shared.finish()}
                var request=DaemonRequest(.configure);request.settings=m.daemonState!.settings
                let edit=Task{@MainActor in await m.rapidChange(request)};await settle();m.setMode(.global);await settle()
                try check(RapidTransport.shared.requests.count==1 && !m.rapidModeGate,"Mode overlapped non-mode write")
                RapidTransport.shared.reply(0);_ = await edit.value
                m.rapidServiceBusy(true);m.setMode(.direct);await settle()
                try check(RapidTransport.shared.requests.count==1 && !m.rapidModeGate,"Mode overlapped service operation")
                m.rapidServiceBusy(false)
            }),
            ("mode-admission-is-bounded",{
                let m=try fixture();defer{RapidTransport.shared.finish()}
                for index in 0..<40 {m.setMode(index%2==0 ? .global:.direct);await settle()}
                try check(RapidTransport.shared.requests.count==32 && !m.rapidModeGate,"Pending mode RPC capacity must be 32 without dropping earlier admitted intents")
                RapidTransport.shared.reply(0,outcome:.superseded);await settle()
                try check(m.rapidModeGate && m.isChangingSettings,"Mode capacity did not reopen after one terminal reply")
            }),
            ("ordinary-terminal-outcomes-are-not-errors",{
                let m=try fixture();defer{RapidTransport.shared.finish()}
                for outcome in [MimoControlOutcome.superseded,.cancelled] {
                    let request=try modeRequest(m,.direct);let operation=Task{@MainActor in await m.rapidChange(request)};await settle()
                    RapidTransport.shared.reply(RapidTransport.shared.requests.count-1,outcome:outcome)
                    let applied=await operation.value
                    try check(!applied && m.operationError==nil && !m.isChangingSettings,"Ordinary terminal outcome invoked success or reported failure")
                }
            }),
            ("applied-reply-with-stale-snapshot-still-succeeds",{
                let m=try fixture();defer{RapidTransport.shared.finish()};let instance=m.daemonState!.instanceID
                var request=DaemonRequest(.configure);request.settings=m.daemonState!.settings
                let operation=Task{@MainActor in await m.rapidChange(request)};await settle()
                m.receive(try state(instance,revision:6,sequence:3,reason:"new subscription"))
                RapidTransport.shared.reply(0,state:try state(instance,revision:5,sequence:2,reason:"old applied reply"),outcome:.applied)
                let applied=await operation.value
                try check(applied && m.daemonState?.revision==6 && m.routingState.reason=="new subscription","Applied acknowledgment was lost or its stale snapshot replaced newer state")
            }),
            ("delayed-lower-revision-state-is-ignored",{
                let m=try fixture();let instance=m.daemonState!.instanceID
                m.receive(try state(instance,revision:8,sequence:10,reason:"new"));m.receive(try state(instance,revision:7,sequence:11,reason:"old"))
                try check(m.daemonState?.revision==8 && m.routingState.reason=="new","Older revision overwrote newer settings")
            }),
            ("same-revision-state-sequence-orders-health",{
                let m=try fixture();let instance=m.daemonState!.instanceID
                m.receive(try state(instance,revision:4,sequence:20,reason:"fresh health"));m.receive(try state(instance,revision:4,sequence:19,reason:"stale health"))
                try check(m.routingState.reason=="fresh health","Delayed same-revision reply rolled health backward")
            }),
            ("duplicate-sequence-cannot-rewrite-state",{
                let m=try fixture();let instance=m.daemonState!.instanceID
                m.receive(try state(instance,revision:4,sequence:20,reason:"accepted"));m.receive(try state(instance,revision:4,sequence:20,reason:"duplicate mutation"))
                try check(m.routingState.reason=="accepted","Duplicate state sequence rewrote accepted content")
            }),
            ("old-rpc-error-cannot-affect-replacement-instance",{
                let m=try fixture();defer{RapidTransport.shared.finish()}
                m.setMode(.global);await settle()
                let replacement=UUID();m.receive(try state(replacement,revision:1,sequence:1,reason:"replacement ready"))
                RapidTransport.shared.fail(0);await settle()
                try check(m.daemonState?.instanceID==replacement && m.connected && m.operationError==nil,"Old control error contaminated replacement-instance state")
            }),
            ("new-instance-retires-old-instance-and-rpc",{
                let m=try fixture();defer{RapidTransport.shared.finish()};let old=m.daemonState!.instanceID
                m.setMode(.global);await settle();m.rapidAdvanceConnection()
                let replacement=UUID();m.receive(try state(replacement,revision:1,sequence:1,reason:"new instance"))
                m.receive(try state(old,revision:99,sequence:99,reason:"retired instance"))
                RapidTransport.shared.reply(0,state:try state(UUID(),revision:100,sequence:100,reason:"old connection RPC"));await settle()
                try check(m.daemonState?.instanceID==replacement && m.routingState.reason=="new instance","Retired instance or old-generation RPC overwrote replacement daemon")
            })
        ]
        let selected=Set(CommandLine.arguments.dropFirst(2));guard selected.isSubset(of:Set(cases.map{$0.0})) else{throw Failure(message:"Unknown case")}
        for(name,body) in cases where selected.isEmpty || selected.contains(name) {
            do{try await body();results.append(.init(name:name,passed:true,failures:[]));print("PASS: \(name)")}
            catch{let message=(error as? Failure)?.message ?? String(describing:type(of:error));results.append(.init(name:name,passed:false,failures:[message]));print("FAIL: \(name): \(message)")}
            RapidTransport.shared.finish();await settle()
        }
        try JSONEncoder().encode(results).write(to:output.appendingPathComponent("results.json"));print("GUI controls: \(results.filter(\.passed).count)/\(results.count) passed")
        exit(results.allSatisfy(\.passed) ? 0:1)
    }
}
