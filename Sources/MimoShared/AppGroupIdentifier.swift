import Foundation

public enum MimoAppGroup {
    /// Replace this value with the App Group registered for both Xcode targets.
    #if MIMO_TEST_HOST
    public static let identifier = ProcessInfo.processInfo.environment["MIMO_TEST_APP_GROUP"]!
    #else
    public static let identifier = "group.com.mimo"
    #endif

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

public enum MimoPreferenceKey {
    public static let snapshot = "mimo.snapshot.v1"
    public static let provider = "mimo.provider.v1"
    public static let providerPool = "mimo.provider-pool.v1"
    public static let allowedIPs = "mimo.allowed-ips.v1"
    public static let refreshInterval = "mimo.refresh-interval.v1"
    public static let menuBarDisplayStyle = "mimo.menu-bar-display-style.v1"
    public static let highlightCountryChanges = "mimo.highlight-country-changes.v1"
    public static let providerCooldownPrefix = "mimo.provider-cooldown.v1."
    /// Superseded by the per-provider `lastRefreshAttemptPrefix`; only removed on `RefreshAttemptStore.clear()`.
    public static let legacyLastRefreshAttempt = "mimo.last-refresh-attempt.v1"
    public static let lastRefreshAttemptPrefix = "mimo.last-refresh-attempt.v2."
    public static let indicatorState = "mimo.indicator-state.v1"
    public static let lookupBudget = "mimo.lookup-budget.v1"
    public static let providerHealthPrefix = "mimo.provider-health.v1."
    public static let diagnostics = "mimo.diagnostics.v1"
    /// Set once the dashboard has been shown on the app's first launch.
    public static let firstLaunchDashboardShown = "mimo.first-launch-dashboard-shown.v1"
    /// The user's Launch at login choice (absent: never chosen). Re-applied at every launch.
    public static let launchAtLogin = "mimo.launch-at-login.v1"
}
