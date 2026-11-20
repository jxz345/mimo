import Foundation

@MainActor
enum MimoCoordinatorTests {
    static func run() async throws {
        try await staleHeartbeatAfterClose()
        try await outOfOrderHeartbeats()
        try await heartbeatDuringTransition()
        try await networkChangeDuringPreparation()
        try await networkChangeDuringLookup()
        try await cancelledLookupCannotApprove()
        try await heartbeatPulseDoesNotWaitForStatus()
        try await credentialChangeDuringLookup()
        try await directRestoreFailure()
        try await delayedDirectCannotOpenClosedGate()
        try await delayedCloseCannotUndoDirect()
        try await nonRoutingRevisionPreservesVerifiedAccess()
        try await singlePreparationOwnsClosure()
        try await approvalProgressWaitsAndCannotUndoDirect()
        try await failedPreparationCannotProbe()
        try await supervisorEventInvalidatesWithoutDuplicateClose()
        print("PASS: stale supervisor replies, interrupted preparation/probes, credential mutation fencing and Direct failure isolation")
    }

    private static func singlePreparationOwnsClosure() async throws {
        let fixture = Fixture()
        fixture.holdPrepare = true
        let coordinator = fixture.coordinator()
        let task = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.prepareGate.waiting }
        require(coordinator.state.phase == .validating, "confirmed prepare progress must display blocking before profile completion")
        require(fixture.closeRequests == 0, "prepare must not be preceded by a duplicate close RPC")
        let staleProgress = fixture.lastProgress
        var blocked = MimoRoutingState(configuration: fixture.configuration)
        blocked.phase = .blocked
        fixture.prepareGate.resume(fixture.policy.state)
        _ = try await task.value
        staleProgress?(blocked)
        require(coordinator.state.allowsTraffic, "late preparation progress must not overwrite completed approval")
    }

    private static func approvalProgressWaitsAndCannotUndoDirect() async throws {
        let fixture = Fixture()
        fixture.holdApproval = true
        let coordinator = fixture.coordinator()
        let task = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.approvalGate.waiting }
        require(coordinator.state.phase == .checking && !coordinator.state.allowsTraffic,
                "approved IP must remain visibly blocked until readiness completes")
        require(coordinator.state.observedIP?.address == Fixture.snapshot.ipAddress,
                "readiness progress must show the newly checked IP")
        let lateProgress = fixture.lastProgress
        let old = fixture.policy.state
        var direct = fixture.configuration; direct.mode = .direct
        await coordinator.update(configuration: direct, allowlist: Fixture.allowed, revision: 2)
        lateProgress?(old)
        fixture.approvalGate.resume(old)
        try await cancelled(task)
        require(coordinator.state.allowsTraffic && coordinator.state.effectiveMode == .direct,
                "late readiness progress/results cannot undo the newer Direct selection")
    }

    private static func failedPreparationCannotProbe() async throws {
        let fixture = Fixture()
        fixture.failPrepareClose = true
        let coordinator = fixture.coordinator()
        do { _ = try await coordinator.lookup(Fixture.lookupConfiguration); fatalError("failed closure must abort") } catch {}
        require(fixture.lookupCount == 0 && fixture.approvals.isEmpty && coordinator.state.phase == .unavailable,
                "failed prepare closure must never spend an exit lookup, approve or display confirmed blocking")
    }

    private static func supervisorEventInvalidatesWithoutDuplicateClose() async throws {
        let fixture = Fixture()
        fixture.holdLookup = true
        let coordinator = fixture.coordinator()
        let old = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.lookupGate.waiting }
        coordinator.supervisorNetworkChanged()
        fixture.lookupGate.resume(Fixture.snapshot)
        try await cancelled(old)
        require(fixture.approvals.isEmpty && fixture.closeRequests == 0,
                "a supervisor event must revoke old results without requesting another full close")
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        require(coordinator.state.allowsTraffic && fixture.approvals.count == 1,
                "only the fresh post-event probe may approve")
    }

    private static func nonRoutingRevisionPreservesVerifiedAccess() async throws {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        require(coordinator.state.allowsTraffic, "fixture must first verify protected access")
        let proof = coordinator.state.verification
        await coordinator.update(configuration: fixture.configuration, allowlist: Fixture.allowed, revision: 2,
                                 preservingAccess: true)
        require(coordinator.state.allowsTraffic && coordinator.state.verification == proof && fixture.lookupCount == 1,
                "a Tailnet/diagnostic revision must preserve the independently verified public connection")
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        require(fixture.approvals.last?.revision == 2, "the next verification must use the new revision")
    }

    private static func delayedDirectCannotOpenClosedGate() async throws {
        let fixture = Fixture(mode: .direct)
        let coordinator = fixture.coordinator()
        fixture.holdDirectDelivery = true
        let old = Task { await coordinator.update(configuration: fixture.configuration, allowlist: Fixture.allowed, revision: 1) }
        try await wait { fixture.directDeliveryGate.waiting }
        var protected = fixture.configuration; protected.mode = .rule
        await coordinator.update(configuration: protected, allowlist: Fixture.allowed, revision: 2)
        fixture.directDeliveryGate.resume(true)
        await old.value
        require(fixture.policy.state.phase == .blocked && !fixture.policy.state.allowsTraffic,
                "a delayed old Direct command must not open the actual supervisor gate")
    }

    private static func delayedCloseCannotUndoDirect() async throws {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        fixture.holdCloseDelivery = true
        let old = Task { await coordinator.networkChanged() }
        try await wait { fixture.closeDeliveryGate.waiting }
        var direct = fixture.configuration; direct.mode = .direct
        await coordinator.update(configuration: direct, allowlist: Fixture.allowed, revision: 2)
        fixture.closeDeliveryGate.resume(true)
        await old.value
        require(fixture.policy.state.allowsTraffic && fixture.policy.state.effectiveMode == .direct,
                "a delayed old close must not undo a newer Direct selection")
    }

    private static func staleHeartbeatAfterClose() async throws {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        let old = fixture.policy.state
        fixture.holdHeartbeat = true
        let poll = Task { await coordinator.refreshSupervisorState() }
        try await wait { fixture.heartbeatGate.waiting }
        await coordinator.networkChanged()
        fixture.heartbeatGate.resume(.success(old))
        await poll.value
        require(coordinator.state.phase == .blocked, "a delayed active heartbeat must not replace a newer closed gate")
    }

    private static func outOfOrderHeartbeats() async throws {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        let old = fixture.policy.state
        fixture.holdHeartbeat = true
        let first = Task { await coordinator.refreshSupervisorState() }
        try await wait { fixture.heartbeatGate.waiting }
        fixture.failHeartbeat = true
        await coordinator.refreshSupervisorState()
        fixture.heartbeatGate.resume(.success(old))
        await first.value
        require(coordinator.state.phase == .unavailable, "an older successful poll must not hide a newer supervisor failure")
    }

    private static func heartbeatDuringTransition() async throws {
        let fixture = Fixture()
        fixture.holdPrepare = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.prepareGate.waiting }
        let candidate = fixture.policy.state
        fixture.holdHeartbeat = true
        let poll = Task { await coordinator.refreshSupervisorState() }
        try await wait { fixture.heartbeatGate.waiting }
        fixture.prepareGate.resume(candidate)
        _ = try await check.value
        require(coordinator.state.allowsTraffic, "the current probe must complete")
        fixture.heartbeatGate.resume(.success(candidate))
        await poll.value
        require(coordinator.state.allowsTraffic, "a poll begun during preparation must not overwrite its completed transition")
    }

    private static func networkChangeDuringPreparation() async throws {
        let fixture = Fixture()
        fixture.holdPrepare = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.prepareGate.waiting }
        let candidate = fixture.policy.state
        await coordinator.networkChanged()
        fixture.prepareGate.resume(candidate)
        try await cancelled(check)
        require(fixture.lookupCount == 0 && fixture.approvals.isEmpty,
                "superseded preparation must not spend a provider lookup or approve traffic")
        require(coordinator.state.phase == .blocked, "cancelled preparation must preserve confirmed blocking")
    }

    private static func networkChangeDuringLookup() async throws {
        let fixture = Fixture()
        fixture.holdLookup = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.lookupGate.waiting }
        await coordinator.networkChanged()
        fixture.lookupGate.resume(Fixture.snapshot)
        try await cancelled(check)
        require(fixture.approvals.isEmpty && coordinator.state.phase == .blocked,
                "an IP result from the previous network must never reach approval")
    }

    private static func cancelledLookupCannotApprove() async throws {
        let fixture = Fixture()
        fixture.holdLookup = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.lookupGate.waiting }
        check.cancel()
        fixture.lookupGate.resume(Fixture.snapshot)
        try await cancelled(check)
        require(fixture.approvals.isEmpty && !fixture.policy.state.allowsTraffic,
                "a timed-out or cancelled lookup must not submit a successful late result for approval")
        require(MimoLookupClient(coordinator).lookupTimeout > PublicIPLookupClient().lookupTimeout,
                "managed routing must budget preparation and activation separately from the HTTP deadline")
    }

    private static func heartbeatPulseDoesNotWaitForStatus() async throws {
        var configuration = MimoConfiguration()
        configuration.mode = .rule
        let statusGate = Gate<Bool>()
        var pulses = 0
        let coordinator = MimoCoordinator(configuration: configuration, allowlist: Fixture.allowed, revision: 1,
            transport: { message, _ in
                if message.livenessOnly == true { pulses += 1 }
                else if message.command == .heartbeat { _ = await statusGate.wait() }
                return MimoRoutingState(configuration: configuration)
            })
        await coordinator.start()
        try await wait { statusGate.waiting }
        let before = pulses
        try await Task.sleep(for: .milliseconds(1200))
        require(pulses > before, "liveness must continue while a status reply waits behind profile work")
        coordinator.stop()
        statusGate.resume(true)
    }

    private static func credentialChangeDuringLookup() async throws {
        let fixture = Fixture()
        fixture.holdLookup = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.lookupGate.waiting }
        await coordinator.beginConfigurationChange(reason: "Changing lookup credential")
        let blockedAttempt = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await cancelled(blockedAttempt)
        require(fixture.lookupCount == 1, "no new probe may start while credentials and settings are being committed")
        await coordinator.update(configuration: fixture.configuration, allowlist: Fixture.allowed, revision: 2)
        fixture.lookupGate.resume(Fixture.snapshot)
        try await cancelled(check)
        coordinator.endConfigurationChange()
        require(fixture.approvals.isEmpty, "a pre-change credential result must not approve access")
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        require(fixture.approvals.last?.revision == 2 && coordinator.state.allowsTraffic,
                "the next successful probe must use the committed revision")
    }

    private static func directRestoreFailure() async throws {
        let fixture = Fixture(mode: .direct)
        fixture.failDirect = true
        let coordinator = fixture.coordinator()
        do {
            _ = try await coordinator.lookup(Fixture.lookupConfiguration)
            fatalError("a failed Direct restore was treated as ready")
        } catch is MimoRuntimeError { }
        require(fixture.lookupCount == 0 && coordinator.state.phase == .unavailable,
                "Direct must not claim a live result until interception and blocking have been removed")
    }

    private static func cancelled(_ task: Task<ExitIPSnapshot, Error>) async throws {
        do { _ = try await task.value; fatalError("a superseded operation completed") }
        catch is CancellationError { }
    }

    private static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { fatalError("test operation did not reach its suspension point") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }

    @MainActor
    private final class Gate<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?
        var waiting: Bool { continuation != nil }
        func wait() async -> Value {
            await withCheckedContinuation { continuation = $0 }
        }
        func resume(_ value: Value) {
            guard let continuation else { fatalError("test gate was not waiting") }
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }

    @MainActor
    private final class Fixture {
        static let allowed = AllowedIPList(addresses: ["192.0.2.10"])
        static let lookupConfiguration = LookupConfiguration(provider: .ipWhois, ipinfoToken: nil)
        static var snapshot: ExitIPSnapshot {
            ExitIPSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois)
        }
        let configuration: MimoConfiguration
        var policy: MimoAccessPolicy
        var holdHeartbeat = false
        var failHeartbeat = false
        var failDirect = false
        var holdPrepare = false
        var holdApproval = false
        var holdLookup = false
        var lookupCount = 0
        var holdDirectDelivery = false
        var holdCloseDelivery = false
        var closeRequests = 0
        var failPrepareClose = false
        var lastProgress: MimoCoordinator.Progress?
        var commandFence = MimoCommandFence()
        let directDeliveryGate = Gate<Bool>()
        let closeDeliveryGate = Gate<Bool>()
        var approvals: [MimoVerification] = []
        let heartbeatGate = Gate<Result<MimoRoutingState, DaemonFailure>>()
        let prepareGate = Gate<MimoRoutingState>()
        let approvalGate = Gate<MimoRoutingState>()
        let lookupGate = Gate<ExitIPSnapshot>()

        init(mode: ProxyMode = .rule) {
            var configuration = MimoConfiguration()
            configuration.mode = mode
            configuration.proxy = MimoProxy(ClashProxySettings(name: "Test", type: .socks5,
                                                               server: "192.0.2.20", port: 1080))
            self.configuration = configuration
            policy = MimoAccessPolicy(configuration: configuration)
        }

        func coordinator() -> MimoCoordinator {
            MimoCoordinator(configuration: configuration, allowlist: Self.allowed, revision: 1,
                            transport: { try await self.handle($0, progress: $1) }, lookup: { _, protected in
                require(protected, "fixture probes must use the protected path")
                self.lookupCount += 1
                if self.holdLookup {
                    self.holdLookup = false
                    return await self.lookupGate.wait()
                }
                return Self.snapshot
            })
        }

        private func handle(_ message: MimoSupervisorRequest, progress: @escaping MimoCoordinator.Progress) async throws -> MimoRoutingState {
            if message.command == .direct, holdDirectDelivery {
                holdDirectDelivery = false
                _ = await directDeliveryGate.wait()
            }
            if message.command == .close, holdCloseDelivery {
                holdCloseDelivery = false
                _ = await closeDeliveryGate.wait()
            }
            guard let stamp = message.stamp,
                  commandFence.accept(stamp, peer: 42, currentCore: 42, enabled: true,
                                      heartbeat: message.command == .heartbeat || message.command == .state) else {
                throw DaemonFailure.conflict
            }
            switch message.command {
            case .heartbeat, .state:
                if holdHeartbeat {
                    holdHeartbeat = false
                    return try await heartbeatGate.wait().get()
                }
                if failHeartbeat { throw DaemonFailure.unavailable }
            case .close:
                closeRequests += 1
                policy.block("Verification required")
            case .direct:
                if failDirect { throw DaemonFailure.unavailable }
                policy.directRestored(configuration: message.configuration ?? configuration)
            case .prepare:
                policy.block("Preparing", confirmed: !failPrepareClose)
                if failPrepareClose { return policy.state }
                lastProgress = progress
                progress(policy.state)
                let token = policy.begin(configuration: message.configuration!, revision: message.revision!,
                                         networkGeneration: message.networkGeneration!)
                policy.checking(token)
                if holdPrepare {
                    holdPrepare = false
                    return await prepareGate.wait()
                }
            case .approve:
                if holdApproval {
                    holdApproval = false
                    policy.waitingForReadiness(address: message.address!, verification: message.verification!)
                    lastProgress = progress
                    progress(policy.state)
                    return await approvalGate.wait()
                }
                approvals.append(message.verification!)
                _ = policy.approve(address: message.address!, at: .now, allowlist: Self.allowed,
                                   verification: message.verification!, runtimeMatches: true)
            case .service, .profile: throw DaemonFailure.invalidRequest
            }
            return policy.state
        }
    }
}
