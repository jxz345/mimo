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
    init(root: URL, mode: ProxyMode = .rule, withProxy: Bool = true) throws {
        directory = root.appendingPathComponent(UUID().uuidString)
        storage = try FilePreferenceStorage(url: directory.appendingPathComponent("state.plist"))
        let preferences = MonitoringPreferences(provider: .ipWhois, providerPool: [.ipWhois], refreshInterval: .never)
        preferences.save(to: storage)
        let entry = MimoSavedProxy(proxy: MimoProxy(.init(name: "isolated-proxy", type: .socks5, server: "192.0.2.2", port: 1080)), hasPassword: false)
        var routing = MimoConfiguration();routing.mode = mode;routing.proxies = withProxy ? [entry] : [];routing.activeProxyID = withProxy ? entry.id : nil
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

private func stamped(_ request: DaemonRequest, stream: UUID, sequence: UInt64) throws -> DaemonRequest {
    var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any]
    object["requestedMode"]=request.routing?.mode.rawValue
    object["modeIntent"]=["stream":stream.uuidString,"sequence":sequence]
    return try JSONDecoder().decode(DaemonRequest.self,from:JSONSerialization.data(withJSONObject:object))
}
@MainActor private func deliver(_ f: Fixture, _ mode: ProxyMode, _ stream: UUID, _ sequence: UInt64, uid: uid_t = 501) async throws -> DaemonResponse {
    await f.service.handle(try stamped(f.request(mode),stream:stream,sequence:sequence),uid:uid)
}
@MainActor private func pending(_ f: Fixture, _ mode: ProxyMode, _ stream: UUID, _ sequence: UInt64) async throws -> Task<DaemonResponse,Never> {
    let request=try stamped(f.request(mode),stream:stream,sequence:sequence)
    let task=Task { @MainActor in await f.service.handle(request,uid:501) }
    for _ in 0..<5 { await Task.yield() };try await Task.sleep(for:.milliseconds(8));return task
}
@main private struct ModeIntentOrderingTests {
    struct Result: Codable { let name: String;let passed: Bool;let failures: [String] }
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);var results:[Result]=[]
        let cases:[(String,@MainActor () async throws -> Void)] = [
            ("same-gui-reversed-delivery-keeps-newest", {
                let f=try Fixture(root:root);defer{f.stop()};let stream=UUID()
                let newer=try await deliver(f,.global,stream,2)
                let revision=f.state.revision
                let older=try await deliver(f,.direct,stream,1)
                try check(newer.failure==nil && outcome(newer)=="applied", "Newest valid intent was not applied")
                try check(older.failure==nil && outcome(older)=="superseded" && f.state.revision==revision && f.state.routing!.configuration.mode == .global, "Late older RPC replaced newer GUI mode")
            }),
            ("late-old-rpc-cannot-replace-pending-newest", {
                let f=try Fixture(root:root);defer{f.stop()};let stream=UUID();let revision=f.state.revision
                f.service.rapidIntentTestHoldMutation(true)
                let newer=try await pending(f,.global,stream,2)
                let older=try await pending(f,.direct,stream,1)
                f.service.rapidIntentTestHoldMutation(false)
                let a=await newer.value;let b=await older.value
                try check(a.failure==nil && outcome(a)=="applied" && b.failure==nil && outcome(b)=="superseded", "Stale request entered queue and superseded newer pending ticket")
                try check(f.state.routing!.configuration.mode == .global && f.state.revision==revision+1, "Pending newest mode did not commit exactly once")
            }),
            ("different-gui-streams-use-core-arrival-order", {
                let f=try Fixture(root:root);defer{f.stop()}
                _=try await deliver(f,.global,UUID(),99)
                let last=try await deliver(f,.direct,UUID(),1)
                try check(last.failure==nil && outcome(last)=="applied" && f.state.routing!.configuration.mode == .direct, "Independent GUI stream inherited another stream's sequence")
            }),
            ("different-authenticated-callers-use-independent-streams", {
                let f=try Fixture(root:root);defer{f.stop()};let stream=UUID()
                _=try await deliver(f,.global,stream,99,uid:501)
                let last=try await deliver(f,.direct,stream,1,uid:502)
                try check(last.failure==nil && outcome(last)=="applied" && f.state.routing!.configuration.mode == .direct, "Authenticated caller inherited another caller's sequence")
            }),
            ("unauthorized-intent-cannot-poison-sequence", {
                let f=try Fixture(root:root);defer{f.stop()};let stream=UUID()
                var denied=try stamped(f.request(.global),stream:stream,sequence:99);denied.authorization=nil
                let a=await f.service.handle(denied,uid:501)
                let b=try await deliver(f,.direct,stream,1)
                try check(a.failure == .unauthorized && b.failure==nil && outcome(b)=="applied", "Unauthorized request poisoned stream admission")
            }),
            ("invalid-intent-cannot-poison-sequence", {
                let f=try Fixture(root:root,mode:.direct,withProxy:false);defer{f.stop()};let stream=UUID()
                let a=try await deliver(f,.global,stream,99)
                let b=try await deliver(f,.direct,stream,1)
                let zero=try await deliver(f,.direct,UUID(),0)
                try check(a.failure == .invalidRequest && b.failure==nil && outcome(b)=="applied", "Invalid protected mode without proxy poisoned stream admission")
                try check(zero.failure == .invalidRequest, "Zero sequence was accepted as a valid issued intent")
            }),
            ("old-intent-retained-beyond-rpc-lifetime", {
                let f=try Fixture(root:root);defer{f.stop()};let stream=UUID()
                _=try await deliver(f,.global,stream,2);let revision=f.state.revision
                try await Task.sleep(for:.seconds(76))
                let old=try await deliver(f,.direct,stream,1)
                try check(old.failure==nil && outcome(old)=="superseded" && f.state.revision==revision, "Old packet revived after the 75-second RPC lifetime")
            }),
            ("stream-cap-rejects-new-without-evicting-live", {
                let f=try Fixture(root:root,mode:.direct);defer{f.stop()};let first=UUID()
                _=try await deliver(f,.direct,first,2)
                for _ in 1..<128 { let reply=try await deliver(f,.direct,UUID(),1);try check(reply.failure==nil,"Capacity rejected one of its 128 permitted streams") }
                let revision=f.state.revision
                let full=try await deliver(f,.global,UUID(),1)
                let stale=try await deliver(f,.global,first,1)
                let current=try await deliver(f,.direct,first,3)
                try check(full.failure?.rawValue == "modeIntentCapacity" && stale.failure==nil && outcome(stale)=="superseded" && current.failure==nil, "Full tracker evicted a live stream or accepted an untracked request")
                try check(f.state.revision==revision+1 && f.state.routing!.configuration.mode == .direct, "Rejected streams changed routing state")
            })
        ]
        let selected=Set(CommandLine.arguments.dropFirst(2));guard selected.isSubset(of:Set(cases.map{$0.0})) else { throw Failure(message:"Unknown focused case") }
        for (name,body) in cases where selected.isEmpty || selected.contains(name) {
            do { try await body();results.append(.init(name:name,passed:true,failures:[]));print("PASS: \(name)") }
            catch { let message=(error as? Failure)?.message ?? String(describing:type(of:error));results.append(.init(name:name,passed:false,failures:[message]));print("FAIL: \(name): \(message)") }
        }
        try JSONEncoder().encode(results).write(to:root.appendingPathComponent("results.json"))
        print("Mode-intent ordering controls: \(results.filter(\.passed).count)/\(results.count) passed")
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }
}
