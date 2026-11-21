import AppIntents

/// App-target only. The widget extension compiles `MimoIntents.swift` without this file, so the
/// Control Center button keeps the default `OpenIntent` behavior there (bring the app forward), and
/// the app process, where the intent actually runs, opens the dashboard.
extension OpenMimoDashboardIntent {
    @MainActor
    func perform() async throws -> some IntentResult {
        MimoAppDelegate.showDashboard()
        return .result()
    }
}
