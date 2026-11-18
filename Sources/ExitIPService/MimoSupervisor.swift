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
    private var lastHeartbeat = ContinuousClock.now
    private var watchdog: Task<Void, Never>?
    private var profileEnabled = true
    private var engineEnabled = true
    private var coreEnabled = true
    private var operationPending = false
    private var generation: UInt64 = 0
    private var configurationKnown = false
    private var directRestorationAllowed = false
    private var commandFence = MimoCommandFence()
    private lazy var networkObserver = MimoNetworkObserver { [weak self] reason in self?.networkChanged(reason) }
    private var tailnetEnabled = false
    private lazy var nativeTransportObserver = MimoNativeTransportObserver { [weak self] transport in
        guard let self else { return }
        do { try self.runtime.updateNativeTransport(transport) }
        catch { self.close("Native Tailscale transport could not be constrained: \(error.localizedDescription)") }
    }

    func start() {
        runtime.profileWillChange = { [weak self] in
            guard let self else { return }
            self.networkObserver.willChangeProfile(engineProcess: self.runtime.runningProcessID(MimoRuntime.engineLabel))
        }
        runtime.profileDidChange = { [weak self] in self?.networkObserver.didChangeProfile() }
        do {
            try runtime.checkInstallation()
            try runtime.updateNativeTransport(.init())
            try runtime.closeGate()
            let flags = try runtime.servicePreferences()
            profileEnabled = flags.profile; engineEnabled = flags.engine; coreEnabled = flags.core
            policy = MimoAccessPolicy(configuration: try runtime.savedConfiguration())
            configurationKnown = true
            directRestorationAllowed = policy.state.configuration.mode == .direct
            policy.block("Startup protection is active. Waiting for mimo-core.")
            guard !runtime.maintenanceActive else {
                policy.block("Service installation is in progress.")
                return
            }
            try runtime.service(.mihomo, operation: engineEnabled ? .start : .stop)
            if engineEnabled { try runtime.waitForBlockingEngine() }
            if policy.state.configuration.mode == .direct {
                try runtime.restoreDirect()
                policy.directRestored(configuration: policy.state.configuration)
            }
            try runtime.service(.core, operation: coreEnabled ? .start : .stop)
            RuntimeLog.shared.info("mimo_supervisor_ready", fields: ["mode": policy.state.configuration.mode.rawValue])
        } catch { policy.block(error.localizedDescription, confirmed: runtime.closed) }
        networkObserver.start()
        tailnetEnabled = (try? runtime.savedTailnetEnabled()) ?? false
        nativeTransportObserver.start(tailnetEnabled: tailnetEnabled)
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
                   self.policy.state.phase == .active || self.policy.state.verification != nil,
                   (self.lastHeartbeat.duration(to: .now) > .seconds(5) || !self.runtime.isRunning(MimoRuntime.engineLabel) ||
                    (self.policy.state.phase == .active && self.runtime.gateState != "active")) {
                    self.close("The controller heartbeat or proxy engine was lost.")
                }
                if self.policy.state.phase == .active, self.policy.state.configuration.mode.requiresVerification {
                    do {
                        guard self.networkObserver.isRunning, let profile = self.activeProfile,
                              try self.runtime.matches(profile, active: true, proxy: self.proxy) else {
                            throw MimoRuntimeError.unavailable("The active runtime or network observer changed. Verification is required.")
                        }
                    } catch { self.close(error.localizedDescription) }
                }
            }
        }
    }

    func stop() {
        watchdog?.cancel(); networkObserver.stop(); nativeTransportObserver.stop()
        if policy.state.configuration.mode.requiresVerification { close("The supervisor is restarting.") }
    }

    private func networkChanged(_ reason: String) {
        generation &+= 1
        if policy.state.configuration.mode.requiresVerification { close("Network settings changed. Verification is required.") }
        else if !runtime.maintenanceActive {
            do { try runtime.enforceIPv4Policy() }
            catch { close("IPv4-only network settings could not be applied: \(error.localizedDescription)") }
        }
        RuntimeLog.shared.info("mimo_network_changed", fields: ["source": reason, "generation": String(generation)])
        Task { _ = try? await DaemonRPC.call(DaemonRequest(.networkChanged), timeout: 2) }
    }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ExitIPDaemonProtocol.self)
        connection.exportedObject = MimoSupervisorSession(supervisor: self, connection: connection)
        connection.resume()
        return true
    }

    func handle(_ request: DaemonRequest, uid: uid_t, pid: pid_t) async -> DaemonResponse {
        guard request.protocolVersion == ExitIPService.protocolVersion else { return DaemonResponse(failure: .incompatible) }
        guard request.command == .supervisor, let message = request.supervisor else { return DaemonResponse(failure: .invalidRequest) }
        do {
            if message.command == .service {
                guard uid == 0 || ServiceAuthorization.validate(request.authorization) else { throw DaemonFailure.unauthorized }
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
            case .state: break
            case .heartbeat:
                lastHeartbeat = .now
                refreshTailnetPolicy()
            case .close:
                directRestorationAllowed = false
                close("Network or configuration changed. Verification is required.")
            case .direct:
                generation &+= 1
                try runtime.restoreDirect()
                policy.directRestored(configuration: message.configuration ?? policy.state.configuration)
                configurationKnown = true
                directRestorationAllowed = true
                proxy = nil; endpoint = nil; activeProfile = nil
                RuntimeLog.shared.info("mimo_direct_restored")
            case .prepare:
                directRestorationAllowed = false
                guard let configuration = message.configuration, configuration.mode.requiresVerification,
                      let revision = message.revision, let network = message.networkGeneration, let allowed = message.allowlist else { throw DaemonFailure.invalidRequest }
                close("Validating the protected profile.")
                guard runtime.closed else { throw MimoRuntimeError.unavailable("The firewall could not confirm blocking.") }
                var validated = try configuration.validated()
                validated.profileHostingEnabled = profileEnabled; validated.mihomoEnabled = engineEnabled
                guard coreEnabled, engineEnabled, profileEnabled else { throw MimoRuntimeError.unavailable("A required background service is stopped.") }
                let check = policy.begin(configuration: validated, revision: revision, networkGeneration: network)
                guard let metadata = validated.proxy else { throw MimoRuntimeError.unavailable("Save a proxy in Settings.") }
                allowlist = allowed
                // Qualification is checked before staging any permissive runtime configuration.
                try runtime.checkInstallation()
                guard networkObserver.isRunning else { throw MimoRuntimeError.unavailable("Network change observation is unavailable. Repair installation.") }
                try runtime.requireQualifiedRuntime()
                let secret = try credentials.read(account: MimoRuntime.proxyPasswordAccount) ?? ""
                var proxy = try metadata.settings(password: secret)
                let epoch = generation
                let address = try await resolve(proxy.server)
                guard epoch == generation, policy.state.verification == check, !runtime.maintenanceActive else { throw CancellationError() }
                proxy.server = address
                try runtime.closeGate(endpoints: [address], proxyPort: proxy.port)
                let password = try probePassword()
                let verificationProfile = try MihomoProfile.render(proxy, mode: validated.mode, stage: .verification, probePassword: password)
                try runtime.loadProfile(verificationProfile)
                guard try runtime.matches(verificationProfile, active: false, proxy: proxy) else { throw MimoRuntimeError.unavailable("The verification profile could not be confirmed.") }
                self.proxy = proxy; endpoint = address
                activeProfile = try MihomoProfile.render(proxy, mode: validated.mode, stage: .active, probePassword: password)
                policy.checking(check)
                RuntimeLog.shared.info("mimo_private_probe_ready", fields: ["revision": String(revision), "generation": String(network)])
            case .approve:
                guard let check = message.verification, check == policy.state.verification,
                      policy.state.phase == .checking, let address = message.address,
                      let activeProfile, let proxy, let endpoint else { throw DaemonFailure.conflict }
                guard !allowlist.isEmpty, allowlist.contains(address) else {
                    _ = policy.approve(address: address, at: .now, allowlist: allowlist, verification: check, runtimeMatches: false)
                    RuntimeLog.shared.info("mimo_exit_rejected", fields: ["ip": address])
                    return response()
                }
                try runtime.loadProfile(activeProfile)
                try runtime.configureProtectedDNS()
                let activationGeneration = generation
                await Task.yield()
                guard activationGeneration == generation, check == policy.state.verification else { throw CancellationError() }
                let matches = try runtime.matches(activeProfile, active: true, proxy: proxy)
                guard policy.approve(address: address, at: .now, allowlist: allowlist, verification: check, runtimeMatches: matches) else {
                    close("The active profile did not match the verified candidate."); return response()
                }
                try runtime.openGate(mode: policy.state.configuration.mode, endpoints: [endpoint], proxyPort: proxy.port)
                RuntimeLog.shared.info("mimo_traffic_opened", fields: ["mode": policy.state.configuration.mode.rawValue, "ip": address])
            case .service:
                guard !operationPending, let service = message.service, let operation = message.operation else { throw DaemonFailure.conflict }
                operationPending = true; defer { operationPending = false }
                if service != .tailnetProvider, policy.state.configuration.mode.requiresVerification { close("A required service is changing state.") }
                // Persist intent before the launchd operation. A crash during Stop must
                // never turn into an automatic Start on the next boot.
                switch service {
                case .core:
                    generation &+= 1
                    if operation != .start || runtime.runningProcessID(ExitIPService.label) == nil {
                        commandFence = MimoCommandFence()
                    }
                    try updateFlag(.core, enabled: operation != .stop)
                    try runtime.service(service, operation: operation)
                case .mihomo:
                    try updateFlag(.mihomo, enabled: operation != .stop)
                    try runtime.service(service, operation: operation)
                case .profileHosting:
                    try updateFlag(.profileHosting, enabled: operation != .stop)
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
            if !(error is CancellationError) { close(error.localizedDescription) }
            return response()
        }
    }

    private func close(_ reason: String) {
        generation &+= 1
        do {
            try runtime.closeGate(endpoints: endpoint.map { [$0] } ?? [], proxyPort: proxy?.port)
            try runtime.disconnectFlows()
            policy.block(reason)
        }
        catch { policy.block("\(reason) Firewall status is unavailable: \(error.localizedDescription)", confirmed: false) }
        activeProfile = nil
        RuntimeLog.shared.info("mimo_gate_closed", fields: ["confirmed": String(runtime.closed), "reason": reason])
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
        state.configuration.profileHostingEnabled = profileEnabled
        state.configuration.mihomoEnabled = engineEnabled
        state.services = [
            .init(id: .core, health: runtime.isRunning(ExitIPService.label) ? .running : .stopped, transport: "XPC / Mach"),
            .init(id: .mihomo, health: runtime.isRunning(MimoRuntime.engineLabel) ? .running : .stopped, transport: "HTTP / SOCKS · Unix controller", address: "127.0.0.1", port: MimoRuntime.mixedPort, bindingConfirmed: state.allowsTraffic && state.configuration.mode.requiresVerification),
            .init(id: .profileHosting, health: profileEnabled ? .running : .stopped, transport: "Private file delivery")
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
        _ = try runtime.writePrivate(JSONEncoder().encode(flags), name: "services.json")
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
    init(supervisor: MimoSupervisor, connection: NSXPCConnection) { self.supervisor = supervisor; self.connection = connection }
    func request(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard data.count <= ExitIPService.maximumMessageSize, let request = try? JSONDecoder().decode(DaemonRequest.self, from: data) else {
            reply((try? JSONEncoder().encode(DaemonResponse(failure: .invalidRequest))) ?? Data()); return
        }
        let uid = connection.effectiveUserIdentifier
        let pid = connection.processIdentifier
        Task { @MainActor in reply((try? JSONEncoder().encode(await supervisor.handle(request, uid: uid, pid: pid))) ?? Data()) }
    }
}
