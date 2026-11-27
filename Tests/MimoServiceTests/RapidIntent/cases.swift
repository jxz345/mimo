import Foundation
import Darwin

private struct EmptyCredentials: CredentialBackend {
    func read(account: String) throws -> String? { nil }
    func save(_ value: String, account: String) throws { }
    func delete(account: String) throws { }
}
private struct Failure: Error { let message: String }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
private struct LogRow: Decodable { let event: String; let level: String; let fields: [String: String] }
private func logs() -> [LogRow] { RuntimeLog.shared.recentDiagnosticRecords().compactMap { try? JSONDecoder().decode(LogRow.self, from: Data($0.utf8)) } }
private func outcome(_ reply: DaemonResponse) throws -> String? {
    (try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])?["controlOutcome"] as? String
}
private final class HeldClient: PublicIPLookupClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var cancellationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var holdSecond = false
    private var secondContinuation: CheckedContinuation<Void, Never>?
    var secondHeld: Bool { lock.withLock { secondContinuation != nil } }
    func releaseSecond() { let c=lock.withLock { let value=secondContinuation;secondContinuation=nil;return value };c?.resume() }
    var count: Int { lock.withLock { calls } }
    var cancelled: Int { lock.withLock { cancellationCount } }
    var isHeld: Bool { lock.withLock { continuation != nil } }
    func release() {
        let pending = lock.withLock { released = true; let old = continuation; continuation = nil; return old }
        pending?.resume()
    }
    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        let number = lock.withLock { calls += 1; return calls }
        if number == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { c in
                    let immediate = lock.withLock { if released { return true }; continuation = c; return false }
                    if immediate { c.resume() }
                }
            } onCancel: { self.lock.withLock { self.cancellationCount += 1 } }
            try Task.checkCancellation()
        }
        if number == 2 && holdSecond { await withCheckedContinuation { c in lock.withLock { secondContinuation=c } } }
        return MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: configuration.provider)
    }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
        try await lookup(configuration: .init(provider: primaryProvider, ipinfoToken: nil))
    }
}
@MainActor private final class Fixture {
    let directory: URL
    let storage: FilePreferenceStorage
    let service: DaemonService
    let client = HeldClient()
    var engine: MonitoringEngine { service.engine }
    init(root: URL, mode: ProxyMode = .rule) throws {
        directory = root.appendingPathComponent(UUID().uuidString)
        storage = try FilePreferenceStorage(url: directory.appendingPathComponent("state.plist"))
        let preferences = MonitoringPreferences(provider: .ipWhois, providerPool: [.ipWhois], refreshInterval: .never)
        preferences.save(to: storage)
        let entry = MimoSavedProxy(proxy: MimoProxy(.init(name: "isolated-proxy", type: .socks5, server: "192.0.2.2", port: 1080)), hasPassword: false)
        var routing = MimoConfiguration();routing.mode = mode;routing.proxies = [entry];routing.activeProxyID = entry.id
        try storage.update(["service.settings": JSONEncoder().encode(MachineSettings(preferences: preferences)),
                            "service.routing": JSONEncoder().encode(try routing.validated()), "service.revision": 42])
        service = try DaemonService(storage: storage, observeSystem: false, credentials: EmptyCredentials(), client: client,
                                    authorize: { $0 == Data("isolated-authorized".utf8) })
    }
    var state: DaemonState { service.state(for: 501) }
    func request(_ mode: ProxyMode) -> DaemonRequest {
        var request = DaemonRequest(.configureRouting);request.authorization = Data("isolated-authorized".utf8)
        request.expectedRevision = state.revision
        var next = state.routing!.configuration;next.mode = mode;request.routing = next;return request
    }
    func stop() { client.release();client.releaseSecond();service.rapidIntentTestHoldMutation(false);service.stop();try? FileManager.default.removeItem(at: directory) }
}
@MainActor private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<500 { if condition() { return };try await Task.sleep(for: .milliseconds(5)) }
    throw Failure(message: "Expected isolated boundary not reached")
}
@MainActor private func queued(_ fixture: Fixture, _ mode: ProxyMode, uid: uid_t = 501) async -> Task<DaemonResponse, Never> {
    let request = fixture.request(mode)
    let task = Task { @MainActor in await fixture.service.handle(request, uid: uid) }
    // Let the real handler reach its suspended admission boundary.
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(8))
    return task
}
@MainActor private func modeRun(_ root: URL, modes: [ProxyMode], users: [uid_t]) async throws {
    let f = try Fixture(root: root);defer { f.stop() };let before = f.state.revision;let start = logs().count
    f.service.rapidIntentTestHoldMutation(true)
    var tasks: [Task<DaemonResponse, Never>] = []
    for (mode, user) in zip(modes, users) { tasks.append(await queued(f, mode, uid: user)) }
    try check(f.state.revision == before, "Pending modes mutated storage before current owner released")
    f.service.rapidIntentTestHoldMutation(false)
    var replies: [DaemonResponse] = []
    for task in tasks { replies.append(await task.value) }
    try check(f.state.routing!.configuration.mode == modes.last!, "Final accepted mode was lost")
    try check(f.state.revision == before + 1, "Superseded pending modes performed intermediate persistent commits")
    let commits = logs().dropFirst(start).filter { $0.event == "mimo_routing_configuration_committed" }
    try check(commits.count == 1 && commits.first?.fields["mode"] == modes.last!.rawValue, "Superseded modes initiated routing effects")
    for reply in replies.dropLast() { try check(reply.failure == nil && outcome(reply) == "superseded", "Superseded caller lacked ordinary terminal outcome") }
    try check(replies.last!.failure == nil && outcome(replies.last!) == "applied", "Latest mode did not receive applied outcome")
}
@main private struct RapidIntentTests {
    struct Result: Codable { let name: String; let passed: Bool; let failures: [String] }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]);var results: [Result] = []
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("public-state-sequence-is-monotonic", {
                let f=try Fixture(root:root);defer{f.stop()}
                let a=f.state;let b=f.state
                let first=try JSONSerialization.jsonObject(with:JSONEncoder().encode(a)) as! [String:Any]
                let second=try JSONSerialization.jsonObject(with:JSONEncoder().encode(b)) as! [String:Any]
                let sa=(first["stateSequence"] as? NSNumber)?.uint64Value
                let sb=(second["stateSequence"] as? NSNumber)?.uint64Value
                try check(a.instanceID==b.instanceID && a.revision==b.revision && sa != nil && sb != nil && sb!>sa!,"Read-only state lacked monotonic per-instance sequence")
            }),
            ("legacy-state-request-schema-remains-readable", {
                let f=try Fixture(root:root);defer{f.stop()}
                var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(f.state)) as! [String:Any]
                value.removeValue(forKey:"stateSequence")
                let decoded=try JSONDecoder().decode(DaemonState.self,from:JSONSerialization.data(withJSONObject:value))
                var request=try JSONSerialization.jsonObject(with:JSONEncoder().encode(f.request(.direct))) as! [String:Any]
                request.removeValue(forKey:"requestedMode")
                let old=try JSONDecoder().decode(DaemonRequest.self,from:JSONSerialization.data(withJSONObject:request))
                try check(decoded.revision==f.state.revision && old.routing?.mode == .direct,"Optional protocol additions rejected legacy messages")
            }),
            ("explicit-mode-rebases-stale-family-and-proxy", {
                let f=try Fixture(root:root);defer{f.stop()}
                var stale=f.request(.global);stale.expectedRevision=f.state.revision-1
                stale.routing?.networkFamily = .dual
                stale.routing?.proxies=[];stale.routing?.activeProxyID=nil
                var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(stale)) as! [String:Any]
                object["requestedMode"]="global"
                let request=try JSONDecoder().decode(DaemonRequest.self,from:JSONSerialization.data(withJSONObject:object))
                let original=f.state.routing!.configuration
                let reply=await f.service.handle(request,uid:501)
                let final=f.state.routing!.configuration
                try check(reply.failure==nil && final.mode == .global && final.networkFamily==original.networkFamily && final.proxies==original.proxies && final.activeProxyID==original.activeProxyID,"Narrow mode intent conflicted or replaced current proxy/family")
            }),
            ("old-manual-without-new-click-terminates-on-cancellation", {
                let f=try Fixture(root:root,mode:.direct);defer{f.stop()}
                f.engine.start();try await wait{f.client.isHeld};f.engine.beginManualRefresh()
                let old=f.engine.manualRefresh!.id;f.engine.invalidatePendingLookup();f.client.release()
                try await wait{!f.engine.lookupInFlight}
                try check(f.engine.manualRefresh?.id==old && f.engine.manualRefresh?.pending==false && f.engine.manualRefresh?.phase == .failed,"Invalidated manual request without a replacement remained pending")
            }),
            ("old-cancellation-cannot-finish-new-manual-refresh", {
                let f=try Fixture(root:root,mode:.direct);defer{f.stop()};f.client.holdSecond=true
                f.engine.start();try await wait{f.client.isHeld}
                f.engine.holdForControl();f.engine.invalidatePendingLookup()
                f.engine.beginManualRefresh();let manual=f.engine.manualRefresh!.id
                await f.engine.refresh(force:true,bypassMinimumInterval:true,trigger:.manual,intent:.transition)
                f.engine.releaseControl();f.client.release();try await wait{f.client.secondHeld}
                let pending=f.engine.manualRefresh?.pending==true && f.engine.manualRefresh?.id==manual
                f.client.releaseSecond();try await wait{!f.engine.lookupInFlight}
                try check(pending,"Old transport cancellation terminated the newer manual request before its lookup finished")
                try check(f.engine.manualRefresh?.id==manual && f.engine.manualRefresh?.phase == .succeeded,"Newer manual request did not report its own successful result")
            }),
            ("pending-modes-final-direct", { try await modeRun(root, modes: [.global,.rule,.direct], users: [501,501,501]) }),
            ("pending-modes-final-global", { try await modeRun(root, modes: [.direct,.rule,.global], users: [501,501,501]) }),
            ("two-users-share-latest-pending-mode", { try await modeRun(root, modes: [.global,.direct,.global], users: [501,502,501]) }),
            ("non-mode-write-is-ordering-barrier", {
                let f = try Fixture(root: root);defer { f.stop() };let before = f.state.revision
                f.service.rapidIntentTestHoldMutation(true)
                let first = await queued(f,.global)
                var edit = DaemonRequest(.setToken);edit.authorization = Data("isolated-authorized".utf8);edit.token = "local-test-token";edit.expectedRevision = before + 1
                let barrier = Task { @MainActor in await f.service.handle(edit,uid:501) };try await Task.sleep(for:.milliseconds(15))
                let last = await queued(f,.direct)
                f.service.rapidIntentTestHoldMutation(false)
                let a=await first.value;let b=await barrier.value;let c=await last.value
                try check(a.failure == nil && b.failure == nil && c.failure == nil,"Ordered non-mode write was lost or rebased incorrectly")
                try check(f.state.revision == before + 3 && f.state.routing!.configuration.mode == .direct && f.state.hasIPinfoToken,"Mode coalescing crossed a non-mode ordering barrier")
            }),
            ("read-only-state-bypasses-held-mutation", {
                let f = try Fixture(root:root);defer { f.stop() };let before=f.state.revision
                f.service.rapidIntentTestHoldMutation(true);let pending=await queued(f,.direct)
                let started=ContinuousClock.now;let read=await f.service.handle(DaemonRequest(.state),uid:502)
                let elapsed=started.duration(to:.now)
                try check(read.failure == nil && read.state?.revision == before && elapsed < .milliseconds(100),"Read-only state waited behind pending mutation")
                f.service.rapidIntentTestHoldMutation(false);_ = await pending.value
            }),
            ("cancelled-pending-mode-is-normal-noop", {
                let f = try Fixture(root:root);defer { f.stop() };let before=f.state.revision;let start=logs().count
                f.service.rapidIntentTestHoldMutation(true);let pending=await queued(f,.global);pending.cancel()
                let reply=await pending.value;f.service.rapidIntentTestHoldMutation(false)
                try check(f.state.revision == before && f.state.routing!.configuration.mode == .rule,"Cancelled pending caller still committed")
                try check(reply.failure == nil && outcome(reply) == "cancelled","Caller cancellation was reported as infrastructure/storage failure")
                try check(!logs().dropFirst(start).contains { $0.level == "error" },"Expected cancellation emitted an error")
            }),
            ("refresh-burst-shares-active-lookup", {
                let f=try Fixture(root:root,mode:.direct);defer { f.stop() };f.engine.start();try await wait { f.client.isHeld }
                for i in 0..<20 { _ = await f.service.handle(DaemonRequest(.refresh),uid:i%2 == 0 ? 501:502) }
                try await Task.sleep(for:.milliseconds(40));try check(f.client.count==1,"Concurrent Refresh started another HTTP request")
                f.client.release();try await wait { !f.engine.lookupInFlight };try await Task.sleep(for:.milliseconds(60))
                try check(f.client.count==1 && f.engine.manualRefresh?.phase == .succeeded,"Shared active result did not complete manual feedback")
            }),
            ("cancelled-lookup-unwinds-before-one-followup", {
                let f=try Fixture(root:root,mode:.direct);defer { f.stop() };let start=logs().count
                f.engine.start();try await wait { f.client.isHeld };f.engine.holdForControl();f.engine.invalidatePendingLookup()
                for _ in 0..<20 { await f.engine.refresh(force:true,bypassMinimumInterval:true,trigger:.manual,intent:.transition) }
                f.engine.releaseControl();try await Task.sleep(for:.milliseconds(40))
                try check(f.client.count==1 && f.engine.lookupInFlight,"New lookup overlapped the cancelled transport before it joined")
                f.client.release();try await wait { f.client.count==2 && !f.engine.lookupInFlight };try await Task.sleep(for:.milliseconds(60))
                try check(f.client.count==2,"Invalidated burst created redundant follow-up lookups")
                let events=logs().dropFirst(start)
                try check(!events.contains { $0.event == "provider_failure_paused" || $0.event == "lookup_failed" },"Expected cancellation charged provider failure")
            })
        ]
        let selected = Set(CommandLine.arguments.dropFirst(2))
        guard selected.isSubset(of: Set(cases.map { $0.0 })) else { throw Failure(message: "Unknown focused case") }
        for (name,body) in cases where selected.isEmpty || selected.contains(name) {
            do { try await body();results.append(.init(name:name,passed:true,failures:[]));print("PASS: \(name)") }
            catch { let message=(error as? Failure)?.message ?? String(describing:type(of:error));results.append(.init(name:name,passed:false,failures:[message]));print("FAIL: \(name): \(message)") }
        }
        try JSONEncoder().encode(results).write(to:root.appendingPathComponent("results.json"))
        print("Rapid-intent controls: \(results.filter(\.passed).count)/\(results.count) passed")
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }
}
