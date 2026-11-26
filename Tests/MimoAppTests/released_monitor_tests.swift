import AppKit
import SwiftUI

@MainActor
enum ReleasedMonitorTests {
    private final class CountingStore: PreferenceStorage {
        var values: [String: Any] = [:]
        var writes = 0
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { writes += 1; values[key] = value }
        func removeObject(forKey key: String) { writes += 1; values.removeValue(forKey: key) }
    }
    private actor Client: PublicIPLookupClientProtocol {
        var count = 0
        func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
            count += 1
            var value = CredentialAppTests.snapshot(configuration.provider)
            value.ipAddress = "203.0.113.\(count)"; value.checkedAt = .now
            return value
        }
        func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
            CredentialAppTests.snapshot(primaryProvider)
        }
    }

    static func run(output: URL) async throws {
        let require = CredentialAppTests.require
        let counting = CountingStore()
        let rememberedStatus = MimoReleasedMonitor(defaults: counting, client: Client(), observeSystem: false)
        var poll = ClientConnectionTests.state()
        rememberedStatus.remember(poll)
        let initialWrites = counting.writes
        for _ in 0..<10 {
            poll.routing?.supervisorCheckedAt = .now
            rememberedStatus.remember(poll)
        }
        require(counting.writes == initialWrites,
            "Health-only status updates must not rewrite local monitoring preferences (extra writes: \(counting.writes - initialWrites))")
        poll.settings.refreshInterval = .never
        rememberedStatus.remember(poll)
        require(counting.writes > initialWrites, "A changed monitoring preference must still be saved")
        let suite = "group.com.mimo.tests.released.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = Client()
        let remembered = MimoReleasedMonitor(defaults: defaults, client: Client(), observeSystem: false)
        var explicitInterval = ClientConnectionTests.state()
        explicitInterval.settings.refreshInterval = .fifteenMinutes
        remembered.remember(explicitInterval)
        remembered.start()
        require(remembered.engine?.preferences.refreshInterval == .fifteenMinutes,
            "The first Stop after upgrade must preserve an explicitly selected 15-minute interval")
        remembered.stop()
        defaults.removePersistentDomain(forName: suite)
        let released = MimoReleasedMonitor(defaults: defaults, client: client, observeSystem: false)
        var inactive = true
        var subscriptions = 0
        var requests = 0
        let monitor = PublicIPMonitor(subscribe: { _ in subscriptions += 1; return {} },
            readStatus: { _, _, _ in requests += 1; throw DaemonFailure.unavailable },
            readDeactivation: { inactive }, releasedMonitor: released)
        defer { monitor.stop() }
        monitor.start()
        for _ in 0..<100 where monitor.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        require(monitor.snapshot?.ipAddress == "203.0.113.1", "Cold launch after Stop must obtain a new exit IP locally")
        require(monitor.routingState.observedIP?.address == monitor.snapshot?.ipAddress, "Released Dashboard must display the locally observed IP")
        require(monitor.canRefresh && !monitor.connected, "Manual refresh must work without a daemon connection")
        require(subscriptions == 0 && requests == 0, "Released monitoring cannot reconnect to or activate removed jobs")
        require(monitor.serviceHealthLabel(.core, at: .now) == "Removed", "Local lookup must not imply a core service is running")
        await monitor.refresh()
        for _ in 0..<100 where monitor.snapshot?.ipAddress == "203.0.113.1" { try await Task.sleep(for: .milliseconds(10)) }
        require(monitor.snapshot?.ipAddress == "203.0.113.2", "Refresh must replace the released IP, not retain a cached daemon value")
        try await Task.sleep(for: .milliseconds(50))
        for dark in [false, true] {
            try CredentialAppTests.render(DashboardView(monitor: monitor), size: NSSize(width: 1040, height: 660), dark: dark,
                to: output.appendingPathComponent("dashboard-monitor-only-\(dark ? "dark" : "light").png"), padding: 0)
        }
        let firstEngine = released.engine
        monitor.sessionDidResignActive()
        require(released.engine == nil, "Inactive account must stop local monitoring")
        monitor.sessionDidBecomeActive()
        require(released.engine != nil && released.engine !== firstEngine, "Returning account creates a new observer lifecycle")
        inactive = false
        monitor.refreshInstallationState()
        require(released.engine == nil, "Activation stops GUI-only monitoring before reconnecting")
        try await Task.sleep(for: .milliseconds(30))
        require(subscriptions > 0, "Activated GUI reconnects to shared status")
        var shared = ClientConnectionTests.state()
        shared.settings.refreshInterval = .thirtyMinutes
        let pausedUntil = Date.now.addingTimeInterval(3600)
        shared.cooldowns[.ipapiIs] = pausedUntil
        monitor.receive(shared)
        inactive = true
        monitor.refreshInstallationState()
        require(released.engine != nil, "Successful cleanup transitions to local monitoring")
        require(released.engine?.preferences.refreshInterval == .thirtyMinutes, "Stop retains the selected periodic interval")
        require(released.engine?.pausedUntil(.ipapiIs) == pausedUntil, "Stop preserves provider pauses")
        monitor.receive(ClientConnectionTests.state())
        require(monitor.installationInactive && !monitor.connected, "Late daemon replies cannot reclaim a released GUI")
        let privateOnly = MonitoringPreferences(provider: .ipinfoLite, providerPool: [.ipinfoLite])
        let anonymous = MimoReleasedMonitor.anonymousPreferences(privateOnly)
        require(!anonymous.providerPool.contains(.ipinfoLite) && !anonymous.providerPool.isEmpty,
            "Released monitoring requires no retained System Keychain capability")
        monitor.stop()
        require(released.engine == nil, "Quitting GUI stops remaining monitoring")
        print("PASS: released GUI obtains fresh IPs, never uses XPC, handles account/activation lifecycles and keeps services Removed")
    }
}
