import Foundation
import Darwin

private struct NoCredentials: CredentialBackend {
    func read(account: String) throws -> String? { nil }
    func save(_ value: String, account: String) throws { }
    func delete(account: String) throws { }
}

private struct LogRow: Decodable, Sendable {
    let event: String
    let fields: [String: String]
}

private func rows() -> [LogRow] {
    RuntimeLog.shared.recentDiagnosticRecords().compactMap {
        try? JSONDecoder().decode(LogRow.self, from: Data($0.utf8))
    }
}

private final class HeldClient: PublicIPLookupClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var nextHeld = true
    private var failure = false
    private var captured: LookupConfiguration?
    private var cancellationRows: [LogRow] = []
    private var cancellations = 0
    var held: LookupConfiguration? { lock.withLock { captured } }
    var atCancellation: [LogRow] { lock.withLock { cancellationRows } }
    var cancellationCount: Int { lock.withLock { cancellations } }
    func holdNext() { lock.withLock { nextHeld = true; captured = nil; cancellationRows = []; cancellations = 0 } }
    func succeedImmediately() { lock.withLock { nextHeld = false } }
    func failNext() { lock.withLock { nextHeld = false; failure = true } }
    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        let (hold, fail) = lock.withLock {
            let result = (nextHeld, failure)
            nextHeld = false; failure = false
            if result.0 { captured = configuration }
            return result
        }
        if fail { throw LookupError.transport("isolated provider failure") }
        if hold {
            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(10))
            } onCancel: {
                // Synchronous cancellation handler: the initiating record must
                // already exist before URLSession-like cancellation begins.
                let observed = rows()
                self.lock.withLock { self.cancellationRows = observed; self.cancellations += 1 }
            }
        }
        return MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: configuration.provider)
    }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
        try await lookup(configuration: .init(provider: primaryProvider, ipinfoToken: nil))
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let file: URL
    let storage: FilePreferenceStorage
    let client = HeldClient()
    let service: DaemonService
    let proxyID: UUID
    let configuration: MimoConfiguration
    var engine: MonitoringEngine { service.engine }
    init(root: URL) throws {
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        file = directory.appendingPathComponent("state.plist")
        storage = try FilePreferenceStorage(url: file)
        let preferences = MonitoringPreferences(provider: .ipWhois, providerPool: [.ipWhois], refreshInterval: .never)
        preferences.save(to: storage)
        let entry = MimoSavedProxy(proxy: MimoProxy(.init(name: "private-fixture-name", type: .socks5,
            server: "192.0.2.2", port: 1080, username: "private-fixture-user", password: "private-fixture-password")), hasPassword: true)
        proxyID = entry.id
        var routing = MimoConfiguration(); routing.mode = .rule; routing.proxies = [entry]; routing.activeProxyID = entry.id
        routing = try routing.validated(); configuration = routing
        try storage.update(["service.settings": JSONEncoder().encode(MachineSettings(preferences: preferences)),
                            "service.routing": JSONEncoder().encode(routing), "service.revision": 42])
        service = try DaemonService(storage: storage, observeSystem: false, credentials: NoCredentials(),
                                    client: client, authorize: { $0 == Data("authorized".utf8) })
    }
    func begin() async throws { engine.start(); try await wait { self.client.held != nil } }
    func close() { service.stop(); try? FileManager.default.removeItem(at: directory) }
    func request(_ command: DaemonCommand) -> DaemonRequest {
        var request = DaemonRequest(command); request.authorization = Data("authorized".utf8)
        request.expectedRevision = service.state(for: 501).revision
        switch command {
        case .configureRouting:
            var next = configuration; next.mode = .direct; request.routing = next
        case .selectProxy: request.proxyID = nil
        case .removeProxy: request.proxyID = proxyID
        case .saveProxy:
            var proxy = configuration.proxy!; proxy.port += 1; request.proxy = proxy; request.proxyID = proxyID
        default: break
        }
        return request
    }
}

@MainActor
private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestFailure(message: "isolated lookup did not reach the expected boundary")
}

private struct TestFailure: Error { let message: String }
private struct Result: Codable { let name: String; let passed: Bool; let failures: [String] }

@main
private struct CancellationDiagnosticsTests {
    @MainActor
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var results: [Result] = []
        let scenarios = ["generic", "provider_changed", "duplicate", "idle", "completed", "fresh_recovery", "provider_failure",
                         "configureRouting", "selectProxy", "removeProxy", "saveProxy", "unauthorized", "invalid", "storage_failure", "no_op"]
        for name in scenarios {
            var failures: [String] = []
            func expect(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
            do {
                let fixture = try Fixture(root: output)
                defer { fixture.close() }
                let baseline = rows().count
                if name == "idle" {
                    fixture.engine.invalidatePendingLookup()
                    expect(rows().dropFirst(baseline).allSatisfy { $0.event != "lookup_cancellation_requested" }, "idle invalidation claimed active cancellation")
                } else if name == "completed" || name == "provider_failure" {
                    if name == "completed" { fixture.client.succeedImmediately() } else { fixture.client.failNext() }
                    fixture.engine.start()
                    try await wait { !fixture.engine.lookupInFlight && fixture.engine.status != .idle }
                    let before = rows().count
                    fixture.engine.invalidatePendingLookup()
                    expect(rows().dropFirst(before).allSatisfy { $0.event != "lookup_cancellation_requested" }, "finished lookup claimed active cancellation")
                    if name == "provider_failure" { expect(fixture.engine.pausedUntil(.ipWhois) != nil, "genuine provider failure stopped creating its normal pause") }
                } else {
                    try await fixture.begin()
                    let lookup = fixture.client.held!.lookupID!.uuidString
                    let expectedRevision = String(fixture.service.state(for: 501).revision + 1)
                    if ["unauthorized", "invalid", "no_op"].contains(name) {
                        var request = fixture.request(.configureRouting)
                        if name == "unauthorized" { request.authorization = nil }
                        if name == "invalid" { request.routing = nil }
                        if name == "no_op" { request.routing = fixture.configuration }
                        let response = await fixture.service.handle(request, uid: 501)
                        expect(response.failure == (name == "unauthorized" ? .unauthorized : name == "invalid" ? .invalidRequest : nil), "wrong validation result")
                        expect(fixture.client.cancellationCount == 0, "rejected/no-op request cancelled a lookup")
                        expect(rows().dropFirst(baseline).allSatisfy { $0.event != "mimo_routing_configuration_committed" }, "rejected/no-op request claimed routing commit")
                    } else {
                        let command = DaemonCommand(rawValue: name)
                        if command != nil || name == "storage_failure" {
                            if name == "storage_failure" {
                                try FileManager.default.moveItem(at: fixture.file, to: fixture.directory.appendingPathComponent("original.plist"))
                                try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
                            }
                            let response = await fixture.service.handle(fixture.request(command ?? .configureRouting), uid: 501)
                            expect(response.failure == (name == "storage_failure" ? .storage : nil), "unexpected routing persistence result")
                        } else {
                            if name == "provider_changed" {
                                var preferences = fixture.engine.preferences
                                preferences.provider = .ipapiCo; preferences.providerPool = [.ipapiCo]
                                fixture.engine.apply(preferences, requestRefresh: false)
                            }
                            fixture.engine.invalidatePendingLookup()
                            if name == "duplicate" { fixture.engine.invalidatePendingLookup() }
                        }
                        try await wait { fixture.client.cancellationCount == 1 }
                        let initiated = fixture.client.atCancellation.filter { $0.event == "lookup_cancellation_requested" && $0.fields["lookup"] == lookup }
                        expect(initiated.count == 1, "exact active lookup cancellation was not logged before its cancellation handler")
                        if let event = initiated.first {
                            let fields = event.fields
                            expect(fields["provider"] == "ipWhois", "cancellation attributed to preferences instead of the actual active provider")
                            expect(fields["lookup_generation"] == fields["lifecycle_before"], "initial cancellation used the wrong lookup lifecycle")
                            expect(Int(fields["lifecycle_after"] ?? "") == (Int(fields["lifecycle_before"] ?? "") ?? -2) + 1, "lifecycle invalidation was not recorded accurately")
                            expect(fields["already_cancelled"] == "false", "initial cancellation was marked duplicate")
                            let allowed = Set(["lookup", "provider", "lookup_generation", "lifecycle_before", "lifecycle_after", "already_cancelled", "cause", "request", "command", "intended_mode", "intended_revision", "pid", "processRole", "recordSequence"])
                            expect(Set(fields.keys).isSubset(of: allowed), "cancellation exposed unexpected fields")
                            expect(!fields.values.contains(where: { $0.contains("private-fixture") }), "cancellation exposed fixture credentials or metadata")
                            if command != nil || name == "storage_failure" {
                                let actualCommand = command ?? .configureRouting
                                let expectedMode = actualCommand == .saveProxy ? "rule" : "direct"
                                expect(fields["cause"] == "routing_configuration" && fields["command"] == actualCommand.rawValue, "wrong cancellation cause/command")
                                expect(UUID(uuidString: fields["request"] ?? "") != nil && fields["intended_mode"] == expectedMode && fields["intended_revision"] == expectedRevision, "missing validated routing request identity")
                                let commits = rows().filter { $0.event == "mimo_routing_configuration_committed" && $0.fields["request"] == fields["request"] }
                                if name == "storage_failure" { expect(commits.isEmpty, "failed persistence claimed a committed mode") }
                                else {
                                    expect(commits.count == 1 && commits[0].fields["mode"] == expectedMode && commits[0].fields["revision"] == expectedRevision && commits[0].fields["command"] == actualCommand.rawValue, "cancellation lacks an exact successful routing commit")
                                    expect(fixture.client.atCancellation.allSatisfy { $0.event != "mimo_routing_configuration_committed" || $0.fields["request"] != fields["request"] }, "commit was claimed before cancellation/persistence")
                                }
                            } else {
                                expect(fields["cause"] == "invalidated" && fields["request"] == nil && fields["intended_mode"] == nil, "generic invalidation invented a routing request")
                            }
                        }
                        if name == "duplicate" {
                            let all = rows().filter { $0.event == "lookup_cancellation_requested" && $0.fields["lookup"] == lookup }
                            expect(all.count == 2 && all.last?.fields["already_cancelled"] == "true", "duplicate cancellation was not distinguished")
                        }
                        try await wait { !fixture.engine.lookupInFlight }
                        expect(fixture.engine.pausedUntil(.ipWhois) == nil, "cancelled lookup created a provider cooldown")
                        if name == "fresh_recovery" {
                            await fixture.engine.refresh(force: true, bypassMinimumInterval: true)
                            expect(fixture.engine.status == .ready, "cancellation diagnostics changed fresh lookup recovery")
                        }
                    }
                }
            } catch { failures.append((error as? TestFailure)?.message ?? String(describing: type(of: error))) }
            results.append(Result(name: name, passed: failures.isEmpty, failures: failures))
            print("\(failures.isEmpty ? "PASS" : "FAIL"): \(name)\(failures.isEmpty ? "" : " — " + failures.joined(separator: "; "))")
        }
        try JSONEncoder().encode(results).write(to: output.appendingPathComponent("results.json"))
        print("\(results.filter(\.passed).count)/\(results.count) cancellation diagnostic controls passed")
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }
}
