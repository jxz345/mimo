import Foundation

/// Core owns verification scheduling and provider budgets. The independent supervisor owns the gate.
@MainActor
final class MimoCoordinator {
    typealias Progress = @MainActor @Sendable (MimoRoutingState) -> Void
    typealias Transport = @MainActor (MimoSupervisorRequest, @escaping Progress) async throws -> MimoRoutingState
    typealias Lookup = @MainActor (LookupConfiguration, Bool) async throws -> MimoSnapshot

    private(set) var state: MimoRoutingState
    var changed: (() -> Void)?
    var willRequest: ((ProviderID) throws -> Void)?
    private var configuration: MimoConfiguration
    private var allowlist: AllowedIPList
    private var revision: Int
    private var networkGeneration: UInt64 = 0
    private var heartbeat: Task<Void, Never>?
    private var heartbeatPulse: Task<Void, Never>?
    private var directRestored = false
    // Core owns Direct lookups; supervisor replies only describe the gate.
    // Keep the observation separate so a temporary repair/blocked reply cannot
    // erase it before Direct recovers. Never carry it across mode changes.
    private var directObservation: MimoIPObservation?
    // Display-only history for this selected proxy. Never used for approval.
    private var lastExitObservation: MimoSnapshot?
    private let transport: Transport
    private let pulse: @MainActor (MimoSupervisorRequest) async throws -> Void
    private let heartbeatChannel: MimoHeartbeatChannel?
    private let lookupOverride: Lookup?
    private var transitionGeneration: UInt64 = 0
    private var transitionsInFlight = 0
    private var pollSequence: UInt64 = 0
    private var appliedPollSequence: UInt64 = 0
    private var configurationChangesInFlight = 0
    private var configurationBarrier: (network: UInt64, transition: UInt64)?
    private let controllerID = UUID()
    private var commandSequence: UInt64 = 0

    init(configuration: MimoConfiguration, allowlist: AllowedIPList, revision: Int,
         transport: Transport? = nil, lookup: Lookup? = nil) {
        self.configuration = configuration; self.allowlist = allowlist; self.revision = revision
        self.transport = transport ?? Self.callSupervisor
        if let transport {
            heartbeatChannel = nil
            pulse = { _ = try await transport($0, { _ in }) }
        } else {
            let channel = MimoHeartbeatChannel()
            heartbeatChannel = channel
            pulse = { try await channel.send($0) }
        }
        lookupOverride = lookup
        state = MimoRoutingState(configuration: configuration)
    }

    func start() async {
        guard heartbeat == nil else { return }
        heartbeatPulse = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var message = MimoSupervisorRequest(.heartbeat)
                message.livenessOnly = true
                message.stamp = MimoCommandStamp(controller: self.controllerID, sequence: self.commandSequence)
                do { try await self.pulse(message) }
                catch {
                    guard !Task.isCancelled else { return }
                    RuntimeLog.shared.error("mimo_heartbeat_failed", fields: [
                        "sequence": String(self.commandSequence), "error": error.localizedDescription
                    ])
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
        directObservation = nil
        lastExitObservation = nil
        heartbeat?.cancel()
        heartbeat = nil
        heartbeatPulse?.cancel()
        heartbeatPulse = nil
        heartbeatChannel?.invalidate()
        networkGeneration &+= 1
        transitionGeneration &+= 1
    }

    func beginConfigurationChange(reason: String, selectingDirect: Bool = false) async {
        configurationChangesInFlight += 1
        configurationBarrier = nil
        if selectingDirect {
            // Cancel old verification without closing the gate. Direct is an
            // explicit opt-out of proxy/IP approval; persistence must still
            // succeed before sending the supervisor's ordered Direct command.
            networkGeneration &+= 1
            transitionGeneration &+= 1
            return
        }
        if await invalidate(reason: reason) {
            configurationBarrier = (networkGeneration, transitionGeneration)
        }
    }

    func endConfigurationChange() {
        precondition(configurationChangesInFlight > 0)
        configurationChangesInFlight -= 1
        if configurationChangesInFlight == 0 { configurationBarrier = nil }
    }

    func adoptNetworkRelease(configuration: MimoConfiguration, revision: Int) {
        self.configuration = configuration; self.revision = revision
        networkGeneration &+= 1; transitionGeneration &+= 1
        directObservation = nil
        lastExitObservation = nil; state.lastExitObservation = nil
        state.configuration = configuration
        state.networkReleaseRequested = true
        state.networkReleased = false
        state.phase = .restoringDirect; state.effectiveMode = nil
        state.verification = nil; state.blockingIP = nil
        state.reason = "Stopping engine and restoring system networking…"
        changed?()
    }

    func startReleasedEngine() async throws {
        var message = MimoSupervisorRequest(.service)
        message.service = .mihomo; message.operation = .start
        let result = try await send(message)
        guard result.networkReleaseRequested != true, result.phase == .active,
              result.services.first(where: { $0.id == .mihomo })?.health == .running else {
            throw MimoRuntimeError.unavailable(result.reason)
        }
    }

    func refreshSupervisorState() async {
        do {
            _ = try await send(MimoSupervisorRequest(.heartbeat))
            if configuration.mode == .direct, !state.allowsTraffic, state.networkReleaseRequested != true, transitionsInFlight == 0 {
                await restoreDirect()
            }
        } catch { /* send publishes current failures; stale replies are ignored. */ }
    }

    func update(configuration: MimoConfiguration, allowlist: AllowedIPList, revision: Int, preservingAccess: Bool = false) async {
        // The edit already closed traffic before persistence. Reuse only that
        // acknowledged barrier, within the same edit and unchanged epochs.
        // Failed/superseded closes and intervening network events cannot qualify.
        let hasCurrentBarrier = configurationChangesInFlight > 0 && state.phase == .blocked &&
            configurationBarrier?.network == networkGeneration &&
            configurationBarrier?.transition == transitionGeneration
        configurationBarrier = nil
        if self.configuration.mode != configuration.mode { directObservation = nil }
        if configuration.mode == .direct || self.configuration.mode == .direct ||
            self.configuration.proxy != configuration.proxy || self.configuration.activeProxyID != configuration.activeProxyID {
            lastExitObservation = nil; state.lastExitObservation = nil
        }
        self.configuration = configuration; self.allowlist = allowlist; self.revision = revision
        state.configuration = configuration
        if preservingAccess {
            // Non-routing edits, including a future family selection in Direct,
            // do not alter the current network path. Retain core-owned selection
            // when merging the supervisor's effective state.
            await refreshSupervisorState()
            return
        }
        networkGeneration &+= 1; directRestored = false
        if configuration.mode == .direct { await restoreDirect() }
        else if hasCurrentBarrier {
            markPending("Configuration changed. Verification is required.")
            RuntimeLog.shared.info("mimo_configuration_barrier_reused", fields: [
                "revision": String(revision), "generation": String(networkGeneration),
                "mode": configuration.mode.rawValue, "family": configuration.networkFamily.rawValue
            ])
        }
        else { await invalidate(reason: "Configuration changed. Verification is required.") }
    }

    func networkChanged() async {
        networkGeneration &+= 1
        guard configuration.mode.requiresVerification else { return }
        await invalidate(reason: "Network settings changed. Checking the exit IP immediately.")
    }

    /// The root supervisor already attempted closure before delivering this
    /// event. Invalidate local work immediately, then let prepare confirm the
    /// current gate. Do not send a second standalone close round trip.
    func supervisorNetworkChanged() {
        networkGeneration &+= 1
        transitionGeneration &+= 1
        guard configuration.mode.requiresVerification else { return }
        markPending("System or network changed. Preparing a fresh exit-IP check.")
    }

    @discardableResult
    func invalidate(reason: String, lookupID: UUID? = nil) async -> Bool {
        networkGeneration &+= 1
        guard configuration.mode.requiresVerification else { return false }
        markPending(reason)
        var message = MimoSupervisorRequest(.close)
        message.reason = reason; message.lookupID = lookupID
        do { return try await send(message).phase == .blocked }
        catch { return false /* A superseded close must not replace a newer state. */ }
    }

    /// Scheduler status is not a new network event. A failed lookup has already
    /// closed its gate; do not close it again for both failed and coolingDown.
    /// Capture the epoch before scheduling so a late notification cannot revoke
    /// a newer private probe, approval, configuration edit or Direct selection.
    func requiredCheckUnavailable(reason: String) {
        guard configuration.mode.requiresVerification else { return }
        guard state.phase != .blocked || transitionsInFlight > 0 else {
            RuntimeLog.shared.info("mimo_required_check_close_skipped", fields: ["reason": "already_blocked", "phase": state.phase.rawValue])
            return
        }
        let network = networkGeneration, transition = transitionGeneration
        Task { [weak self] in
            guard let self, self.networkGeneration == network,
                  self.transitionGeneration == transition,
                  self.configuration.mode.requiresVerification else {
                RuntimeLog.shared.info("mimo_required_check_close_skipped", fields: ["reason": "superseded_notification"])
                return
            }
            await self.invalidate(reason: reason)
        }
    }

    private func restoreDirect() async {
        state.phase = .restoringDirect
        state.effectiveMode = nil
        state.verification = nil
        state.blockingIP = nil
        state.reason = "Switching to Direct. Removing proxy routing and restoring system DNS."
        changed?()
        var message = MimoSupervisorRequest(.direct); message.configuration = configuration
        do { _ = try await send(message); directRestored = state.allowsTraffic }
        catch { /* send handles current failures without publishing stale ones. */ }
    }

    func lookup(_ lookup: LookupConfiguration) async throws -> MimoSnapshot {
        try Task.checkCancellation()
        guard configurationChangesInFlight == 0 else { throw CancellationError() }
        let generation = networkGeneration, revision = revision, mode = configuration.mode
        var check: MimoVerification?
        if mode == .direct {
            if !directRestored || !state.allowsTraffic { await restoreDirect() }
            guard state.allowsTraffic else { throw MimoRuntimeError.unavailable(state.reason) }
        } else {
            markPending("Preparing verification. Waiting for the supervisor to confirm blocking.")
            // Prepare streams confirmed blocking before slower profile work.
            // One request owns closure and preparation, avoiding a duplicate
            // full firewall transaction solely to display progress.
            var message = MimoSupervisorRequest(.prepare)
            message.lookupID = lookup.lookupID
            message.configuration = configuration; message.allowlist = allowlist
            message.revision = revision; message.networkGeneration = generation
            let result = try await send(message)
            try Task.checkCancellation()
            guard generation == networkGeneration, revision == self.revision else { throw CancellationError() }
            guard result.phase == .checking, let token = result.verification,
                  token.revision == revision, token.networkGeneration == generation else {
                throw MimoRuntimeError.unavailable(result.reason)
            }
            check = token
        }
        try Task.checkCancellation()
        guard generation == networkGeneration, revision == self.revision else { throw CancellationError() }
        do {
            var timing = MimoTransitionTiming("lookup")
            func observe(_ family: MimoAddressFamily?) async throws -> MimoSnapshot {
                try willRequest?(lookup.provider)
                let request = LookupConfiguration(provider: lookup.provider, ipinfoToken: lookup.ipinfoToken, family: family, lookupID: lookup.lookupID)
                let started = ProcessInfo.processInfo.systemUptime
                var fields = ["provider": lookup.provider.rawValue, "family": family?.rawValue ?? "native",
                              "path": mode.requiresVerification ? "private_proxy_probe" : "native_direct",
                              "phase": state.phase.rawValue]
                fields["lookup"] = lookup.lookupID?.uuidString; fields["attempt"] = check?.id.uuidString
                RuntimeLog.shared.info("mimo_probe_http_started", fields: fields)
                var outcome = "failed"
                defer {
                    fields["outcome"] = outcome
                    fields["duration_ms"] = String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
                    RuntimeLog.shared.info("mimo_probe_http_finished", fields: fields)
                }
                let value: MimoSnapshot
                if let lookupOverride { value = try await lookupOverride(request, mode.requiresVerification) }
                else {
                    let session = try makeSession(protected: mode.requiresVerification, family: family)
                    defer { session.invalidateAndCancel() }
                    value = try await PublicIPLookupClient(session: session).lookup(configuration: request)
                }
                if let family, !family.accepts(value.ipAddress) {
                    throw LookupError.transport("The provider did not return the requested \(family.rawValue) exit.")
                }
                outcome = "succeeded"
                return value
            }
            let result = try await observe(mode.requiresVerification ? .ipv4 : nil)
            timing.record("exit_ip")
            try Task.checkCancellation()
            guard generation == networkGeneration, revision == self.revision else { throw CancellationError() }
            if let check {
                lastExitObservation = result
                state.lastExitObservation = result
                state.observedIP = .init(address: result.ipAddress, checkedAt: result.checkedAt)
                state.reason = "IPv4 exit received. Checking approval and runtime readiness. Internet remains blocked."
                changed?()
                var message = MimoSupervisorRequest(.approve); message.verification = check; message.address = result.ipAddress
                message.lookupID = lookup.lookupID
                message.exitObservations = MimoExitObservations(verification: check, ipv4: result)
                _ = try await send(message)
            } else {
                directObservation = MimoIPObservation(address: result.ipAddress, checkedAt: result.checkedAt)
                state.observedIP = directObservation
                changed?()
            }
            return result
        } catch {
            if generation == networkGeneration, revision == self.revision, !(error is CancellationError) {
                await invalidate(reason: "The IPv4 exit-IP check failed. Internet remains blocked. Retry the check or use Direct.", lookupID: lookup.lookupID)
            }
            throw error
        }
    }

    func confirm(primaryProvider: ProviderID, token: String?) async throws -> MimoSnapshot {
        let generation = networkGeneration, revision = revision
        let session = try makeSession(protected: configuration.mode.requiresVerification,
                                      family: configuration.mode.requiresVerification ? .ipv4 : nil)
        defer { session.invalidateAndCancel() }
        try willRequest?(CountryChangeConfirmationPolicy.secondaryProvider(for: primaryProvider))
        let result = try await PublicIPLookupClient(session: session).confirmCountryChange(primaryProvider: primaryProvider, ipinfoToken: token)
        guard generation == networkGeneration, revision == self.revision else { throw CancellationError() }
        return result
    }

    private func makeSession(protected: Bool, family: MimoAddressFamily? = nil) throws -> URLSession {
        if protected {
            let password = try String(contentsOf: MimoRuntime.directory.appendingPathComponent("probe.secret"), encoding: .utf8)
            return try MimoLookupSession.make(probePassword: password, family: family)
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
        let started = ProcessInfo.processInfo.systemUptime
        var diagnostic = message.diagnosticFields
        if !isPoll { RuntimeLog.shared.info("mimo_core_command_started", fields: diagnostic) }
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
            var result = try await transport(message) { [weak self] interim in
                guard let self, self.transitionGeneration == generation, self.transitionsInFlight > 0 else { return }
                let preparing = message.command == .prepare && interim.phase == .blocked
                let waiting = message.command == .approve && interim.phase == .checking
                    && interim.verification == message.verification && interim.observedIP != nil
                guard preparing || waiting else { return }
                self.state = interim
                self.state.lastExitObservation = self.lastExitObservation
                self.state.configuration.mode = self.configuration.mode
                self.state.configuration.networkFamily = self.configuration.networkFamily
                self.state.configuration.proxy = self.configuration.proxy
                self.state.configuration.proxies = self.configuration.proxies
                self.state.configuration.activeProxyID = self.configuration.activeProxyID
                if preparing {
                    self.state.phase = .validating
                    self.state.reason = "Validating the profile. Internet remains blocked."
                }
                self.changed?()
            }
            diagnostic["phase"] = result.phase.rawValue
            diagnostic["attempt"] = (message.verification ?? result.verification)?.id.uuidString
            diagnostic["duration_ms"] = String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
            guard isCurrent() else { throw CancellationError() }
            if !isPoll { RuntimeLog.shared.info("mimo_core_command_finished", fields: diagnostic) }
            if isPoll { appliedPollSequence = sequence }
            // Selected configuration is owned by core, while supervisor reports the actual gate.
            result.configuration.mode = configuration.mode
            result.configuration.networkFamily = configuration.networkFamily
            result.configuration.proxy = configuration.proxy
            result.configuration.proxies = configuration.proxies
            result.configuration.activeProxyID = configuration.activeProxyID
            if configuration.mode == .direct, result.effectiveMode == .direct {
                result.observedIP = directObservation
            }
            result.lastExitObservation = configuration.mode.requiresVerification ? lastExitObservation : nil
            state = result; changed?()
            return result
        } catch {
            if !isPoll {
                diagnostic["outcome"] = isCurrent() && !(error is CancellationError) ? "failed" : "superseded"
                diagnostic["errorType"] = String(describing: type(of: error))
                diagnostic["duration_ms"] = String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
                RuntimeLog.shared.info("mimo_core_command_failed", fields: diagnostic)
            }
            guard isCurrent(), !(error is CancellationError) else { throw CancellationError() }
            if isPoll { appliedPollSequence = sequence }
            unavailable(error)
            throw error
        }
    }

    private static func callSupervisor(_ message: MimoSupervisorRequest, progress: @escaping Progress) async throws -> MimoRoutingState {
        var request = DaemonRequest(.supervisor)
        request.supervisor = message
        let response = try await DaemonRPC.call(request, timeout: message.command == .service ? 75 : 20, serviceLabel: MimoRuntime.supervisorLabel,
                                               returningFailures: true,
                                               progress: { response in
            guard let state = response.routing else { return }
            Task { @MainActor in progress(state) }
        })
        guard let result = response.routing else { throw response.failure ?? DaemonFailure.unavailable }
        if let failure = response.failure, message.command != .service { throw failure }
        return result
    }

    private func markPending(_ reason: String) {
        // A new request is progress, not loss of the service. Keep an already
        // confirmed closed gate visible while another close is acknowledged.
        let alreadyClosed = [.blocked, .validating, .checking].contains(state.phase)
        state.phase = alreadyClosed ? .blocked : .closing
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

/// Keep the liveness connection separate from status/profile RPCs. Reusing its
/// already accepted connection avoids repeated XPC handshakes during activation.
/// A failed transport is discarded; neither retries nor late replies extend the
/// supervisor's unchanged five-second heartbeat deadline.
@MainActor
private final class MimoHeartbeatChannel {
    private var connection: NSXPCConnection?

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    func send(_ message: MimoSupervisorRequest) async throws {
        let connection: NSXPCConnection
        if let current = self.connection { connection = current }
        else {
            connection = NSXPCConnection(machServiceName: MimoRuntime.supervisorLabel, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: MimoDaemonProtocol.self)
            connection.resume()
            self.connection = connection
        }
        var request = DaemonRequest(.supervisor)
        request.supervisor = message
        let data = try JSONEncoder().encode(request)
        do {
            let response: DaemonResponse = try await withCheckedThrowingContinuation { continuation in
                let completion = MimoHeartbeatReply(continuation)
                connection.invalidationHandler = { @Sendable in completion.finish(.failure(DaemonFailure.unavailable)) }
                connection.interruptionHandler = { @Sendable in completion.finish(.failure(DaemonFailure.unavailable)) }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                    let failure = error as NSError
                    RuntimeLog.shared.error("mimo_heartbeat_transport_failed", fields: [
                        "domain": failure.domain, "code": String(failure.code), "reason": failure.localizedDescription
                    ])
                    completion.finish(.failure(DaemonFailure.unavailable))
                }) as? MimoDaemonProtocol else {
                    completion.finish(.failure(DaemonFailure.unavailable)); return
                }
                proxy.request(data) { data in
                    guard data.count <= MimoService.maximumMessageSize else {
                        completion.finish(.failure(DaemonFailure.invalidRequest)); return
                    }
                    completion.finish(Result { try JSONDecoder().decode(DaemonResponse.self, from: data) })
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    completion.finish(.failure(DaemonFailure.unavailable))
                }
            }
            // Initial authority is established by an ordered core command, not
            // by this connection. A rejection keeps the channel but renews no lease.
            if let failure = response.failure { throw failure }
        } catch {
            if (error as? DaemonFailure) != .conflict { invalidate() }
            throw error
        }
    }
}

private final class MimoHeartbeatReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DaemonResponse, any Error>?
    init(_ continuation: CheckedContinuation<DaemonResponse, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<DaemonResponse, any Error>) {
        let pending = lock.withLock { let value = continuation; continuation = nil; return value }
        pending?.resume(with: result)
    }
}

@MainActor
final class MimoLookupClient: PublicIPLookupClientProtocol {
    // Two bounded supervisor calls (20s each), a 15s HTTP resource deadline,
    // and a small scheduling margin. Public HTTP timeouts are unchanged.
    nonisolated var lookupTimeout: Duration { .seconds(75) }
    nonisolated var accountsActualRequests: Bool { true }
    let coordinator: MimoCoordinator
    init(_ coordinator: MimoCoordinator) { self.coordinator = coordinator }
    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot { try await coordinator.lookup(configuration) }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
        try await coordinator.confirm(primaryProvider: primaryProvider, token: ipinfoToken)
    }
}
