import Foundation

public struct MonitorIndicatorState: Codable, Equatable, Sendable {
    public var errorMessage: String?
    public var suppressLocation: Bool

    public init(errorMessage: String? = nil, suppressLocation: Bool = false) {
        self.errorMessage = errorMessage
        self.suppressLocation = suppressLocation
    }

    public var hasError: Bool { errorMessage != nil }
}

public final class IndicatorStore: @unchecked Sendable {
    private let defaults: any PreferenceStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: any PreferenceStorage = MimoAppGroup.defaults) {
        self.defaults = defaults
    }

    public func load() -> MonitorIndicatorState {
        guard let data = defaults.data(forKey: MimoPreferenceKey.indicatorState),
              let state = try? decoder.decode(MonitorIndicatorState.self, from: data) else {
            return MonitorIndicatorState()
        }
        return state
    }

    public func save(_ state: MonitorIndicatorState) {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: MimoPreferenceKey.indicatorState)
    }

    public func clear() {
        defaults.removeObject(forKey: MimoPreferenceKey.indicatorState)
    }
}

public final class SnapshotStore: @unchecked Sendable {
    private let defaults: any PreferenceStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: any PreferenceStorage = MimoAppGroup.defaults) {
        self.defaults = defaults
    }

    public func load() -> MimoSnapshot? {
        guard let data = defaults.data(forKey: MimoPreferenceKey.snapshot) else { return nil }
        return try? decoder.decode(MimoSnapshot.self, from: data)
    }

    public func save(_ snapshot: MimoSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: MimoPreferenceKey.snapshot)
    }

    public func clear() {
        defaults.removeObject(forKey: MimoPreferenceKey.snapshot)
    }
}

/// Persists a provider-specific Retry-After deadline so an app restart cannot accidentally retry early.
public final class ProviderCooldownStore: @unchecked Sendable {
    private let defaults: any PreferenceStorage

    public init(defaults: any PreferenceStorage = MimoAppGroup.defaults) {
        self.defaults = defaults
    }

    public func retryNotBefore(for provider: ProviderID) -> Date? {
        defaults.object(forKey: key(for: provider)) as? Date
    }

    public func save(retryNotBefore date: Date, for provider: ProviderID) {
        defaults.set(date, forKey: key(for: provider))
    }

    public func clear(for provider: ProviderID) {
        defaults.removeObject(forKey: key(for: provider))
    }

    private func key(for provider: ProviderID) -> String {
        MimoPreferenceKey.providerCooldownPrefix + provider.rawValue
    }
}

/// Persists each provider's most recent lookup attempt so event bursts and app relaunches cannot call
/// the same provider more often than the hard minimum interval.
public final class RefreshAttemptStore: @unchecked Sendable {
    private let defaults: any PreferenceStorage

    public init(defaults: any PreferenceStorage = MimoAppGroup.defaults) {
        self.defaults = defaults
    }

    public func lastAttempt(for provider: ProviderID) -> Date? {
        defaults.object(forKey: key(for: provider)) as? Date
    }

    public func lastAttempts() -> [ProviderID: Date] {
        var attempts: [ProviderID: Date] = [:]
        for provider in ProviderID.allCases {
            attempts[provider] = lastAttempt(for: provider)
        }
        return attempts
    }

    public func recordAttempt(for provider: ProviderID, at date: Date = .now) {
        defaults.set(date, forKey: key(for: provider))
    }

    public func clear() {
        ProviderID.allCases.forEach { defaults.removeObject(forKey: key(for: $0)) }
        defaults.removeObject(forKey: MimoPreferenceKey.legacyLastRefreshAttempt)
    }

    private func key(for provider: ProviderID) -> String {
        MimoPreferenceKey.lastRefreshAttemptPrefix + provider.rawValue
    }
}

public struct ProviderHealthRecord: Codable, Equatable, Sendable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastFailure: Date?
    public var lastError: String?
    public var consecutiveFailures: Int

    public init(
        lastAttempt: Date? = nil,
        lastSuccess: Date? = nil,
        lastFailure: Date? = nil,
        lastError: String? = nil,
        consecutiveFailures: Int = 0
    ) {
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.lastError = lastError
        self.consecutiveFailures = consecutiveFailures
    }
}

public final class ProviderHealthStore: @unchecked Sendable {
    private let defaults: any PreferenceStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: any PreferenceStorage = MimoAppGroup.defaults) {
        self.defaults = defaults
    }

    public func load(for provider: ProviderID) -> ProviderHealthRecord {
        guard let data = defaults.data(forKey: key(for: provider)),
              let record = try? decoder.decode(ProviderHealthRecord.self, from: data) else {
            return ProviderHealthRecord()
        }
        return record
    }

    public func loadAll() -> [ProviderID: ProviderHealthRecord] {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, load(for: $0)) })
    }

    public func save(_ record: ProviderHealthRecord, for provider: ProviderID) {
        guard let data = try? encoder.encode(record) else { return }
        defaults.set(data, forKey: key(for: provider))
    }

    private func key(for provider: ProviderID) -> String {
        MimoPreferenceKey.providerHealthPrefix + provider.rawValue
    }
}

public struct DiagnosticPreferences: Codable, Equatable, Sendable {
    public var includeFullIPAddresses: Bool
    public var retentionDays: Int

    public init(includeFullIPAddresses: Bool = false, retentionDays: Int = 7) {
        self.includeFullIPAddresses = includeFullIPAddresses
        self.retentionDays = [1, 7, 30].contains(retentionDays) ? retentionDays : 7
    }
}

public final class DiagnosticPreferencesStore: @unchecked Sendable {
    private let defaults: any PreferenceStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: any PreferenceStorage = MimoAppGroup.defaults) {
        self.defaults = defaults
    }

    public func load() -> DiagnosticPreferences {
        guard let data = defaults.data(forKey: MimoPreferenceKey.diagnostics),
              let preferences = try? decoder.decode(DiagnosticPreferences.self, from: data) else {
            return DiagnosticPreferences()
        }
        return preferences
    }

    public func save(_ preferences: DiagnosticPreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: MimoPreferenceKey.diagnostics)
    }
}

public enum RefreshInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    // Swift enum raw values must be literals; these values are seconds.
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case sixtyMinutes = 3_600
    case never = -1

    public var id: Int { rawValue }
    public var periodicSeconds: TimeInterval? { self == .never ? nil : Double(rawValue) }
    public var snapshotStaleThreshold: TimeInterval { periodicSeconds.map { $0 * 2 } ?? .infinity }

    public var displayName: String {
        switch self {
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .thirtyMinutes: "Every 30 minutes"
        case .sixtyMinutes: "Every hour (default)"
        case .never: "Never"
        }
    }
}

public struct MonitoringPreferences: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var providerPool: [ProviderID]
    public var refreshInterval: RefreshInterval
    public var menuBarDisplayStyle: MenuBarDisplayStyle
    public var highlightCountryChanges: Bool

    public init(
        provider: ProviderID = .ipapiCo,
        providerPool: [ProviderID] = [.ipapiCo, .ipWhois, .ipapiIs],
        refreshInterval: RefreshInterval = .sixtyMinutes,
        menuBarDisplayStyle: MenuBarDisplayStyle = .flag,
        highlightCountryChanges: Bool = true
    ) {
        self.provider = provider
        var uniquePool: [ProviderID] = []
        for item in providerPool where !uniquePool.contains(item) {
            uniquePool.append(item)
        }
        if !uniquePool.contains(provider) {
            uniquePool.insert(provider, at: 0)
        }
        self.providerPool = uniquePool
        self.refreshInterval = refreshInterval
        self.menuBarDisplayStyle = menuBarDisplayStyle
        self.highlightCountryChanges = highlightCountryChanges
    }

    public static func load(from defaults: any PreferenceStorage = MimoAppGroup.defaults) -> MonitoringPreferences {
        let provider = ProviderID(rawValue: defaults.string(forKey: MimoPreferenceKey.provider) ?? "") ?? .ipapiCo
        let storedPool = (defaults.string(forKey: MimoPreferenceKey.providerPool) ?? "")
            .split(separator: ",")
            .compactMap { ProviderID(rawValue: String($0)) }
        let providerPool = storedPool.isEmpty ? [ProviderID.ipapiCo, .ipWhois, .ipapiIs] : storedPool
        let refreshInterval = RefreshInterval(rawValue: defaults.integer(forKey: MimoPreferenceKey.refreshInterval)) ?? .sixtyMinutes
        let menuBarDisplayStyle = MenuBarDisplayStyle(rawValue: defaults.string(forKey: MimoPreferenceKey.menuBarDisplayStyle) ?? "") ?? .flag
        let highlightCountryChanges = defaults.object(forKey: MimoPreferenceKey.highlightCountryChanges) as? Bool ?? true
        return MonitoringPreferences(
            provider: provider,
            providerPool: providerPool,
            refreshInterval: refreshInterval,
            menuBarDisplayStyle: menuBarDisplayStyle,
            highlightCountryChanges: highlightCountryChanges
        )
    }

    public func save(to defaults: any PreferenceStorage = MimoAppGroup.defaults) {
        defaults.set(provider.rawValue, forKey: MimoPreferenceKey.provider)
        defaults.set(providerPool.map(\.rawValue).joined(separator: ","), forKey: MimoPreferenceKey.providerPool)
        defaults.set(refreshInterval.rawValue, forKey: MimoPreferenceKey.refreshInterval)
        defaults.set(menuBarDisplayStyle.rawValue, forKey: MimoPreferenceKey.menuBarDisplayStyle)
        defaults.set(highlightCountryChanges, forKey: MimoPreferenceKey.highlightCountryChanges)
    }
}

public enum MimoSurfaceID {
    public static let widget = "com.mimo.widget"
    public static let control = "com.mimo.control"
}
