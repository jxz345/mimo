import AppKit
import Combine
import Foundation
import SystemConfiguration
import WidgetKit

@MainActor
final class PublicIPMonitor: ObservableObject {
    enum DebugSimulationScenario: String, CaseIterable, Identifiable {
        case transportFailure
        case malformedResponse
        case rateLimit
        case countryDisagreement
        case notAllowedAddress

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .transportFailure: "Transport failure"
            case .malformedResponse: "Malformed response"
            case .rateLimit: "HTTP 429 rate limit"
            case .countryDisagreement: "Country confirmation disagreement"
            case .notAllowedAddress: "Exit IP not on the allowlist"
            }
        }
    }

    typealias Status = MonitoringStatus
    enum RefreshTrigger { case manual, periodic, startup }
    @Published private(set) var snapshot: MimoSnapshot?
    @Published private(set) var status: Status = .idle
    @Published private(set) var preferences = MonitoringPreferences.load()
    @Published private(set) var indicators = MonitorIndicatorState(suppressLocation: true)
    @Published private(set) var allowedIPList = AllowedIPList()
    @Published private(set) var authorizationState: MimoAuthorizationState = .unavailable
    @Published private(set) var providerHealth: [ProviderID: ProviderHealthRecord] = [:]
    @Published private(set) var lookupBudget = LookupBudget()
    @Published private(set) var diagnosticPreferences = DiagnosticPreferences()
    @Published private(set) var simulationMessage: String?
    @Published private(set) var displayDate = Date.now
    @Published private(set) var daemonState: DaemonState?
    @Published private(set) var connection = MimoClientConnectionStatus()
    @Published private(set) var installationInactive = false
    var connected: Bool { !installationInactive && connection.phase == .connected }
    @Published private(set) var serviceMessage: String? = "Connecting to background service…"
    @Published private(set) var operationError: String?
    @Published private(set) var isChangingSettings = false
    @Published private(set) var isCredentialBusy = false
    @Published private(set) var serviceOperation: MimoServiceID?
    @Published private(set) var supervisorState: MimoRoutingState?
    @Published private(set) var supervisorReplyAt: Date?
    @Published private var serviceRoutingProgress: MimoRoutingState?
    private var serviceOperationID: UUID?
    private var serviceOperationStartedAt: Date?
    private var serviceOperationRevision = 0
    private var serviceRPCFinished = false
    let ipinfoCredentials = AppCredentials.makeSession(account: SecureTokenStore.ipinfoLiteAccount)
    typealias SubscriptionFactory = (@escaping @Sendable (DaemonConnectionEvent) -> Void) -> (() -> Void)
    typealias StatusReader = (DaemonRequest, TimeInterval, String) async throws -> DaemonResponse
    private let subscribe: SubscriptionFactory
    private let readStatus: StatusReader
    private let readDeactivation: () -> Bool
    private let releasedMonitor: MimoReleasedMonitor
    private let reconnectDelay: Duration
    private var cancelSubscription: (() -> Void)?
    private var reconnectTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var connectionStartedAt = Date.now
    private var displayTimer: Timer?
    private var sessionObservers: [NSObjectProtocol] = []
    private var warningPresented: UUID?
    private var heartbeat: Task<Void, Never>?
    private var localPresentationImported = false
    private var started = false
    private var connectionGeneration = 0
    private var subscriptionReplied = false
    private var sessionActive = true
    var isSessionActive: Bool { sessionActive }

    init(subscribe: @escaping SubscriptionFactory = { receive in
        let subscription = DaemonSubscription(receive: receive)
        return { subscription.invalidate() }
    }, readStatus: @escaping StatusReader = { request, timeout, label in
        try await DaemonRPC.call(request, timeout: timeout, serviceLabel: label)
    }, reconnectDelay: Duration = .seconds(3), readDeactivation: @escaping () -> Bool = MimoDeactivation.isConfirmed,
       releasedMonitor: MimoReleasedMonitor = MimoReleasedMonitor()) {
        self.releasedMonitor = releasedMonitor
        self.readDeactivation = readDeactivation
        self.installationInactive = readDeactivation()
        self.subscribe = subscribe
        self.readStatus = readStatus
        self.reconnectDelay = reconnectDelay
        releasedMonitor.changed = { [weak self] in self?.receiveReleasedMonitoring() }
    }

    func hasSupervisorReply(at date: Date = .now) -> Bool {
        guard let age = MimoHealthLabel.age(checkedAt: supervisorReplyAt, at: date) else { return false }
        return age < 10
    }

    func hasServiceReport(_ id: MimoServiceID, at date: Date = .now) -> Bool {
        connected || hasSupervisorReply(at: date)
    }

    func serviceHealthLabel(_ id: MimoServiceID, at date: Date) -> String {
        if installationInactive { return "Removed" }
        guard hasServiceReport(id, at: date) else { return connection.rowTitle }
        let service = routingState.services.first { $0.id == id }
        var title = serviceOperation == id ? "Working…" : service?.healthTitle(at: date) ?? "Unavailable"
        // A supervisor process inspection does not establish a working core connection.
        if !connected, id == .core, title == "Healthy" { title = "Running" }
        return MimoHealthLabel.text(title, checkedAt: service?.checkedAt, at: date)
    }

    func connectionSummary(at date: Date) -> String {
        connection.lastReplyText(at: date) + (hasSupervisorReply(at: date) ? " Supervisor is responding." : " Reconnecting automatically.")
    }

    var isCoolingDown: Bool { if case .coolingDown = status { true } else { false } }
    var isRefreshDeferred: Bool {
        switch status { case .coolingDown, .waitingForMinimumInterval: true; default: false }
    }
    var nextProvider: ProviderID { installationInactive ? preferences.provider : daemonState?.nextProvider ?? preferences.provider }
    var isIPinfoTokenUnavailable: Bool { daemonState?.hasIPinfoToken != true }
    var canChangeSharedSettings: Bool { connected && daemonState?.initialized == true && !isChangingSettings && serviceOperation == nil }
    var canRefresh: Bool {
        if installationInactive { return releasedMonitor.engine != nil && status != .refreshing }
        return connected && !isChangingSettings && (daemonState?.initialized == true || routingState.configuration.mode == .direct)
            && status != .refreshing && ![.checking, .validating].contains(routingState.phase)
    }
    var lookupStatusMessage: String? {
        guard connected || installationInactive else { return nil }
        let manual = installationInactive ? releasedMonitor.engine?.manualRefresh : daemonState?.manualRefresh
        if let manual, manual.pending || manual.finishedAt.map({ displayDate.timeIntervalSince($0) < 30 }) == true {
            return manual.message
        }
        switch status {
        case .idle, .ready: return nil
        case .refreshing: return "Checking the exit IP…"
        case .awaitingConfirmation(let message), .failed(let message): return message
        case .coolingDown(let until):
            return "Lookup providers are paused or out of budget until \(until.formatted(date: .omitted, time: .shortened))."
        case .providerPaused(let provider, let until):
            return "\(provider.displayName) is paused until \(until.formatted(date: .omitted, time: .shortened))."
        case .waitingForMinimumInterval:
            return "A refresh is queued to respect the minimum lookup interval."
        case .waitingForIPinfoToken:
            return "Save or import the shared IPinfo token in Settings → Monitoring."
        }
    }
    var ipinfoToken: String? { nil } // Saved machine credentials never leave the daemon.
    var ipinfoCredentialStatus: String {
        if isCredentialBusy { return "Updating local token…" }
        if let error = daemonState?.credentialError { return error }
        return isIPinfoTokenUnavailable ? "No shared IPinfo token" : "Shared token available to background monitoring"
    }

    var statusPresentation: MimoStatusPresentation {
        MimoStatusPresentation(routing: routingState, snapshot: snapshot ?? daemonState?.snapshot,
            preferences: preferences, date: displayDate, monitoringStatus: status, lookupError: indicators.errorMessage)
    }

    var routingState: MimoRoutingState {
        if installationInactive {
            var state = MimoRoutingState(configuration: daemonState?.routing?.configuration ?? .init())
            state.configuration.mode = .direct; state.configuration.mihomoEnabled = false
            state.phase = .active; state.effectiveMode = .direct
            state.networkReleased = true; state.networkReleaseRequested = true
            state.reason = "Network controls released. Exit IP monitoring continues while Mimo is open."
            state.observedIP = snapshot.map { MimoIPObservation(address: $0.ipAddress, checkedAt: $0.checkedAt) }
            state.services = MimoServiceID.allCases.map { .init(id: $0, health: .notInstalled, transport: "") }
            return state
        }
        if let serviceRoutingProgress, connected || hasSupervisorReply() { return serviceRoutingProgress }
        // A missed supervisor reply does not erase the last saved proxy or mode.
        // Retain only configuration; live health and access still become unknown.
        var state = (connected ? daemonState?.routing : supervisorState ?? daemonState?.routing)
            ?? MimoRoutingState(configuration: daemonState?.routing?.configuration ?? .init())
        if !connected && !(hasSupervisorReply() && supervisorState?.phase == .blocked) {
            state.phase = .unavailable; state.effectiveMode = nil
            state.reason = hasSupervisorReply() && state.services.first(where: { $0.id == .core })?.health == .stopped
                ? "mimo-core is stopped. Start it below to restore monitoring."
                : connection.detail
        }
        return state
    }

    func setMode(_ mode: ProxyMode) {
        var request = DaemonRequest(.configureRouting)
        var configuration = routingState.configuration; configuration.mode = mode; request.routing = configuration
        Task { _ = await changeShared(request) }
    }

    func setNetworkFamily(_ family: MimoNetworkFamily) {
        var request = DaemonRequest(.configureRouting)
        var configuration = routingState.configuration
        configuration.networkFamily = family
        request.routing = configuration
        Task { _ = await changeShared(request) }
    }

    func saveProxy(_ proxy: MimoProxy, password: String?, expectedRevision: Int, id: UUID? = nil) async -> Bool {
        var request = DaemonRequest(.saveProxy); request.proxyID = id; request.proxy = proxy; request.proxyPassword = password
        request.expectedRevision = expectedRevision
        return await changeShared(request)
    }

    func selectProxy(_ id: UUID?) async -> Bool {
        var request = DaemonRequest(.selectProxy)
        request.proxyID = id
        return await changeShared(request)
    }

    func saveBypass(_ blocks: [MimoBypassBlock], expectedRevision: Int) async -> Bool {
        guard var settings = daemonState?.settings else { return false }
        settings.bypassBlocks = blocks
        var request = DaemonRequest(.configure)
        request.settings = settings; request.expectedRevision = expectedRevision
        return await changeShared(request)
    }

    func importLegacyProxy(expectedRevision: Int) async -> Bool {
        guard await AppCredentials.proxy.load(), let text = AppCredentials.proxy.value,
              let proxy = ClashVergeProfile.decode(text) else {
            operationError = AppCredentials.proxy.errorMessage ?? "No saved proxy was found in this account’s Keychain."
            return false
        }
        return await saveProxy(MimoProxy(proxy), password: proxy.password, expectedRevision: expectedRevision)
    }

    func removeProxy(id: UUID, expectedRevision: Int) async -> Bool {
        var request = DaemonRequest(.removeProxy)
        request.proxyID = id
        request.expectedRevision = expectedRevision
        return await changeShared(request)
    }

    func changeService(_ service: MimoServiceID, operation: MimoServiceOperation) {
        guard serviceOperation == nil else { return }
        let operationID = UUID()
        serviceOperationID = operationID
        serviceRPCFinished = false
        serviceOperation = service
        let releasing = service == .mihomo && operation == .stop
        if releasing || routingState.configuration.mode.requiresVerification {
            var pending = routingState
            pending.phase = .closing; pending.effectiveMode = nil
            pending.reason = "Blocking internet access before changing \(service.title)…"
            if releasing {
                pending.phase = .restoringDirect
                pending.networkReleaseRequested = true; pending.networkReleased = false
                pending.reason = "Stopping engine and restoring system networking…"
            }
            serviceRoutingProgress = pending
            serviceOperationStartedAt = .now
            serviceOperationRevision = daemonState?.revision ?? 0
        }
        Task {
            var succeeded = false
            defer {
                if serviceOperationID == operationID {
                    serviceOperationID = nil; serviceOperation = nil
                    if succeeded, let state = daemonState?.routing { reconcileServiceProgress(state) }
                }
            }
            do {
                var message = MimoSupervisorRequest(.service); message.service = service; message.operation = operation
                var request = DaemonRequest(.supervisor); request.supervisor = message
                let response = try await DaemonRPC.call(request, timeout: 75, serviceLabel: MimoService.supervisorControlLabel, returningFailures: true) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.serviceOperationID == operationID, !self.serviceRPCFinished, let routing = progress.routing else { return }
                        self.serviceRoutingProgress = self.serviceProgressState(routing)
                        RuntimeLog.shared.info("mimo_service_progress_received", fields: ["service": service.rawValue,
                            "operation": operation.rawValue, "phase": routing.phase.rawValue])
                    }
                }
                serviceRPCFinished = true
                supervisorState = response.routing
                if response.routing != nil { supervisorReplyAt = .now }
                if let routing = response.routing {
                    if serviceRoutingProgress != nil { serviceRoutingProgress = serviceProgressState(routing) }
                    else { daemonState?.routing = routing }
                }
                if let failure = response.failure {
                    operationError = response.routing?.reason ?? failure.localizedDescription
                    return
                }
                succeeded = true
                operationError = nil
                if service == .core, operation == .stop { disconnected() }
                else { applicationDidBecomeActive(); if operation != .stop { await refresh() } }
            } catch {
                operationError = error.localizedDescription
                if !serviceRPCFinished, serviceRoutingProgress != nil {
                    serviceRoutingProgress?.phase = .unavailable
                    serviceRoutingProgress?.supervisorCheckedAt = .now
                    serviceRoutingProgress?.reason = releasing ? "Network cleanup could not be confirmed. Reconnect and retry Stop engine." : "Blocking could not be confirmed. The service operation did not complete."
                }
            }
        }
    }

    private func reconcileServiceProgress(_ state: MimoRoutingState) {
        guard serviceOperationID == nil, let progress = serviceRoutingProgress else { return }
        if MimoServiceProgress.canReplace(progress, with: state, startedAt: serviceOperationStartedAt ?? .distantFuture,
            configurationAdvanced: (daemonState?.revision ?? 0) > serviceOperationRevision) {
            serviceRoutingProgress = nil
            serviceOperationStartedAt = nil
        }
    }

    private func serviceProgressState(_ routing: MimoRoutingState) -> MimoRoutingState {
        var state = routing
        state.hasProxyPassword = daemonState?.routing?.hasProxyPassword ?? false
        return state
    }

    func openProfile() async -> String? {
        guard serviceOperation == nil else { return nil }
        serviceOperation = .profileHosting
        defer { serviceOperation = nil }
        do {
            var request = DaemonRequest(.supervisor)
            request.supervisor = MimoSupervisorRequest(.profile)
            let response = try await DaemonRPC.call(request, timeout: 15, serviceLabel: MimoService.supervisorControlLabel)
            if let failure = response.failure { throw failure }
            guard let contents = response.profileContents else { throw DaemonFailure.unavailable }
            operationError = nil
            return contents
        } catch { operationError = error.localizedDescription; return nil }
    }

    func start() {
        guard !started else { return }
        started = true
        connect()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.refreshInstallationState()
                if self.connected { self.requestStatus() }
            }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayDate = .now }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidWakeNotification] {
            sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.sessionDidResignActiveNotification { self?.sessionDidResignActive() }
                    else if name == NSWorkspace.sessionDidBecomeActiveNotification { self?.sessionDidBecomeActive() }
                    else if self?.sessionActive == true { self?.reconnect() }
                }
                RuntimeLog.shared.info("mimo_session_event", fields: [
                    "source": name == NSWorkspace.sessionDidResignActiveNotification ? "session_inactive" : name == NSWorkspace.sessionDidBecomeActiveNotification ? "session_active" : "display_wake",
                    "action": name == NSWorkspace.sessionDidResignActiveNotification ? "pause_gui_updates" : "reconnect_shared_status"
                ])
            })
        }
        RuntimeLog.shared.info("daemon_client_started")
    }

    func stop() {
        started = false
        releasedMonitor.stop()
        connectionGeneration += 1
        cancelSubscription?(); cancelSubscription = nil
        statusTask?.cancel(); statusTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        displayTimer?.invalidate(); displayTimer = nil
        sessionObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sessionObservers.removeAll()
        heartbeat?.cancel(); heartbeat = nil
        supervisorState = nil
        supervisorReplyAt = nil
        connection.phase = .interrupted
        serviceRoutingProgress = nil; serviceOperationID = nil; serviceOperation = nil
        RuntimeLog.shared.info("daemon_client_stopped")
    }

    private func connect() {
        refreshInstallationState()
        guard started, sessionActive, !installationInactive else { return }
        connectionGeneration += 1
        let generation = connectionGeneration
        connectionStartedAt = .now
        subscriptionReplied = false
        cancelSubscription?()
        statusTask?.cancel(); statusTask = nil
        if connection.phase != .incompatible {
            connection.phase = connection.lastReplyAt == nil ? .connecting : .interrupted
        }
        serviceMessage = connection.detail
        RuntimeLog.shared.info("daemon_client_connecting", fields: ["generation": String(generation)])
        cancelSubscription = subscribe { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.connectionGeneration == generation else { return }
                switch event {
                case .state(let state): self.subscriptionReplied = true; self.receive(state)
                case .failed(let failure): self.disconnected(failure: failure)
                }
            }
        }
        requestStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.started, self.connectionGeneration == generation, !self.subscriptionReplied else { return }
            self.disconnected(source: "subscription_timeout")
        }
    }

    private func disconnected(failure: DaemonFailure = .unavailable, source: String = "subscription") {
        refreshInstallationState()
        guard started, sessionActive, !installationInactive else { return }
        connectionGeneration += 1
        cancelSubscription?(); cancelSubscription = nil
        statusTask?.cancel(); statusTask = nil
        connection.phase = failure == .incompatible ? .incompatible : .interrupted
        serviceMessage = connection.detail
        indicators = MonitorIndicatorState(errorMessage: connection.title, suppressLocation: true)
        status = .failed(serviceMessage!)
        RuntimeLog.shared.info("daemon_client_disconnected", fields: ["source": source,
            "generation": String(connectionGeneration), "reason": failure.localizedDescription])
        showWarningIfNeeded()
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.readSupervisorState()
            try? await Task.sleep(for: self?.reconnectDelay ?? .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func readSupervisorState() async {
        let generation = connectionGeneration
        var request = DaemonRequest(.supervisor)
        request.supervisor = MimoSupervisorRequest(.state)
        let response = try? await readStatus(request, 2, MimoRuntime.supervisorLabel)
        guard started, !connected, generation == connectionGeneration else { return }
        if let response, response.failure == nil, let routing = response.routing {
            supervisorState = routing
            supervisorReplyAt = .now
        }
        if serviceOperationID == nil, serviceRoutingProgress != nil {
            serviceRoutingProgress = supervisorState.map(serviceProgressState)
        }
    }

    func receive(_ state: DaemonState) {
        refreshInstallationState()
        guard sessionActive, !installationInactive else { return }
        guard state.protocolVersion == MimoService.protocolVersion else {
            disconnected(failure: .incompatible); return
        }
        let oldSnapshot = snapshot, oldIndicators = indicators
        let oldStatusPresentation = statusPresentation
        daemonState = state
        releasedMonitor.remember(state)
        if let routing = state.routing { reconcileServiceProgress(routing) }
        if !connected {
            RuntimeLog.shared.info("daemon_client_connected", fields: ["generation": String(connectionGeneration),
                "duration_ms": String(Int(max(0, Date.now.timeIntervalSince(connectionStartedAt)) * 1_000))])
        }
        connection.phase = .connected
        connection.lastReplyAt = .now
        reconnectTask?.cancel(); reconnectTask = nil
        serviceMessage = state.storageError ?? (state.initialized ? nil : "Set up shared monitoring using this account’s existing settings.")
        preferences = state.preferences
        snapshot = state.presentedSnapshot
        status = state.status
        indicators = state.presentedIndicators
        allowedIPList = state.settings.allowlist
        authorizationState = state.authorizationState
        providerHealth = state.providerHealth
        lookupBudget = state.budget
        diagnosticPreferences = state.settings.diagnostics
        RuntimeLog.shared.configure(state.settings.diagnostics)
        if snapshot?.hasWidgetContentChange(comparedTo: oldSnapshot) == true || oldIndicators != indicators
            || oldStatusPresentation != statusPresentation {
            reloadSurfaces()
        }
        // Import appearance once per UID in the service. A widget or another account cannot seed it.
        if !state.presentation.imported, !localPresentationImported {
            localPresentationImported = true
            let old = MonitoringPreferences.load()
            var presentation = state.presentation
            presentation.imported = true
            presentation.displayStyle = old.menuBarDisplayStyle
            presentation.highlightCountryChanges = old.highlightCountryChanges
            var request = DaemonRequest(.presentation)
            request.presentation = presentation
            Task { [weak self] in
                guard let self else { return }
                guard self.connected else { self.localPresentationImported = false; return }
                if !(await self.send(request)) { self.localPresentationImported = false }
            }
        } else if state.presentation.imported {
            showWarningIfNeeded()
        }
    }

    private var isActiveSession: Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        _ = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid)
        return uid == getuid()
    }

    private func showWarningIfNeeded() {
        guard connected, !indicators.suppressLocation,
              let state = daemonState, state.initialized, let event = state.allowlistEventID,
              case .notAllowed(let address) = authorizationState,
              state.routing?.configuration.mode.requiresVerification == true,
              state.routing?.phase == .blocked, state.routing?.blockingIP?.address == address,
              state.snapshot?.isStale(threshold: state.settings.refreshInterval.snapshotStaleThreshold) == false else {
            if warningPresented != nil { RuntimeLog.shared.info("allowlist_warning_cleared") }
            AllowlistWarningWindowController.shared.dismiss(); warningPresented = nil; return
        }
        guard isActiveSession, warningPresented != event, state.presentation.seenAllowlistEvent != event else { return }
        warningPresented = event
        RuntimeLog.shared.info("allowlist_warning_presented", fields: ["ip": address])
        AllowlistWarningWindowController.shared.show(address: address)
        var presentation = state.presentation
        presentation.seenAllowlistEvent = event
        updatePresentation(presentation)
    }

    func refreshInstallationState() {
        let inactive = readDeactivation()
        guard inactive != installationInactive else {
            if inactive && started && sessionActive { releasedMonitor.start() }
            return
        }
        installationInactive = inactive
        if inactive {
            connectionGeneration += 1
            cancelSubscription?(); cancelSubscription = nil
            reconnectTask?.cancel(); reconnectTask = nil
            statusTask?.cancel(); statusTask = nil
            serviceRoutingProgress = nil; supervisorState = nil; supervisorReplyAt = nil
            connection.phase = .inactive
            serviceOperation = nil; serviceOperationID = nil
            snapshot = nil; status = .idle; operationError = nil
            serviceMessage = "Network controls released. Monitoring in this app."
            if started && sessionActive { releasedMonitor.start() }
        } else {
            releasedMonitor.stop()
            guard started, sessionActive else { return }
            reconnectTask = Task { [weak self] in
                self?.reconnectTask = nil
                self?.connect()
            }
        }
    }

    private func receiveReleasedMonitoring() {
        guard installationInactive, started, sessionActive, let engine = releasedMonitor.engine else { return }
        snapshot = engine.snapshot
        status = engine.status
        preferences = engine.preferences
        indicators = engine.indicators
        providerHealth = engine.providerHealth
        lookupBudget = engine.lookupBudget
        diagnosticPreferences = engine.diagnosticPreferences
        authorizationState = .unavailable
        displayDate = .now
        reloadSurfaces()
    }

    func applicationDidBecomeActive() {
        refreshInstallationState()
        guard started, sessionActive else { return }
        if !connected { reconnect() }
        else { requestStatus() }
    }

    /// Re-establish this GUI's subscription; never restart services or change routing.
    func reconnect() {
        guard started, sessionActive else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        connect()
    }

    func sessionDidResignActive() {
        guard started else { return }
        sessionActive = false
        releasedMonitor.stop()
        connectionGeneration += 1
        cancelSubscription?(); cancelSubscription = nil
        reconnectTask?.cancel(); reconnectTask = nil
        statusTask?.cancel(); statusTask = nil
        supervisorReplyAt = nil
        connection.phase = .inactive
        serviceMessage = connection.detail
        showWarningIfNeeded()
    }

    func sessionDidBecomeActive() {
        sessionActive = true
        reconnect()
    }

    /// Read-only probes have their own short deadline and are coalesced per connection.
    func requestStatus() {
        guard started, sessionActive, !installationInactive, statusTask == nil else { return }
        let generation = connectionGeneration
        let requestedAt = Date.now
        statusTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.connectionGeneration { self.statusTask = nil } }
            do {
                let response = try await self.readStatus(DaemonRequest(.state), 3, MimoService.label)
                guard self.started, !Task.isCancelled, generation == self.connectionGeneration else { return }
                if let failure = response.failure { throw failure }
                guard let state = response.state else { throw DaemonFailure.unavailable }
                self.receive(state)
            } catch {
                guard self.started, !Task.isCancelled, generation == self.connectionGeneration else { return }
                // A subscription reply arriving during a failed probe still proves communication.
                guard self.connection.lastReplyAt.map({ $0 >= requestedAt }) != true else { return }
                self.disconnected(failure: error as? DaemonFailure ?? .unavailable, source: "status_probe")
            }
        }
    }

    @discardableResult
    private func send(_ request: DaemonRequest, serviceLabel: String = MimoService.label) async -> Bool {
        do {
            let response = try await DaemonRPC.call(request, timeout: 75, serviceLabel: serviceLabel)
            if let state = response.state { receive(state) }
            if request.command != .state { operationError = nil }
            return true
        } catch {
            operationError = error.localizedDescription
            if let failure = error as? DaemonFailure, failure == .unavailable { disconnected() }
            // A stale editor must see the winning revision before retrying.
            requestStatus()
            return false
        }
    }

    private func updatePresentation(_ presentation: UserPresentationPreferences, completion: (() -> Void)? = nil) {
        var request = DaemonRequest(.presentation)
        request.presentation = presentation
        Task { if await send(request) { completion?(); reloadSurfaces() } }
    }

    func apply(_ updated: MonitoringPreferences) {
        if installationInactive { releasedMonitor.engine?.apply(MimoReleasedMonitor.anonymousPreferences(updated)); return }
        guard let state = daemonState else { return }
        if updated.menuBarDisplayStyle != preferences.menuBarDisplayStyle || updated.highlightCountryChanges != preferences.highlightCountryChanges {
            var presentation = state.presentation
            presentation.displayStyle = updated.menuBarDisplayStyle
            presentation.highlightCountryChanges = updated.highlightCountryChanges
            updatePresentation(presentation)
        }
        if updated.provider != preferences.provider || updated.providerPool != preferences.providerPool || updated.refreshInterval != preferences.refreshInterval {
            var settings = state.settings
            settings.provider = updated.provider
            settings.providerPool = updated.providerPool
            if !settings.providerPool.contains(updated.provider) { settings.providerPool.insert(updated.provider, at: 0) }
            settings.refreshInterval = updated.refreshInterval
            configure(settings)
        }
    }

    func setAllowedIPList(_ list: AllowedIPList) {
        guard var settings = daemonState?.settings else { return }
        settings.allowlist = list; configure(settings)
    }
    func addAllowedIP(_ value: String) -> Bool {
        guard let address = IPAddressValidator.normalize(value) else { return false }
        var list = allowedIPList
        guard list.insert(address) else { return false }
        setAllowedIPList(list); return true
    }
    func removeAllowedIP(_ value: String) { var list = allowedIPList; if list.remove(value) { setAllowedIPList(list) } }
    func applyDiagnosticPreferences(_ preferences: DiagnosticPreferences) {
        guard var settings = daemonState?.settings else { return }
        settings.diagnostics = preferences; configure(settings)
    }
    private func configure(_ settings: MachineSettings) {
        var request = DaemonRequest(.configure)
        request.settings = settings
        Task { _ = await changeShared(request) }
    }

    func initializeSharedSettings() async {
        let defaults = MimoAppGroup.defaults
        do { try MimoLocalSettings.migrateMonitoring(defaults) }
        catch { operationError = "Could not migrate monitoring preferences."; return }
        let settings = MachineSettings(preferences: MonitoringPreferences.load(), allowlist: AllowedIPStore().load(),
                                       diagnostics: DiagnosticPreferencesStore().load())
        var request = DaemonRequest(.initialize)
        request.migration = MigrationState(settings: settings, budget: LookupBudgetStore().load(),
            attempts: RefreshAttemptStore().lastAttempts(), cooldowns: Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap { provider in
                ProviderCooldownStore(defaults: defaults).retryNotBefore(for: provider).map { (provider, $0) }
            }), snapshot: SnapshotStore().load())
        _ = await changeShared(request)
    }

    private func changeShared(_ request: DaemonRequest) async -> Bool {
        guard connected, let state = daemonState else {
            operationError = DaemonFailure.unavailable.localizedDescription
            return false
        }
        guard request.command == .initialize || state.initialized else {
            operationError = "Initialize shared settings before changing monitoring or proxy configuration."
            return false
        }
        guard !isChangingSettings else { return false }
        isChangingSettings = true
        defer { isChangingSettings = false }
        var request = request
        if let revision = request.expectedRevision, revision != state.revision {
            operationError = DaemonFailure.conflict.localizedDescription
            return false
        }
        request.expectedRevision = request.expectedRevision ?? state.revision
        // The installer pins this app's signature. The helper verifies it on
        // every control message; routine operations never invoke SecurityAgent.
        return await send(request, serviceLabel: MimoService.controlLabel)
    }

    func loadIPinfoToken() async -> Bool {
        guard !isCredentialBusy else { return false }
        guard await ipinfoCredentials.load(), let token = ipinfoCredentials.value else {
            operationError = ipinfoCredentials.errorMessage ?? "No IPinfo token was found in this account’s Keychain."; return false
        }
        return await saveIPinfoToken(token)
    }
    func saveIPinfoToken(_ token: String) async -> Bool {
        guard !isCredentialBusy else { return false }
        isCredentialBusy = true; defer { isCredentialBusy = false }
        var request = DaemonRequest(.setToken); request.token = token
        return await changeShared(request)
    }
    func removeIPinfoToken() async -> Bool {
        guard !isCredentialBusy else { return false }
        isCredentialBusy = true; defer { isCredentialBusy = false }
        return await changeShared(DaemonRequest(.removeToken))
    }
    func refresh(force: Bool = false, bypassMinimumInterval: Bool = false, trigger: RefreshTrigger = .manual) async {
        guard canRefresh else { return }
        if installationInactive { await releasedMonitor.engine?.refresh(force: true, bypassMinimumInterval: true); return }
        _ = await send(DaemonRequest(.refresh))
    }
    func testProvider(_ provider: ProviderID) async {
        guard canRefresh else { return }
        if installationInactive { await releasedMonitor.engine?.testProvider(provider); return }
        var request = DaemonRequest(.testProvider); request.provider = provider; _ = await send(request)
    }
    func pausedUntil(_ provider: ProviderID) -> Date? { installationInactive ? releasedMonitor.engine?.pausedUntil(provider) : daemonState?.cooldowns[provider] }
    func setCountryChangeHighlightsEnabled(_ enabled: Bool) { var updated = preferences; updated.highlightCountryChanges = enabled; apply(updated) }
    func dismissCountryChangeHighlight() {
        if installationInactive { releasedMonitor.engine?.dismissCountryChangeHighlight(); return }
        guard var presentation = daemonState?.presentation else { return }
        presentation.dismissedCountryChange = daemonState?.snapshot?.countryChange?.changedAt
        updatePresentation(presentation) { RuntimeLog.shared.info("country_change_dismissed") }
    }
    func clearError() {
        if installationInactive { releasedMonitor.engine?.clearError(); return }
        guard var presentation = daemonState?.presentation else { return }
        presentation.dismissedError = daemonState?.errorEventID
        updatePresentation(presentation) { RuntimeLog.shared.info("error_cleared") }
    }
    func clearIndicators() {
        guard var presentation = daemonState?.presentation else { return }
        presentation.dismissedError = daemonState?.errorEventID
        presentation.dismissedCountryChange = daemonState?.snapshot?.countryChange?.changedAt
        updatePresentation(presentation)
    }
    func runDebugSimulation(_ scenario: DebugSimulationScenario) {
        simulationMessage = "Simulation: \(scenario.displayName)"
        switch scenario {
        case .transportFailure, .malformedResponse: indicators = .init(errorMessage: scenario.displayName, suppressLocation: true)
        case .rateLimit: status = .providerPaused(preferences.provider, Date().addingTimeInterval(3600))
        case .countryDisagreement: status = .awaitingConfirmation("Simulated country disagreement")
        case .notAllowedAddress: authorizationState = .notAllowed("203.0.113.8")
        }
    }
    func clearDebugSimulation() { simulationMessage = nil; if let state = daemonState { receive(state) } }
    private func reloadSurfaces() {
        RuntimeLog.shared.info("widget_reload_requested")
        WidgetCenter.shared.reloadTimelines(ofKind: MimoSurfaceID.widget)
        if #available(macOS 26.0, *) { ControlCenter.shared.reloadControls(ofKind: MimoSurfaceID.control) }
    }
}
