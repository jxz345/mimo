import Foundation
import Darwin

@MainActor
final class ApprovalRaceRuntime {
    static var shared = ApprovalRaceRuntime()
    var maintenanceActive = false
    var networkReleaseRequested = false
    var closed = true
    var gateState: String? = "blocked"
    var nativeReleaseIssue: String?
    var loadedReceipt: Data?
    var events: [String] = []
    var holds = 0
    var baselineAttempts = 0
    var opens = 0
    var interventionApplied = false
    var holdsAtIntervention = 0
    var phaseAtIntervention = "none"
    var failReadiness = false
    func savedAllowlist() throws -> AllowedIPList { .init(addresses: ["203.0.113.10"]) }
    func acceptBaseline(_ receipt: MimoReadinessReceipt) throws {
        baselineAttempts += 1; events.append("acceptBaseline")
        // Production confirmReadiness checks DNS/loaded-receipt validity before
        // the supervisor's post-await generation check.
        guard loadedReceipt == receipt.profileDigest else {
            events.append("confirmationUnavailable")
            throw MimoRuntimeError.unavailable("The final profile, tunnel or protected DNS could not be confirmed.")
        }
    }
    func confirmReadiness(_ receipt: MimoReadinessReceipt) throws {
        if failReadiness {
            events.append("readinessFailed")
            throw MimoRuntimeError.unavailable("Owned readiness failure")
        }
        guard loadedReceipt == receipt.profileDigest else {
            throw MimoRuntimeError.unavailable("The final profile, tunnel or protected DNS could not be confirmed.")
        }
        events.append("readinessConfirmed")
    }
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
        events.append("restoreDirect"); loadedReceipt = nil; closed = false; gateState = "direct"
    }
    func restoreDirectOnline() async throws { try restoreDirect() }
    func holdApplicationGate() throws { holds += 1; closed = true; gateState = "blocked"; events.append("holdApplicationGate") }
    func disconnectFlows() throws { events.append("disconnectFlows") }
    func closeGate(endpoints: [String] = [], proxyPort: Int? = nil) throws {
        closed = true; gateState = "blocked"; events.append("closeGate")
    }
    func revokeBaseline() { events.append("revokeBaseline") }
    func openGate(receipt: MimoReadinessReceipt) throws { opens += 1; closed = false; gateState = "active"; events.append("openGate") }
    func infrastructureStatus(generation: UInt64? = nil) -> MimoInfrastructureStatus { .init(pf: .healthy, launchd: .healthy, checkedAt: .now) }
}

final class ReadinessLatch: @unchecked Sendable {
    private let lock=NSLock()
    private let release=DispatchSemaphore(value: 0)
    private var reached=false
    private(set) var returnedCancelled=false
    var waiting: Bool { lock.withLock { reached } }
    func unblock() { release.signal() }
    func run(_ receipt: MimoReadinessReceipt, cancellationAfterWait: Bool) throws -> MimoReadinessReceipt {
        // Only the detached inspection is held. The production MainActor
        // readiness wrapper, including both ownership fences, remains intact.
        if !cancellationAfterWait { try Task.checkCancellation() }
        lock.withLock { reached=true }
        guard release.wait(timeout:.now()+10) == .success else { throw CancellationError() }
        if cancellationAfterWait { try Task.checkCancellation() }
        lock.withLock { returnedCancelled=Task.isCancelled }
        return receipt
    }
}

struct ApprovalRaceResult: Codable {
    var mode: String
    var family: String
    var scenario: String
    var passed: Bool
    var phaseBeforeResume: String
    var phaseAfterResume: String
    var replacementTokenRetained: Bool
    var taskReturnedDespiteCancellation: Bool
    var gateHoldsAfterNewIntent: Int
    var baselineAttempts: Int
    var opens: Int
    var events: [String]
}

@main
struct ApprovalRaceTests {
    @MainActor
    static func main() async throws {
        var results: [ApprovalRaceResult]=[]
        for mode in [ProxyMode.rule,.global] {
            for family in [MimoNetworkFamily.ipv4,.dual] {
                for scenario in ["direct-queued-at-completion","replacement-queued-at-completion",
                                 "direct-queued-at-error-completion","replacement-queued-at-error-completion",
                                 "current-success","current-readiness-failure","cooperative-direct-cancellation"] {
                    ApprovalRaceRuntime.shared=ApprovalRaceRuntime()
                    ApprovalRaceRuntime.shared.failReadiness=scenario.contains("error-completion") || scenario=="current-readiness-failure"
                    let supervisor=MimoSupervisor()
                    var configuration=MimoConfiguration();configuration.mode=mode;configuration.networkFamily=family
                    configuration.proxy=MimoProxy(ClashProxySettings(name:"Owned fixture",type:.socks5,server:"192.0.2.1",port:1080))
                    let oldReceipt=MimoReadinessReceipt(process:101,profileDigest:Data("old".utf8),checkedAt:.now)
                    let latch=ReadinessLatch()
                    let inspection=Task.detached { try latch.run(oldReceipt,cancellationAfterWait:true) }
                    let token=try supervisor.qualificationPrepare(configuration,readiness:inspection,receipt:oldReceipt)
                    supervisor.qualificationWrapReadiness(inspection,check:token)
                    let readiness=supervisor.qualificationReadinessTask!
                    let snapshot=MimoSnapshot(ipAddress:"203.0.113.10",countryCode:"SG",countryName:"Test",provider:.ipWhois)
                    var approve=MimoSupervisorRequest(.approve)
                    approve.verification=token;approve.address=snapshot.ipAddress
                    approve.exitObservations=MimoExitObservations(verification:token,ipv4:snapshot)
                    var request=DaemonRequest(.supervisor);request.supervisor=approve
                    let task=Task { await supervisor.handle(request,uid:0,pid:getpid()+100) }
                    for _ in 0..<1000 {
                        if supervisor.qualificationAwaitingReadiness && latch.waiting { break }
                        try await Task.sleep(for:.milliseconds(1))
                    }
                    precondition(supervisor.qualificationAwaitingReadiness && latch.waiting,"Approval did not await readiness")
                    var replacement: MimoVerification?
                    var intervention: Task<Void, Never>?
                    func applyIntervention() async {
                      if scenario.contains("direct") {
                        var direct=configuration;direct.mode = .direct
                        var message=MimoSupervisorRequest(.direct);message.configuration=direct
                        var command=DaemonRequest(.supervisor);command.supervisor=message
                        _ = await supervisor.handle(command,uid:0,pid:getpid()+100)
                      } else if scenario.hasPrefix("replacement") {
                        let receipt=MimoReadinessReceipt(process:202,profileDigest:Data("replacement".utf8),checkedAt:.now)
                        replacement=try! supervisor.qualificationPrepare(configuration,readiness:Task { receipt },receipt:receipt)
                      }
                      let runtime=ApprovalRaceRuntime.shared
                      runtime.interventionApplied=true
                      runtime.holdsAtIntervention=runtime.holds
                      runtime.phaseAtIntervention=supervisor.qualificationState.phase.rawValue
                      runtime.events.append("interventionCommitted")
                    }
                    if scenario=="cooperative-direct-cancellation" { await applyIntervention() }
                    else if scenario.hasPrefix("direct-") || scenario.hasPrefix("replacement-") {
                        let enqueue: () -> Void = {
                            // Enqueue external work during the synchronous tail;
                            // the MainActor cannot run it until that task returns.
                            intervention=Task { @MainActor in await applyIntervention() }
                        }
                        if scenario.contains("error-completion") { supervisor.qualificationOnReadinessFailureTail=enqueue }
                        else { supervisor.qualificationOnReadinessTail=enqueue }
                    }
                    latch.unblock()
                    _ = await task.value
                    await intervention?.value
                    let completedReceipt = try? await readiness.value
                    let state=supervisor.qualificationState
                    let runtime=ApprovalRaceRuntime.shared
                    let phaseBefore=runtime.phaseAtIntervention
                    let holdsBefore=runtime.holdsAtIntervention
                    let tokenRetained=replacement.map { state.verification==$0 } ?? true
                    let passed: Bool
                    if scenario=="current-success" { passed=state.allowsTraffic && runtime.opens==1 && runtime.holds==0 }
                    else if scenario=="current-readiness-failure" { passed=state.phase == .blocked && runtime.closed && runtime.holds>=1 && runtime.opens==0 }
                    else if scenario.hasPrefix("replacement") { passed=tokenRetained && state.phase == .checking && runtime.holds==holdsBefore }
                    else { passed=state.allowsTraffic && state.effectiveMode == .direct && runtime.holds==holdsBefore }
                    let result=ApprovalRaceResult(mode:mode.rawValue,family:family.rawValue,scenario:scenario,passed:passed,
                        phaseBeforeResume:phaseBefore,phaseAfterResume:state.phase.rawValue,replacementTokenRetained:tokenRetained,
                        taskReturnedDespiteCancellation:readiness.isCancelled && completedReceipt != nil,gateHoldsAfterNewIntent:runtime.holds-holdsBefore,
                        baselineAttempts:runtime.baselineAttempts,opens:runtime.opens,events:runtime.events)
                    results.append(result)
                    print(String(data:try JSONEncoder().encode(result),encoding:.utf8)!)
                }
            }
        }
        let url=URL(fileURLWithPath:CommandLine.arguments[1])
        try JSONEncoder().encode(results).write(to:url)
        let passed=results.filter(\.passed).count
        print("RESULT \(passed)/\(results.count) pass; \(results.count-passed) failing expectations")
        exit(passed==results.count ? 0 : 1)
    }
}
