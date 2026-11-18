import Foundation

/// Core owns verification scheduling and provider budgets. The independent supervisor owns the gate.
@MainActor
final class MimoCoordinator {
    typealias Transport = @MainActor (MimoSupervisorRequest) async throws -> MimoRoutingState
    typealias Lookup = @MainActor (LookupConfiguration, Bool) async throws -> ExitIPSnapshot

    private(set) var state: MimoRoutingState
    var changed: (() -> Void)?
    private var configuration: MimoConfiguration
    private var allowlist: AllowedIPList
    private var revision: Int
    private var networkGeneration: UInt64 = 0
    private var heartbeat: Task<Void, Never>?
    private var directRestored = false
    private let transport: Transport
    private let lookupOverride: Lookup?
    private var transitionGeneration: UInt64 = 0
    private var transitionsInFlight = 0
    private var pollSequence: UInt64 = 0
    private var appliedPollSequence: UInt64 = 0
    private var configurationChangesInFlight = 0
    private let controllerID = UUID()
    private var commandSequence: UInt64 = 0

    init(configuration: MimoConfiguration, allowlist: AllowedIPList, revision: Int,
         transport: Transport? = nil, lookup: Lookup? = nil) {
        self.configuration = configuration; self.allowlist = allowlist; self.revision = revision
        self.transport = transport ?? Self.callSupervisor
        lookupOverride = lookup
        state = MimoRoutingState(configuration: configuration)
    }

    func start() async {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSupervisorState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if configuration.mode == .direct { await restoreDirect() }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        networkGeneration &+= 1
        transitionGeneration &+= 1
    }

    func beginConfigurationChange(reason: String) async {
        configurationChangesInFlight += 1
        await invalidate(reason: reason)
    }

    func endConfigurationChange() {
        precondition(configurationChangesInFlight > 0)
        configurationChangesInFlight -= 1
    }

    func refreshSupervisorState() async {
        do {
            _ = try await send(MimoSupervisorRequest(.heartbeat))
            if configuration.mode == .direct, !state.allowsTraffic, transitionsInFlight == 0 {
                await restoreDirect()
            }
        } catch { /* send publishes current failures; stale replies are ignored. */ }
    }

    func update(configuration: MimoConfiguration, allowlist: AllowedIPList, revision: Int, preservingAccess: Bool = false) async {
        self.configuration = configuration; self.allowlist = allowlist; self.revision = revision
        state.configuration = configuration
        if preservingAccess {
            // Presentation/diagnostic and native-provider changes do not alter the
            // verified public profile. A heartbeat applies the saved tailnet policy.
            await refreshSupervisorState()
            return
        }
        networkGeneration &+= 1; directRestored = false
        if configuration.mode == .direct { await restoreDirect() }
        else { await invalidate(reason: "Configuration changed. Verification is required.") }
    }

    func networkChanged() async {
        networkGeneration &+= 1
        guard configuration.mode.requiresVerification else { return }
        await invalidate(reason: "Network settings changed. Checking the exit IP immediately.")
    }

    func invalidate(reason: String) async {
        networkGeneration &+= 1
        guard configuration.mode.requiresVerification else { return }
        markPending(reason)
        do { _ = try await send(MimoSupervisorRequest(.close)) }
        catch { /* A superseded close must not replace a newer state. */ }
    }

    private func restoreDirect() async {
        markPending("Restoring normal networking. Waiting for the supervisor.")
        var message = MimoSupervisorRequest(.direct); message.configuration = configuration
        do { _ = try await send(message); directRestored = state.allowsTraffic }
        catch { /* send handles current failures without publishing stale ones. */ }
    }

    func lookup(_ lookup: LookupConfiguration) async throws -> ExitIPSnapshot {
        guard configurationChangesInFlight == 0 else { throw CancellationError() }
        let generation = networkGeneration, revision = revision, mode = configuration.mode
        var check: MimoVerification?
        if mode == .direct {
            if !directRestored || !state.allowsTraffic { await restoreDirect() }
            guard state.allowsTraffic else { throw MimoRuntimeError.unavailable(state.reason) }
        } else {
            markPending("Preparing verification. Waiting for the supervisor to confirm blocking.")
            var message = MimoSupervisorRequest(.prepare)
            message.configuration = configuration; message.allowlist = allowlist
            message.revision = revision; message.networkGeneration = generation
            let result = try await send(message)
            guard result.phase == .checking, let token = result.verification,
                  token.revision == revision, token.networkGeneration == generation else {
                throw MimoRuntimeError.unavailable(result.reason)
            }
            check = token
        }
        guard generation == networkGeneration, revision == self.revision else { throw CancellationError() }
        do {
            let result: ExitIPSnapshot
            if let lookupOverride {
                result = try await lookupOverride(lookup, mode.requiresVerification)
            } else {
                let session = try makeSession(protected: mode.requiresVerification)
                defer { session.invalidateAndCancel() }
                result = try await PublicIPLookupClient(session: session).lookup(configuration: lookup)
            }
            guard generation == networkGeneration, revision == self.revision else { throw CancellationError() }
            if let check {
                var message = MimoSupervisorRequest(.approve); message.verification = check; message.address = result.ipAddress
                _ = try await send(message)
            } else {
                state.observedIP = MimoIPObservation(address: result.ipAddress, checkedAt: result.checkedAt)
                changed?()
            }
            return result
        } catch {
            if generation == networkGeneration, revision == self.revision, !(error is CancellationError) {
                await invalidate(reason: "The required IP check failed. Internet remains blocked.")
            }
            throw error
        }
    }

    func confirm(primaryProvider: ProviderID, token: String?) async throws -> ExitIPSnapshot {
        let generation = networkGeneration, revision = revision
        let session = try makeSession(protected: configuration.mode.requiresVerification)
        defer { session.invalidateAndCancel() }
        let result = try await PublicIPLookupClient(session: session).confirmCountryChange(primaryProvider: primaryProvider, ipinfoToken: token)
        guard generation == networkGeneration, revision == self.revision else { throw CancellationError() }
        return result
    }

    private func makeSession(protected: Bool) throws -> URLSession {
        if protected {
            let password = try String(contentsOf: MimoRuntime.directory.appendingPathComponent("probe.secret"), encoding: .utf8)
            return try MimoLookupSession.make(probePassword: password)
        }
        return try MimoLookupSession.make()
    }

    @discardableResult
    private func send(_ message: MimoSupervisorRequest) async throws -> MimoRoutingState {
        var message = message
        let isPoll = message.command == .heartbeat || message.command == .state
        if !isPoll {
            transitionGeneration &+= 1
            transitionsInFlight += 1
            commandSequence &+= 1
        }
        message.stamp = MimoCommandStamp(controller: controllerID, sequence: commandSequence)
        message.revision = revision
        message.networkGeneration = networkGeneration
        let generation = transitionGeneration
        let pollCanPublish = transitionsInFlight == 0
        pollSequence &+= 1
        let sequence = pollSequence
        defer {
            if !isPoll {
                transitionsInFlight -= 1
                // Discard polling replies that began while this transition was pending.
                if generation == transitionGeneration { transitionGeneration &+= 1 }
            }
        }
        func isCurrent() -> Bool {
            generation == transitionGeneration && (!isPoll ||
                (pollCanPublish && transitionsInFlight == 0 && sequence > appliedPollSequence))
        }
        do {
            var result = try await transport(message)
            guard isCurrent() else { throw CancellationError() }
            if isPoll { appliedPollSequence = sequence }
            // Selected configuration is owned by core, while supervisor reports the actual gate.
            result.configuration.mode = configuration.mode
            result.configuration.proxy = configuration.proxy
            if message.command == .heartbeat, result.effectiveMode == .direct { result.observedIP = state.observedIP }
            state = result; changed?()
            return result
        } catch {
            guard isCurrent(), !(error is CancellationError) else { throw CancellationError() }
            if isPoll { appliedPollSequence = sequence }
            unavailable(error)
            throw error
        }
    }

    private static func callSupervisor(_ message: MimoSupervisorRequest) async throws -> MimoRoutingState {
        var request = DaemonRequest(.supervisor)
        request.supervisor = message
        let response = try await DaemonRPC.call(request, timeout: 20, serviceLabel: MimoRuntime.supervisorLabel)
        guard let result = response.routing else { throw DaemonFailure.unavailable }
        return result
    }

    private func markPending(_ reason: String) {
        state.phase = .unavailable
        state.effectiveMode = nil
        state.verification = nil
        state.reason = reason
        changed?()
    }

    private func unavailable(_ error: Error) {
        state.phase = .unavailable; state.effectiveMode = nil; state.reason = error.localizedDescription
        directRestored = false; changed?()
    }
}

@MainActor
final class MimoLookupClient: PublicIPLookupClientProtocol {
    let coordinator: MimoCoordinator
    init(_ coordinator: MimoCoordinator) { self.coordinator = coordinator }
    func lookup(configuration: LookupConfiguration) async throws -> ExitIPSnapshot { try await coordinator.lookup(configuration) }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> ExitIPSnapshot {
        try await coordinator.confirm(primaryProvider: primaryProvider, token: ipinfoToken)
    }
}
