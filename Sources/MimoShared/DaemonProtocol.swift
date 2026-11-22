import Foundation

/// Monitoring's warning state. MimoAccessPolicy independently enforces Rule/Global blocking.
public enum MimoAuthorizationState: Codable, Equatable, Sendable {
    /// The allowlist is empty (no warnings) or no address has been verified this session.
    case unavailable
    case allowed
    case notAllowed(String)

    public var isNotAllowed: Bool {
        if case .notAllowed = self { return true }
        return false
    }
}


public enum MonitoringStatus: Codable, Equatable, Sendable {
    case idle
    case refreshing
    case ready
    case awaitingConfirmation(String)
    /// Every enabled provider is paused or out of daily budget; lookups resume at the date.
    case coolingDown(Date)
    /// One provider refused requests and is paused until the date; rotation uses the others meanwhile.
    case providerPaused(ProviderID, Date)
    case waitingForMinimumInterval(Date)
    case waitingForIPinfoToken
    case failed(String)
}


public enum MimoService {
    public static let label = "com.mimo.core"
    public static let controlLabel = "com.mimo.core.control"
    public static let supervisorControlLabel = "com.mimo.supervisor.control"
    public static let installedAppIdentity = URL(fileURLWithPath: "/Library/Application Support/Mimo/app.cdhash")
    // Shared proxy catalogs and refresh outcomes require a matching 2.1 client.
    public static let protocolVersion = 7
    public static let executable = "/Library/PrivilegedHelperTools/mimo-core"
    public static let plist = "/Library/LaunchDaemons/\(label).plist"
    public static let support = URL(fileURLWithPath: "/Library/Application Support/Mimo", isDirectory: true)
    public static let storageURL = support.appendingPathComponent("Service/state.plist")
    public static let logDirectory = URL(fileURLWithPath: "/Library/Logs/Mimo", isDirectory: true)
    public static let settingsRight = "com.mimo.configure"
    public static let maximumMessageSize = 1_048_576
}

public struct MachineSettings: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var providerPool: [ProviderID]
    public var refreshInterval: RefreshInterval
    public var allowlist: AllowedIPList
    public var diagnostics: DiagnosticPreferences
    public var tailscaleProviderEnabled: Bool
    public var bypassBlocks: [MimoBypassBlock]?
    public var effectiveBypassBlocks: [MimoBypassBlock] { bypassBlocks ?? MimoBypassBlock.defaults }

    public init(preferences: MonitoringPreferences = MonitoringPreferences(), allowlist: AllowedIPList = AllowedIPList(),
                diagnostics: DiagnosticPreferences = DiagnosticPreferences(), tailscaleProviderEnabled: Bool = false) {
        provider = preferences.provider
        providerPool = preferences.providerPool
        refreshInterval = preferences.refreshInterval
        self.allowlist = allowlist
        self.diagnostics = diagnostics
        self.tailscaleProviderEnabled = tailscaleProviderEnabled
    }

    public var monitoring: MonitoringPreferences {
        MonitoringPreferences(provider: provider, providerPool: providerPool, refreshInterval: refreshInterval)
    }

    public func affectsVerification(comparedTo previous: MachineSettings, mode: ProxyMode = .rule) -> Bool {
        monitoring != previous.monitoring || allowlist != previous.allowlist ||
            (mode == .rule && effectiveBypassBlocks != previous.effectiveBypassBlocks)
    }

    public func validated() throws -> MachineSettings {
        guard !providerPool.isEmpty, providerPool.count <= ProviderID.allCases.count,
              Set(providerPool).count == providerPool.count, providerPool.contains(provider),
              [1, 7, 30].contains(diagnostics.retentionDays), allowlist.addresses.count <= 1024,
              allowlist.addresses.allSatisfy({ IPAddressValidator.normalize($0) == $0 }) else {
            throw DaemonFailure.invalidRequest
        }
        var result = self
        if let bypassBlocks { result.bypassBlocks = try MimoBypassBlock.validated(bypassBlocks) }
        return result
    }
}

public struct UserPresentationPreferences: Codable, Equatable, Sendable {
    public var imported = false
    public var displayStyle: MenuBarDisplayStyle = .flag
    public var highlightCountryChanges = true
    public var dismissedCountryChange: Date?
    public var dismissedError: UUID?
    public var seenAllowlistEvent: UUID?
    public init() {}
}

public struct MigrationState: Codable, Sendable {
    public var settings: MachineSettings
    public var budget: LookupBudget
    public var attempts: [ProviderID: Date]
    public var cooldowns: [ProviderID: Date]
    public var snapshot: MimoSnapshot?
    public init(settings: MachineSettings, budget: LookupBudget, attempts: [ProviderID: Date], cooldowns: [ProviderID: Date], snapshot: MimoSnapshot? = nil) {
        self.settings = settings
        self.budget = budget
        self.attempts = attempts
        self.cooldowns = cooldowns
        self.snapshot = snapshot
    }
}

public struct DaemonState: Codable, Sendable {
    public var protocolVersion = MimoService.protocolVersion
    public var instanceID: UUID
    public var build: String
    public var initialized: Bool
    public var revision: Int
    public var settings: MachineSettings
    public var presentation: UserPresentationPreferences
    public var snapshot: MimoSnapshot?
    public var status: MonitoringStatus
    public var indicators: MonitorIndicatorState
    public var authorizationState: MimoAuthorizationState
    public var providerHealth: [ProviderID: ProviderHealthRecord]
    public var budget: LookupBudget
    public var nextProvider: ProviderID
    public var cooldowns: [ProviderID: Date]
    public var hasIPinfoToken: Bool
    public var credentialError: String?
    public var allowlistEventID: UUID?
    public var errorEventID: UUID?
    public var providerStatus: TailscaleVergeStatus?
    public var providerError: String?
    public var storageError: String?
    public var routing: MimoRoutingState? = nil
    public var manualRefresh: MimoManualRefresh? = nil

    public var preferences: MonitoringPreferences {
        var preferences = settings.monitoring
        preferences.menuBarDisplayStyle = presentation.displayStyle
        preferences.highlightCountryChanges = presentation.highlightCountryChanges
        return preferences
    }

    public var presentedSnapshot: MimoSnapshot? {
        guard var result = snapshot else { return nil }
        if !presentation.highlightCountryChanges || result.countryChange?.changedAt == presentation.dismissedCountryChange {
            result.countryChange = nil
        }
        return result
    }

    public var presentedIndicators: MonitorIndicatorState {
        var result = indicators
        if let errorEventID, presentation.dismissedError == errorEventID { result.errorMessage = nil }
        return result
    }
}

public enum DaemonCommand: String, Codable, Sendable {
    case state, subscribe, refresh, testProvider, configure, initialize, presentation, setToken, removeToken, events
    case configureRouting, saveProxy, removeProxy, selectProxy, supervisor, networkChanged
    case startTailnetProvider
}

public struct DaemonRequest: Codable, Sendable {
    public var reportsProgress: Bool?
    public var protocolVersion = MimoService.protocolVersion
    public var command: DaemonCommand
    public var expectedRevision: Int?
    public var settings: MachineSettings?
    public var presentation: UserPresentationPreferences?
    public var migration: MigrationState?
    public var provider: ProviderID?
    public var token: String?
    public var authorization: Data?
    public var routing: MimoConfiguration?
    public var proxy: MimoProxy?
    /// nil creates a proxy for saveProxy, or selects None for selectProxy.
    public var proxyID: UUID?
    /// Write-only. nil preserves the existing secret; an empty value explicitly clears it.
    public var proxyPassword: String?
    public var supervisor: MimoSupervisorRequest?
    public init(_ command: DaemonCommand) { self.command = command }
}

public enum DaemonFailure: String, Error, Codable, LocalizedError, Sendable {
    case unavailable, incompatible, unauthorized, conflict, invalidRequest, storage, credential, alreadyInitialized
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The background service is unavailable. Install or repair it in the dashboard."
        case .incompatible: "The app and background service need matching versions. Update or repair the installation."
        case .unauthorized: "Administrator authentication is required to change shared settings."
        case .conflict: "Another user changed the shared settings. Review the latest values and try again."
        case .invalidRequest: "The requested settings are invalid."
        case .storage: "The background service could not save its state. Check the service log."
        case .credential: "The saved credential could not be loaded or updated. Check the credential status and try again."
        case .alreadyInitialized: "Shared settings have already been initialized and were not overwritten."
        }
    }
}

public struct DaemonResponse: Codable, Sendable {
    public var state: DaemonState?
    public var failure: DaemonFailure?
    public var events: [String]?
    /// Recent already-redacted JSON records; present only in explicit log requests.
    public var diagnosticEvents: [String]? = nil
    public var routing: MimoRoutingState? = nil
    /// Returned only for an explicitly authorized profile-view request, never in state broadcasts.
    public var profileContents: String? = nil
    public init(state: DaemonState? = nil, failure: DaemonFailure? = nil, events: [String]? = nil) {
        self.state = state
        self.failure = failure
        self.events = events
    }
}
