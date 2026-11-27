#if SWIFT_PACKAGE
import MimoShared
#endif
import Combine
import Foundation
import Network

@MainActor
final class MonitoringEngine: ObservableObject {
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

    /// Why a refresh was requested; written to the runtime log so event-driven behavior can be audited.
    enum RefreshTrigger: String {
        case startup
        case manual
        case periodic
        case networkPath = "network_path"
        case networkConfiguration = "network_configuration"
        case routeChange = "route_change"
        case systemWake = "system_wake"
        case screensWake = "screens_wake"
        case sessionActive = "session_active"
        case appActive = "app_active"
        case queued
        /// One follow-up lookup at the end of an event window for events merged after the immediate one.
        case trailing
        case retry
        case recheck
        case providerChanged = "provider_changed"
        case settingsChanged = "settings_changed"

        var checkIntent: MimoCheckIntent {
            switch self {
            case .startup, .networkPath, .networkConfiguration, .routeChange, .systemWake, .trailing: .transition
            default: .observation
            }
        }

        /// How much API quota the trigger justifies (see `LookupBudget`). `.queued`, `.recheck`, and
        /// `.trailing` normally pass the urgency of the requests they stand in for (`refresh(urgency:)`);
        /// this is only their fallback.
        var urgency: RefreshUrgency {
            switch self {
            case .manual, .providerChanged, .settingsChanged:
                .manual
            case .periodic, .appActive, .screensWake, .sessionActive:
                .routine
            case .retry:
                .followUp
            case .startup, .networkPath, .networkConfiguration, .routeChange, .systemWake, .queued, .trailing, .recheck:
                .networkChange
            }
        }
    }

    typealias Status = MonitoringStatus

    /// Validated local command metadata only; never proxy details or credentials.
    struct RoutingCancellationContext {
        let request: UUID
        let command: DaemonCommand
        let mode: ProxyMode
        let revision: Int
    }

    @Published private(set) var snapshot: MimoSnapshot?
    @Published private(set) var status: Status = .idle {
        didSet {
            switch status {
            case .failed, .coolingDown, .providerPaused, .waitingForIPinfoToken:
                requiredCheckUnavailable?("A fresh required IP check is unavailable.")
            default: break
            }
        }
    }
    var networkConfigurationChanged: (() -> Void)?
    var requiredCheckUnavailable: ((String) -> Void)?
    /// A successful provider response can still be rejected by the supervisor.
    var accessBlockReason: (() -> String?)?
    var routingRevision: (() -> Int?)?
    private var activeRefreshGeneration: Int?
    private var activeLookupID: UUID?
    private var activeLookupProvider: ProviderID?
    private var activeLookupTask: Task<MimoSnapshot, Error>?
    @Published private(set) var preferences: MonitoringPreferences
    @Published private(set) var indicators: MonitorIndicatorState
    @Published private(set) var allowedIPList: AllowedIPList
    @Published private(set) var authorizationState: MimoAuthorizationState = .unavailable
    /// Mimo's Direct mode monitors location without evaluating the allowlist.
    /// Legacy standalone monitoring keeps its warn-only policy by default.
    var allowlistChecksEnabled = true {
        didSet {
            guard oldValue != allowlistChecksEnabled else { return }
            if allowlistChecksEnabled {
                // A cached Direct observation cannot authorize or reject a proxy exit.
                hasVerifiedAddressThisSession = false
                verifiedAddress = nil
                authorizationState = .unavailable
            } else {
                authorizationState = verifiedAddress == nil ? .unavailable : .allowed
            }
        }
    }
    @Published private(set) var providerHealth: [ProviderID: ProviderHealthRecord]
    @Published private(set) var lookupBudget: LookupBudget
    @Published private(set) var diagnosticPreferences: DiagnosticPreferences
    @Published private(set) var simulationMessage: String?
    @Published private(set) var displayDate = Date.now
    private var displayTimer: Timer?

    private let snapshotStore: SnapshotStore
    private let cooldownStore: ProviderCooldownStore
    private let refreshAttemptStore: RefreshAttemptStore
    private let lookupBudgetStore: LookupBudgetStore
    private let indicatorStore: IndicatorStore
    private let allowedIPStore: AllowedIPStore
    private let providerHealthStore: ProviderHealthStore
    private let diagnosticPreferencesStore: DiagnosticPreferencesStore
    private let client: any PublicIPLookupClientProtocol
    private let now: @Sendable () -> Date
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.mimo.network-path")
    private lazy var configurationObserver = NetworkConfigurationObserver { [weak self] in
        Task { @MainActor [weak self] in
            self?.handleEventTrigger(.networkConfiguration)
        }
    }
    private lazy var routeObserver = RouteChangeObserver { [weak self] in
        Task { @MainActor [weak self] in
            self?.handleEventTrigger(.routeChange)
        }
    }
    private var refreshTimer: Timer?
    private var retryTask: Task<Void, Never>?
    /// Leading-plus-trailing throttle shared by every event-driven trigger.
    private var eventWindow = EventRefreshWindow()
    private var eventWindowTask: Task<Void, Never>?
    private var minimumIntervalTask: Task<Void, Never>?
    private var highlightExpiryTask: Task<Void, Never>?
    private let preferencesStore: any PreferenceStorage
    private let observeSystem: Bool
    private var powerObserver: SystemPowerObserver?
    private var receivedInitialPath = false
    private var lastPathSignature: NetworkPathSignature?
    private var consecutiveFailures = 0
    private var temporarilyFailedProviders: Set<ProviderID> = []
    private var isRefreshing = false
    @Published private(set) var manualRefresh: MimoManualRefresh?
    var lookupInFlight: Bool { isRefreshing }
    var periodicRefreshScheduled: Bool { refreshTimer?.isValid == true }
    var networkEventChecksEnabled = true
    private var controlHolds = 0
    var hasQueuedControl: Bool { controlHolds > 0 }
    /// All held/recheck/timer paths transfer the same bounded pending demand.
    private struct LookupDemand {
        let generation: Int
        var manualID: UUID?
        var reasons: Set<RefreshTrigger>
        var force: Bool
        var bypass: Bool
        var trigger: RefreshTrigger
        var urgency: RefreshUrgency
        var provider: ProviderID?
        var intent: MimoCheckIntent
        var notBefore: Date?
    }
    private var pendingDemand: LookupDemand?
    private var demandDrainTask: Task<Void, Never>?

    func holdForControl() { controlHolds += 1 }

    func releaseControl() {
        controlHolds -= 1
        guard controlHolds == 0 else { return }
        reconcileManualOwnership(reason: "control_drain")
        scheduleDemandDrain()
    }

    private func demandFields(_ demand: LookupDemand, reason: String) -> [String: String] {
        var fields = ["generation": String(demand.generation), "reason": reason,
                      "reasons": demand.reasons.map(\.rawValue).sorted().joined(separator: ",")]
        if let id = demand.manualID { fields["request"] = id.uuidString }
        if let revision = routingRevision?() { fields["revision"] = String(revision) }
        return fields
    }

    private func enqueueDemand(_ demand: LookupDemand, reason: String) {
        guard demand.generation == lifecycleGeneration else { return }
        var next = demand
        if let old = pendingDemand, old.generation == demand.generation {
            next.reasons.formUnion(old.reasons)
            next.manualID = currentManualID ?? demand.manualID ?? old.manualID
            next.force = next.force || old.force
            next.bypass = next.bypass || old.bypass
            next.urgency = max(next.urgency, old.urgency)
            next.intent = next.intent == .transition || old.intent == .transition ? .transition : .observation
            // An immediate admitted demand must stay immediate when a later
            // retry is merged into it. Provider admission still applies below.
            if let oldDate = old.notBefore, let nextDate = next.notBefore {
                next.notBefore = min(nextDate, oldDate)
            } else {
                next.notBefore = nil
            }
        }
        pendingDemand = next
        RuntimeLog.shared.info("refresh_demand_queued", fields: demandFields(next, reason: reason))
    }

    private func scheduleDemandDrain() {
        guard demandDrainTask == nil, controlHolds == 0, !isRefreshing,
              isStarted, pendingDemand != nil else { return }
        let generation = lifecycleGeneration
        demandDrainTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, generation == self.lifecycleGeneration else { return }
            self.demandDrainTask = nil
            guard self.controlHolds == 0, !self.isRefreshing, self.isStarted,
                  var demand = self.pendingDemand, demand.generation == generation else { return }
            if let date = demand.notBefore, date > self.currentDate { return }
            self.pendingDemand = nil
            if let manual = demand.manualID, manual != self.currentManualID {
                demand.manualID = nil
                demand.reasons.remove(.manual)
            }
            guard !demand.reasons.isEmpty else {
                RuntimeLog.shared.info("refresh_demand_discarded", fields: self.demandFields(demand, reason: "manual_finished"))
                self.reconcileManualOwnership(reason: "discarded_replay")
                return
            }
            RuntimeLog.shared.info("refresh_demand_consumed", fields: self.demandFields(demand, reason: "admitted"))
            await self.execute(demand)
        }
    }

    private var currentManualID: UUID? {
        guard manualRefresh?.pending == true, manualRefreshGeneration == lifecycleGeneration else { return nil }
        return manualRefresh?.id
    }
    private var pendingIntent: MimoCheckIntent = .observation
    /// The single pending `.queued` refresh (boundary + highest urgency).
    private var pendingRefresh = PendingRefresh()
    private var hasVerifiedAddressThisSession = false
    private var verifiedAddress: String?
    /// The address the allowlist warning window was last opened for, so it opens once per address.
    private var warningPresentedForAddress: String?
    let ipinfoCredentials: CredentialSession
    private var isStarted = false
    private var lifecycleGeneration = 0
    private var manualRefreshGeneration: Int?

    init(
        preferencesStore: any PreferenceStorage = MimoAppGroup.defaults,
        observeSystem: Bool = true,
        snapshotStore: SnapshotStore = SnapshotStore(),
        cooldownStore: ProviderCooldownStore = ProviderCooldownStore(),
        refreshAttemptStore: RefreshAttemptStore = RefreshAttemptStore(),
        lookupBudgetStore: LookupBudgetStore = LookupBudgetStore(),
        indicatorStore: IndicatorStore = IndicatorStore(),
        allowedIPStore: AllowedIPStore = AllowedIPStore(),
        providerHealthStore: ProviderHealthStore = ProviderHealthStore(),
        diagnosticPreferencesStore: DiagnosticPreferencesStore = DiagnosticPreferencesStore(),
        client: any PublicIPLookupClientProtocol = PublicIPLookupClient(),
        ipinfoCredentials: CredentialSession? = nil,
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.preferencesStore = preferencesStore
        self.observeSystem = observeSystem
        self.snapshotStore = snapshotStore
        self.cooldownStore = cooldownStore
        self.refreshAttemptStore = refreshAttemptStore
        self.lookupBudgetStore = lookupBudgetStore
        self.indicatorStore = indicatorStore
        self.allowedIPStore = allowedIPStore
        self.providerHealthStore = providerHealthStore
        self.diagnosticPreferencesStore = diagnosticPreferencesStore
        self.client = client
        self.ipinfoCredentials = ipinfoCredentials ?? CredentialSession(service: CredentialService(backend: KeychainCredentialBackend()), account: SecureTokenStore.ipinfoLiteAccount)
        self.now = now
        self.snapshot = snapshotStore.load()
        self.indicators = indicatorStore.load()
        self.allowedIPList = allowedIPStore.load()
        self.preferences = MonitoringPreferences.load(from: preferencesStore)
        self.providerHealth = providerHealthStore.loadAll()
        self.lookupBudget = lookupBudgetStore.load(now: now())
        self.diagnosticPreferences = diagnosticPreferencesStore.load()
    }

    private var currentDate: Date { now() }

    private func secondsUntil(_ date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(currentDate))
    }

    var isCoolingDown: Bool {
        if case .coolingDown = status { return true }
        return false
    }

    var isRefreshDeferred: Bool {
        switch status {
        case .coolingDown, .waitingForMinimumInterval:
            true
        default:
            false
        }
    }

    func reloadBeforeStart() {
        guard !isStarted else { return }
        snapshot = snapshotStore.load()
        lookupBudget = lookupBudgetStore.load(now: currentDate)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lifecycleGeneration &+= 1
        RuntimeLog.shared.info("monitor_started")
        if observeSystem {
            startNetworkPathMonitoring()
            configurationObserver.start()
            routeObserver.start()
            powerObserver = SystemPowerObserver { [weak self] in self?.handleEventTrigger(.systemWake) }
            powerObserver?.start()
        }
        schedulePeriodicRefresh()
        displayDate = currentDate
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.displayDate = self.currentDate
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
        scheduleHighlightExpiry()
        // Like Refresh now and provider Test, startup bypasses the persisted spacing gate.
        // Every launch gets one immediate check, while subsequent automatic events remain gated.
        Task {
            await refresh(force: true, bypassMinimumInterval: true, trigger: .startup)
        }
    }

    func stop() {
        RuntimeLog.shared.info("monitor_stopped")
        cancelManualRefresh()
        pendingDemand = nil
        demandDrainTask?.cancel(); demandDrainTask = nil
        isStarted = false
        lifecycleGeneration &+= 1
        activeLookupTask?.cancel()
        refreshTimer?.invalidate()
        refreshTimer = nil
        nextPeriodicCheck = nil
        displayTimer?.invalidate()
        displayTimer = nil
        retryTask?.cancel()
        eventWindowTask?.cancel()
        eventWindowTask = nil
        eventWindow.reset()
        minimumIntervalTask?.cancel()
        minimumIntervalTask = nil
        pendingRefresh = PendingRefresh()
        highlightExpiryTask?.cancel()
        powerObserver?.stop()
        powerObserver = nil
        configurationObserver.stop()
        routeObserver.stop()
        pathMonitor.cancel()
    }

    func setAllowedIPList(_ list: AllowedIPList) {
        allowedIPList = list
        allowedIPStore.save(list)
        warningPresentedForAddress = nil
        if hasVerifiedAddressThisSession {
            evaluateAuthorization(for: verifiedAddress)
        }
    }

    func addAllowedIP(_ value: String) -> Bool {
        var updated = allowedIPList
        guard updated.insert(value) else { return false }
        setAllowedIPList(updated)
        return true
    }

    func removeAllowedIP(_ value: String) {
        var updated = allowedIPList
        guard updated.remove(value) else { return }
        setAllowedIPList(updated)
    }

    func reloadLocalIPinfoToken() async -> Bool {
        guard await ipinfoCredentials.load() else { return false }
        cooldownStore.clear(for: .ipinfoLite)
        ipinfoCredentialChanged(requestRefresh: false)
        return true
    }

    @discardableResult
    func beginManualRefresh() -> UUID? {
        guard !Task.isCancelled else { return nil }
        if let current = currentManualID { return current }
        if manualRefresh?.pending == true { terminateManual(.superseded, reason: "lifecycle_changed") }
        manualRefresh = MimoManualRefresh(at: currentDate)
        manualRefreshGeneration = lifecycleGeneration
        manualRefresh?.lifecycleGeneration = lifecycleGeneration
        let id = manualRefresh!.id
        RuntimeLog.shared.info("manual_refresh_queued", fields: manualFields(reason: "manual"))
        if isRefreshing, activeRefreshGeneration == lifecycleGeneration, let lookup = activeLookupID {
            bindManual(id: id, generation: lifecycleGeneration, lookup: lookup, joined: true)
        } else {
            enqueueDemand(.init(generation: lifecycleGeneration, manualID: id, reasons: [.manual],
                force: true, bypass: true, trigger: .manual, urgency: .manual, provider: nil,
                intent: .observation, notBefore: nil), reason: "manual_admitted")
        }
        return id
    }

    private func manualFields(reason: String) -> [String: String] {
        var fields = ["reason": reason]
        if let operation = manualRefresh {
            fields["request"] = operation.id.uuidString
            if let generation = operation.lifecycleGeneration { fields["generation"] = String(generation) }
            if let lookup = operation.lookupID { fields["lookup"] = lookup.uuidString }
        }
        if let revision = routingRevision?() { fields["revision"] = String(revision) }
        return fields
    }

    private func bindManual(id: UUID?, generation: Int, lookup: UUID, joined: Bool = false) {
        guard let id, id == currentManualID, generation == lifecycleGeneration else { return }
        manualRefresh?.lookupID = lookup
        if manualRefresh?.startedAt == nil { manualRefresh?.startedAt = currentDate }
        manualRefresh?.phase = .checking
        manualRefresh?.message = "Checking the exit IP…"
        RuntimeLog.shared.info(joined ? "manual_refresh_joined" : "manual_refresh_started",
                               fields: manualFields(reason: joined ? "current_lookup" : "lookup_admitted"))
    }

    private func terminateManual(_ result: MimoManualRefresh.Result, reason: String, message: String? = nil) {
        guard var operation = manualRefresh, operation.pending else { return }
        operation.result = result
        operation.finishedAt = currentDate
        let outcome: String
        switch result {
        case .checkedAllowed:
            operation.phase = .succeeded; operation.message = "Exit IP refreshed."; outcome = "succeeded"
        case .checkedBlocked:
            operation.phase = .failed
            operation.message = "Exit IP checked. Outbound access remains blocked. \(message ?? "Review Allowed IPs or select another proxy.")"
            outcome = "blocked"
        case .superseded:
            operation.phase = .failed
            operation.message = "Refresh superseded by a newer network or settings change."
            outcome = "superseded"
        case .cancelled:
            operation.phase = .failed; operation.message = "Refresh cancelled because monitoring or services stopped."; outcome = "cancelled"
        case .providerFailed:
            operation.phase = .failed; operation.message = message ?? "The exit-IP provider request failed."; outcome = "provider_failed"
        case .deferred:
            operation.phase = .deferred; operation.message = message ?? "Refresh deferred until a provider is available."; outcome = "deferred"
        case .internalFailure:
            operation.phase = .failed; operation.message = "Refresh could not finish. Try Refresh now again."; outcome = "internal_failure"
        }
        manualRefresh = operation
        if pendingDemand?.manualID == operation.id {
            pendingDemand?.manualID = nil
            pendingDemand?.reasons.remove(.manual)
            if pendingDemand?.reasons.isEmpty == true { pendingDemand = nil }
        }
        var fields = manualFields(reason: reason)
        fields["result"] = result.rawValue; fields["outcome"] = outcome
        RuntimeLog.shared.info("manual_refresh_finished", fields: fields)
    }

    private func cancelManualRefresh(generation: Int? = nil) {
        if let generation, manualRefreshGeneration != generation { return }
        terminateManual(.cancelled, reason: "monitor_stopped_or_execution_cancelled")
    }

    private func finishManualRefresh(generation: Int, lookup: UUID?, failure: MimoManualRefresh.Result? = nil) {
        guard generation == lifecycleGeneration, manualRefreshGeneration == generation,
              let operation = manualRefresh, operation.pending,
              operation.lookupID == nil || operation.lookupID == lookup else { return }
        if let failure {
            terminateManual(failure, reason: "lookup_failed", message: indicators.errorMessage)
            return
        }
        switch status {
        case .ready:
            guard lookup != nil, operation.lookupID == lookup else { return }
            if let reason = accessBlockReason?() { terminateManual(.checkedBlocked, reason: "exit_rejected", message: reason) }
            else { terminateManual(.checkedAllowed, reason: "lookup_succeeded") }
        case .coolingDown(let date), .waitingForMinimumInterval(let date), .providerPaused(_, let date):
            terminateManual(.deferred, reason: "provider_admission_deferred", message:
                "No lookup ran. Providers are paused or out of budget until \(date.formatted(date: .omitted, time: .shortened)).")
        case .waitingForIPinfoToken:
            terminateManual(.deferred, reason: "missing_token", message: "Not refreshed. Save an IPinfo token or enable another provider.")
        case .failed, .awaitingConfirmation:
            terminateManual(.internalFailure, reason: "local_check_failed")
        default: break
        }
    }

    private func reconcileManualOwnership(reason: String) {
        guard manualRefresh?.pending == true else { return }
        guard manualRefreshGeneration == lifecycleGeneration else {
            terminateManual(.superseded, reason: "lifecycle_changed"); return
        }
        if activeRefreshGeneration == lifecycleGeneration, activeLookupID != nil,
           manualRefresh?.lookupID == activeLookupID { return }
        if pendingDemand?.generation == lifecycleGeneration, pendingDemand?.manualID == manualRefresh?.id { return }
        terminateManual(.internalFailure, reason: "orphan_" + reason)
    }

    func loadIPinfoToken() async -> Bool {
        guard await ipinfoCredentials.load() else { return false }
        ipinfoCredentialChanged(requestRefresh: true)
        return true
    }

    /// A saved token may resolve an authentication pause, so clear it and check with the new credential.
    func saveIPinfoToken(_ token: String, requestRefresh: Bool = true) async -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, await ipinfoCredentials.save(token) else { return false }
        cooldownStore.clear(for: .ipinfoLite)
        ipinfoCredentialChanged(requestRefresh: requestRefresh)
        return true
    }

    /// Without a token IPinfo Lite can only fail, so rotation skips it (like a pause) instead of
    /// producing a lookup error that would hide the location. The old credential's pause no longer
    /// applies. No lookup is spent: the current result is still valid.
    func removeIPinfoToken() async -> Bool {
        guard await ipinfoCredentials.remove() else { return false }
        cooldownStore.clear(for: .ipinfoLite)
        RuntimeLog.shared.info("ipinfo_token_removed")
        ipinfoCredentialChanged(requestRefresh: false)
        return true
    }

    private func ipinfoCredentialChanged(requestRefresh: Bool) {
        objectWillChange.send()
        if ipinfoToken == nil {
            if preferences.provider == .ipinfoLite, advanceProvider(after: .ipinfoLite) == nil {
                status = .waitingForIPinfoToken
            }
        } else if requestRefresh, isStarted, preferences.providerPool.contains(.ipinfoLite) {
            Task { await refresh(force: true, trigger: .settingsChanged) }
        }
    }

    /// Cancel obsolete work, but keep its slot until it has actually unwound.
    /// Later requests share one follow-up instead of starting overlapping probes.
    func invalidatePendingLookup(routing context: RoutingCancellationContext? = nil) {
        let previousGeneration = lifecycleGeneration
        terminateManual(.superseded, reason: "lifecycle_changed")
        pendingDemand = nil
        demandDrainTask?.cancel(); demandDrainTask = nil
        minimumIntervalTask?.cancel(); minimumIntervalTask = nil
        pendingRefresh = PendingRefresh(); pendingIntent = .observation
        eventWindowTask?.cancel(); eventWindowTask = nil; eventWindow.reset()
        lifecycleGeneration &+= 1
        if let task = activeLookupTask, let lookup = activeLookupID,
           let provider = activeLookupProvider, let lookupGeneration = activeRefreshGeneration {
            var fields = [
                "lookup": lookup.uuidString, "provider": provider.rawValue,
                "lookup_generation": String(lookupGeneration),
                "lifecycle_before": String(previousGeneration), "lifecycle_after": String(lifecycleGeneration),
                "already_cancelled": String(task.isCancelled), "cause": "invalidated"
            ]
            if let context {
                fields["cause"] = "routing_configuration"
                fields["request"] = context.request.uuidString
                fields["command"] = context.command.rawValue
                fields["intended_mode"] = context.mode.rawValue
                fields["intended_revision"] = String(context.revision)
            }
            // cancel() can synchronously abort a transport before the later
            // routing command is sent. Record its exact owner before signalling.
            RuntimeLog.shared.info("lookup_cancellation_requested", fields: fields)
        }
        activeLookupTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
    }

    /// These are memory-only checks, including during view rendering and automatic refresh.
    var ipinfoToken: String? {
        guard let token = ipinfoCredentials.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    var isIPinfoTokenUnavailable: Bool { ipinfoToken == nil }

    var ipinfoCredentialStatus: String {
        if ipinfoCredentials.isBusy { return "Loading local token…" }
        if ipinfoToken != nil { return "Token available for this session" }
        switch ipinfoCredentials.state {
        case .notLoaded: return "Saved token not loaded"
        case .loading: return "Loading local token…"
        case .missing, .available: return "No saved token found"
        case .failed: return "Local token could not be loaded; try again"
        }
    }

    func applicationDidBecomeActive() {
        handleEventTrigger(.appActive)
    }

    func apply(_ updatedPreferences: MonitoringPreferences, requestRefresh: Bool = true) {
        let providerChanged = preferences.provider != updatedPreferences.provider
        preferences = updatedPreferences
        updatedPreferences.save(to: preferencesStore)
        if !updatedPreferences.highlightCountryChanges {
            dismissCountryChangeHighlight()
        }
        if isStarted { schedulePeriodicRefresh() }
        reloadSystemSurfaces(reloadWidget: false)
        if providerChanged, isStarted, requestRefresh {
            retryTask?.cancel()
            Task { await refresh(force: true, trigger: .providerChanged) }
        }
    }

    func applyDiagnosticPreferences(_ updated: DiagnosticPreferences) {
        diagnosticPreferences = updated
        diagnosticPreferencesStore.save(updated)
        RuntimeLog.shared.info("diagnostic_preferences_changed", fields: [
            "fullIPAddresses": String(updated.includeFullIPAddresses),
            "retentionDays": String(updated.retentionDays)
        ])
    }

    /// Tests exactly `provider`. Explicit tests may retry local failures, but
    /// provider restrictions and daily budgets still prohibit a request.
    func testProvider(_ provider: ProviderID) async {
        guard preferences.providerPool.contains(provider) else { return }
        if provider == .ipinfoLite, isIPinfoTokenUnavailable {
            RuntimeLog.shared.info("provider_test_skipped", fields: ["provider": provider.rawValue, "reason": "token_unavailable"])
            return
        }
        let now = currentDate
        permitExplicitLocalRetry(preferred: provider, pool: [provider])
        if let retryNotBefore = cooldownStore.retryNotBefore(for: provider), retryNotBefore > now {
            status = .providerPaused(provider, retryNotBefore)
            RuntimeLog.shared.info("provider_test_skipped", fields: [
                "provider": provider.rawValue,
                "reason": "provider_paused",
                "resumeAt": retryNotBefore.formatted(.iso8601)
            ])
            return
        }
        if lookupBudgetStore.load(now: now).isExhausted(provider, now: now) {
            let resetAt = LookupBudget.budgetResetDate(after: now)
            status = .coolingDown(resetAt)
            RuntimeLog.shared.info("provider_test_skipped", fields: [
                "provider": provider.rawValue,
                "reason": "daily_budget",
                "resumeAt": resetAt.formatted(.iso8601)
            ])
            return
        }
        await refresh(force: true, bypassMinimumInterval: true, trigger: .manual, preferredProvider: provider)
    }

    func runDebugSimulation(_ scenario: DebugSimulationScenario) {
        simulationMessage = "Simulation: \(scenario.displayName)"
        RuntimeLog.shared.info("debug_simulation_started", fields: ["scenario": scenario.rawValue])
        switch scenario {
        case .transportFailure:
            status = .failed("Simulated network transport failure")
            setError("Simulated transport failure")
        case .malformedResponse:
            status = .failed("Simulated malformed provider response")
            setError("Simulated malformed provider response")
        case .rateLimit:
            status = .providerPaused(preferences.provider, currentDate.addingTimeInterval(3600))
        case .countryDisagreement:
            status = .awaitingConfirmation("Simulated country disagreement; the last verified location remains active.")
        case .notAllowedAddress:
            authorizationState = .notAllowed(snapshot?.ipAddress ?? "203.0.113.8")
        }
        objectWillChange.send()
    }

    func clearDebugSimulation() {
        guard simulationMessage != nil else { return }
        simulationMessage = nil
        clearError()
        authorizationState = .unavailable
        if hasVerifiedAddressThisSession {
            evaluateAuthorization(for: verifiedAddress)
        } else {
            authorizationState = .unavailable
        }
        status = snapshot == nil ? .idle : .ready
        RuntimeLog.shared.info("debug_simulation_cleared")
        objectWillChange.send()
    }

    func setCountryChangeHighlightsEnabled(_ enabled: Bool) {
        var updatedPreferences = preferences
        updatedPreferences.highlightCountryChanges = enabled
        apply(updatedPreferences)
    }

    func refresh(
        force: Bool = false,
        bypassMinimumInterval: Bool = false,
        trigger: RefreshTrigger = .manual,
        urgency urgencyOverride: RefreshUrgency? = nil,
        preferredProvider: ProviderID? = nil,
        intent intentOverride: MimoCheckIntent? = nil,
        manualRequestID: UUID? = nil
    ) async {
        guard !Task.isCancelled else { return }
        if trigger == .manual {
            if let manualRequestID { guard currentManualID == manualRequestID else { return } }
            else { guard beginManualRefresh() != nil else { return } }
        }
        let demand = LookupDemand(generation: lifecycleGeneration, manualID: currentManualID, reasons: [trigger],
            force: force, bypass: bypassMinimumInterval, trigger: trigger, urgency: urgencyOverride ?? trigger.urgency,
            provider: preferredProvider, intent: intentOverride ?? trigger.checkIntent, notBefore: nil)
        await execute(demand)
    }

    private func execute(_ incoming: LookupDemand) async {
        guard !Task.isCancelled, incoming.generation == lifecycleGeneration else { return }
        var demand = incoming
        demand.manualID = currentManualID
        if let pending = pendingDemand, pending.generation == lifecycleGeneration {
            demand.reasons.formUnion(pending.reasons)
            demand.force = demand.force || pending.force
            demand.bypass = demand.bypass || pending.bypass
            demand.urgency = max(demand.urgency, pending.urgency)
            if pending.intent == .transition { demand.intent = .transition }
        }
        let force = demand.force, bypassMinimumInterval = demand.bypass
        let trigger = demand.trigger, urgency = demand.urgency, intent = demand.intent
        let preferredProvider = demand.provider
        let refreshID = UUID()
        if isRefreshing, activeRefreshGeneration == lifecycleGeneration, intent != .transition {
            bindManual(id: currentManualID, generation: lifecycleGeneration, lookup: activeLookupID!, joined: true)
            if pendingDemand?.generation == lifecycleGeneration { pendingDemand = nil }
            RuntimeLog.shared.info("refresh_coalesced_in_flight", fields: ["trigger": trigger.rawValue,
                "lookup": refreshID.uuidString, "activeLookup": activeLookupID?.uuidString ?? "none"])
            return
        }
        if controlHolds > 0 || isRefreshing {
            enqueueDemand(demand, reason: controlHolds > 0 ? "control_hold" : "execution_join")
            return
        }
        pendingDemand = nil
        retryTask?.cancel(); retryTask = nil
        minimumIntervalTask?.cancel(); minimumIntervalTask = nil
        RuntimeLog.shared.info("refresh_requested", fields: ["trigger": trigger.rawValue,
            "urgency": urgency.logName, "intent": intent.rawValue, "force": String(force),
            "lookup": refreshID.uuidString, "startupBypass": String(bypassMinimumInterval),
            "provider": (preferredProvider ?? preferences.provider).rawValue])
        var providerFollowUp = false
        let refreshGeneration = demand.generation
        var executionLookup: UUID?
        var manualFailure: MimoManualRefresh.Result?
        defer {
            if !providerFollowUp { finishManualRefresh(generation: refreshGeneration, lookup: executionLookup, failure: manualFailure) }
            reconcileManualOwnership(reason: "lookup_completion")
        }
        var activeProvider = preferredProvider ?? preferences.provider
        // No credential read, network request, quota charge, or missing-token error is needed.
        // Keep the last verified snapshot visible until the user explicitly loads/saves a token.
        if isIPinfoTokenUnavailable,
           preferredProvider == .ipinfoLite || preferences.providerPool.allSatisfy({ $0 == .ipinfoLite }) {
            status = .waitingForIPinfoToken
            RuntimeLog.shared.info("refresh_skipped", fields: ["trigger": trigger.rawValue, "reason": "token_unavailable"])
            return
        }
        if !force, let interval = preferences.refreshInterval.periodicSeconds, let snapshot,
           currentDate.timeIntervalSince(snapshot.checkedAt) < interval {
            return
        }

        if urgency == .manual {
            permitExplicitLocalRetry(preferred: activeProvider,
                                     pool: preferredProvider.map { [$0] } ?? preferences.providerPool)
        }
        var budget = lookupBudgetStore.load(now: currentDate)
        // One shared decision covers refusal cooldowns, daily budgets, the per-provider gap, and the burst
        // allowance. A paused provider is skipped by normal rotation; the refused request itself was never
        // retried elsewhere. Startup, Refresh now and provider Test bypass the gap and burst allowance.
        let cooldowns = providerCooldowns()
        let decision = RefreshGate.decide(
            urgency: urgency,
            pool: preferences.providerPool,
            preferred: activeProvider,
            lastAttempts: refreshAttemptStore.lastAttempts(),
            excluded: ineligibleProviders(keeping: activeProvider),
            cooldowns: cooldowns,
            budget: &budget,
            lastSuccess: snapshot?.checkedAt,
            bypassLimits: bypassMinimumInterval,
            recordAtAdmission: !client.accountsActualRequests,
            now: currentDate
        )
        lookupBudgetStore.save(budget)
        lookupBudget = budget
        if let storage = preferencesStore as? FilePreferenceStorage, let error = storage.lastError {
            status = .failed("Cannot persist provider quota: \(error)")
            return
        }
        switch decision {
        case .run(let provider, let rotatedFrom):
            if let rotatedFrom {
                let event = if budget.isExhausted(rotatedFrom) {
                    "provider_rotated_daily_budget"
                } else if let pausedUntil = cooldowns[rotatedFrom], pausedUntil > currentDate {
                    "provider_rotated_cooldown"
                } else {
                    "provider_rotated_spacing"
                }
                RuntimeLog.shared.info(event, fields: [
                    "from": rotatedFrom.rawValue,
                    "to": provider.rawValue,
                    "trigger": trigger.rawValue
                ])
                selectProvider(provider)
                activeProvider = provider
            }
        case .queue(let date, let reason):
            queueRefresh(at: date, urgency: urgency, trigger: trigger, reason: reason, intent: intent)
            return
        case .skip(let reason):
            RuntimeLog.shared.info("refresh_skipped", fields: ["trigger": trigger.rawValue, "reason": reason])
            return
        case .dailyBudgetExhausted(let resetAt):
            status = .coolingDown(resetAt)
            RuntimeLog.shared.info("lookup_daily_budget_exhausted", fields: [
                "provider": activeProvider.rawValue,
                "resetAt": resetAt.formatted(.iso8601)
            ])
            scheduleRetry(after: secondsUntil(resetAt), intent: intent)
            return
        case .allProvidersPaused(let resumeAt):
            // A pause is not an exit-IP error: the last verified result stays visible.
            status = .coolingDown(resumeAt)
            RuntimeLog.shared.info("lookup_all_providers_paused", fields: [
                "trigger": trigger.rawValue,
                "resumeAt": resumeAt.formatted(.iso8601), "lookup": refreshID.uuidString,
                "restrictions": preferences.providerPool.map { provider in
                    let kind = budget.isExhausted(provider, now: currentDate) ? "daily_budget" :
                        (cooldownStore.allowsExplicitRetry(for: provider, health: providerHealth[provider], now: currentDate)
                         ? "local_backoff" : "provider_or_legacy_pause")
                    return "\(provider.rawValue):\(kind)"
                }.joined(separator: ", ")
            ])
            scheduleRetry(after: secondsUntil(resumeAt), intent: intent)
            return
        }

        // This lookup answers every earlier request, so a pending queued lookup is no longer needed.
        if let superseded = pendingRefresh.supersede() {
            pendingIntent = .observation
            minimumIntervalTask?.cancel()
            minimumIntervalTask = nil
            RuntimeLog.shared.info("refresh_queue_superseded", fields: [
                "trigger": trigger.rawValue,
                "notBefore": superseded.formatted(.iso8601)
            ])
        }
        refreshAttemptStore.recordAttempt(for: activeProvider, at: currentDate)
        updateProviderHealth(activeProvider) { record in
            record.lastAttempt = currentDate
        }
        let lookupID = refreshID
        let lookupStarted = ProcessInfo.processInfo.systemUptime
        activeLookupID = lookupID
        executionLookup = lookupID
        activeLookupProvider = activeProvider
        activeRefreshGeneration = refreshGeneration
        isRefreshing = true
        status = .refreshing
        bindManual(id: currentManualID, generation: refreshGeneration, lookup: lookupID)
        RuntimeLog.shared.info("lookup_started", fields: ["provider": activeProvider.rawValue, "lookup": lookupID.uuidString,
            "trigger": trigger.rawValue, "lifecycle_generation": String(refreshGeneration)])
        defer {
            RuntimeLog.shared.info("lookup_finished", fields: ["lookup": lookupID.uuidString,
                "duration_ms": String(Int((ProcessInfo.processInfo.systemUptime - lookupStarted) * 1000))])
            if activeLookupID == lookupID {
                activeLookupID = nil
                activeLookupProvider = nil
                activeLookupTask = nil
                isRefreshing = false
                if isStarted { scheduleDemandDrain() }
            }
        }

        do {
            let token = activeProvider == .ipinfoLite ? ipinfoToken : nil
            let configuration = LookupConfiguration(provider: activeProvider, ipinfoToken: token, lookupID: lookupID, intent: intent)
            let request = Task { try await self.lookup(configuration: configuration) }
            activeLookupTask = request
            var fetched = try await request.value
            guard isStarted, refreshGeneration == lifecycleGeneration else {
                cancelManualRefresh(generation: refreshGeneration)
                RuntimeLog.shared.info("lookup_discarded_after_stop", fields: ["provider": activeProvider.rawValue])
                return
            }
            guard let normalizedIP = IPAddressValidator.normalize(fetched.ipAddress) else {
                throw LookupError.invalidResponse
            }
            fetched.ipAddress = normalizedIP
            consecutiveFailures = 0
            temporarilyFailedProviders.removeAll()
            cooldownStore.clear(for: activeProvider)

            // Country is display metadata, not a verification trigger. Accept
            // the fresh IP result without a second provider call or retry for
            // missing/disagreeing geography. Routing already checked this IP.
            if !fetched.hasValidCountryCode {
                RuntimeLog.shared.info("lookup_country_unknown", fields: ["provider": fetched.provider.rawValue])
            } else if let previous = snapshot, previous.ipAddress == fetched.ipAddress,
                      previous.countryCode != fetched.countryCode {
                RuntimeLog.shared.info("location_metadata_changed", fields: ["country": fetched.countryCode])
            }

            commitVerifiedSnapshot(fetched)
            markFreshAddress(fetched.ipAddress)
            updateProviderHealth(activeProvider) { record in
                record.lastSuccess = currentDate
                record.lastError = nil
                record.consecutiveFailures = 0
            }
            RuntimeLog.shared.info("lookup_succeeded", fields: [
                "provider": fetched.provider.rawValue,
                "lookup": lookupID.uuidString,
                "country": fetched.countryCode
            ])
        } catch {
            guard isStarted, refreshGeneration == lifecycleGeneration else { cancelManualRefresh(generation: refreshGeneration); return }
            if error is CancellationError {
                cancelManualRefresh(generation: refreshGeneration)
                RuntimeLog.shared.info("lookup_cancelled", fields: ["provider": activeProvider.rawValue, "lookup": lookupID.uuidString])
                return
            }
            manualFailure = error is LookupError ? .providerFailed : .internalFailure
            consecutiveFailures += 1
            updateProviderHealth(activeProvider) { record in
                record.lastFailure = currentDate
                record.lastError = lookupErrorCategory(error)
                record.consecutiveFailures += 1
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(message)
            setError("Unable to check the exit IP with \(activeProvider.displayName): \(message)")
            RuntimeLog.shared.error("lookup_failed", fields: [
                "provider": activeProvider.rawValue, "message": message, "category": lookupErrorCategory(error), "lookup": lookupID.uuidString
            ])
            // A routing/service preparation failure is not evidence that a
            // provider failed. Only actual lookup errors pause that provider.
            guard let lookupError = error as? LookupError else { return }
            let resumeAt = ProviderFailurePolicy.resumeAt(after: lookupError, now: currentDate)
            let explicitRetry = ProviderFailurePolicy.allowsExplicitRetry(after: lookupError)
            cooldownStore.save(retryNotBefore: resumeAt, for: activeProvider, allowsExplicitRetry: explicitRetry)
            RuntimeLog.shared.info("provider_failure_paused", fields: [
                "provider": activeProvider.rawValue, "reason": lookupError.category, "lookup": lookupID.uuidString,
                "resumeAt": resumeAt.formatted(.iso8601), "seconds": String(Int(resumeAt.timeIntervalSince(currentDate))),
                "explicitRetry": String(explicitRetry)
            ])
            if let next = advanceProvider(after: activeProvider) {
                RuntimeLog.shared.info("provider_rotated_after_failure", fields: [
                    "from": activeProvider.rawValue, "to": next.rawValue, "category": lookupError.category
                ])
                // The current task unwinds before the next provider starts.
                // A different provider has its own quota and cooldown.
                enqueueDemand(.init(generation: refreshGeneration, manualID: currentManualID, reasons: [.recheck],
                    force: true, bypass: true, trigger: .recheck, urgency: urgency, provider: next,
                    intent: intent, notBefore: nil), reason: "provider_rotation")
                providerFollowUp = true
            } else {
                status = .coolingDown(providerCooldowns().values.min() ?? resumeAt)
                scheduleRetry(after: secondsUntil(providerCooldowns().values.min() ?? resumeAt), intent: intent)
            }
        }
    }

    func clearError() {
        RuntimeLog.shared.info("error_cleared")
        indicators.errorMessage = nil
        indicatorStore.save(indicators)
        if case .failed = status {
            status = snapshot == nil ? .idle : .ready
        }
        objectWillChange.send()
        reloadSystemSurfaces()
    }

    func clearIndicators() {
        clearError()
        dismissCountryChangeHighlight()
    }

    func dismissCountryChangeHighlight() {
        RuntimeLog.shared.info("country_change_dismissed")
        guard var updated = snapshot else { return }
        updated.countryChange = nil
        snapshot = updated
        snapshotStore.save(updated)
        reloadSystemSurfaces()
        highlightExpiryTask?.cancel()
    }

    private func commitVerifiedSnapshot(_ fetched: MimoSnapshot) {
        var updated = CountryChangeDetector.applyingCountryChange(to: fetched, previous: snapshot)
        if !preferences.highlightCountryChanges {
            updated.countryChange = nil
        }
        let shouldReloadWidget = updated.hasWidgetContentChange(comparedTo: snapshot)
        snapshot = updated
        snapshotStore.save(updated)
        if isStarted { schedulePeriodicRefresh() }
        indicators = MonitorIndicatorState()
        indicatorStore.save(indicators)
        _ = advanceProvider(after: fetched.provider)
        status = .ready
        reloadSystemSurfaces(reloadWidget: shouldReloadWidget)
        scheduleHighlightExpiry()
    }

    private func markFreshAddress(_ address: String) {
        hasVerifiedAddressThisSession = true
        verifiedAddress = address
        evaluateAuthorization(for: address)
    }

    /// Warn-only allowlist: an address outside a non-empty list opens the warning window once per address
    /// and shows a notice in the dashboard. It never blocks traffic, never sets the error
    /// indicator, and never hides the location. Only fresh, successful lookups reach this.
    private func evaluateAuthorization(for address: String?) {
        guard allowlistChecksEnabled else {
            authorizationState = address == nil ? .unavailable : .allowed
            return
        }
        guard let address, !allowedIPList.isEmpty, !allowedIPList.contains(address) else {
            authorizationState = (address == nil || allowedIPList.isEmpty) ? .unavailable : .allowed
            return
        }
        authorizationState = .notAllowed(address)
    }

    private func setError(_ message: String) {
        RuntimeLog.shared.error("indicator_error_set", fields: ["message": message])
        indicators = MonitorIndicatorState(errorMessage: message, suppressLocation: true)
        indicatorStore.save(indicators)
        objectWillChange.send()
        reloadSystemSurfaces()
    }

    private func updateProviderHealth(_ provider: ProviderID, update: (inout ProviderHealthRecord) -> Void) {
        var record = providerHealth[provider] ?? ProviderHealthRecord()
        update(&record)
        providerHealth[provider] = record
        providerHealthStore.save(record, for: provider)
        RuntimeLog.shared.info("provider_health_changed", fields: [
            "provider": provider.rawValue,
            "consecutiveFailures": String(record.consecutiveFailures),
            "lastError": record.lastError ?? ""
        ])
    }

    /// Ordinary HTTP clients have a 15-second deadline. A managed-routing client
    /// also budgets its bounded preparation/activation; its HTTP session still
    /// independently limits provider resource time to 15 seconds.
    /// Managed clients account each actual HTTP request after preparation,
    /// including the required IPv4 observation and any explicit country confirmation.
    func accountActualRequest(_ provider: ProviderID) throws {
        let now = currentDate
        var budget = lookupBudgetStore.load(now: now)
        guard !budget.isExhausted(provider, now: now),
              (cooldownStore.retryNotBefore(for: provider) ?? .distantPast) <= now else {
            RuntimeLog.shared.info("lookup_http_refused", fields: ["provider": provider.rawValue,
                "lookup": activeLookupID?.uuidString ?? "none",
                "reason": budget.isExhausted(provider, now: now) ? "daily_budget" : "provider_pause"])
            throw LookupError.rateLimited(retryAfter: cooldownStore.retryNotBefore(for: provider))
        }
        budget.recordCall(to: provider, now: now)
        lookupBudgetStore.save(budget); lookupBudget = budget
        RuntimeLog.shared.info("lookup_http_request", fields: ["provider": provider.rawValue, "lookup": activeLookupID?.uuidString ?? "none"])
    }

    private func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        let providerClient = client
        return try await withThrowingTaskGroup(of: MimoSnapshot.self) { group in
            group.addTask {
                return try await providerClient.lookup(configuration: configuration)
            }
            group.addTask {
                try await Task.sleep(for: providerClient.lookupTimeout)
                throw LookupError.transport("The exit-IP check timed out.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func advanceProvider(after provider: ProviderID) -> ProviderID? {
        let pool = preferences.providerPool
        guard pool.count > 1, let index = pool.firstIndex(of: provider) else { return nil }
        guard case .use(let candidate) = RefreshPolicy.providerSelection(
            pool: pool,
            preferred: pool[(index + 1) % pool.count],
            lastAttempts: [:],
            excluded: ineligibleProviders(keeping: nil).union([provider])
        ) else { return nil }
        selectProvider(candidate)
        return candidate
    }

    /// Providers that pool rotation must skip: used-up daily budget, a refusal cooldown, or a temporary
    /// failure in the current rotation. `kept` (the active provider) is never excluded for a temporary
    /// failure, so a refresh can still start on it.
    private func ineligibleProviders(keeping kept: ProviderID?) -> Set<ProviderID> {
        let budget = lookupBudgetStore.load(now: currentDate)
        let now = currentDate
        let tokenUnavailable = isIPinfoTokenUnavailable
        return Set(preferences.providerPool.filter { candidate in
            if budget.isExhausted(candidate, now: now) { return true }
            if candidate == .ipinfoLite, tokenUnavailable { return true }
            if let retryNotBefore = cooldownStore.retryNotBefore(for: candidate), retryNotBefore > now { return true }
            if candidate == kept { return false }
            return temporarilyFailedProviders.contains(candidate)
        })
    }

    /// The refusal cooldown deadline for `provider`, if it is still paused. Read-only, for display.
    func pausedUntil(_ provider: ProviderID) -> Date? {
        guard let retryNotBefore = cooldownStore.retryNotBefore(for: provider), retryNotBefore > currentDate else { return nil }
        return retryNotBefore
    }

    /// Refusal deadlines still in the future, for the pool and the active provider.
    private func providerCooldowns() -> [ProviderID: Date] {
        let now = currentDate
        var cooldowns: [ProviderID: Date] = [:]
        for provider in Set(preferences.providerPool + [preferences.provider]) {
            if let retryNotBefore = cooldownStore.retryNotBefore(for: provider), retryNotBefore > now {
                cooldowns[provider] = retryNotBefore
            }
        }
        return cooldowns
    }

    /// One explicit user action releases at most one local backoff. Automatic
    /// retry/rotation never calls this with manual urgency, so a continuing
    /// outage still settles instead of looping through paused providers.
    private func permitExplicitLocalRetry(preferred: ProviderID, pool: [ProviderID]) {
        let candidates = [preferred] + pool.filter { $0 != preferred }
        guard let provider = candidates.first(where: {
            cooldownStore.allowsExplicitRetry(for: $0, health: providerHealth[$0], now: currentDate)
        }) else { return }
        cooldownStore.clear(for: provider)
        RuntimeLog.shared.info("provider_local_retry_requested", fields: ["provider": provider.rawValue])
    }

    private func selectProvider(_ provider: ProviderID) {
        var updated = preferences
        updated.provider = provider
        preferences = updated
        updated.save(to: preferencesStore)
    }

    private func lookupErrorCategory(_ error: Error) -> String {
        (error as? LookupError)?.category ?? "unknown"
    }

    private(set) var nextPeriodicCheck: Date?

    private func schedulePeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard isStarted, let interval = preferences.refreshInterval.periodicSeconds else {
            nextPeriodicCheck = nil; return
        }
        // Successful observations, including policy denials, start a new period.
        // A past deadline waits at least one minute; provider retry/backoff owns
        // earlier recovery and cannot cause a tight periodic loop.
        let due = (snapshot?.checkedAt ?? currentDate).addingTimeInterval(interval)
        nextPeriodicCheck = max(due, currentDate.addingTimeInterval(60))
        RuntimeLog.shared.info("periodic_check_scheduled", fields: ["next": nextPeriodicCheck!.formatted(.iso8601)])
        let timer = Timer(timeInterval: secondsUntil(nextPeriodicCheck!), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.runPeriodicCheckIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func runPeriodicCheckIfDue() async {
        guard isStarted, let nextPeriodicCheck, currentDate >= nextPeriodicCheck else { return }
        // Keep a bounded future timer even if admission or a local runtime error
        // prevents this attempt. Success below replaces it from the new snapshot.
        schedulePeriodicRefresh()
        await refresh(force: true, trigger: .periodic)
    }

    private func startNetworkPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = NetworkPathSignature(path)
            Task { @MainActor in
                guard let self else { return }
                let previous = self.lastPathSignature
                self.lastPathSignature = signature
                defer { self.receivedInitialPath = true }
                guard self.receivedInitialPath else { return }
                // NWPathMonitor also reports updates in which nothing observable changed. A network change
                // always spends a lookup, so only a different path counts; proxy, DNS, and route changes
                // that keep the same path are reported by the SystemConfiguration and routing observers.
                guard signature != previous else {
                    RuntimeLog.shared.info("network_path_unchanged")
                    return
                }
                self.handleEventTrigger(.networkPath)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    /// Event-driven refreshes run immediately, then wait: events inside the following
    /// `RefreshPolicy.eventWindow` are merged into one trailing lookup at its end. The per-provider gap in
    /// `refresh` sends that trailing lookup to the next provider, so neither lookup has to queue.
    private func handleEventTrigger(_ trigger: RefreshTrigger) {
        guard networkEventChecksEnabled else {
            RuntimeLog.shared.info("mimo_direct_event_ignored", fields: ["source": trigger.rawValue])
            return
        }
        if let networkConfigurationChanged {
            invalidatePendingLookup()
            networkConfigurationChanged()
            let generation = lifecycleGeneration
            Task {
                guard generation == lifecycleGeneration, isStarted else { return }
                await refresh(force: true, bypassMinimumInterval: true, trigger: trigger)
            }
            return
        }
        switch eventWindow.register(trigger.urgency, now: currentDate) {
        case .runNow(let windowEndsAt):
            scheduleEventWindowEnd(at: windowEndsAt)
            Task { await refresh(force: true, trigger: trigger) }
        case .mergedIntoTrailing(let windowEndsAt):
            RuntimeLog.shared.info("refresh_event_merged", fields: [
                "trigger": trigger.rawValue,
                "trailingAt": windowEndsAt.formatted(.iso8601)
            ])
        case .absorbed:
            RuntimeLog.shared.info("refresh_skipped", fields: ["trigger": trigger.rawValue, "reason": "event_window"])
        }
    }

    /// The privileged supervisor has already closed protected traffic before sending
    /// this event. Keep scheduling/budgets here while invalidating any pending result.
    func supervisorNetworkChanged() { handleEventTrigger(.networkConfiguration) }

    private func scheduleEventWindowEnd(at date: Date) {
        eventWindowTask?.cancel()
        eventWindowTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.secondsUntil(date) ?? 0))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.eventWindowTask = nil
            guard let trailing = self.eventWindow.takeTrailing(now: self.currentDate) else { return }
            self.scheduleEventWindowEnd(at: trailing.windowEndsAt)
            await self.refresh(force: true, trigger: .trailing, urgency: trailing.urgency)
        }
    }

    private func queueRefresh(at date: Date, urgency: RefreshUrgency, trigger: RefreshTrigger, reason: String, intent: MimoCheckIntent) {
        pendingIntent = pendingIntent == .transition || intent == .transition ? .transition : .observation
        // Keep the earliest pending boundary; a later request must not postpone an earlier one.
        if pendingRefresh.enqueue(at: date, urgency: urgency) || minimumIntervalTask == nil {
            scheduleRefreshAfterMinimumInterval(pendingRefresh.notBefore ?? date)
        }
        enqueueDemand(.init(generation: lifecycleGeneration, manualID: nil, reasons: [.queued],
            force: true, bypass: false, trigger: .queued, urgency: urgency, provider: nil,
            intent: pendingIntent, notBefore: pendingRefresh.notBefore ?? date), reason: "minimum_interval")
        status = .waitingForMinimumInterval(pendingRefresh.notBefore ?? date)
        RuntimeLog.shared.info("refresh_queued", fields: [
            "trigger": trigger.rawValue,
            "urgency": urgency.logName,
            "reason": reason,
            "notBefore": (pendingRefresh.notBefore ?? date).formatted(.iso8601)
        ])
    }

    private func scheduleRefreshAfterMinimumInterval(_ date: Date) {
        minimumIntervalTask?.cancel()
        let generation = lifecycleGeneration
        minimumIntervalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.secondsUntil(date) ?? 0))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, generation == self.lifecycleGeneration else { return }
            self.minimumIntervalTask = nil
            _ = self.pendingRefresh.take(); self.pendingIntent = .observation
            self.scheduleDemandDrain()
        }
    }

    private func scheduleResilienceRetryIfAppropriate(for error: Error) {
        guard let lookupError = error as? LookupError,
              lookupError.supportsResilienceRetry else { return }

        let delay: TimeInterval
        if let retryAfter = lookupError.retryAfter {
            delay = max(0, secondsUntil(retryAfter))
        } else {
            delay = RefreshPolicy.retryDelay(forConsecutiveFailure: consecutiveFailures)
        }

        scheduleRetry(after: delay)
    }

    private func scheduleRetry(after delay: TimeInterval, intent: MimoCheckIntent = .observation) {
        retryTask?.cancel()
        let generation = lifecycleGeneration
        enqueueDemand(.init(generation: generation, manualID: nil, reasons: [.retry],
            force: true, bypass: false, trigger: .retry, urgency: .followUp, provider: nil,
            intent: intent, notBefore: currentDate.addingTimeInterval(max(0, delay))), reason: "provider_retry")
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, delay)))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, generation == self.lifecycleGeneration else { return }
            self.retryTask = nil
            self.scheduleDemandDrain()
        }
    }

    private func scheduleHighlightExpiry() {
        highlightExpiryTask?.cancel()
        guard let snapshot,
              let highlightUntil = snapshot.countryChange?.highlightUntil,
              highlightUntil > currentDate else { return }

        highlightExpiryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(self.secondsUntil(highlightUntil)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.dismissCountryChangeHighlight()
        }
    }

    private func reloadSystemSurfaces(reloadWidget: Bool = true) {
        objectWillChange.send()
    }

}

/// The parts of an `NWPath` that can change the exit IP: reachability, the interfaces in use (and their
/// order), gateways, and address families.
private struct NetworkPathSignature: Equatable, Sendable {
    let status: String
    let interfaces: [String]
    let gateways: [String]
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let supportsDNS: Bool

    init(_ path: NWPath) {
        status = String(describing: path.status)
        interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }
        gateways = path.gateways.map { String(describing: $0) }
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
    }
}
