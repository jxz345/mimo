import Combine
import Foundation

@MainActor
final class DaemonService: NSObject, NSXPCListenerDelegate {
    private let storage: FilePreferenceStorage
    let engine: MonitoringEngine
    private let instanceID = UUID()
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
    private let authorize: @Sendable (Data?) -> Bool
    private let credentialMigrationWarning: String?
    private var routingConfiguration: MimoConfiguration
    private let routing: MimoCoordinator?
    private var hasProxyPassword = false
    private var networkReleaseRequested: Bool { routing != nil && MimoSystemRuntime().networkReleaseRequested }

    init(storage: FilePreferenceStorage, observeSystem: Bool = true,
         credentials: any CredentialBackend = MimoLegacyCredentials(),
         client: any PublicIPLookupClientProtocol = PublicIPLookupClient(),
         authorize: @escaping @Sendable (Data?) -> Bool = ServiceAuthorization.validate) throws {
        self.storage = storage
        self.authorize = authorize
        let cleaned = try MimoLocalSettings.migrate(storage, legacy: credentials)
        credentialMigrationWarning = cleaned ? nil : "Credentials saved locally. Legacy Keychain cleanup needs retry after restarting core."
        try MimoLocalSettings.migrateMonitoring(storage)
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
        let routing = observeSystem ? MimoCoordinator(configuration: routingConfiguration, allowlist: settings.allowlist, revision: revision) : nil
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
        engine.allowlistChecksEnabled = routingConfiguration.mode.requiresVerification
        engine.networkEventChecksEnabled = routingConfiguration.mode.requiresVerification
        RuntimeLog.shared.configure(settings.diagnostics)
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
            engine.requiredCheckUnavailable = { reason in Task { await routing.invalidate(reason: reason) } }

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
        engine.start()
        schedulePublication()
        RuntimeLog.shared.info("daemon_ready", fields: ["instance": instanceID.uuidString])
    }

    func stop() {
        routing?.stop()
        engine.stop()
        for session in sessions.values { session.connection.invalidate() }
        sessions.removeAll()
        RuntimeLog.shared.info("daemon_stopped")
    }

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
        // Mode buttons express a narrow intent. Rebase that mode on the latest
        // configuration when its turn arrives; never rebase proxy/allowlist edits.
        let queuedMode: ProxyMode? = {
            guard request.command == .configureRouting, var candidate = request.routing else { return nil }
            let mode = candidate.mode
            candidate.mode = routingConfiguration.mode
            return candidate == routingConfiguration ? mode : nil
        }()
        if humanControl { engine.holdForControl() }
        defer { if humanControl { engine.releaseControl() } }
        do {
            if humanControl {
                try await controls.wait(command: request.command.rawValue) { self.engine.lookupInFlight || self.mutationInProgress }
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
                // Concurrent users share the same in-flight lookup and cannot create a request storm.
                if Date().timeIntervalSince(lastManualRequest) >= 1 {
                    lastManualRequest = Date()
                    let selected = request.provider
                    if request.command == .refresh { engine.beginManualRefresh() }
                    Task { [engine] in
                        if request.command == .testProvider, let selected { await engine.testProvider(selected) }
                        else { await engine.refresh(force: true, bypassMinimumInterval: true, trigger: .manual) }
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
                    let affectsRouting = !initialized || validated.affectsVerification(comparedTo: settings, mode: routing?.state.configuration.mode ?? routingConfiguration.mode) ||
                        routing?.state.phase == .checking || routing?.state.phase == .validating
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
                        if affectsRouting {
                            Task { [engine] in await engine.refresh(force: true, bypassMinimumInterval: true, trigger: .settingsChanged) }
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
                    await routing?.beginConfigurationChange(reason: "The lookup credential is changing. Verification is required.")
                    defer { routing?.endConfigurationChange() }
                    try storage.update([MimoLocalSettings.tokenKey: request.command == .setToken ? token : nil,
                                        "service.revision": revision + 1])
                    guard await engine.reloadLocalIPinfoToken() else { throw DaemonFailure.credential }
                    revision += 1
                    await routing?.update(configuration: routingConfiguration, allowlist: settings.allowlist, revision: revision)
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
                if affectsRouting {
                    engine.invalidatePendingLookup()
                    await routing?.beginConfigurationChange(reason: "Shared proxy configuration is changing.", selectingDirect: next.mode == .direct)
                }
                defer { if affectsRouting { routing?.endConfigurationChange() } }
                try storage.update(["service.routing": try JSONEncoder().encode(next),
                                    MimoLocalSettings.passwordsKey: try JSONEncoder().encode(passwords),
                                    "service.revision": revision + 1])
                routingConfiguration = next; revision += 1
                engine.allowlistChecksEnabled = next.mode.requiresVerification
                engine.networkEventChecksEnabled = next.mode.requiresVerification
                hasProxyPassword = next.activeProxyID.flatMap { passwords[$0] }?.isEmpty == false
                await routing?.update(configuration: next, allowlist: settings.allowlist, revision: revision, preservingAccess: !affectsRouting)
                if affectsRouting {
                    Task { [engine] in await engine.refresh(force: true, bypassMinimumInterval: true, trigger: .settingsChanged) }
                }
                RuntimeLog.shared.info("mimo_proxy_catalog_changed", fields: ["operation": request.command.rawValue,
                    "count": String(entries.count), "mode": next.mode.rawValue, "family": next.networkFamily.rawValue,
                    "revision": String(revision), "reload": String(affectsRouting)])
            case .supervisor: throw DaemonFailure.invalidRequest
            }
            publish()
            return DaemonResponse(state: state(for: uid))
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
        var result = DaemonState(instanceID: instanceID, build: "3.0", initialized: initialized, revision: revision,
                           settings: settings, presentation: presentation, snapshot: engine.snapshot, status: engine.status,
                           indicators: engine.indicators, authorizationState: currentAuthorization,
                           providerHealth: engine.providerHealth, budget: engine.lookupBudget, nextProvider: engine.preferences.provider, cooldowns: cooldowns,
                           hasIPinfoToken: !engine.isIPinfoTokenUnavailable, credentialError: engine.ipinfoCredentials.errorMessage ?? credentialMigrationWarning,
                           allowlistEventID: allowlistEventID, errorEventID: errorEventID,
                           storageError: storage.lastError)
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
