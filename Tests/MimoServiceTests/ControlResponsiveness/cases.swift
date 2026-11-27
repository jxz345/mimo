import Foundation
import Darwin

@MainActor
final class ControlRuntime {
    static var shared = ControlRuntime()
    var maintenanceActive = false
    var networkReleaseRequested = false
    var protectedDNSConfigurationMatches = true
    var closed = true
    var gateState: String? = "blocked"
    var nativeReleaseIssue: String?
    var loadedReceipt: Data?
    var events: [String] = []
    var flags = MimoServicePreferences()
    var releaseDelay: TimeInterval = 0.2
    var releaseStarted: DispatchSemaphore?
    var failure: String?
    var physicalReleaseFinished = false
    var restoreCalls = 0
    let healthDate = Date(timeIntervalSince1970: 1_700_000_000)
    func savedAllowlist() throws -> AllowedIPList { .init(addresses: ["203.0.113.10"]) }
    func acceptBaseline(_ receipt: MimoReadinessReceipt) throws { loadedReceipt = receipt.profileDigest }
    func confirmReadiness(_ receipt: MimoReadinessReceipt) throws { }
    // Isolate external readiness facts while preserving each current async call
    // signature. Physical queue/lease ownership is exercised by separate tests.
    func confirmReadinessOnline(_ receipt: MimoReadinessReceipt, lease: MimoProtectedLease) async throws {
        try lease.check(); try confirmReadiness(receipt)
    }
    func acceptBaselineOnline(_ receipt: MimoReadinessReceipt, lease: MimoProtectedLease) async throws {
        try lease.check(); try acceptBaseline(receipt)
    }
    func openGateOnline(receipt: MimoReadinessReceipt, address: String, lease: MimoProtectedLease,
                        fence: MimoPowerFence, powerEpoch: UInt64) async throws {
        try lease.check()
        try fence.completeCycle(epoch: powerEpoch) { try openGate(receipt: receipt) }
    }
    func holdApplicationGateOnline() async throws { try holdApplicationGate() }
    func receiptMatchesLoadedProfile(_ receipt: MimoReadinessReceipt) -> Bool { loadedReceipt == receipt.profileDigest }
    func restoreDirect() throws {
        restoreCalls += 1; releaseStarted?.signal(); Thread.sleep(forTimeInterval:releaseDelay)
        physicalReleaseFinished = true; events.append("released"); loadedReceipt = nil; closed = false; gateState = "direct"
    }
    func restoreDirectOnline() async throws {
        restoreCalls += 1; loadedReceipt = nil
        let delay = releaseDelay, started = releaseStarted
        let worker = MimoBlockingWorkQueue("test.direct-external-boundary")
        _ = await worker.run { started?.signal(); Thread.sleep(forTimeInterval:delay); return true }
        physicalReleaseFinished = true; events.append("released")
        if let failure {
            closed = failure != "invalid"; gateState = closed ? "blocked" : nil
            throw MimoRuntimeError.unavailable("Injected owned child failure")
        }
        closed = false; gateState = "direct"
    }
    func holdApplicationGate() throws { closed = true; gateState = "blocked"; events.append("hold") }
    func disconnectFlows() throws { events.append("disconnect") }
    func closeGate(endpoints: [String] = [], proxyPort: Int? = nil) throws { closed = true; gateState = "blocked"; events.append("close") }
    func revokeBaseline() { loadedReceipt = nil }
    func openGate(receipt: MimoReadinessReceipt) throws { closed = false; gateState = "active"; events.append("open") }
    func infrastructureStatus(generation: UInt64? = nil) -> MimoInfrastructureStatus { .init(pf: .healthy, launchd: .healthy, checkedAt: healthDate) }
    func servicePreferences() throws -> MimoServicePreferences { flags }
    func saveServicePreferences(_ value: MimoServicePreferences) throws { flags = value; networkReleaseRequested = value.releaseNetwork == true }
    func persistDirectRecovery() throws -> MimoConfiguration { MimoConfiguration() }
    func releaseNetworking() async throws { events.append("stop"); loadedReceipt = nil; closed = false; gateState = "released" }
}

func waitForStart(_ latch: DispatchSemaphore) -> Bool { latch.wait(timeout: .now()+10) == .success }
struct NoCredentials: CredentialBackend {
    func read(account: String) throws -> String? { nil }
    func save(_ value: String, account: String) throws { }
    func delete(account: String) throws { }
}
struct ResponsivenessResult: Codable {
    let mode: String, family: String, scenario: String
    let passed: Bool, statusReplied: Bool, physicalJoined: Bool, ownershipPreserved: Bool
    let statusSeconds: Double
    let events: [String]
}

@main
struct ControlResponsivenessTests {
    @MainActor
    static func main() async throws {
        let destination = URL(fileURLWithPath:CommandLine.arguments[1])
        let selected = ProcessInfo.processInfo.environment["MIMO_RESPONSIVENESS_CASES"]
        let scenarios = ["fast", "slow", "queued-direct", "queued-protected", "queued-stop", "caller-cancelled",
                         "helper-failure", "helper-timeout", "helper-invalid", "helper-readback", "held-power-fence", "stale-infrastructure-error", "stop-held-power"]
        var rows: [ResponsivenessResult] = []
        for mode in [ProxyMode.rule, .global] { for family in [MimoNetworkFamily.ipv4, .dual] {
            for scenario in scenarios where selected == nil || selected == scenario {
                ControlRuntime.shared = ControlRuntime()
                let runtime = ControlRuntime.shared, supervisor = MimoSupervisor()
                runtime.releaseDelay = (scenario == "slow" || scenario == "helper-invalid") ? 4.2 : scenario == "fast" ? 0.02 : 0.2
                runtime.failure = scenario.hasPrefix("helper-") ? String(scenario.dropFirst(7)) : nil
                var configuration = MimoConfiguration(); configuration.mode = mode; configuration.networkFamily = family
                configuration.proxy = MimoProxy(ClashProxySettings(name:"Isolated", type:.socks5, server:"192.0.2.1", port:1080))
                let receipt = MimoReadinessReceipt(process:1, profileDigest:Data("isolated".utf8), checkedAt:.now)
                let initialToken = try supervisor.qualificationPrepare(configuration, readiness:Task { receipt }, receipt:receipt)
                if scenario == "stop-held-power" {
                    let snapshot = MimoSnapshot(ipAddress:"203.0.113.10", countryCode:"SG", countryName:"Test", provider:.ipWhois)
                    var message = MimoSupervisorRequest(.approve); message.verification = initialToken; message.address = snapshot.ipAddress
                    message.exitObservations = MimoExitObservations(verification:initialToken, ipv4:snapshot)
                    var command = DaemonRequest(.supervisor); command.supervisor = message
                    let approved = await supervisor.handle(command,uid:0,pid:getpid()+100)
                    precondition(approved.routing?.phase == .active)
                    runtime.events.removeAll()
                }
                let beforeGeneration = supervisor.qualificationGeneration
                let store = try FilePreferenceStorage(url:destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".plist"))
                let service = try DaemonService(storage:store, observeSystem:false, credentials:NoCredentials())
                let listener = NSXPCListener.anonymous(); listener.delegate = service; listener.resume()
                let endpoint = listener.endpoint
                let supervisorListener = NSXPCListener.anonymous(); supervisorListener.delegate = supervisor; supervisorListener.resume()
                let supervisorEndpoint = supervisorListener.endpoint
                let started = DispatchSemaphore(value:0); runtime.releaseStarted = started
                var heldFence: Task<Void, Never>?
                if scenario == "held-power-fence" || scenario == "stop-held-power" {
                    let fence = supervisor.qualificationPowerFence
                    let admitted = DispatchSemaphore(value:0)
                    heldFence = Task.detached {
                        _ = try? fence.sleep { admitted.signal(); Thread.sleep(forTimeInterval:4.2) }
                    }
                    let admittedTask = Task.detached { waitForStart(admitted) }
                    let lockHeld = await admittedTask.value
                    precondition(lockHeld)
                }
                // The RPC deadline is the production GUI deadline, on the real
                // XPC transport. A stalled actor cannot delay its timeout timer.
                let probe = Task.detached { () -> (Bool,Double) in
                    if scenario != "held-power-fence" && scenario != "stop-held-power" {
                        guard waitForStart(started) else { return (false,-1) }
                    } else { try? await Task.sleep(for:.milliseconds(40)) }
                    let start = Date()
                    do {
                        let result = try await DaemonRPC.call(DaemonRequest(.state),connection:NSXPCConnection(listenerEndpoint:endpoint),timeout:3)
                        var state = DaemonRequest(.supervisor); state.supervisor = MimoSupervisorRequest(.state)
                        let status = try await DaemonRPC.call(state,connection:NSXPCConnection(listenerEndpoint:supervisorEndpoint),timeout:3)
                        state.supervisor?.includeEvents = true
                        let events = try await DaemonRPC.call(state,connection:NSXPCConnection(listenerEndpoint:supervisorEndpoint),timeout:3)
                        var heartbeat = DaemonRequest(.supervisor); heartbeat.supervisor = MimoSupervisorRequest(.heartbeat)
                        let heart = await supervisor.handle(heartbeat,uid:0,pid:getpid()+100)
                        let healthUnchanged = status.routing?.infrastructure?.checkedAt == Date(timeIntervalSince1970:1_700_000_000)
                        let available = result.state != nil && status.routing != nil && events.failure == nil && heart.routing != nil
                        return (available && healthUnchanged,Date().timeIntervalSince(start))
                    } catch { return (false,Date().timeIntervalSince(start)) }
                }
                var direct = configuration; direct.mode = .direct
                func request(_ message: MimoSupervisorRequest) -> DaemonRequest {
                    var result = DaemonRequest(.supervisor); result.supervisor = message; return result
                }
                var directMessage = MimoSupervisorRequest(.direct); directMessage.configuration = direct
                var stopMessage = MimoSupervisorRequest(.service); stopMessage.service = .mihomo; stopMessage.operation = .stop
                let operation = Task {
                    await supervisor.handle(request(scenario == "stop-held-power" ? stopMessage : directMessage),uid:0,pid:getpid()+100)
                }
                var follower: Task<DaemonResponse,Never>?
                if scenario.hasPrefix("queued-") || scenario == "caller-cancelled" || scenario == "stale-infrastructure-error" {
                    for _ in 0..<1000 {
                        if supervisor.qualificationState.phase == .restoringDirect { break }
                        try await Task.sleep(for:.milliseconds(1))
                    }
                    if scenario == "caller-cancelled" { operation.cancel() }
                    else if scenario == "stale-infrastructure-error" { supervisor.qualificationOldInfrastructureFailure(beforeGeneration) }
                    else {
                        var next = scenario == "queued-direct" ? directMessage : scenario == "queued-stop" ? stopMessage : MimoSupervisorRequest(.close)
                        next.reason = "New protected intent"
                        let queued = next
                        follower = Task { await supervisor.handle(request(queued),uid:0,pid:getpid()+100) }
                    }
                }
                let response = await operation.value
                let finalResponse = await follower?.value ?? response
                await heldFence?.value
                let (replied,seconds) = await probe.value
                var stateMessage = MimoSupervisorRequest(.state)
                stateMessage.includeEvents = true
                let eventResponse = try await DaemonRPC.call(request(stateMessage),connection:NSXPCConnection(listenerEndpoint:supervisorEndpoint),timeout:3)
                let noUnexpectedReceipt = runtime.loadedReceipt == nil || scenario == "stop-held-power"
                let physical = runtime.physicalReleaseFinished || scenario == "stop-held-power"
                let writes = runtime.events.filter { $0 != "native observer endpoint cleared" }
                let ordered: Bool
                if scenario == "queued-protected" { ordered = writes.first == "released" && runtime.closed && finalResponse.routing?.phase == .blocked }
                else if scenario == "queued-stop" { ordered = writes == ["released", "stop"] && runtime.gateState == "released" }
                else if scenario.hasPrefix("helper-") { ordered = finalResponse.routing?.phase == (scenario == "helper-invalid" ? .unavailable : .blocked) }
                else { ordered = finalResponse.routing?.phase == .active && (scenario == "stop-held-power" || runtime.restoreCalls == 1) }
                let stateProof = eventResponse.failure == nil && noUnexpectedReceipt
                let row = ResponsivenessResult(mode:mode.rawValue, family:family.rawValue, scenario:scenario,
                    passed:replied && physical && ordered && stateProof, statusReplied:replied,
                    physicalJoined:physical, ownershipPreserved:ordered && stateProof, statusSeconds:seconds, events:runtime.events)
                rows.append(row); print(String(data:try JSONEncoder().encode(row),encoding:.utf8)!)
                listener.invalidate(); supervisorListener.invalidate()
            }
        } }
        try JSONEncoder().encode(rows).write(to:destination)
        let passed = rows.filter(\.passed).count
        print("RESULT \(passed)/\(rows.count) pass")
        exit(passed == rows.count ? 0 : 1)
    }
}
