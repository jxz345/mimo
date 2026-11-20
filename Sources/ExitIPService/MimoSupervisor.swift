import Foundation
import Security

/// Independent launchd process: the GUI/core may exit without removing the firewall gate.
@MainActor
final class MimoSupervisor: NSObject, NSXPCListenerDelegate {
    private let runtime = MimoSystemRuntime()
    private let credentials = SystemCredentials()
    private var policy = MimoAccessPolicy()
    private var allowlist = AllowedIPList()
    private var endpoint: String?
    private var proxy: ClashProxySettings?
    private var activeProfile: String?
    private var installationCheck: Task<Void, Error>?
    private var readinessCheck: Task<MimoReadinessReceipt, Error>?
    nonisolated let heartbeatLease = MimoHeartbeatLease()
    private var watchdog: Task<Void, Never>?
    private var infrastructureMonitor: Task<Void, Never>?
    private var infrastructureRecoveryPending = false
    private var profileEnabled = true
    private var engineEnabled = true
    private var coreEnabled = true
    private var operationPending = false
    private var generation: UInt64 = 0
    private var configurationKnown = false
    private var directRestorationAllowed = false
    private var commandFence = MimoCommandFence()
    private lazy var networkObserver = MimoNetworkObserver { [weak self] reason in self?.networkChanged(reason) }
    private lazy var powerGuard = MimoPowerGuard { [weak self] reason in self?.networkChanged(reason) }
    private lazy var sessionObserver = MimoSessionObserver(powerGuard: powerGuard) { [weak self] reason in self?.networkChanged(reason) }
    private var verificationPowerEpoch: UInt64?
    private var tailnetEnabled = false
    private lazy var nativeTransportObserver = MimoNativeTransportObserver { [weak self, runtime = self.runtime] transport in
        do { try runtime.updateNativeTransport(transport) }
        catch {
            let reason = "Native Tailscale transport could not be constrained: \(error.localizedDescription)"
            Task { @MainActor [weak self] in
                guard let self else { return }
                RuntimeLog.shared.error("mimo_native_transport_failed", fields: ["reason": reason])
                // Direct does not use this sub-anchor. A delayed worker error
                // from the preceding protected mode must not close Direct.
                if self.policy.state.configuration.mode.requiresVerification { self.close(reason) }
            }
        }
    }

    func start() {
        powerGuard.start()
#if MIMO_VM_ACCEPTANCE
        networkObserver.diagnostic = { RuntimeLog.shared.info("mimo_vm_network_diagnostic", fields: ["detail": $0]) }
#endif
        runtime.profileWillChange = { [weak self] in
            guard let self else { return }
            self.networkObserver.willChangeProfile(engineProcess: self.runtime.runningProcessID(MimoRuntime.engineLabel))
        }
        runtime.profileDidChange = { [weak self] in self?.networkObserver.didChangeProfile() }
        do {
            try runtime.closeStartupGate()
            try runtime.checkInstallation()
            try runtime.updateNativeTransport(.init())
            try runtime.closeGate()
            let flags = try runtime.servicePreferences()
            profileEnabled = flags.profile; engineEnabled = flags.engine; coreEnabled = flags.core
            policy = MimoAccessPolicy(configuration: try runtime.savedConfiguration())
            if policy.state.configuration.mode.requiresVerification { _ = try powerGuard.fence.arm() }
            configurationKnown = true
            directRestorationAllowed = policy.state.configuration.mode == .direct
            policy.block("Startup protection is active. Waiting for mimo-core.")
            guard !runtime.maintenanceActive else {
                policy.block("Service installation is in progress.")
                return
            }
            try runtime.service(.mihomo, operation: engineEnabled ? .start : .stop)
            if policy.state.configuration.mode == .direct {
                try runtime.restoreDirect()
                policy.directRestored(configuration: policy.state.configuration)
            }
            try runtime.service(.core, operation: coreEnabled ? .start : .stop)
            RuntimeLog.shared.info("mimo_supervisor_ready", fields: ["mode": policy.state.configuration.mode.rawValue])
        } catch { policy.block(error.localizedDescription, confirmed: runtime.closed) }
        networkObserver.start()
        sessionObserver.start()
        tailnetEnabled = (try? runtime.savedTailnetEnabled()) ?? false
        nativeTransportObserver.start(tailnetEnabled: tailnetEnabled)
        // Infrastructure commands can wait for launchd or the firewall lock.
        // Keep them off the main actor and separate from the liveness watchdog.
        infrastructureMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.runtime.maintenanceActive {
                    do {
                        try await self.runtime.repairInfrastructure()
                        if self.infrastructureRecoveryPending {
                            self.infrastructureRecoveryPending = false
                            self.networkChanged("infrastructure_recovered")
                        }
                    }
                    catch {
                        guard !Task.isCancelled else { return }
                        self.infrastructureRecoveryPending = true
                        self.close(error.localizedDescription)
                    }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refreshTailnetPolicy()
                if self.runtime.maintenanceActive {
                    if self.policy.state.phase != .blocked { self.close("Service installation is in progress.") }
                    continue
                }
                if self.configurationKnown, self.directRestorationAllowed,
                   self.policy.state.configuration.mode == .direct, self.runtime.gateState != "direct" {
                    do {
                        if self.engineEnabled, self.runtime.isRunning(MimoRuntime.engineLabel) {
                            try self.runtime.waitForBlockingEngine()
                        }
                        try self.runtime.restoreDirect()
                        self.policy.directRestored(configuration: self.policy.state.configuration)
                    } catch { self.policy.block(error.localizedDescription, confirmed: self.runtime.closed) }
                }
                if self.policy.state.configuration.mode.requiresVerification,
                   self.policy.state.phase == .active || self.policy.state.verification != nil {
                    let heartbeatExpired = self.heartbeatLease.expired()
                    let engineRunning = self.runtime.isRunning(MimoRuntime.engineLabel)
                    let gate = self.runtime.gateState ?? "unknown"
                    let gateChanged = self.policy.state.phase == .active && gate != "active"
                    if heartbeatExpired || !engineRunning || gateChanged {
                        RuntimeLog.shared.error("mimo_liveness_lost", fields: self.heartbeatLease.diagnostics().merging([
                            "heartbeatExpired": String(heartbeatExpired),
                            "heartbeatAgeSeconds": self.heartbeatLease.ageSeconds().map { String($0) } ?? "unregistered",
                            "engineRunning": String(engineRunning), "gate": gate
                        ], uniquingKeysWith: { _, new in new }))
                        self.close(heartbeatExpired ? "The core heartbeat expired. Verification is required." :
                            !engineRunning ? "The proxy engine stopped. Verification is required." :
                            "The firewall gate changed. Verification is required.")
                    }
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
                    } catch {
                        if inspectedGeneration == self.generation, self.policy.state.phase == .active {
                            self.close(error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    func stop() {
        watchdog?.cancel(); infrastructureMonitor?.cancel()
        sessionObserver.stop(); networkObserver.stop(); nativeTransportObserver.stop(); powerGuard.stop()
        if policy.state.configuration.mode.requiresVerification { close("The supervisor is restarting.") }
    }

    private func networkChanged(_ reason: String) {
        generation &+= 1
        if policy.state.configuration.mode.requiresVerification {
            // Close public egress now. Prepare owns controller cleanup and the
            // private-probe exceptions; doing both here repeats the same work.
            close("Network or system state changed. Verification is required.", strictOnly: true)
        }
        else if !runtime.maintenanceActive {
            do { try runtime.enforceIPv4Policy() }
            catch { close("IPv4-only network settings could not be applied: \(error.localizedDescription)") }
        }
        RuntimeLog.shared.info("mimo_network_changed", fields: ["source": reason, "generation": String(generation)])
        Task { _ = try? await DaemonRPC.call(DaemonRequest(.networkChanged), timeout: 2) }
    }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        accept(connection, installedApp: false)
    }

    nonisolated func accept(_ connection: NSXPCConnection, installedApp: Bool) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ExitIPDaemonProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: ExitIPDaemonObserver.self)
        connection.exportedObject = MimoSupervisorSession(supervisor: self, connection: connection, installedApp: installedApp)
        connection.resume()
        return true
    }

    func handle(_ request: DaemonRequest, uid: uid_t, pid: pid_t,
                receivedAt: ContinuousClock.Instant = .now, installedApp: Bool = false,
                progress: (@Sendable (DaemonResponse) -> Void)? = nil) async -> DaemonResponse {
        guard request.protocolVersion == ExitIPService.protocolVersion else { return DaemonResponse(failure: .incompatible) }
        guard request.command == .supervisor, let message = request.supervisor else { return DaemonResponse(failure: .invalidRequest) }
        do {
            if message.command == .service || message.command == .profile {
                guard installedApp || uid == 0 || ServiceAuthorization.validate(request.authorization) else { throw DaemonFailure.unauthorized }
            } else if message.command != .state {
                guard uid == 0 else { throw DaemonFailure.unauthorized }
            }
            guard !runtime.maintenanceActive || [.state, .heartbeat, .close].contains(message.command) else {
                throw MimoRuntimeError.unavailable("Service installation is in progress.")
            }
            if let stamp = message.stamp, message.command != .state {
                let previousProcess = commandFence.processID
                guard commandFence.accept(stamp, peer: pid, currentCore: runtime.runningProcessID(ExitIPService.label),
                                          enabled: coreEnabled, heartbeat: message.command == .heartbeat) else {
                    RuntimeLog.shared.info("mimo_command_rejected", fields: ["command": message.command.rawValue, "reason": "ordering_or_core_identity"])
                    throw DaemonFailure.conflict
                }
                // Every ordered request from the live core proves liveness. Profile
                // preparation can occupy this actor while a heartbeat waits in XPC;
                // do not measure its deadline from an older idle-state poll.
                heartbeatLease.authorize(stamp, process: pid, at: receivedAt)
                if let previousProcess, previousProcess != pid {
                    generation &+= 1
                    if policy.state.configuration.mode.requiresVerification { close("Core restarted. Verification is required.") }
                }
                // After a supervisor restart there is no in-memory ordering history.
                // Persisted revision/mode still forbid an old Direct or approval.
                if [.direct, .prepare, .approve].contains(message.command) {
                    let saved = try runtime.savedRouting()
                    guard MimoCommandFence.matchesSavedRouting(message, configuration: saved.configuration,
                                                               revision: saved.revision) else {
                        RuntimeLog.shared.info("mimo_command_rejected", fields: ["command": message.command.rawValue, "reason": "saved_configuration_changed"])
                        throw DaemonFailure.conflict
                    }
                }
            } else if message.command != .state, pid == runtime.runningProcessID(ExitIPService.label) {
                // Root administrator recovery is independent of core. Core itself
                // must use ordered requests; never silently downgrade its protocol.
                throw DaemonFailure.invalidRequest
            }
            switch message.command {
            case .profile:
                var result = DaemonResponse()
                result.profileContents = try runtime.profileContents()
                return result
            case .state: break
            case .heartbeat:
                refreshTailnetPolicy()
            case .close:
                directRestorationAllowed = false
                close("Network or configuration changed. Verification is required.")
            case .direct:
                cancelReadiness()
                generation &+= 1
                try powerGuard.fence.direct {
                    try runtime.restoreDirect()
                }
                policy.directRestored(configuration: message.configuration ?? policy.state.configuration)
                configurationKnown = true
                directRestorationAllowed = true
                proxy = nil; endpoint = nil; activeProfile = nil
                RuntimeLog.shared.info("mimo_direct_restored")
            case .prepare:
                var timing = MimoTransitionTiming("prepare")
                directRestorationAllowed = false
                verificationPowerEpoch = try powerGuard.fence.arm()
                guard let configuration = message.configuration, configuration.mode.requiresVerification,
                      let revision = message.revision, let network = message.networkGeneration, let allowed = message.allowlist else { throw DaemonFailure.invalidRequest }
                guard close("Validating the protected profile.", strictOnly: true), runtime.closed else {
                    throw MimoRuntimeError.unavailable("The firewall could not confirm blocking.")
                }
                progress?(response())
                timing.record("confirmed_close")
                guard let powerEpoch = verificationPowerEpoch else { throw CancellationError() }
                var validated = try configuration.validated()
                validated.profileHostingEnabled = profileEnabled; validated.mihomoEnabled = engineEnabled
                guard coreEnabled, engineEnabled, profileEnabled else { throw MimoRuntimeError.unavailable("A required background service is stopped.") }
                let check = policy.begin(configuration: validated, revision: revision, networkGeneration: network)
                guard let metadata = validated.proxy else { throw MimoRuntimeError.unavailable("Save a proxy in Settings.") }
                allowlist = allowed
                // Installation checks overlap preparation and the core's IP lookup.
                // Their successful result is mandatory at the opening barrier.
                let runtime = self.runtime
                let installation = Task.detached {
                    try await runtime.readinessChecks.validateInstallation { try runtime.checkInstallation() }
                }
                installationCheck = installation
                guard networkObserver.isRunning, powerGuard.isRunning, sessionObserver.isRunning else { throw MimoRuntimeError.unavailable("Network, session or power change observation is unavailable. Repair installation.") }
                let secret = try credentials.read(account: MimoRuntime.proxyPasswordAccount) ?? ""
                var proxy = try metadata.settings(password: secret)
                // Strict PF denies even old engine egress while flows are
                // discarded. Do not install the old endpoint's probe policy
                // merely to replace it with the freshly resolved endpoint.
                try runtime.disconnectFlows()
                timing.record("connection_cleanup")
                if IPAddressValidator.normalize(proxy.server) == nil {
                    // Hostnames need only the fixed encrypted bootstrap
                    // resolver before resolution; no old proxy exception.
                    try runtime.closeGate()
                    try powerGuard.fence.activate(epoch: powerEpoch) { try MimoPowerGuard.clear() }
                }
                let epoch = generation
                let address = try await resolve(proxy.server)
                timing.record("endpoint_resolution")
                guard epoch == generation, policy.state.verification == check, !runtime.maintenanceActive else { throw CancellationError() }
                proxy.server = address
                try runtime.closeGate(endpoints: [address], proxyPort: proxy.port)
                // The parent gate denies applications. Release the system
                // barrier only for this fresh, restricted verification path.
                try powerGuard.fence.activate(epoch: powerEpoch) { try MimoPowerGuard.clear() }
                let password = try probePassword()
                let finalProfile = try MihomoProfile.render(proxy, mode: validated.mode, stage: .active, probePassword: password)
                timing.record("probe_gate")
                try runtime.loadProfile(finalProfile)
                timing.record("final_profile")
                RuntimeLog.shared.info("mimo_final_profile_loaded", fields: ["attempt": check.id.uuidString])
                self.proxy = proxy; endpoint = address; activeProfile = finalProfile
                let readinessGeneration = generation
                let candidateProxy = proxy
                readinessCheck = Task { [weak self] in
                    guard let self else { throw CancellationError() }
                    do {
                        try Task.checkCancellation()
                        guard readinessGeneration == self.generation, check == self.policy.state.verification else { throw CancellationError() }
                        RuntimeLog.shared.info("mimo_readiness_started", fields: ["attempt": check.id.uuidString])
                        try runtime.configureProtectedDNS()
                        let receipt = try await runtime.inspectReadiness(profile: finalProfile, proxy: candidateProxy, installation: installation)
                        try Task.checkCancellation()
                        guard readinessGeneration == self.generation, check == self.policy.state.verification else { throw CancellationError() }
                        RuntimeLog.shared.info("mimo_readiness_passed", fields: ["attempt": check.id.uuidString])
                        return receipt
                    } catch {
                        if !(error is CancellationError), readinessGeneration == self.generation, check == self.policy.state.verification {
                            self.close(error.localizedDescription, strictOnly: true)
                        }
                        throw error
                    }
                }
                policy.checking(check)
                RuntimeLog.shared.info("mimo_private_probe_ready", fields: ["revision": String(revision), "generation": String(network), "attempt": check.id.uuidString])
            case .approve:
                var timing = MimoTransitionTiming("approve")
                guard let check = message.verification, check == policy.state.verification,
                      policy.state.phase == .checking, let address = message.address,
                      let activeProfile, let proxy, let endpoint else { throw DaemonFailure.conflict }
                guard !allowlist.isEmpty, allowlist.contains(address) else {
                    _ = policy.approve(address: address, at: .now, allowlist: allowlist, verification: check, runtimeMatches: false)
                    RuntimeLog.shared.info("mimo_exit_rejected", fields: ["ip": address])
                    return response()
                }
                guard let readinessCheck else { throw DaemonFailure.conflict }
                let activationGeneration = generation
                RuntimeLog.shared.info("mimo_exit_ip_approved", fields: ["attempt": check.id.uuidString])
                policy.waitingForReadiness(address: address, verification: check)
                progress?(response())
                let receipt: MimoReadinessReceipt
                do { receipt = try await readinessCheck.value }
                catch {
                    guard activationGeneration == generation, check == policy.state.verification else { throw CancellationError() }
                    throw error
                }
                guard activationGeneration == generation, check == policy.state.verification else { throw CancellationError() }
                guard self.activeProfile == activeProfile, runtime.receiptIsCurrent(receipt),
                      networkObserver.isRunning, powerGuard.isRunning, sessionObserver.isRunning else {
                    throw MimoRuntimeError.unavailable("The verified runtime changed before opening. A fresh check is required.")
                }
                timing.record("readiness_join")
                guard policy.approve(address: address, at: .now, allowlist: allowlist, verification: check, runtimeMatches: true) else {
                    close("The active profile did not match the verified candidate."); return response()
                }
                guard let powerEpoch = verificationPowerEpoch else { throw CancellationError() }
                try powerGuard.fence.activate(epoch: powerEpoch) {
                    try runtime.openGate(mode: policy.state.configuration.mode, endpoints: [endpoint], proxyPort: proxy.port, receipt: receipt)
                    try MimoPowerGuard.clear()
                }
                self.readinessCheck = nil; installationCheck = nil
                timing.record("open_gate")
                RuntimeLog.shared.info("mimo_traffic_opened", fields: ["mode": policy.state.configuration.mode.rawValue, "ip": address])
            case .service:
                guard !operationPending, let service = message.service, let operation = message.operation else { throw DaemonFailure.conflict }
                operationPending = true; defer { operationPending = false }
                guard service != .tailnetProvider else { throw DaemonFailure.invalidRequest }
                let savedMode = try runtime.savedConfiguration().mode
                if savedMode.requiresVerification || policy.state.configuration.mode.requiresVerification {
                    directRestorationAllowed = false
                    guard close("A required service is changing state. Internet remains blocked.", strictOnly: true) else {
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
                // Persist intent before the launchd operation. A crash during Stop must
                // never turn into an automatic Start on the next boot.
                switch service {
                case .core:
                    generation &+= 1
                    if operation != .start || runtime.runningProcessID(ExitIPService.label) == nil {
                        commandFence = MimoCommandFence()
                        heartbeatLease.reset()
                    }
                    try updateFlag(.core, enabled: operation != .stop)
                    try runtime.service(service, operation: operation)
                case .mihomo:
                    try updateFlag(.mihomo, enabled: operation != .stop)
                    try runtime.service(service, operation: operation)
                case .profileHosting:
                    try updateFlag(.profileHosting, enabled: operation != .stop)
                    if operation != .stop, policy.state.configuration.mode == .direct {
                        try runtime.loadProfile(MihomoProfile.blocking())
                    }
                case .tailnetProvider:
                    // Provider changes require core's authorized settings transaction.
                    throw DaemonFailure.invalidRequest
                }
                RuntimeLog.shared.info("mimo_service_changed", fields: ["service": service.rawValue, "operation": operation.rawValue])
            }
            return response()
        } catch let failure as DaemonFailure {
            return DaemonResponse(failure: failure)
        } catch {
            if message.command == .profile { return DaemonResponse(failure: .unavailable) }
            if !(error is CancellationError) { close(error.localizedDescription) }
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

    private func cancelReadiness() {
        readinessCheck?.cancel(); readinessCheck = nil
        installationCheck?.cancel(); installationCheck = nil
    }

    @discardableResult
    private func close(_ reason: String, strictOnly: Bool = false) -> Bool {
        generation &+= 1
        cancelReadiness()
        activeProfile = nil
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
        return succeeded
    }

    private func refreshTailnetPolicy() {
        let enabled = (try? runtime.savedTailnetEnabled()) ?? false
        guard enabled != tailnetEnabled else { return }
        tailnetEnabled = enabled
        // Clearing the sub-anchor is synchronous, before acknowledging Stop.
        nativeTransportObserver.start(tailnetEnabled: enabled)
    }

    private func response() -> DaemonResponse {
        var state = policy.state
        state.supervisorCheckedAt = .now
        state.infrastructure = runtime.infrastructureStatus()
        state.configuration.profileHostingEnabled = profileEnabled
        state.configuration.mihomoEnabled = engineEnabled
        state.services = [
            .init(id: .core, health: runtime.isRunning(ExitIPService.label) ? .running : .stopped, transport: "XPC / Mach"),
            .init(id: .mihomo, health: runtime.isRunning(MimoRuntime.engineLabel) ? .running : .stopped, transport: "HTTP / SOCKS · Unix controller", address: "127.0.0.1", port: MimoRuntime.mixedPort, bindingConfirmed: state.allowsTraffic && state.configuration.mode.requiresVerification),
            .init(id: .profileHosting, health: profileEnabled ? .running : .stopped, transport: "In-memory · Unix socket", address: MimoRuntime.controller.path)
        ]
        state.mihomoVersion = MimoRuntime.version
        var response = DaemonResponse(); response.routing = state; return response
    }

    private func updateFlag(_ service: MimoServiceID, enabled: Bool) throws {
        var flags = MimoServicePreferences()
        flags.profile = profileEnabled; flags.engine = engineEnabled; flags.core = coreEnabled
        switch service {
        case .core: flags.core = enabled
        case .mihomo: flags.engine = enabled
        case .profileHosting: flags.profile = enabled
        case .tailnetProvider: throw DaemonFailure.invalidRequest
        }
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

private final class MimoSupervisorSession: NSObject, ExitIPDaemonProtocol, @unchecked Sendable {
    private let supervisor: MimoSupervisor
    private let connection: NSXPCConnection
    private let installedApp: Bool
    init(supervisor: MimoSupervisor, connection: NSXPCConnection, installedApp: Bool) {
        self.supervisor = supervisor; self.connection = connection; self.installedApp = installedApp
    }
    func request(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard data.count <= ExitIPService.maximumMessageSize, let request = try? JSONDecoder().decode(DaemonRequest.self, from: data) else {
            reply((try? JSONEncoder().encode(DaemonResponse(failure: .invalidRequest))) ?? Data()); return
        }
        let uid = connection.effectiveUserIdentifier
        let pid = connection.processIdentifier
        let receivedAt = ContinuousClock.now
        if uid == 0, request.protocolVersion == ExitIPService.protocolVersion,
           request.command == .supervisor, let message = request.supervisor,
           message.command == .heartbeat, let stamp = message.stamp {
            let accepted = supervisor.heartbeatLease.receive(stamp, process: pid, at: receivedAt)
            if message.livenessOnly == true {
                reply((try? JSONEncoder().encode(DaemonResponse(failure: accepted ? nil : .conflict))) ?? Data())
                return
            }
        }
        Task { @MainActor in
            let response = await supervisor.handle(request, uid: uid, pid: pid, receivedAt: receivedAt, installedApp: installedApp) { [self] response in
                guard request.reportsProgress == true, let data = try? JSONEncoder().encode(response) else { return }
                let observer = connection.remoteObjectProxyWithErrorHandler { _ in } as? ExitIPDaemonObserver
                observer?.changed(data)
            }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
