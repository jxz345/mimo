import Foundation
import Darwin

private struct EmptyCredentials: CredentialBackend {
    func read(account:String) throws -> String? {nil}
    func save(_ value:String,account:String) throws {}
    func delete(account:String) throws {}
}
private struct Failure:Error {let message:String}
private func check(_ value:Bool,_ message:String) throws {if !value{throw Failure(message:message)}}
private func result(_ value:MimoManualRefresh?) throws -> String? {
    guard let value else{return nil}
    return (try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? [String:Any])?["result"] as? String
}
private final class HeldClient:PublicIPLookupClientProtocol,@unchecked Sendable {
    private let lock=NSLock()
    private var continuations:[Int:CheckedContinuation<Void,Never>]=[:]
    private var failures:Set<Int>=[]
    private var calls=0
    private var active=0
    private var peak=0
    var count:Int{lock.withLock{calls}}
    var inFlight:Int{lock.withLock{active}}
    var maximum:Int{lock.withLock{peak}}
    func held(_ number:Int)->Bool{lock.withLock{continuations[number] != nil}}
    func release(_ number:Int,fail:Bool=false){
        let c=lock.withLock{if fail{failures.insert(number)};return continuations.removeValue(forKey:number)};c?.resume()
    }
    func releaseAll(){let ids=lock.withLock{Array(continuations.keys)};for i in ids{release(i)}}
    func lookup(configuration:LookupConfiguration) async throws ->MimoSnapshot{
        let number=lock.withLock{calls+=1;active+=1;peak=max(peak,active);return calls}
        defer{lock.withLock{active-=1}}
        await withCheckedContinuation{c in lock.withLock{continuations[number]=c}}
        try Task.checkCancellation()
        if lock.withLock({failures.contains(number)}){throw LookupError.transport("isolated fixture refusal")}
        return MimoSnapshot(ipAddress:"192.0.2.10",countryCode:"SG",countryName:"Singapore",provider:configuration.provider)
    }
    func confirmCountryChange(primaryProvider:ProviderID,ipinfoToken:String?) async throws ->MimoSnapshot{
        try await lookup(configuration:.init(provider:primaryProvider,ipinfoToken:nil))
    }
}
@MainActor private final class Fixture {
    let service:DaemonService;let client=HeldClient();let directory:URL
    var engine:MonitoringEngine{service.engine}
    init(_ root:URL,pool:[ProviderID]=[.ipWhois])throws{
        directory=root.appendingPathComponent(UUID().uuidString)
        let storage=try FilePreferenceStorage(url:directory.appendingPathComponent("state.plist"))
        let preferences=MonitoringPreferences(provider:.ipWhois,providerPool:pool,refreshInterval:.never)
        preferences.save(to:storage)
        var routing=MimoConfiguration();routing.mode = .direct
        try storage.update(["service.settings":JSONEncoder().encode(MachineSettings(preferences:preferences)),"service.routing":JSONEncoder().encode(routing),"service.revision":1])
        service=try DaemonService(storage:storage,observeSystem:false,credentials:EmptyCredentials(),client:client,authorize:{_ in true})
    }
    func startHeld() async{engine.holdForControl();engine.start();await settle()}
    func stop(){engine.stop();client.releaseAll();try? FileManager.default.removeItem(at:directory)}
}
@MainActor private func settle() async{for _ in 0..<8{await Task.yield()};try? await Task.sleep(for:.milliseconds(40))}
@MainActor private func wait(_ condition:()->Bool) async throws{
    for _ in 0..<500{if condition(){return};try await Task.sleep(for:.milliseconds(5))};throw Failure(message:"Isolated boundary was not reached")
}
@MainActor private func manual(_ f:Fixture) async{await f.engine.refresh(force:true,bypassMinimumInterval:true,trigger:.manual)}
@MainActor private func automatic(_ f:Fixture) async{await f.engine.refresh(force:true,bypassMinimumInterval:true,trigger:.settingsChanged,intent:.transition)}
@main private struct ManualDemandTests{
    struct Record:Codable{let name:String;let passed:Bool;let failures:[String]}
    @MainActor static func main() async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);var records:[Record]=[]
        let cases:[(String,@MainActor ()async throws->Void)]=[
            ("held-no-http-mode-invalidation",{
                let f=try Fixture(root);defer{f.stop()};await f.startHeld();await manual(f)
                let old=f.engine.manualRefresh!.id;try check(f.client.count==0,"Fixture already issued HTTP")
                f.engine.invalidatePendingLookup();f.engine.invalidatePendingLookup()
                try check(f.engine.manualRefresh?.pending==false && result(f.engine.manualRefresh)=="superseded","Queued ticket was not atomically superseded without HTTP")
                await automatic(f);f.engine.releaseControl();try await wait{f.client.held(1)}
                try check(f.engine.manualRefresh?.id==old && f.engine.manualRefresh?.pending==false,"New settings execution revived obsolete manual Checking")
                f.client.release(1);try await wait{!f.engine.lookupInFlight}
                try check(f.client.count==1 && f.engine.manualRefresh?.id==old,"Transition demand duplicated or manual identity changed")
            }),
            ("invalidation-without-successor-terminates",{
                let f=try Fixture(root);defer{f.stop()};await f.startHeld();await manual(f)
                f.engine.invalidatePendingLookup()
                try check(f.engine.manualRefresh?.pending==false && f.engine.manualRefresh?.finishedAt != nil,"Manual ticket needs a successor HTTP task to finish")
                f.engine.releaseControl();await settle()
                try check(f.client.count==0 && result(f.engine.manualRefresh)=="superseded","Stale deferred manual replay manufactured another lookup")
            }),
            ("stale-deferred-replay-cannot-replace-new-ticket",{
                let f=try Fixture(root);defer{f.stop()};await f.startHeld();await manual(f);let old=f.engine.manualRefresh!.id
                f.engine.releaseControl();f.engine.invalidatePendingLookup();f.engine.holdForControl();await manual(f)
                let new=f.engine.manualRefresh!.id;try check(new != old,"New generation reused obsolete ticket")
                f.engine.releaseControl();try await wait{f.client.held(1)};f.client.release(1);try await wait{!f.engine.lookupInFlight};await settle()
                try check(f.client.count==1 && f.engine.manualRefresh?.id==new && result(f.engine.manualRefresh)=="checkedAllowed","Deferred replay replaced or resurrected a manual ticket")
            }),
            ("current-ticket-joins-denied-final-lookup",{
                let f=try Fixture(root);defer{f.stop()};await f.startHeld();f.engine.invalidatePendingLookup()
                f.engine.accessBlockReason={"The observed exit IP is not approved."}
                await manual(f);let owner=f.engine.manualRefresh!.id;await automatic(f);f.engine.releaseControl()
                try await wait{f.client.held(1)};f.client.release(1);try await wait{!f.engine.lookupInFlight};await settle()
                try check(f.client.count==1 && f.engine.manualRefresh?.id==owner && !f.engine.manualRefresh!.pending,"Current manual demand was lost to settings trigger")
                try check(result(f.engine.manualRefresh)=="checkedBlocked" && f.engine.snapshot?.ipAddress=="192.0.2.10" && f.engine.pausedUntil(.ipWhois)==nil,"Denied successful result was classified as provider failure")
            }),
            ("completion-before-deferred-replay-does-not-repeat",{
                let f=try Fixture(root);defer{f.stop()};f.engine.start();try await wait{f.client.held(1)}
                f.engine.holdForControl();await manual(f);let owner=f.engine.manualRefresh!.id
                f.client.release(1);try await wait{!f.engine.lookupInFlight};try check(f.engine.manualRefresh?.pending==false,"Valid live lookup did not answer joined manual request")
                f.engine.releaseControl();await settle()
                try check(f.client.count==1 && f.engine.manualRefresh?.id==owner && result(f.engine.manualRefresh)=="checkedAllowed","Completed manual deferred demand issued a second HTTP or new ticket")
            }),
            ("current-provider-failure-keeps-provider-policy",{
                let f=try Fixture(root);defer{f.stop()};await f.startHeld();await manual(f);let owner=f.engine.manualRefresh!.id
                f.engine.releaseControl();try await wait{f.client.held(1)};f.client.release(1,fail:true);try await wait{!f.engine.lookupInFlight}
                try check(f.engine.manualRefresh?.id==owner && !f.engine.manualRefresh!.pending && f.engine.pausedUntil(.ipWhois) != nil,"Real provider failure lost its terminal result or existing pause policy")
                try check(result(f.engine.manualRefresh)=="providerFailed","Real provider failure lacks a structured distinct result")
            }),
            ("sustained-demand-one-active-one-pending",{
                let f=try Fixture(root);defer{f.stop()};f.engine.start();try await wait{f.client.held(1)}
                f.engine.holdForControl();await manual(f);f.engine.invalidatePendingLookup()
                for _ in 0..<100{await manual(f);await automatic(f)}
                let owner=f.engine.manualRefresh!.id;f.engine.releaseControl();await settle()
                try check(f.client.count==1 && f.client.maximum==1,"New demand overlapped cancelled physical execution")
                f.client.release(1);try await wait{f.client.held(2)};f.client.release(2);try await wait{!f.engine.lookupInFlight};await settle()
                try check(f.client.count==2 && f.client.maximum==1 && f.engine.manualRefresh?.id==owner && result(f.engine.manualRefresh)=="checkedAllowed","Burst did not consume exactly one owned follow-up")
            }),
            ("daemon-cancelled-refresh-does-not-admit-or-throttle",{
                let f=try Fixture(root);defer{f.stop()};await f.startHeld();f.engine.invalidatePendingLookup()
                let task=Task{@MainActor in await f.service.handle(DaemonRequest(.refresh),uid:501)}
                task.cancel();let cancelled=await task.value;await settle()
                let reply=try JSONSerialization.jsonObject(with:JSONEncoder().encode(cancelled)) as! [String:Any]
                try check(f.engine.manualRefresh==nil && reply["controlOutcome"] as? String == "cancelled","Cancelled daemon caller admitted a new ticket or lacked ordinary cancellation")
                _ = await f.service.handle(DaemonRequest(.refresh),uid:501);await settle()
                try check(f.engine.manualRefresh?.pending==true,"Cancelled daemon request consumed the live caller's admission timing")
                f.engine.releaseControl();try await wait{f.client.held(1)};f.client.release(1);try await wait{!f.engine.lookupInFlight}
                try check(f.client.count==1 && result(f.engine.manualRefresh)=="checkedAllowed","Current daemon caller did not own exactly one request")
            }),
            ("immediate-transition-demand-survives-later-retry-deadline",{
                let f=try Fixture(root);defer{f.stop()};f.engine.start();try await wait{f.client.held(1)}
                await automatic(f)
                f.client.release(1,fail:true)
                try await wait{f.client.held(2)}
                f.client.release(2);try await wait{!f.engine.lookupInFlight};await settle()
                try check(f.client.count==2 && f.client.maximum==1 && f.engine.snapshot != nil,"A later retry postponed or duplicated the already-immediate transition")
            }),
            ("automatic-provider-fallback-retains-failed-provider-backoff",{
                let f=try Fixture(root,pool:[.ipWhois,.ipapiCo]);defer{f.stop()};await f.startHeld();await manual(f)
                let owner=f.engine.manualRefresh!.id;f.engine.releaseControl();try await wait{f.client.held(1)}
                f.client.release(1,fail:true);try await wait{f.client.held(2)}
                try check(f.engine.manualRefresh?.id==owner && f.engine.manualRefresh?.pending==true,"Fallback finished or replaced the shared ticket prematurely")
                try check(f.engine.pausedUntil(.ipWhois) != nil,"Automatic rotation cleared the preceding provider's backoff")
                f.client.release(2,fail:true);try await wait{!f.engine.lookupInFlight};await settle()
                try check(f.client.count==2 && f.engine.pausedUntil(.ipWhois) != nil && f.engine.pausedUntil(.ipapiCo) != nil,"Automatic fallback reused explicit-user retry authority and repeated a failed provider")
                try check(f.engine.manualRefresh?.id==owner && !f.engine.manualRefresh!.pending && result(f.engine.manualRefresh)=="providerFailed","Exhausted fallback did not finish the same ticket exactly once")
            }),
            ("cancelled-caller-before-held-admission-is-noop",{
                let f=try Fixture(root);defer{f.stop()};await f.startHeld();f.engine.invalidatePendingLookup()
                let task=Task{@MainActor in await manual(f)};task.cancel();await task.value
                try check(f.engine.manualRefresh==nil,"Cancelled caller created shared feedback before admission")
                f.engine.releaseControl();await settle();try check(f.client.count==0,"Cancelled caller left deferred HTTP demand")
            })
        ]
        let selected=Set(CommandLine.arguments.dropFirst(2));guard selected.isSubset(of:Set(cases.map{$0.0}))else{throw Failure(message:"Unknown case")}
        for(name,body) in cases where selected.isEmpty || selected.contains(name){
            do{try await body();records.append(.init(name:name,passed:true,failures:[]));print("PASS: \(name)")}
            catch{let message=(error as? Failure)?.message ?? String(describing:type(of:error));records.append(.init(name:name,passed:false,failures:[message]));print("FAIL: \(name): \(message)")}
            await settle()
        }
        try JSONEncoder().encode(records).write(to:root.appendingPathComponent("results.json"));print("Manual demand: \(records.filter(\.passed).count)/\(records.count) passed")
        exit(records.allSatisfy(\.passed) ? 0:1)
    }
}
