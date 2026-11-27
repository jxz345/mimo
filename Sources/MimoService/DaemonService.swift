import Combine
import Foundation

@MainActor
final class DaemonService: NSObject, NSXPCListenerDelegate {
    private let storage: FilePreferenceStorage
    let engine: MonitoringEngine
    private let instanceID = UUID()
    private var stateSequence: UInt64 = 0
    private var settings: MachineSettings
    private var revision: Int
    private var initialized: Bool
    private var sessions: [UUID: DaemonSession] = [:]
    private var observation: AnyCancellable?
    private var publicationPending = false
    private var lastAuthorization: MimoAuthorizationState = .unavailable
    private var lastError: String?
    private var allowlistEventID: UUID?
    private var errorEventID: UUID?
    private var lastManualRequest = Date.distantPast
    private var mutationInProgress = false
    private let controls = MimoControlQueue()
    private let modeIntents = MimoModeIntentOrder()
    private let authorize: @Sendable (Data?) -> Bool
    private let credentialMigrationWarning: String?
    private var routingConfiguration: MimoConfiguration
    private let routing: MimoCoordinator?
    private var hasProxyPassword = false
    private var networkReleaseRequested: Bool { routing != nil && MimoSystemRuntime().networkReleaseRequested }

    init(storage: FilePreferenceStorage, observeSystem: Bool = true, supervisor: MimoSupervisor? = nil,
         credentials: any CredentialBackend = MimoLegacyCredentials(),
         client: any PublicIPLookupClientProtocol = PublicIPLookupClient(),
         authorize: @escaping @Sendable (Data?) -> Bool = ServiceAuthorization.validate) throws {
        self.storage = storage
        self.authorize = authorize
        let cleaned = try MimoLocalSettings.migrate(storage, legacy: credentials)
        credentialMigrationWarning = cleaned ? nil : "Credentials saved locally. Legacy Keychain cleanup needs retry after restarting core."
        try MimoLocalSettings.migrateMonitoring(storage)
        let removedIPv6Entries = try MimoLocalSettings.migrateIPv4Allowlist(storage)
        let localCredentials = MimoLocalCredentials(storage: storage)
        if let data = storage.data(forKey: "service.settings") {
            settings = try JSONDecoder().decode(MachineSettings.self, from: data).validated()
            initialized = true
        } else {
            settings = MachineSettings()
            initialized = false
        }
        revision = storage.integer(forKey: "service.revision")
        if let data = storage.data(forKey: "service.routing") {
            routingConfiguration = try JSONDecoder().decode(MimoConfiguration.self, from: data).validated()
        } else { routingConfiguration = MimoConfiguration() }
        if observeSystem, MimoSystemRuntime().networkReleaseRequested {
            let previous = routingConfiguration
            routingConfiguration.mode = .direct
            routingConfiguration.mihomoEnabled = false
            if previous != routingConfiguration {
                try storage.update(["service.routing": try JSONEncoder().encode(routingConfiguration), "service.revision": revision + 1])
                revision += 1
            }
        }
        let localTransport: MimoCoordinator.Transport?
        if let supervisor {
            localTransport = { message, progress in
                var request = DaemonRequest(.supervisor); request.supervisor = message
                let response = await supervisor.handle(request, uid: 0, pid: getpid(), receivedAt: .now, installedApp: false, progress: { response in
                    if let state = response.routing { progress(state) }
                })
                if let failure = response.failure { throw failure }
                guard let state = response.routing else { throw DaemonFailure.unavailable }
                return state
            }
        } else { localTransport = nil }
        let routing = observeSystem ? MimoCoordinator(configuration: routingConfiguration, allowlist: settings.allowlist,
                                                       revision: revision, transport: localTransport) : nil
        self.routing = routing
        engine = MonitoringEngine(
            preferencesStore: storage, observeSystem: false,
            snapshotStore: SnapshotStore(defaults: storage), cooldownStore: ProviderCooldownStore(defaults: storage),
            refreshAttemptStore: RefreshAttemptStore(defaults: storage), lookupBudgetStore: LookupBudgetStore(defaults: storage),
            indicatorStore: IndicatorStore(defaults: storage), allowedIPStore: AllowedIPStore(defaults: storage),
            providerHealthStore: ProviderHealthStore(defaults: storage), diagnosticPreferencesStore: DiagnosticPreferencesStore(defaults: storage),
            client: routing.map { MimoLookupClient($0) as any PublicIPLookupClientProtocol } ?? client, ipinfoCredentials: CredentialSession(service: CredentialService(backend: localCredentials),
                                                               account: SecureTokenStore.ipinfoLiteAccount))
        super.init()
        engine.routingRevision = { [weak self] in self?.revision }
        engine.allowlistChecksEnabled = routingConfiguration.mode.requiresVerification
        engine.networkEventChecksEnabled = routingConfiguration.mode.requiresVerification
        RuntimeLog.shared.configure(settings.diagnostics)
        if removedIPv6Entries > 0 {
            RuntimeLog.shared.info("mimo_ipv4_allowlist_migrated", fields: ["removedIPv6Entries": String(removedIPv6Entries)])
        }
        observation = engine.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.schedulePublication() }
        }
        routing?.willRequest = { [weak self] provider in
            guard let self else { throw CancellationError() }
            try self.engine.accountActualRequest(provider)
        }
        routing?.changed = { [weak self] in self?.schedulePublication() }
        engine.accessBlockReason = { [weak routing] in
            guard let state = routing?.state, state.rejectedExit != nil else { return nil }
            return state.reason
        }
        if let routing {
            engine.networkConfigurationChanged = { routing.supervisorNetworkChanged() }
            engine.requiredCheckUnavailable = { routing.requiredCheckUnavailable(reason: $0) }

        }
    }

    func start() async {
        await routing?.start()
        guard initialized || routingConfiguration.mode == .direct else { return }
        if initialized, routingConfiguration.proxy != nil {
            hasProxyPassword = routingConfiguration.proxies?.first(where: { $0.id == routingConfiguration.activeProxyID })?.hasPassword == true
        }
        if initialized { _ = await engine.ipinfoCredentials.load() }
        else { engine.apply(settings.monitoring, requestRefresh: false) }
        if (try? MimoSystemRuntime().servicePreferences().core) != false { engine.start() }
        schedulePublication()
        RuntimeLog.shared.info("daemon_ready", fields: ["instance": instanceID.uuidString])
    }

    func changeMonitoring(_ operation: MimoServiceOperation) {
        if operation != .start { engine.stop() }
        if operation != .stop { engine.start() }
        schedulePublication()
    }

    func stop() {
        routing?.stop()
        engine.stop()
        for session in sessions.values { session.connection.invalidate() }
        sessions.removeAll()
        RuntimeLog.shared.info("daemon_stopped")
    }

    func drainInfrastructure() async { await routing?.drainInfrastructure() }

    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        accept(connection, installedApp: false)
    }

    nonisolated func accept(_ connection: NSXPCConnection, installedApp: Bool) -> Bool {
        let session = DaemonSession(service: self, connection: connection, installedApp: installedApp)
        connection.exportedInterface = NSXPCInterface(with: MimoDaemonProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: MimoDaemonObserver.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self, weak session] in
            guard let id = session?.id else { return }
            Task { @MainActor [weak self] in self?.sessions.removeValue(forKey: id) }
        }
        connection.interruptionHandler = { connection.invalidate() }
        connection.resume()
        return true
    }

    func handle(_ request: DaemonRequest, session: DaemonSession) async -> DaemonResponse {
        await handle(request, uid: session.uid, session: session)
    }

    // The UID overload is internal for isolated tests; only the kernel-derived session entry is exported.
    func handle(_ request: DaemonRequest, uid: uid_t, session: DaemonSession? = nil) async -> DaemonResponse {
        var request = request
        guard request.protocolVersion == MimoService.protocolVersion else { return DaemonResponse(failure: .incompatible) }
        let humanControl = [.configureRouting, .saveProxy, .removeProxy, .selectProxy, .configure, .initialize,
                            .setToken, .removeToken, .testProvider].contains(request.command)
        let restricted = [.configureRouting, .saveProxy, .removeProxy, .selectProxy, .configure, .initialize, .setToken, .removeToken].contains(request.command)
        if restricted, session?.installedApp != true, !authorize(request.authorization) {
            return DaemonResponse(failure: .unauthorized)
        }
        guard request.requestedMode == nil || request.command == .configureRouting else {
            return DaemonResponse(failure: .invalidRequest)
        }
        // Mode buttons express a narrow intent. Rebase that mode on the latest
        // configuration when its turn arrives; never rebase proxy/allowlist edits.
        let queuedMode: ProxyMode? = {
            guard request.command == .configureRouting else { return nil }
            if let mode = request.requestedMode { return mode }
            guard var candidate = request.routing else { return nil }
            let mode = candidate.mode
            candidate.mode = routingConfiguration.mode
            return candidate == routingConfiguration ? mode : nil
        }()
        let controlRequestID = UUID()
        if let intent = request.modeIntent {
            // This check precedes queue coalescing: a delayed older packet must
            // not replace a newer ticket which is still waiting for its turn.
            guard request.command == .configureRouting, let mode = request.requestedMode,
                  intent.sequence > 0 else { return DaemonResponse(failure: .invalidRequest) }
            guard initialized else { return DaemonResponse(failure: .conflict) }
            var candidate = routingConfiguration
            candidate.mode = mode
            guard (try? candidate.validated()) != nil,
                  !mode.requiresVerification || candidate.proxy != nil else {
                return DaemonResponse(failure: .invalidRequest)
            }
            if Task.isCancelled {
                var response = DaemonResponse(state: state(for: uid))
                response.controlOutcome = .cancelled
                return response
            }
            switch modeIntents.admit(intent, uid: uid) {
            case .admitted: break
            case .superseded:
                RuntimeLog.shared.info("mimo_mode_intent_superseded", fields: [
                    "request": controlRequestID.uuidString, "reason": "older_or_duplicate_sequence"
                ])
                var response = DaemonResponse(state: state(for: uid))
                response.controlOutcome = .superseded
                return response
            case .capacity:
                RuntimeLog.shared.info("mimo_mode_intent_rejected", fields: [
                    "request": controlRequestID.uuidString, "reason": "stream_capacity", "capacity": "128"
                ])
                return DaemonResponse(state: state(for: uid), failure: .modeIntentCapacity)
            }
        }
        if humanControl { engine.holdForControl() }
        defer { if humanControl { engine.releaseControl() } }
        do {
            if humanControl {
                let admitted: Bool
                do {
                    admitted = try await controls.wait(command: request.command.rawValue,
                        coalescingKey: queuedMode == nil ? nil : "routing-mode", requestID: controlRequestID) {
                        self.mutationInProgress || (request.command == .testProvider && self.engine.lookupInFlight)
                    }
                } catch is CancellationError {
                    RuntimeLog.shared.info("mimo_control_cancelled", fields: [
                        "command": request.command.rawValue, "request": controlRequestID.uuidString
                    ])
                    var response = DaemonResponse(state: state(for: uid))
                    response.controlOutcome = .cancelled
                    return response
                }
                if !admitted {
                    var response = DaemonResponse(state: state(for: uid))
                    response.controlOutcome = .superseded
                    return response
                }
            }
            if let queuedMode {
                var next = routingConfiguration
                next.mode = queuedMode
                request.routing = next
                request.expectedRevision = revision
            }
            switch request.command {
            case .state: return DaemonResponse(state: state(for: uid))
            case .networkChanged:
                guard uid == 0 else { throw DaemonFailure.unauthorized }
                if networkReleaseRequested {
                    guard !mutationInProgress else { throw DaemonFailure.conflict }
                    engine.invalidatePendingLookup()
                    var next = routingConfiguration
                    next.mode = .direct; next.mihomoEnabled = false
                    if next != routingConfiguration {
                        try storage.update(["service.routing": try JSONEncoder().encode(next), "service.revision": revision + 1])
                        routingConfiguration = next; revision += 1
                    }
                    engine.allowlistChecksEnabled = false; engine.networkEventChecksEnabled = false
                    routing?.adoptNetworkRelease(configuration: next, revision: revision)
                } else {
                    if initialized || routingConfiguration.mode == .direct { engine.supervisorNetworkChanged() }
                }
            case .subscribe:
                guard let session else { throw DaemonFailure.invalidRequest }
                guard sessions.count < 128 || sessions[session.id] != nil else { throw DaemonFailure.unavailable }
                sessions[session.id] = session
            case .refresh, .testProvider:
                if request.command == .testProvider {
                    guard let selected = request.provider, settings.providerPool.contains(selected) else { throw DaemonFailure.invalidRequest }
                }
                guard initialized || (request.command == .refresh && routingConfiguration.mode == .direct) else { throw DaemonFailure.invalidRequest }
                // Cancellation before admission neither creates shared demand nor
                // consumes the next live caller's coalescing interval.
                if Task.isCancelled {
                    var response = DaemonResponse(state: state(for: uid))
                    response.controlOutcome = .cancelled
                    return response
                }
                // Concurrent users share the same in-flight lookup and cannot create a request storm.
                if Date().timeIntervalSince(lastManualRequest) >= 1 {
                    let selected = request.provider
                    let manualRequest = request.command == .refresh ? engine.beginManualRefresh() : nil
                    if request.command == .refresh, manualRequest == nil {
                        var response = DaemonResponse(state: state(for: uid))
                        response.controlOutcome = .cancelled
                        return response
                    }
                    lastManualRequest = Date()
                    Task { [engine] in
                        if request.command == .testProvider, let selected { await engine.testProvider(selected) }
                        else { await engine.refresh(force: true, bypassMinimumInterval: true, trigger: .manual, manualRequestID: manualRequest) }
                    }
                }
            case .presentation:
                guard let value = request.presentation else { throw DaemonFailure.invalidRequest }
                try storage.update(["user.\(uid).presentation": try JSONEncoder().encode(value)])
                RuntimeLog.shared.info("user_presentation_changed", fields: ["uid": String(uid)])
            case .configure, .initialize, .setToken, .removeToken:
                guard session?.installedApp == true || authorize(request.authorization) else { throw DaemonFailure.unauthorized }
                guard !mutationInProgress, request.expectedRevision == revision else { throw DaemonFailure.conflict }
                mutationInProgress = true
                defer { mutationInProgress = false }
                if request.command == .initialize || request.command == .configure {
                    if request.command == .initialize, initialized { throw DaemonFailure.alreadyInitialized }
                    guard request.command == .initialize || initialized else { throw DaemonFailure.invalidRequest }
                    guard let next = request.migration?.settings ?? request.settings else { throw DaemonFailure.invalidRequest }
                    let validated = try next.validated()
                    let affectsRouting = !initialized || validated.changesNetworkPath(comparedTo: settings, mode: routingConfiguration.mode)
                    let requestsObservation = validated.requestsObservation(comparedTo: settings)
                    let revokesApproval = routing?.state.allowsTraffic == true && routingConfiguration.mode.requiresVerification &&
                        routing?.state.observedIP.map { !validated.allowlist.contains($0.address) } == true
                    let changesProvider = validated.provider != settings.provider || validated.providerPool != settings.providerPool
                    if !affectsRouting, revokesApproval || changesProvider { engine.invalidatePendingLookup() }
                    var updates: [String: Any?] = [
                        "service.settings": try JSONEncoder().encode(validated), "service.revision": revision + 1,
                        MimoPreferenceKey.provider: validated.provider.rawValue,
                        MimoPreferenceKey.providerPool: validated.providerPool.map(\.rawValue).joined(separator: ","),
                        MimoPreferenceKey.refreshInterval: validated.refreshInterval.rawValue,
                        MimoPreferenceKey.allowedIPs: try JSONEncoder().encode(validated.allowlist),
                        MimoPreferenceKey.diagnostics: try JSONEncoder().encode(validated.diagnostics)
                    ]
                    if request.command == .initialize, let migration = request.migration {
                        updates[MimoPreferenceKey.lookupBudget] = try JSONEncoder().encode(migration.budget)
                        if let snapshot = migration.snapshot { updates[MimoPreferenceKey.snapshot] = try JSONEncoder().encode(snapshot) }
                        for (provider, date) in migration.attempts { updates[MimoPreferenceKey.lastRefreshAttemptPrefix + provider.rawValue] = date }
                        for (provider, date) in migration.cooldowns { updates[MimoPreferenceKey.providerCooldownPrefix + provider.rawValue] = date }
                    }
                    if affectsRouting {
                        engine.invalidatePendingLookup()
                        await routing?.beginConfigurationChange(reason: "Shared settings changed. Verification is required.")
                    }
                    defer { if affectsRouting { routing?.endConfigurationChange() } }
                    try storage.update(updates)
                    let wasInitialized = initialized
                    settings = validated
                    revision += 1
                    initialized = true
                    await routing?.update(configuration: routingConfiguration, allowlist: settings.allowlist, revision: revision,
                                          preservingAccess: !affectsRouting)
                    engine.apply(settings.monitoring, requestRefresh: false)
                    engine.setAllowedIPList(settings.allowlist)
                    engine.applyDiagnosticPreferences(settings.diagnostics)
                    RuntimeLog.shared.configure(settings.diagnostics)
                    if wasInitialized {
                        if affectsRouting || requestsObservation {
                            Task { [engine] in await engine.refresh(force: true, bypassMinimumInterval: true, trigger: .settingsChanged,
                                                                   intent: affectsRouting ? .transition : .observation) }
                        }
                    }
                    else { engine.stop(); engine.reloadBeforeStart(); await start() }
                    RuntimeLog.shared.info(wasInitialized ? "shared_settings_changed" : "shared_settings_initialized",
                                           fields: ["uid": String(uid), "revision": String(revision)])
                } else {
                    guard initialized else { throw DaemonFailure.invalidRequest }
                    let token = request.token?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if request.command == .setToken {
                        guard let token, !token.isEmpty, token.utf8.count <= 4096, !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw DaemonFailure.invalidRequest }
                    }
                    engine.invalidatePendingLookup()
                    try storage.update([MimoLocalSettings.tokenKey: request.command == .setToken ? token : nil,
                                        "service.revision": revision + 1])
                    guard await engine.reloadLocalIPinfoToken() else { throw DaemonFailure.credential }
                    revision += 1
                    await routing?.update(configuration: routingConfiguration, allowlist: settings.allowlist, revision: revision, preservingAccess: true)
                    Task { [engine] in await engine.refresh(force: true, bypassMinimumInterval: true, trigger: .settingsChanged) }
                    RuntimeLog.shared.info("shared_credential_changed", fields: ["uid": String(uid)])
                }
            case .events:
                var response = DaemonResponse(state: state(for: uid), events: RuntimeLog.shared.recentLines())
                response.diagnosticEvents = RuntimeLog.shared.recentDiagnosticRecords()
                return response
            case .configureRouting, .saveProxy, .removeProxy, .selectProxy:
                guard session?.installedApp == true || authorize(request.authorization) else { throw DaemonFailure.unauthorized }
                guard initialized, !mutationInProgress, request.expectedRevision == revision else { throw DaemonFailure.conflict }
                mutationInProgress = true
                defer { mutationInProgress = false }
                var next = routingConfiguration
                var entries = next.proxies ?? []
                var passwords = try MimoLocalSettings.passwords(in: storage)
                let previousPassword = next.activeProxyID.flatMap { passwords[$0] }
                switch request.command {
                case .configureRouting:
                    guard let requested = request.routing else { throw DaemonFailure.invalidRequest }
                    next.mode = requested.mode
                    next.networkFamily = requested.networkFamily
                case .selectProxy:
                    if let id = request.proxyID, !entries.contains(where: { $0.id == id }) { throw DaemonFailure.invalidRequest }
                    next.activeProxyID = request.proxyID
                    if request.proxyID == nil { next.mode = .direct }
                case .saveProxy:
                    guard let proxy = request.proxy else { throw DaemonFailure.invalidRequest }
                    let id = request.proxyID ?? UUID()
                    if request.proxyID != nil, !entries.contains(where: { $0.id == id }) { throw DaemonFailure.invalidRequest }
                    let password = request.proxyPassword ?? passwords[id] ?? ""
                    let entry = MimoSavedProxy(id: id, proxy: MimoProxy(try proxy.settings(password: password)), hasPassword: !password.isEmpty)
                    if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = entry }
                    else { entries.append(entry) }
                    passwords[id] = password.isEmpty ? nil : password
                case .removeProxy:
                    guard let id = request.proxyID, entries.contains(where: { $0.id == id }) else { throw DaemonFailure.invalidRequest }
                    entries.removeAll { $0.id == id }; passwords[id] = nil
                    if next.activeProxyID == id { next.activeProxyID = nil; next.mode = .direct }
                default: break
                }
                next.proxies = entries
                next = try next.validated()
                guard !next.mode.requiresVerification || next.proxy != nil else { throw DaemonFailure.invalidRequest }
                let affectsRouting = next.mode != routingConfiguration.mode ||
                    (next.mode.requiresVerification && (next.networkFamily != routingConfiguration.networkFamily ||
                        next.proxy != routingConfiguration.proxy ||
                        next.activeProxyID != routingConfiguration.activeProxyID ||
                        next.activeProxyID.flatMap { passwords[$0] } != previousPassword))
                if next.mode.requiresVerification, networkReleaseRequested {
                    try await routing?.startReleasedEngine()
                    next.mihomoEnabled = true
                }
                let routingRequestID = controlRequestID
                if affectsRouting {
                    engine.invalidatePendingLookup(routing: .init(request: routingRequestID, command: request.command,
                        mode: next.mode, revision: revision + 1))
                    await routing?.beginConfigurationChange(reason: "Shared proxy configuration is changing.", selectingDirect: next.mode == .direct)
                }
                defer { if affectsRouting { routing?.endConfigurationChange() } }
                try storage.update(["service.routing": try JSONEncoder().encode(next),
                                    MimoLocalSettings.passwordsKey: try JSONEncoder().encode(passwords),
                                    "service.revision": revision + 1])
                routingConfiguration = next; revision += 1
                if affectsRouting {
                    RuntimeLog.shared.info("mimo_routing_configuration_committed", fields: [
                        "request": routingRequestID.uuidString, "command": request.command.rawValue,
                        "mode": next.mode.rawValue, "revision": String(revision)
                    ])
                }
                engine.allowlistChecksEnabled = next.mode.requiresVerification
                engine.networkEventChecksEnabled = next.mode.requiresVerification
                hasProxyPassword = next.activeProxyID.flatMap { passwords[$0] }?.isEmpty == false
                await routing?.update(configuration: next, allowlist: settings.allowlist, revision: revision, preservingAccess: !affectsRouting)
                if affectsRouting {
                    Task { [engine] in await engine.refresh(force: true, bypassMinimumInterval: true, trigger: .settingsChanged, intent: .transition) }
                }
                RuntimeLog.shared.info("mimo_proxy_catalog_changed", fields: ["operation": request.command.rawValue,
                    "count": String(entries.count), "mode": next.mode.rawValue, "family": next.networkFamily.rawValue,
                    "revision": String(revision), "reload": String(affectsRouting)])
            case .supervisor: throw DaemonFailure.invalidRequest
            }
            publish()
            var response = DaemonResponse(state: state(for: uid))
            if queuedMode != nil { response.controlOutcome = .applied }
            return response
        } catch let failure as DaemonFailure {
            return DaemonResponse(state: state(for: uid), failure: failure)
        } catch is KeychainError {
            return DaemonResponse(state: state(for: uid), failure: .credential)
        } catch {
            RuntimeLog.shared.error("daemon_storage_failed", fields: ["error": error.localizedDescription])
            return DaemonResponse(state: state(for: uid), failure: .storage)
        }
    }

    func state(for uid: uid_t) -> DaemonState {
        let presentation = storage.data(forKey: "user.\(uid).presentation")
            .flatMap { try? JSONDecoder().decode(UserPresentationPreferences.self, from: $0) } ?? UserPresentationPreferences()
        let cooldowns = Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap { provider in
            engine.pausedUntil(provider).map { (provider, $0) }
        })
        var result = DaemonState(instanceID: instanceID, build: "3.1", initialized: initialized, revision: revision,
                           settings: settings, presentation: presentation, snapshot: engine.snapshot, status: engine.status,
                           indicators: engine.indicators, authorizationState: currentAuthorization,
                           providerHealth: engine.providerHealth, budget: engine.lookupBudget, nextProvider: engine.preferences.provider, cooldowns: cooldowns,
                           hasIPinfoToken: !engine.isIPinfoTokenUnavailable, credentialError: engine.ipinfoCredentials.errorMessage ?? credentialMigrationWarning,
                           allowlistEventID: allowlistEventID, errorEventID: errorEventID,
                           storageError: storage.lastError)
        stateSequence += 1
        result.stateSequence = stateSequence
        result.manualRefresh = engine.manualRefresh
        result.routing = routing?.state ?? MimoRoutingState(configuration: routingConfiguration)
        result.routing?.hasProxyPassword = hasProxyPassword
        return result
    }

    private func schedulePublication() {
        guard !publicationPending else { return }
        publicationPending = true
        DispatchQueue.main.async { [weak self] in self?.publish() }
    }

    private var currentAuthorization: MimoAuthorizationState {
        if let rejected = routing?.state.rejectedExit { return .notAllowed(rejected.address) }
        return engine.authorizationState
    }

    private func publish() {
        publicationPending = false
        if currentAuthorization != lastAuthorization {
            lastAuthorization = currentAuthorization
            allowlistEventID = currentAuthorization.isNotAllowed ? UUID() : nil
        }
        if engine.indicators.errorMessage != lastError {
            lastError = engine.indicators.errorMessage
            errorEventID = lastError == nil ? nil : UUID()
        }
        for session in sessions.values {
            guard let data = try? JSONEncoder().encode(state(for: session.uid)) else { continue }
            (session.connection.remoteObjectProxyWithErrorHandler { _ in session.connection.invalidate() } as? MimoDaemonObserver)?.changed(data)
        }
    }
}

final class DaemonSession: NSObject, MimoDaemonProtocol, @unchecked Sendable {
    let id = UUID()
    let uid: uid_t
    let connection: NSXPCConnection
    let installedApp: Bool
    private let service: DaemonService
    init(service: DaemonService, connection: NSXPCConnection, installedApp: Bool = false) {
        self.service = service
        self.connection = connection
        self.installedApp = installedApp
        uid = connection.effectiveUserIdentifier
    }
    func request(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard data.count <= MimoService.maximumMessageSize,
              let request = try? JSONDecoder().decode(DaemonRequest.self, from: data) else {
            reply((try? JSONEncoder().encode(DaemonResponse(failure: .invalidRequest))) ?? Data())
            return
        }
        Task { @MainActor in
            let response = await service.handle(request, session: self)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
