import Combine
import Foundation

/// Monitoring after full uninstall belongs to the open GUI. It has no XPC,
/// launchd, firewall, routing or machine-Keychain capabilities.
@MainActor
final class MimoReleasedMonitor {
    private final class Store: PreferenceStorage {
        let base: any PreferenceStorage
        init(_ base: any PreferenceStorage) { self.base = base }
        func object(forKey key: String) -> Any? { base.object(forKey: "released." + key) }
        func set(_ value: Any?, forKey key: String) { base.set(value, forKey: "released." + key) }
        func removeObject(forKey key: String) { base.removeObject(forKey: "released." + key) }
    }
    private struct NoCredentials: CredentialBackend {
        func read(account: String) throws -> String? { nil }
        func save(_ value: String, account: String) throws { throw DaemonFailure.unavailable }
        func delete(account: String) throws { throw DaemonFailure.unavailable }
    }
    private let store: Store
    private let client: any PublicIPLookupClientProtocol
    private let observeSystem: Bool
    private struct Remembered: Equatable {
        var preferences: MonitoringPreferences
        var diagnostics: DiagnosticPreferences
        var budget: LookupBudget
        var cooldowns: [ProviderID: Date]
        var health: [ProviderID: ProviderHealthRecord]
    }
    private var remembered: Remembered?
    private var observation: AnyCancellable?
    private(set) var engine: MonitoringEngine?
    var changed: (() -> Void)?

    init(defaults: any PreferenceStorage = MimoAppGroup.defaults,
         client: any PublicIPLookupClientProtocol = PublicIPLookupClient(), observeSystem: Bool = true) {
        store = Store(defaults); self.client = client; self.observeSystem = observeSystem
    }

    static func anonymousPreferences(_ preferences: MonitoringPreferences) -> MonitoringPreferences {
        var result = preferences
        result.providerPool.removeAll { $0 == .ipinfoLite }
        if result.providerPool.isEmpty { result.providerPool = [.ipWhois, .ipapiCo, .ipapiIs] }
        if !result.providerPool.contains(result.provider) { result.provider = result.providerPool[0] }
        return result
    }

    func remember(_ state: DaemonState) {
        guard engine == nil else { return }
        let next = Remembered(preferences: Self.anonymousPreferences(state.preferences),
            diagnostics: state.settings.diagnostics, budget: state.budget,
            cooldowns: state.cooldowns, health: state.providerHealth)
        // Service-health publications are frequent and do not change this
        // fallback. Avoid serializing and writing defaults on the UI thread
        // for each health timestamp or routing progress update.
        guard next != remembered else { return }
        // Upgrade old released preferences before copying the already-migrated
        // machine settings, so an explicit new 15-minute choice stays intact.
        try? MimoLocalSettings.migrateMonitoring(store)
        next.preferences.save(to: store)
        DiagnosticPreferencesStore(defaults: store).save(state.settings.diagnostics)
        LookupBudgetStore(defaults: store).save(state.budget)
        let cooldowns = ProviderCooldownStore(defaults: store)
        let health = ProviderHealthStore(defaults: store)
        for provider in ProviderID.allCases {
            if let until = state.cooldowns[provider] { cooldowns.save(retryNotBefore: until, for: provider) }
            else { cooldowns.clear(for: provider) }
            if let record = state.providerHealth[provider] { health.save(record, for: provider) }
        }
        remembered = next
    }

    func start() {
        guard engine == nil else { return }
        // The local engine may change these defaults while services are
        // released. The first shared reply after activation must replace them.
        remembered = nil
        try? MimoLocalSettings.migrateMonitoring(store)
        Self.anonymousPreferences(MonitoringPreferences.load(from: store)).save(to: store)
        let monitor = MonitoringEngine(preferencesStore: store, observeSystem: observeSystem,
            snapshotStore: SnapshotStore(defaults: store), cooldownStore: ProviderCooldownStore(defaults: store),
            refreshAttemptStore: RefreshAttemptStore(defaults: store), lookupBudgetStore: LookupBudgetStore(defaults: store),
            indicatorStore: IndicatorStore(defaults: store), allowedIPStore: AllowedIPStore(defaults: store),
            providerHealthStore: ProviderHealthStore(defaults: store), diagnosticPreferencesStore: DiagnosticPreferencesStore(defaults: store),
            client: client, ipinfoCredentials: CredentialSession(service: CredentialService(backend: NoCredentials()), account: "released"))
        monitor.allowlistChecksEnabled = false
        RuntimeLog.shared.configure(monitor.diagnosticPreferences)
        engine = monitor
        observation = monitor.objectWillChange.sink { [weak self, weak monitor] in
            Task { @MainActor in
                guard let self, let monitor, self.engine === monitor else { return }
                self.changed?()
            }
        }
        monitor.start()
        changed?()
        RuntimeLog.shared.info("mimo_local_monitor_started")
    }

    func stop() {
        guard let engine else { return }
        observation = nil; self.engine = nil
        engine.stop()
        RuntimeLog.shared.info("mimo_local_monitor_stopped")
    }
}
