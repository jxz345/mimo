import Foundation
import Security

/// Supervisor process owns networking, settings, monitoring and the GUI API.
@MainActor
final class MimoSupervisor: NSObject, NSXPCListenerDelegate {
    private let runtime = MimoSystemRuntime()
    private var policy = MimoAccessPolicy()
    private var allowlist = AllowedIPList()
    private var endpoint: String?
    private var proxy: ClashProxySettings?
    private var activeProfile: String?
    private var installationCheck: Task<Void, Error>?
    private var forceProfileReload = true
    private let preparationQueue = MimoBlockingWorkQueue("com.mimo.prepare-profile")
    private struct PreparedCandidate: Sendable {
        var proxy: ClashProxySettings
        var profile: String?
        var reused: Bool
    }
    private var firewallPreparation: Task<MimoPreparedProbePolicy, Error>?
    private var profilePreparation: Task<PreparedCandidate, Error>?
    private var profileInspection: Task<MimoReadinessReceipt, Error>?
    private var completedReadiness: MimoReadinessReceipt?
    private var cachedServices: (at: Date, values: [MimoServiceStatus])?
    private var readinessCheck: Task<MimoReadinessReceipt, Error>?
    private var watchdog: Task<Void, Never>?
    private var infrastructureMonitor: Task<Void, Never>?
    private let infrastructureScheduler = MimoInfrastructureScheduler()
    var monitoringOperation: ((MimoServiceOperation) -> Void)?
    var coreNetworkChanged: (() async throws -> Void)?
    var peerWatchdog: MimoPeerWatchdog?
    private var infrastructureRecoveryPending = false
    private var infrastructureFailureGeneration: UInt64?
    private var verificationRecoveryPending = false
    private var profileEnabled = true
    private var engineEnabled = true
    private var coreEnabled = true
    private var operationPending = false
    private let controls = MimoControlQueue()
    private var generation: UInt64 = 0
    private var configurationKnown = false
    private var deferredNetworkReasons = Set<String>()
    private var stopping = false
    private var protectedClosureID = UUID()
    private var protectedClosureTask: Task<Void, Never>?
    private var activeProtectedLease: MimoProtectedLease?
    private var directRestorationTask: Task<DaemonResponse, Never>?
    private let directFenceQueue = MimoBlockingWorkQueue("com.mimo.direct-fence", qos: .userInitiated)
    private var directTrackingTask: Task<Void, Never>?
    private var directTrackingPending = false
    private var directRestorationAllowed = false
    private var commandFence = MimoCommandFence()
    private lazy var networkObserver = MimoNetworkObserver(earlyBlock: { [runtime, fence = powerGuard.fence] in
        // Invalidate old approvals at callback delivery, before actor scheduling.
        // The fence also serializes with Direct and excludes Direct from blocking.
        try? fence.observeNetworkChange { runtime.requestEarlyApplicationGate() }
    }, changed: { [weak self] reason, detail in self?.networkChanged(reason, detail: detail) })
    private lazy var powerGuard = MimoPowerGuard { [weak self] reason in self?.networkChanged(reason) }
    private lazy var sessionObserver = MimoSessionObserver(powerGuard: powerGuard) { [weak self] reason in self?.networkChanged(reason) }
    private var verificationPowerEpoch: UInt64?
    func start() {
        powerGuard.start()
#if MIMO_VM_ACCEPTANCE
        networkObserver.diagnostic = { RuntimeLog.shared.info("mimo_vm_network_diagnostic", fields: ["detail": $0]) }
#endif
        runtime.nativePolicyDidCommit = { [weak self] in self?.requestInfrastructureReconciliation("native_policy_committed") }
        runtime.profileWillChange = { [weak self] in
            guard let self else { return }
            self.networkObserver.willChangeProfile(engineProcess: self.runtime.notificationEngineProcess)
        }
        runtime.profileDidChange = { [weak self] in self?.networkObserver.didChangeProfile() }
        runtime.profileDidChangeOnline = { [weak self] in await self?.networkObserver.didChangeProfileOnline() }
        do {
            try runtime.closeStartupGate()
            try runtime.checkInstallation()
            try runtime.migrateLegacyNetworkControls()
            try runtime.closeGate()
            let flags = try runtime.servicePreferences()
            profileEnabled = flags.profile; engineEnabled = flags.engine; coreEnabled = flags.core
            policy = MimoAccessPolicy(configuration: try runtime.savedConfiguration())
            if policy.state.configuration.mode.requiresVerification { _ = try powerGuard.fence.arm() }
            configurationKnown = true
            directRestorationAllowed = policy.state.configuration.mode == .direct
            policy.block("Startup protection is active. Waiting for mimo-core.")
            // Startup must obtain fresh approval. Infrastructure recovery can
            // request verification until the cohosted monitor's preparation
            // consumes this flag; healthy scans must not repeat that request.
            verificationRecoveryPending = policy.state.configuration.mode.requiresVerification &&
                coreEnabled && engineEnabled && profileEnabled
            guard !runtime.maintenanceActive else {
                policy.block("Service installation is in progress.")
                return
            }
            if runtime.networkReleaseRequested {
                policy.releasing(configuration: policy.state.configuration)
                operationPending = true
                Task { [weak self] in
                    guard let self else { return }
                    defer { self.operationPending = false }
                    do { try await self.releaseEngine() }
                    catch { self.policy.releasing(configuration: self.policy.state.configuration, error: error.localizedDescription) }
                }
            } else {
                try runtime.service(.mihomo, operation: engineEnabled ? .start : .stop)
                if policy.state.configuration.mode == .direct {
                    try runtime.restoreDirect()
                    policy.directRestored(configuration: policy.state.configuration, nativeIssue: runtime.nativeReleaseIssue)
                }
            }
            RuntimeLog.shared.info("mimo_supervisor_ready", fields: ["mode": policy.state.configuration.mode.rawValue])
        } catch { policy.block(error.localizedDescription, confirmed: runtime.closed) }
        networkObserver.tailnetChanged = { [weak self] in
            guard let self, self.policy.state.configuration.mode.requiresVerification,
                  self.activeProfile != nil else { return }
            self.forceProfileReload = true
            self.networkChanged("native_dns_changed")
        }
        networkObserver.start()
        sessionObserver.start()
        // Infrastructure commands can wait for launchd or the firewall lock.
        // Keep them off the main actor and separate from the liveness watchdog.
        infrastructureMonitor = Task { [weak self] in
            RuntimeLog.shared.info("mimo_infrastructure_started", fields: ["owner": "supervisor", "intervalSeconds": "10"])
            defer { RuntimeLog.shared.info("mimo_infrastructure_stopped", fields: ["owner": "supervisor"]) }
            while !Task.isCancelled {
                guard let self else { return }
                var outcome = MimoInfrastructureCheckOutcome.superseded
                if !self.runtime.maintenanceActive, self.directRestorationTask == nil {
                    let inspectionGeneration = self.generation
                    do {
                        outcome = try await self.runtime.repairInfrastructure(generation: inspectionGeneration)
                        if self.directRestorationTask != nil || inspectionGeneration != self.generation {
                            outcome = .superseded
                        }
                        if outcome == .completed {
                            let recovered = self.infrastructureRecoveryPending || self.verificationRecoveryPending
                            self.infrastructureRecoveryPending = false
                            self.infrastructureFailureGeneration = nil
                            if recovered, self.policy.state.phase == .blocked {
                                self.networkChanged("infrastructure_recovered")
                            }
                        }
                    }
                    catch {
                        guard !Task.isCancelled else { return }
                        outcome = .failed
                        self.infrastructureInspectionFailed(error, generation: inspectionGeneration)
                    }
                }
                self.peerWatchdog?.workProgressed()
                await self.infrastructureScheduler.wait(after: outcome)
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.runtime.networkReleaseRequested || self.directRestorationTask != nil || self.runtime.protectedIOBusy { continue }
                if self.runtime.maintenanceActive {
                    if self.policy.state.phase != .blocked { self.close("Service installation is in progress.") }
                    continue
                }
                if self.configurationKnown, self.directRestorationAllowed,
                   self.policy.state.configuration.mode == .direct, self.runtime.gateState != "direct" {
                    _ = await self.restoreDirect(configuration: self.policy.state.configuration)
                }
                if self.policy.state.configuration.mode == .direct, self.policy.state.phase == .active {
                    self.requestDirectTrackingRefresh()
                }
                if self.policy.state.configuration.mode.requiresVerification,
                   self.policy.state.phase == .active || self.policy.state.verification != nil {
                    let engineRunning = self.runtime.engineIsAlive()
                    let gate = self.runtime.gateState ?? "unknown"
                    let gateChanged = self.policy.state.phase == .active && gate != "active"
                    if !engineRunning || gateChanged {
                        self.verificationRecoveryPending = true
                        RuntimeLog.shared.error("mimo_liveness_lost", fields: ["engineRunning": String(engineRunning), "gate": gate])
                        self.close(!engineRunning ? "The proxy engine stopped. Verification is required." :
                            "The firewall gate changed. Verification is required.")
                    }
                }
                if self.policy.state.phase == .blocked, self.policy.state.configuration.mode.requiresVerification {
                    do { try await self.runtime.refreshBlockedNativeTransport() }
                    catch is CancellationError { }
                    catch { RuntimeLog.shared.error("mimo_blocked_native_transport_failed", fields: ["reason": error.localizedDescription]) }
                }
                if self.policy.state.phase == .active, self.policy.state.configuration.mode.requiresVerification {
                    let inspectedGeneration = self.generation
                    do {
                        guard self.networkObserver.isRunning, self.powerGuard.isRunning, self.sessionObserver.isRunning,
                              let profile = self.activeProfile, let proxy = self.proxy else {
                            throw MimoRuntimeError.unavailable("The active runtime or network observer changed. Verification is required.")
                        }
                        // Active inspections use the same off-actor readers; they
                        // cannot queue every controller call ahead of a new event.
                        _ = try await self.runtime.inspectReadiness(profile: profile, proxy: proxy, installation: Task {}, recordTiming: false)
                        try await self.runtime.auditPolicies()
                    } catch is CancellationError {
                        // New ownership/closure is ordinary supersession, not a
                        // provider failure or another network verification.
                    } catch {
                        if inspectedGeneration == self.generation, self.policy.state.phase == .active {
                            self.failAudit(error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    func stop() {
        stopping = true
        sessionObserver.stop(); networkObserver.stop(); powerGuard.stop()
        watchdog?.cancel(); infrastructureMonitor?.cancel(); directTrackingTask?.cancel()
        infrastructureScheduler.stop()
        cancelReadiness()
        if policy.state.configuration.mode.requiresVerification { close("The supervisor is restarting.") }
    }

    func drainInfrastructure() async {
        _ = await directRestorationTask?.value
        await protectedClosureTask?.value
        await runtime.drainProtectedIO()
        await directTrackingTask?.value
        await infrastructureMonitor?.value
    }

    private func requestDirectTrackingRefresh(invalidate: Bool = false) {
        guard !stopping, policy.state.configuration.mode == .direct,
              policy.state.phase == .active, directRestorationTask == nil,
              !runtime.networkReleaseRequested else { return }
        directTrackingPending = true
        if invalidate { runtime.cancelNativePolicyUpdates() }
        guard directTrackingTask == nil else { return }
        let ownerGeneration = generation
        directTrackingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.directTrackingTask = nil; self.directTrackingPending = false }
            repeat {
                self.directTrackingPending = false
                guard !Task.isCancelled, !self.stopping, ownerGeneration == self.generation,
                      self.policy.state.configuration.mode == .direct, self.policy.state.phase == .active,
                      self.directRestorationTask == nil, !self.runtime.networkReleaseRequested else { return }
                do { try await self.runtime.refreshDirectTracking() }
                catch is CancellationError { }
                catch {
                    RuntimeLog.shared.error("mimo_direct_tracking_refresh_failed", fields: ["errorType": String(describing: type(of: error))])
                }
            } while self.directTrackingPending
        }
    }

    private func networkChanged(_ reason: String, detail: String = "") {
        guard !stopping, !runtime.networkReleaseRequested else { return }
        if directRestorationTask != nil {
            RuntimeLog.shared.info("mimo_direct_event_ignored", fields: ["source": reason])
            return
        }
        // Prepare arms the protected cycle before its first suspension, while
        // policy.configuration can still describe the previous Direct mode.
        // Honor that cycle first so an early callback and its recorded cause
        // cannot disagree about whether an external change was deferred.
        if powerGuard.fence.isCycleActive {
            if ["infrastructure_recovered", "native_recovered"].contains(reason) { return }
            _ = powerGuard.fence.deferCycleEvent()
            if deferredNetworkReasons.count < 16 { deferredNetworkReasons.insert(detail.isEmpty ? reason : "\(reason): \(detail)") }
            RuntimeLog.shared.info("mimo_cycle_event_deferred", fields: ["source": reason, "detail": detail])
            return
        }
        if configurationKnown, !policy.state.configuration.mode.requiresVerification {
            // Update incoming tracking for a changed local inventory without
            // profile/DNS work, closure or an exit-IP request.
            requestDirectTrackingRefresh(invalidate: true)
            RuntimeLog.shared.info("mimo_direct_tracking_reconcile_requested", fields: ["source": reason])
            return
        }
        powerGuard.fence.beginCycle()
        generation &+= 1
        if policy.state.configuration.mode.requiresVerification {
            // Close public egress now. Prepare owns controller cleanup and the
            // private-probe exceptions; doing both here repeats the same work.
            cancelReadiness()
            activeProfile = nil
            policy.requestingBlock("Blocking traffic and preparing verification.")
            let gate = runtime.requestApplicationGate()
            let epoch = generation
            Task {
                do {
                    guard epoch == generation else { return }
                    try await runtime.confirmApplicationGate(gate)
                    guard epoch == generation else { return }
                    policy.block("Network or system state changed. Verification is required.")
                    RuntimeLog.shared.info("mimo_gate_closed", fields: ["confirmed": "true", "reason": "network_change"])
                } catch {
                    guard epoch == generation, !(error is CancellationError) else { return }
                    close(error.localizedDescription, strictOnly: true)
                }
            }
        }
        RuntimeLog.shared.info("mimo_network_changed", fields: ["source": reason, "detail": detail, "generation": String(generation)])
        if coreEnabled { Task { try? await coreNetworkChanged?() } }
    }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        accept(connection, installedApp: false)
    }

    nonisolated func accept(_ connection: NSXPCConnection, installedApp: Bool) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MimoDaemonProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: MimoDaemonObserver.self)
        connection.exportedObject = MimoSupervisorSession(supervisor: self, connection: connection, installedApp: installedApp)
        connection.resume()
        return true
    }

    func handle(_ request: DaemonRequest, uid: uid_t, pid: pid_t,
                receivedAt: ContinuousClock.Instant = .now, installedApp: Bool = false,
                progress: (@MainActor @Sendable (DaemonResponse) -> Void)? = nil) async -> DaemonResponse {
        guard request.protocolVersion == MimoService.protocolVersion else { return DaemonResponse(failure: .incompatible) }
        guard request.command == .supervisor, let message = request.supervisor else { return DaemonResponse(failure: .invalidRequest) }
        if ![.heartbeat, .state].contains(message.command) {
            RuntimeLog.shared.info("mimo_supervisor_command_received", fields: message.diagnosticFields)
        }
        do {
            guard !stopping || [.state, .heartbeat].contains(message.command) else { return DaemonResponse(failure: .unavailable) }
            if message.command == .service || message.command == .profile {
                guard installedApp || uid == 0 || ServiceAuthorization.validate(request.authorization) else { throw DaemonFailure.unauthorized }
            } else if message.command != .state {
                guard uid == 0 else { throw DaemonFailure.unauthorized }
            }
            // A caller may disappear, but an accepted physical release must be
            // joined before any newer mutation can arm/open protected routing.
            // Reads never wait for PF, DNS, controller or lifecycle locks.
            if ![.state, .heartbeat].contains(message.command), let release = directRestorationTask {
                _ = await release.value
            }
            if ![.state, .heartbeat].contains(message.command), let closure = protectedClosureTask { await closure.value }
            if message.command == .service {
                // Invalid read-only access probes cannot perform an operation and
                // must not wait behind an unrelated verification cycle.
                guard message.service != nil, message.operation != nil else { throw DaemonFailure.conflict }
                try await controls.wait(command: "\(message.service?.rawValue ?? "service") \(message.operation?.rawValue ?? "change")") {
                    self.powerGuard.fence.isCycleActiveOrBusy || self.operationPending
                }
            }
            guard !runtime.maintenanceActive || [.state, .heartbeat, .close].contains(message.command) else {
                throw MimoRuntimeError.unavailable("Service installation is in progress.")
            }
            if let stamp = message.stamp, message.command != .state {
                let previousProcess = commandFence.processID
                guard commandFence.accept(stamp, peer: pid, currentCore: getpid(),
                                          enabled: true, heartbeat: message.command == .heartbeat) else {
                    var fields = message.diagnosticFields
                    fields["reason"] = "ordering_or_core_identity"
                    fields["peerPID"] = String(pid)
                    fields["currentCorePID"] = String(getpid())
                    RuntimeLog.shared.info("mimo_command_rejected", fields: fields)
                    throw DaemonFailure.conflict
                }
                // Every ordered request from the live core proves liveness. Profile
                // preparation can occupy this actor while a heartbeat waits in XPC;
                // do not measure its deadline from an older idle-state poll.
                if let previousProcess, previousProcess != pid {
                    generation &+= 1
                    if policy.state.configuration.mode.requiresVerification { close("Core restarted. Verification is required.") }
                }
                // After a supervisor restart there is no in-memory ordering history.
                // Persisted revision/mode still forbid an old Direct or approval.
                if [.direct, .prepare, .approve, .observe, .completeObservation, .updatePolicy].contains(message.command) {
                    let saved = try runtime.savedRouting()
                    guard MimoCommandFence.matchesSavedRouting(message, configuration: saved.configuration,
                                                               revision: saved.revision) else {
                        var fields = message.diagnosticFields
                        fields["reason"] = "saved_configuration_changed"; fields["savedRevision"] = String(saved.revision)
                        RuntimeLog.shared.info("mimo_command_rejected", fields: fields)
                        throw DaemonFailure.conflict
                    }
                }
            } else if message.command != .state, pid == getpid() {
                // Root administrator recovery is independent of core. Core itself
                // must use ordered requests; never silently downgrade its protocol.
                throw DaemonFailure.invalidRequest
            }
            switch message.command {
            case .profile:
                var result = DaemonResponse()
                result.profileContents = try runtime.profileContents()
                return result
            case .state:
                checkActiveDNSConfiguration()
                if message.includeEvents == true {
                    var response = DaemonResponse(events: RuntimeLog.shared.recentLines())
                    response.diagnosticEvents = RuntimeLog.shared.recentDiagnosticRecords()
                    return response
                }
            case .heartbeat:
                checkActiveDNSConfiguration()
            case .close:
                if let expected = message.verification,
                   policy.state.phase != .checking || policy.state.verification != expected {
                    RuntimeLog.shared.info("mimo_verification_failure_ignored", fields: message.diagnosticFields)
                    throw DaemonFailure.conflict
                }
                directRestorationAllowed = false
                // A lookup/provider failure revokes traffic approval, not a
                // previously qualified unchanged profile. The next prepare
                // still clears connections and requires a fresh allowed IP.
                close(message.reason ?? "Network or configuration changed. Verification is required.", strictOnly: true)
                if let closure = protectedClosureTask { await closure.value }
            case .direct:
                if runtime.networkReleaseRequested {
                    // Heartbeats and saved Direct cannot reacquire networking.
                    return response()
                }
                consumeVerificationRecovery(message, outcome: "direct")
                if policy.state.phase == .active, policy.state.effectiveMode == .direct,
                   !runtime.closed, runtime.gateState == "direct" {
                    // A startup request may arrive after startup already restored
                    // Direct. Acknowledge it without reloading the same profile.
                    policy.directRestored(configuration: message.configuration ?? policy.state.configuration, nativeIssue: runtime.nativeReleaseIssue)
                    return response()
                }
                return await restoreDirect(configuration: message.configuration ?? policy.state.configuration, progress: progress)
            case .updatePolicy:
                guard let allowed = message.allowlist else { throw DaemonFailure.invalidRequest }
                allowlist = allowed
                // Revoke a known disallowed address before acknowledging the edit.
                // A relaxed policy never opens a blocked path on cached evidence.
                if policy.state.configuration.mode.requiresVerification,
                   let observed = policy.state.observedIP, !allowed.contains(observed.address),
                   policy.state.allowsTraffic || policy.state.phase == .checking {
                    let ownerGeneration = generation
                    let verification = policy.state.verification
                    activeProtectedLease?.cancel(); runtime.cancelProtectedIO()
                    // A grant may have completed physically while its actor
                    // continuation still waits. Revoke that known address before
                    // acknowledging the edit, retaining its displayed observation.
                    try await runtime.holdApplicationGateOnline()
                    await runtime.drainProtectedIO()
                    guard ownerGeneration == generation else { throw CancellationError() }
                    if let verification, policy.state.phase == .checking {
                        _ = policy.approve(address: observed.address, at: observed.checkedAt, allowlist: allowed,
                            verification: verification, runtimeMatches: false)
                        finishEventCycle()
                    } else { _ = policy.revokeDisallowed(allowed) }
                    RuntimeLog.shared.info("mimo_policy_revoked", fields: message.diagnosticFields)
                }
            case .observe:
                guard policy.state.allowsTraffic, policy.state.configuration.mode.requiresVerification,
                      !infrastructureRecoveryPending, !operationPending,
                      let epoch = verificationPowerEpoch, let revision = message.revision,
                      let network = message.networkGeneration else { throw DaemonFailure.conflict }
                try runtime.validateObservation()
                try powerGuard.fence.activate(epoch: epoch) {
                    guard policy.beginObservation(revision: revision, networkGeneration: network) != nil else { throw DaemonFailure.conflict }
                }
                var fields = message.diagnosticFields
                fields["attempt"] = policy.state.observation?.id.uuidString; fields["gate"] = "allowed"
                RuntimeLog.shared.info("mimo_observation_started", fields: fields)
            case .completeObservation:
                guard let check = message.verification, check == policy.state.observation,
                      let observations = message.exitObservations, let since = check.startedAt,
                      observations.isValid(for: check, family: policy.state.configuration.networkFamily, since: since),
                      policy.state.allowsTraffic, let epoch = verificationPowerEpoch else { throw DaemonFailure.conflict }
                try runtime.validateObservation()
                allowlist = try runtime.savedAllowlist()
                // No beginCycle: route/power events revoke immediately while HTTP
                // is outstanding. The epoch also fences events before actor delivery.
                try powerGuard.fence.activate(epoch: epoch) {
                    if !allowlist.contains(observations.ipv4.ipAddress) { try runtime.holdApplicationGate() }
                    _ = policy.finishObservation(observations, allowlist: allowlist)
                }
                var fields = message.diagnosticFields
                fields["gate"] = policy.state.allowsTraffic ? "allowed" : "blocked"
                RuntimeLog.shared.info(policy.state.allowsTraffic ? "mimo_observation_approved" : "mimo_exit_ip_rejected", fields: fields)
            case .observationFailed:
                if let check = message.verification, check == policy.state.observation, policy.state.allowsTraffic {
                    try runtime.validateObservation()
                    guard let epoch = verificationPowerEpoch else { throw DaemonFailure.conflict }
                    try powerGuard.fence.activate(epoch: epoch) { policy.failObservation(check) }
                    var fields = message.diagnosticFields; fields["gate"] = "allowed"
                    RuntimeLog.shared.info("mimo_observation_failed", fields: fields)
                }
            case .prepare:
                guard !runtime.networkReleaseRequested else { throw DaemonFailure.conflict }
                var timing = MimoTransitionTiming("prepare")
                directRestorationAllowed = false
                guard let configuration = message.configuration, configuration.mode.requiresVerification,
                      let revision = message.revision, let network = message.networkGeneration, let allowed = message.allowlist else { throw DaemonFailure.invalidRequest }
                allowlist = allowed
                generation &+= 1
                let epoch = generation
                cancelReadiness()
                activeProfile = nil
                if runtime.closed, [.blocked, .validating, .checking].contains(policy.state.phase) {
                    policy.block("Preparing verification. Internet remains blocked.")
                } else {
                    policy.requestingBlock("Blocking traffic and preparing verification.")
                }
                let gate = runtime.requestApplicationGate()
                await runtime.drainProtectedIO()
                guard epoch == generation else { throw CancellationError() }
                let fence = powerGuard.fence
                guard let armed = await directFenceQueue.run({ Result { let value = try fence.arm(); fence.beginCycle(); return value } }) else { throw CancellationError() }
                guard epoch == generation else { throw CancellationError() }
                let powerEpoch = try armed.get()
                verificationPowerEpoch = powerEpoch
                let lease = runtime.beginProtectedIO(configuration: configuration, revision: revision)
                activeProtectedLease = lease
                var validated = try configuration.validated()
                validated.profileHostingEnabled = profileEnabled; validated.mihomoEnabled = engineEnabled
                guard coreEnabled, engineEnabled, profileEnabled else { throw MimoRuntimeError.unavailable("A required background service is stopped.") }
                guard let metadata = validated.proxy else { throw MimoRuntimeError.unavailable("Save a proxy in Settings.") }
                // Recovery requests one fresh attempt, not an approved address.
                // A healthy lookup can legitimately remain blocked by policy.
                // Consume before suspending; a new runtime/liveness failure
                // below may independently arm another recovery attempt.
                consumeVerificationRecovery(message, outcome: "prepare")
                let runtime = self.runtime
                let policyMode = validated.mode
                let literalAddress = IPAddressValidator.normalize(metadata.server)
                let cachedPolicy = try await runtime.cachedProbePolicy(endpoints: literalAddress.map { [$0] } ?? [],
                    proxyPort: literalAddress == nil ? nil : metadata.port, mode: policyMode)
                let initialPolicy = Task.detached {
                    if let cachedPolicy {
                        var timing = MimoTransitionTiming("firewall_preparation")
                        timing.record("rule_reuse")
                        return cachedPolicy
                    }
                    return try await runtime.prepareProbePolicy(endpoints: literalAddress.map { [$0] } ?? [],
                                                         proxyPort: literalAddress == nil ? nil : metadata.port, mode: policyMode)
                }
                firewallPreparation = initialPolicy
                let installation = Task.detached {
                    try await runtime.readinessChecks.validateInstallation { try runtime.checkInstallation() }
                }
                installationCheck = installation
                let password = try probePassword()
                let mode = validated.mode
                let family = validated.networkFamily
                let bypassBlocks = try runtime.savedBypassBlocks()
                let privateDNS = try runtime.nativeDNSRules()
                let mustReload = forceProfileReload
                let cleanup = runtime.requestConnectionCleanup()
                let preparation = Task { () throws -> PreparedCandidate in
                    guard let result = await preparationQueue.run({ Result { () throws -> (ClashProxySettings, String?) in
                        var preparationTiming = MimoTransitionTiming("preparation")
                        let candidate = try runtime.savedProxy(configuration: configuration, revision: revision)
                        let profile = IPAddressValidator.normalize(candidate.server) == nil ? nil :
                            try MihomoProfile.render(candidate, mode: mode, stage: .active, probePassword: password, bypassBlocks: bypassBlocks, family: family, privateDNS: privateDNS)
                        preparationTiming.record("credentials_and_render")
                        return (candidate, profile)
                    } }) else { throw CancellationError() }
                    try Task.checkCancellation()
                    guard epoch == generation else { throw CancellationError() }
                    let (proxy, profile) = try result.get()
                    var preflightTiming = MimoTransitionTiming("profile")
                    let reused = profile.map { !mustReload && runtime.canReuseProfile($0) } ?? false
                    if reused, let profile {
                    }
                    preflightTiming.record("profile_preflight")
                    return PreparedCandidate(proxy: proxy, profile: profile, reused: reused)
                }
                profilePreparation = preparation
                RuntimeLog.shared.info("mimo_parallel_preparation_started")
                do { try await runtime.confirmApplicationGate(gate) }
                catch {
                    guard epoch == generation else { throw CancellationError() }
                    throw error
                }
                guard epoch == generation, runtime.closed else { throw CancellationError() }
                timing.record("confirmed_close")
                let preparedPolicy: MimoPreparedProbePolicy
                do { preparedPolicy = try await initialPolicy.value }
                catch {
                    guard epoch == generation else { throw CancellationError() }
                    throw error
                }
                guard epoch == generation, !runtime.maintenanceActive else { throw CancellationError() }
                timing.record("rule_validation_join")
                // No profile wait or service-status work between confirmed
                // blocking and installation of the already-validated rules.
                try await runtime.installProbePolicyOnline(preparedPolicy, lease: lease)
                guard epoch == generation else { throw CancellationError() }
                timing.record("probe_policy")
                policy.block("Validating the protected profile.")
                RuntimeLog.shared.info("mimo_gate_closed", fields: ["confirmed": "true", "reason": "prepare"])
                progress?(response())
                let check = policy.begin(configuration: validated, revision: revision, networkGeneration: network)
                guard networkObserver.isRunning, powerGuard.isRunning, sessionObserver.isRunning else { throw MimoRuntimeError.unavailable("Network, session or power change observation is unavailable. Repair installation.") }
                let candidate: PreparedCandidate
                do { candidate = try await preparation.value }
                catch {
                    guard epoch == generation else { throw CancellationError() }
                    throw error
                }
                guard epoch == generation, check == policy.state.verification else { throw CancellationError() }
                var proxy = candidate.proxy
                var reused = candidate.reused
                var finalProfile = candidate.profile
                timing.record("preparation_join")
                func joinCleanup() async throws {
                    do { try await runtime.confirmConnectionCleanup(cleanup) }
                    catch {
                        guard epoch == generation else { throw CancellationError() }
                        if !(error is CancellationError) {
                            verificationRecoveryPending = true
                            RuntimeLog.shared.info("mimo_controller_recovery_pending")
                        }
                        throw error
                    }
                    guard epoch == generation, policy.state.verification == check else { throw CancellationError() }
                }
                let hostname = IPAddressValidator.normalize(proxy.server) == nil
                if hostname {
                    // Bootstrap must not follow the previous TUN/profile. An
                    // empty endpoint policy cannot reach that profile's proxy.
                    // Retire it while PF is closed, before permitting DNS.
                    // Literal IPv4 endpoints skip this dependency entirely.
                    try await joinCleanup()
                    try await runtime.prepareHostnameBootstrapOnline(lease: lease)
                    timing.record("hostname_bootstrap_profile")
                    // The preinstalled policy permits only bootstrap DNS.
                    try await runtime.permitPrivateProbeOnline(lease: lease, fence: powerGuard.fence, powerEpoch: powerEpoch)
                    RuntimeLog.shared.info("mimo_bootstrap_permitted")
                }
                let address: String
                do { address = try await resolve(proxy.server) }
                catch {
                    guard epoch == generation else { throw CancellationError() }
                    throw error
                }
                guard epoch == generation, policy.state.verification == check, !runtime.maintenanceActive else { throw CancellationError() }
                proxy.server = address
                networkObserver.setProxyEndpoint(address)
                if finalProfile == nil {
                    let rendered = try MihomoProfile.render(proxy, mode: mode, stage: .active, probePassword: password, bypassBlocks: bypassBlocks, family: family, privateDNS: privateDNS)
                    finalProfile = rendered
                    reused = !mustReload && runtime.canReuseProfile(rendered)
                }
                guard let finalProfile else { throw DaemonFailure.invalidRequest }
                if hostname {
                    // A hostname cannot have endpoint-specific rules until its
                    // A record is known. Re-block while validating those rules,
                    // then install them before permitting any private IP probe.
                    let proxyPort = proxy.port
                    let endpointPolicy = Task.detached {
                        try await runtime.prepareProbePolicy(endpoints: [address], proxyPort: proxyPort, mode: mode)
                    }
                    firewallPreparation = endpointPolicy
                    try await runtime.holdApplicationGateOnline()
                    guard epoch == generation else { throw CancellationError() }
                    let preparedEndpoint: MimoPreparedProbePolicy
                    do { preparedEndpoint = try await endpointPolicy.value }
                    catch {
                        guard epoch == generation else { throw CancellationError() }
                        throw error
                    }
                    guard epoch == generation, check == policy.state.verification else { throw CancellationError() }
                    try await runtime.installProbePolicyOnline(preparedEndpoint, lease: lease)
                    timing.record("endpoint_probe_policy")
                }
                if !hostname { try await joinCleanup() }
                if !reused { try await runtime.loadProtectedProfile(finalProfile, lease: lease) }
                guard epoch == generation, check == policy.state.verification else { throw CancellationError() }
                forceProfileReload = false
                try await runtime.configureProtectedDNSOnline(lease: lease)
                if profileInspection == nil {
                    profileInspection = try runtime.startReadiness(profile: finalProfile, proxy: proxy, installation: installation)
                }
                self.proxy = proxy; endpoint = address; activeProfile = finalProfile
                RuntimeLog.shared.info(reused ? "mimo_final_profile_reused" : "mimo_final_profile_loaded", fields: ["attempt": check.id.uuidString])
                let readinessGeneration = generation
                if let inspection = profileInspection {
                    readinessCheck = Task { [weak self] in
                        guard let self else { throw CancellationError() }
                        do {
                            try Task.checkCancellation()
                            guard readinessGeneration == self.generation, check == self.policy.state.verification else { throw CancellationError() }
                            RuntimeLog.shared.info("mimo_readiness_started", fields: ["attempt": check.id.uuidString])
                            let receipt = try await inspection.value
                            try Task.checkCancellation()
                            guard readinessGeneration == self.generation, check == self.policy.state.verification else { throw CancellationError() }
                            try await runtime.confirmReadinessOnline(receipt, lease: lease)
                            guard readinessGeneration == self.generation, check == self.policy.state.verification else { throw CancellationError() }
                            self.completedReadiness = receipt
                            RuntimeLog.shared.info("mimo_readiness_passed", fields: ["attempt": check.id.uuidString])
                            return receipt
                        } catch {
                            if !(error is CancellationError), readinessGeneration == self.generation, check == self.policy.state.verification {
                                self.forceProfileReload = true
                                self.close(error.localizedDescription, strictOnly: true)
                            }
                            throw error
                        }
                    }
                }
                policy.checking(check)
                // Build status before opening even the private path. Permission
                // is the last privileged action before the core receives its
                // ready reply and starts the IP request.
                var ready = response()
                var permissionTiming = MimoTransitionTiming("permission")
                try await runtime.permitPrivateProbeOnline(lease: lease, fence: powerGuard.fence, powerEpoch: powerEpoch)
                permissionTiming.record("permit_private_probe")
                timing.record("private_probe_join")
                RuntimeLog.shared.info("mimo_private_probe_barrier_ready", fields: ["attempt": check.id.uuidString])
                var probeFields = message.diagnosticFields
                probeFields["revision"] = String(revision); probeFields["generation"] = String(network)
                probeFields["attempt"] = check.id.uuidString
                RuntimeLog.shared.info("mimo_private_probe_ready", fields: probeFields)
                requestInfrastructureReconciliation("private_probe_ready")
                ready.routing?.supervisorCheckedAt = .now
                return ready
            case .approve:
                var timing = MimoTransitionTiming("approve")
                guard let lease = activeProtectedLease, let check = message.verification, check == policy.state.verification,
                      policy.state.phase == .checking, let address = message.address,
                      let activeProfile, let proxy, endpoint != nil else { throw DaemonFailure.conflict }
                guard let observations = message.exitObservations, let since = check.startedAt,
                      observations.isValid(for: check, family: policy.state.configuration.networkFamily, since: since) else {
                    throw MimoRuntimeError.unavailable("A fresh IPv4 exit observation is required.")
                }
                allowlist = try runtime.savedAllowlist()
                if !allowlist.contains(observations.ipv4.ipAddress) {
                    _ = policy.approve(observations: observations, allowlist: allowlist, verification: check, runtimeMatches: false)
                    try runtime.holdApplicationGate()
                    RuntimeLog.shared.info("mimo_exit_ip_rejected", fields: ["attempt": check.id.uuidString,
                        "family": policy.state.configuration.networkFamily.rawValue, "approvalFamily": "ipv4",
                        "emptyAllowlist": String(allowlist.isEmpty), "reason": policy.state.reason])
                    finishEventCycle(); return response()
                }
                let activationGeneration = generation
                RuntimeLog.shared.info("mimo_exits_approved", fields: ["attempt": check.id.uuidString, "family": policy.state.configuration.networkFamily.rawValue, "approvalFamily": "ipv4"])
                guard let readinessCheck else { throw DaemonFailure.conflict }
                policy.waitingForReadiness(address: address, verification: check)
                if completedReadiness == nil { progress?(response()) }
                let receipt: MimoReadinessReceipt
                do { receipt = try await readinessCheck.value }
                catch {
                    // A completed readiness task can deliver its error after
                    // Direct or a replacement preparation has already won.
                    // That obsolete error must not reach the failure closer.
                    guard !Task.isCancelled, activationGeneration == generation,
                          check == policy.state.verification else {
                        var fields = message.diagnosticFields
                        fields["reason"] = "readiness_error_superseded"
                        RuntimeLog.shared.info("mimo_approval_result_cancelled", fields: fields)
                        throw CancellationError()
                    }
                    throw error
                }
                // Task cancellation cannot revoke an already completed result.
                // Check ownership before validating or accepting its baseline.
                guard !Task.isCancelled, activationGeneration == generation,
                      check == policy.state.verification else {
                    var fields = message.diagnosticFields
                    fields["reason"] = "readiness_result_superseded"
                    RuntimeLog.shared.info("mimo_approval_result_cancelled", fields: fields)
                    throw CancellationError()
                }
                try await runtime.acceptBaselineOnline(receipt, lease: lease)
                guard activationGeneration == generation, check == policy.state.verification,
                      self.activeProfile == activeProfile, runtime.receiptMatchesLoadedProfile(receipt),
                      networkObserver.isRunning, powerGuard.isRunning, sessionObserver.isRunning,
                      !infrastructureRecoveryPending else {
                    throw MimoRuntimeError.unavailable("The runtime changed before opening. A fresh check is required.")
                }
                timing.record("opening_join")
                RuntimeLog.shared.info("mimo_opening_barrier_ready", fields: ["attempt": check.id.uuidString])
                // Readiness awaited independent work. A policy-only edit may
                // have committed meanwhile without invalidating the path.
                allowlist = try runtime.savedAllowlist()
                if !allowlist.contains(observations.ipv4.ipAddress) {
                    try runtime.holdApplicationGate()
                    _ = policy.approve(observations: observations, allowlist: allowlist, verification: check, runtimeMatches: false)
                    RuntimeLog.shared.info("mimo_exit_ip_rejected", fields: message.diagnosticFields)
                    finishEventCycle(); return response()
                }
                guard let powerEpoch = verificationPowerEpoch else { throw CancellationError() }
                try await runtime.openGateOnline(receipt: receipt, address: observations.ipv4.ipAddress, lease: lease, fence: powerGuard.fence, powerEpoch: powerEpoch)
                guard activationGeneration == generation, check == policy.state.verification else { throw CancellationError() }
                allowlist = try runtime.savedAllowlist()
                guard policy.approve(observations: observations, allowlist: allowlist, verification: check, runtimeMatches: true) else {
                    close("The active profile did not match the verified candidate."); return response()
                }
                verifiedRecovery()
                self.readinessCheck = nil; installationCheck = nil
                firewallPreparation = nil; profilePreparation = nil; profileInspection = nil; completedReadiness = nil
                timing.record("open_gate")
                RuntimeLog.shared.info("mimo_traffic_opened", fields: ["mode": policy.state.configuration.mode.rawValue,
                    "ip": address, "family": policy.state.configuration.networkFamily.rawValue, "attempt": check.id.uuidString])
                requestInfrastructureReconciliation("protected_active")
                deferredNetworkReasons.removeAll()
            case .service:
                guard !operationPending, let service = message.service, let operation = message.operation else { throw DaemonFailure.conflict }
                operationPending = true; defer { operationPending = false }
                if service == .mihomo, operation == .stop {
                    try await releaseEngine(progress: progress)
                    return response()
                }
                if service == .mihomo, runtime.networkReleaseRequested {
                    try runtime.checkEngineStartConflicts()
                    var flags = try runtime.servicePreferences()
                    flags.releaseNetwork = false; flags.engine = true
                    try runtime.saveServicePreferences(flags)
                    engineEnabled = true; cachedServices = nil
                    try runtime.ensureBootGuard()
                    try runtime.service(.mihomo, operation: .start)
                    let restored = await restoreDirect(configuration: policy.state.configuration, progress: progress)
                    guard restored.routing?.effectiveMode == .direct else { return restored }
                    try await coreNetworkChanged?()
                    return response()
                }
                let savedMode = try runtime.savedConfiguration().mode
                if savedMode.requiresVerification || policy.state.configuration.mode.requiresVerification {
                    directRestorationAllowed = false
                    let closedImmediately = close("A required service is changing state. Internet remains blocked.", strictOnly: true)
                    if let closure = protectedClosureTask { await closure.value }
                    guard closedImmediately || runtime.closed else {
                        RuntimeLog.shared.error("mimo_service_change_aborted", fields: ["service": service.rawValue, "operation": operation.rawValue, "reason": "gate_not_confirmed"])
                        var failure = response(); failure.failure = .unavailable
                        progress?(failure)
                        return failure
                    }
                    // Deliver confirmed blocking before launchd/controller work,
                    // which can occupy this actor for several seconds.
                    progress?(response())
                    // Strict PF blocking has no public engine/probe exception.
                    // A broken controller must not prevent replacing the engine.
                    do { try runtime.disconnectFlows() }
                    catch { RuntimeLog.shared.info("mimo_service_controller_unavailable", fields: ["gate": "strictly_blocked"]) }
                }
                RuntimeLog.shared.info("mimo_service_change_begin", fields: ["service": service.rawValue, "operation": operation.rawValue,
                    "protected": String(savedMode.requiresVerification), "closed": String(runtime.closed)])
                forceProfileReload = true
                // Persist intent before the launchd operation. A crash during Stop must
                // never turn into an automatic Start on the next boot.
                switch service {
                case .core:
                    generation &+= 1
                    try updateFlag(.core, enabled: operation != .stop)
                    monitoringOperation?(operation)
                case .mihomo:
                    try updateFlag(.mihomo, enabled: operation != .stop)
                    try runtime.service(service, operation: operation)
                case .profileHosting:
                    try updateFlag(.profileHosting, enabled: operation != .stop)
                    if operation != .stop, policy.state.configuration.mode == .direct {
                        try runtime.loadProfile(MihomoProfile.blocking())
                    }
                }
                RuntimeLog.shared.info("mimo_service_changed", fields: ["service": service.rawValue, "operation": operation.rawValue])
            }
            if ![.state, .heartbeat].contains(message.command), let closure = protectedClosureTask { await closure.value }
            return response()
        } catch is MimoDeferredNetworkChange {
            close("Network changed during verification. Keeping traffic blocked for one follow-up check.", strictOnly: true)
            if let closure = protectedClosureTask { await closure.value }
            return response()
        } catch let failure as DaemonFailure {
            if message.command == .prepare { finishEventCycle() }
            return DaemonResponse(failure: failure)
        } catch {
            if message.command == .profile { return DaemonResponse(failure: .unavailable) }
            if !(error is CancellationError) {
                runtime.revokeBaseline()
                if [.prepare, .approve, .observe, .completeObservation, .observationFailed].contains(message.command), policy.state.configuration.mode.requiresVerification {
                    verificationRecoveryPending = true
                }
                if message.command == .service, message.service == .mihomo, message.operation != .stop,
                   runtime.networkReleaseRequested, runtime.gateState == "released" {
                    policy.networkReleased(configuration: policy.state.configuration, reason: error.localizedDescription)
                } else { close(error.localizedDescription) }
            }
            if let closure = protectedClosureTask { await closure.value }
            if message.command == .service {
                RuntimeLog.shared.error("mimo_service_change_failed", fields: ["service": message.service?.rawValue ?? "unknown",
                    "operation": message.operation?.rawValue ?? "unknown"])
                var failure = response(); failure.failure = .unavailable
                progress?(failure)
                return failure
            }
            return response()
        }
    }

    private func restoreDirect(configuration: MimoConfiguration,
                               progress: (@MainActor @Sendable (DaemonResponse) -> Void)? = nil) async -> DaemonResponse {
        if let existing = directRestorationTask { return await existing.value }
        deferredNetworkReasons.removeAll()
        cancelReadiness()
        generation &+= 1
        let ownerGeneration = generation
        directRestorationAllowed = false
        configurationKnown = true
        proxy = nil; endpoint = nil; activeProfile = nil
        networkObserver.setProxyEndpoint(nil)
        policy.restoringDirect(configuration: configuration)
        progress?(response())
        let task = Task { [self] in
            defer {
                directRestorationTask = nil
                requestInfrastructureReconciliation("direct_finished")
            }
            do {
                await runtime.drainProtectedIO()
                // Even acquiring this lock can wait for an independent power
                // callback's PF work. Join that wait off the control actor too.
                try await disarmDirectFence()
                try await runtime.restoreDirectOnline()
                guard ownerGeneration == generation else { return response() }
                policy.directRestored(configuration: configuration, nativeIssue: runtime.nativeReleaseIssue)
                directRestorationAllowed = true
                RuntimeLog.shared.info("mimo_direct_restored")
            } catch {
                guard ownerGeneration == generation else { return response() }
                RuntimeLog.shared.error("mimo_direct_worker_failed")
                // The release and conditional failure-close children have both
                // exited. Never synchronously retry a PF operation on this actor.
                policy.block(runtime.closed
                    ? "Direct cleanup did not complete. Retry Direct or Stop engine."
                    : "Direct cleanup did not complete and firewall status is unavailable. Retry Direct or Stop engine.",
                    confirmed: runtime.closed)
            }
            let result = response()
            progress?(result)
            return result
        }
        directRestorationTask = task
        // Unstructured ownership deliberately survives caller cancellation.
        return await task.value
    }

    private func disarmDirectFence() async throws {
        let fence = powerGuard.fence
        guard let disarmed = await directFenceQueue.run({ Result { try fence.direct {} } }) else {
            throw CancellationError()
        }
        try disarmed.get()
    }

    private func releaseEngine(progress: (@MainActor @Sendable (DaemonResponse) -> Void)? = nil) async throws {
        // Save intent before cancelling writers or stopping launchd. Repair and
        // a restarted supervisor must complete this cleanup, never undo it.
        var flags = try runtime.servicePreferences()
        flags.releaseNetwork = true; flags.engine = false
        try runtime.saveServicePreferences(flags)
        engineEnabled = false; cachedServices = nil
        generation &+= 1; cancelReadiness()
        deferredNetworkReasons.removeAll()
        activeProfile = nil; proxy = nil; endpoint = nil
        networkObserver.setProxyEndpoint(nil)
        directRestorationAllowed = false
        policy.releasing(configuration: policy.state.configuration)
        progress?(response())
        await runtime.drainProtectedIO()
        try await disarmDirectFence()
        var coreError: Error?
        do {
            if let coreNetworkChanged { try await coreNetworkChanged() }
            else { _ = try runtime.persistDirectRecovery() }
        } catch { coreError = error }
        // Still restore networking if the control channel has failed.
        try await runtime.releaseNetworking()
        if let coreError { throw coreError }
        policy.networkReleased(configuration: policy.state.configuration)
        requestInfrastructureReconciliation("network_released")
        cachedServices = nil
        progress?(response())
    }

    private func requestInfrastructureReconciliation(_ reason: String) {
        guard !stopping else { return }
        infrastructureScheduler.request(reason: reason)
    }

    private func infrastructureInspectionFailed(_ error: Error, generation inspectedGeneration: UInt64) {
        guard directRestorationTask == nil, inspectedGeneration == generation else {
            RuntimeLog.shared.info("mimo_infrastructure_result_ignored", fields: ["reason": "operation_superseded"])
            return
        }
        // A persistent fault is one recovery episode. Re-closing on every
        // failed scan would wake reconciliation again and form a fast loop.
        guard !infrastructureRecoveryPending || infrastructureFailureGeneration != generation else { return }
        infrastructureRecoveryPending = true
        close(error.localizedDescription)
        infrastructureFailureGeneration = generation
    }

    private func failAudit(_ reason: String) {
        RuntimeLog.shared.error("mimo_verification_audit_failed", fields: ["reason": reason])
        runtime.revokeBaseline()
        forceProfileReload = true
        verificationRecoveryPending = true
        close(reason, strictOnly: true)
    }

    private func checkActiveDNSConfiguration() {
        guard policy.state.phase == .active, policy.state.configuration.mode.requiresVerification,
              !runtime.protectedDNSConfigurationMatches else { return }
        // Status publication must not depend on a background inspection task
        // finishing before a missing resolver revokes an Allowed presentation.
        RuntimeLog.shared.error("mimo_dns_configuration_lost")
        failAudit("Protected DNS resolver disappeared or changed. Verification is required.")
    }

    private func verifiedRecovery() {
        verificationRecoveryPending = false
    }

    private func consumeVerificationRecovery(_ message: MimoSupervisorRequest, outcome: String) {
        guard verificationRecoveryPending else { return }
        verificationRecoveryPending = false
        var fields = message.diagnosticFields
        fields["outcome"] = outcome
        RuntimeLog.shared.info("mimo_recovery_verification_consumed", fields: fields)
    }

    private func cancelReadiness() {
        activeProtectedLease?.cancel(); activeProtectedLease = nil
        runtime.cancelProtectedIO()
        runtime.cancelConnectionCleanup()
        firewallPreparation?.cancel(); firewallPreparation = nil
        profilePreparation?.cancel(); profilePreparation = nil
        profileInspection?.cancel(); profileInspection = nil
        completedReadiness = nil
        readinessCheck?.cancel(); readinessCheck = nil
        installationCheck?.cancel(); installationCheck = nil
    }

    @discardableResult
    private func close(_ reason: String, strictOnly: Bool = false) -> Bool {
        guard !runtime.networkReleaseRequested else {
            policy.releasing(configuration: policy.state.configuration, error: reason)
            return false
        }
        let usesWorker = runtime.hasProtectedOwnership
        generation &+= 1
        let ownerGeneration = generation
        cancelReadiness()
        activeProfile = nil
        if usesWorker {
            policy.requestingBlock(reason)
            let gate = runtime.requestApplicationGate()
            let previous = protectedClosureTask
            let closureID = UUID(); protectedClosureID = closureID
            protectedClosureTask = Task { [self] in
                defer {
                    if protectedClosureID == closureID {
                        protectedClosureTask = nil
                        requestInfrastructureReconciliation("protected_close_finished")
                    }
                }
                await previous?.value
                do {
                    // Early denial runs independently of slow profile work.
                    try await runtime.confirmApplicationGate(gate)
                    await runtime.drainProtectedIO()
                    guard ownerGeneration == generation else { return }
                    policy.block(reason, confirmed: runtime.closed)
                    RuntimeLog.shared.info("mimo_gate_closed", fields: ["confirmed": String(runtime.closed), "reason": reason])
                } catch {
                    guard ownerGeneration == generation else { return }
                    policy.block("\(reason) Firewall status is unavailable.", confirmed: false)
                }
                finishEventCycle()
            }
            return false
        }
        var succeeded = false
        do {
            // Revoke public engine egress as well as application access before asking
            // an old/hung controller to discard flows. Queued old engine data
            // must not resume through a verification endpoint exception.
            try runtime.holdApplicationGate()
            if !strictOnly {
                try runtime.disconnectFlows()
                try runtime.closeGate(endpoints: endpoint.map { [$0] } ?? [], proxyPort: proxy?.port)
            }
            policy.block(reason)
            succeeded = runtime.closed
        }
        catch { policy.block("\(reason) Firewall status is unavailable: \(error.localizedDescription)", confirmed: false) }
        RuntimeLog.shared.info("mimo_gate_closed", fields: ["confirmed": String(succeeded), "reason": reason])
        requestInfrastructureReconciliation("close_finished")
        finishEventCycle()
        return succeeded
    }

    private func finishEventCycle() {
        let changed = powerGuard.fence.finishCycle()
        let reasons = deferredNetworkReasons.sorted().joined(separator: "; ")
        deferredNetworkReasons.removeAll()
        guard changed, !stopping, policy.state.configuration.mode.requiresVerification else { return }
        Task { [weak self] in
            guard let self, !self.stopping, self.policy.state.configuration.mode.requiresVerification else { return }
            self.networkChanged("deferred_events", detail: reasons)
        }
    }

    private func response() -> DaemonResponse {
        var state = policy.state
        state.supervisorCheckedAt = .now
        state.networkReleaseRequested = runtime.networkReleaseRequested
        state.networkReleased = runtime.networkReleaseRequested && runtime.gateState == "released" && state.phase == .active
        state.infrastructure = runtime.infrastructureStatus(generation: generation)
        state.heartbeatHealth = peerWatchdog?.health
        state.heartbeatCheckedAt = peerWatchdog?.checkedAt
        state.configuration.profileHostingEnabled = profileEnabled
        state.configuration.mihomoEnabled = engineEnabled
        if cachedServices == nil || Date.now.timeIntervalSince(cachedServices!.at) > 2 {
            let checkedAt = Date.now
            var engine = runtime.engineInspection
            engine.bindingConfirmed = engine.health == .running && state.allowsTraffic && state.configuration.mode.requiresVerification
            cachedServices = (checkedAt, [
                .init(id: .core, health: coreEnabled ? .running : .stopped, transport: "XPC / Mach", checkedAt: checkedAt),
                engine,
                .init(id: .profileHosting, health: runtime.networkReleaseRequested ? .suspended : !engineEnabled ? .suspended : !profileEnabled ? .stopped : engine.health == .running ? .running : .unavailable, transport: "In-memory · Unix socket", address: MimoRuntime.controller.path, checkedAt: engineEnabled && profileEnabled ? engine.checkedAt : checkedAt)
            ])
        }
        state.services = cachedServices?.values ?? []
        state.mihomoVersion = MimoRuntime.version
        var response = DaemonResponse(); response.routing = state; return response
    }

    private func updateFlag(_ service: MimoServiceID, enabled: Bool) throws {
        var flags = try runtime.servicePreferences()
        flags.profile = profileEnabled; flags.engine = engineEnabled; flags.core = coreEnabled
        switch service {
        case .core: flags.core = enabled
        case .mihomo: flags.engine = enabled
        case .profileHosting: flags.profile = enabled
        }
        cachedServices = nil
        runtime.revokeBaseline()
        try runtime.saveServicePreferences(flags)
        coreEnabled = flags.core; engineEnabled = flags.engine; profileEnabled = flags.profile
    }

    private func probePassword() throws -> String {
        let url = MimoRuntime.directory.appendingPathComponent("probe.secret")
        if let value = try? String(contentsOf: url, encoding: .utf8), value.count == 64, value.allSatisfy(\.isHexDigit) { return value }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DaemonFailure.credential }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        _ = try runtime.writePrivate(Data(secret.utf8), name: "probe.secret")
        return secret
    }

    private func resolve(_ host: String) async throws -> String {
        if let address = IPAddressValidator.normalize(host) {
            guard !address.contains(":") else { throw MimoRuntimeError.unavailable("Mimo requires an IPv4 proxy address or a hostname with an A record.") }
            return address
        }
        // Bootstrap is a single fixed HTTPS resolver reached only by the dedicated runtime group.
        var components = URLComponents(string: "https://1.1.1.1/dns-query")!
        components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5; configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: components.url!); request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]],
              let address = answers.compactMap({ $0["type"] as? Int == 1 ? $0["data"] as? String : nil }).compactMap(IPAddressValidator.normalize).first else {
            throw MimoRuntimeError.unavailable("The proxy endpoint could not be resolved through bootstrap DNS.")
        }
        return address
    }
}

private final class MimoSupervisorSession: NSObject, MimoDaemonProtocol, @unchecked Sendable {
    private let supervisor: MimoSupervisor
    private let connection: NSXPCConnection
    private let installedApp: Bool
    init(supervisor: MimoSupervisor, connection: NSXPCConnection, installedApp: Bool) {
        self.supervisor = supervisor; self.connection = connection; self.installedApp = installedApp
    }
    func request(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard data.count <= MimoService.maximumMessageSize, let request = try? JSONDecoder().decode(DaemonRequest.self, from: data) else {
            reply((try? JSONEncoder().encode(DaemonResponse(failure: .invalidRequest))) ?? Data()); return
        }
        let uid = connection.effectiveUserIdentifier
        let pid = connection.processIdentifier
        let receivedAt = ContinuousClock.now
        Task { @MainActor in
            let response = await supervisor.handle(request, uid: uid, pid: pid, receivedAt: receivedAt, installedApp: installedApp) { [self] response in
                guard request.reportsProgress == true, let data = try? JSONEncoder().encode(response) else { return }
                let observer = connection.remoteObjectProxyWithErrorHandler { _ in } as? MimoDaemonObserver
                observer?.changed(data)
            }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
