import XCTest
@testable import MimoShared

final class MimoV21Tests: XCTestCase {
    private func store() throws -> (FilePreferenceStorage, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try FilePreferenceStorage(url: directory.appendingPathComponent("state.plist")), directory)
    }

    func testCredentialMigrationIsDurablePrivateAndDoesNotReimportDeletedToken() throws {
        let (storage, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        var legacy = MimoConfiguration()
        legacy.mode = .rule
        legacy.proxy = MimoProxy(ClashProxySettings(name: "Original", type: .socks5, server: "192.0.2.20", port: 1080, username: "example"))
        try storage.update(["service.routing": JSONEncoder().encode(legacy), "service.revision": 4])
        let credentials = MigrationCredentials()
        credentials.failDeletion = true
        XCTAssertFalse(try MimoLocalSettings.migrate(storage, legacy: credentials))
        let state = try JSONDecoder().decode(MimoConfiguration.self, from: XCTUnwrap(storage.data(forKey: "service.routing")))
        XCTAssertEqual(state.mode, .rule)
        XCTAssertEqual(state.proxies?.count, 1)
        let id = try XCTUnwrap(state.activeProxyID)
        XCTAssertEqual(try MimoLocalSettings.passwords(in: storage)[id], "synthetic-proxy")
        XCTAssertEqual(storage.string(forKey: MimoLocalSettings.tokenKey), "synthetic-ipinfo")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("synthetic-"))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("state.plist").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try storage.update([MimoLocalSettings.tokenKey: nil])
        credentials.failDeletion = false
        XCTAssertTrue(try MimoLocalSettings.migrate(storage, legacy: credentials))
        XCTAssertNil(storage.string(forKey: MimoLocalSettings.tokenKey))
        XCTAssertEqual(credentials.reads, 2)
        XCTAssertEqual(credentials.writes, 0)
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertEqual(storage.integer(forKey: "service.revision"), 5)
    }

    func testFailedCredentialMigrationPreservesOriginalsAndFreshInstallAvoidsKeychain() throws {
        let (storage, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = MigrationCredentials()
        XCTAssertTrue(try MimoLocalSettings.migrate(storage, legacy: credentials))
        XCTAssertEqual(credentials.reads, 0)
        XCTAssertEqual(credentials.values.count, 2)
        let other = try FilePreferenceStorage(url: directory.appendingPathComponent("failure/state.plist"))
        try other.update(["service.routing": JSONEncoder().encode(MimoConfiguration())])
        credentials.failRead = true
        XCTAssertThrowsError(try MimoLocalSettings.migrate(other, legacy: credentials))
        XCTAssertEqual(credentials.values.count, 2)
        XCTAssertNil(other.data(forKey: MimoLocalSettings.passwordsKey))
    }

    func testCatalogSelectionIsIDBasedAndRejectsMissingOrDuplicateEntries() throws {
        let a = MimoSavedProxy(proxy: MimoProxy(ClashProxySettings(name: "One", type: .http, server: "192.0.2.10", port: 8080)))
        let b = MimoSavedProxy(proxy: MimoProxy(ClashProxySettings(name: "Two", type: .socks5, server: "192.0.2.11", port: 1080)))
        var configuration = MimoConfiguration()
        configuration.proxies = [a, b]; configuration.activeProxyID = b.id
        XCTAssertEqual(try configuration.validated().proxy, b.proxy)
        configuration.activeProxyID = nil
        XCTAssertNil(try configuration.validated().proxy)
        configuration.activeProxyID = UUID()
        XCTAssertThrowsError(try configuration.validated())
        configuration.activeProxyID = nil; configuration.proxies = [a, a]
        XCTAssertThrowsError(try configuration.validated())
        var duplicateName = b; duplicateName.proxy.name = "one"
        configuration.proxies = [a, duplicateName]
        XCTAssertThrowsError(try configuration.validated())
    }

    func testMonitoringUpgradeRunsOnceAndPreservesServerDeadlines() throws {
        let (storage, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = MachineSettings(); settings.refreshInterval = .fifteenMinutes
        try storage.update(["service.settings": JSONEncoder().encode(settings), "service.revision": 2])
        let health = ProviderHealthStore(defaults: storage), cooldowns = ProviderCooldownStore(defaults: storage)
        health.save(.init(lastFailure: now, lastError: "transport"), for: .ipWhois)
        health.save(.init(lastFailure: now, lastError: "rate_limited"), for: .ipapiCo)
        for provider in [ProviderID.ipWhois, .ipapiCo] { cooldowns.save(retryNotBefore: now.addingTimeInterval(8 * 3600), for: provider) }
        try MimoLocalSettings.migrateMonitoring(storage)
        XCTAssertEqual(MonitoringPreferences.load(from: storage).refreshInterval, .sixtyMinutes)
        XCTAssertEqual(cooldowns.retryNotBefore(for: .ipWhois), now.addingTimeInterval(600))
        XCTAssertEqual(cooldowns.retryNotBefore(for: .ipapiCo), now.addingTimeInterval(8 * 3600))
        MonitoringPreferences(refreshInterval: .fifteenMinutes).save(to: storage)
        try MimoLocalSettings.migrateMonitoring(storage)
        XCTAssertEqual(MonitoringPreferences.load(from: storage).refreshInterval, .fifteenMinutes)
        XCTAssertNil(RefreshInterval.never.periodicSeconds)
        XCTAssertTrue(RefreshInterval.never.snapshotStaleThreshold.isInfinite)
        MonitoringPreferences(refreshInterval: .never).save(to: storage)
        XCTAssertEqual(MonitoringPreferences.load(from: storage).refreshInterval, .never)
    }

    func testManualRefreshHonorsCooldownEvenWhenSpacingIsBypassed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), resume = Date(timeIntervalSince1970: 1_800_000_600)
        var budget = LookupBudget()
        XCTAssertEqual(RefreshGate.decide(urgency: .manual, pool: [.ipWhois], preferred: .ipWhois,
            lastAttempts: [:], cooldowns: [.ipWhois: resume], budget: &budget, lastSuccess: nil,
            bypassLimits: true, now: now), .allProvidersPaused(until: resume))
        XCTAssertEqual(budget.callsToday(for: .ipWhois, now: now), 0)
    }

    func testEventLogDistinguishesRefreshAndHistoricalPauseDurations() {
        XCTAssertTrue(EventLogLine.message(event: "manual_refresh_finished", fields: ["outcome": "deferred"])!.contains("no lookup ran"))
        XCTAssertTrue(EventLogLine.message(event: "manual_refresh_finished", fields: ["outcome": "succeeded"])!.contains("exit IP updated"))
        XCTAssertTrue(EventLogLine.message(event: "provider_failure_paused", fields: ["seconds": "600"])!.contains("10 minutes"))
        XCTAssertTrue(EventLogLine.message(event: "provider_failure_paused", fields: ["hours": "8"])!.contains("8 hours"))
        XCTAssertTrue(EventLogLine.message(event: "mimo_proxy_catalog_changed", fields: ["operation": "saveProxy", "reload": "false"])!.contains("routing unchanged"))
    }
}

private final class MigrationCredentials: CredentialBackend, @unchecked Sendable {
    var values = [MimoLocalSettings.ipinfoAccount: "synthetic-ipinfo", MimoRuntime.proxyPasswordAccount: "synthetic-proxy"]
    var failDeletion = false
    var failRead = false
    var reads = 0
    var writes = 0
    func read(account: String) throws -> String? { reads += 1; if failRead { throw DaemonFailure.credential }; return values[account] }
    func save(_ value: String, account: String) throws { writes += 1; values[account] = value }
    func delete(account: String) throws { if failDeletion { throw DaemonFailure.credential }; values[account] = nil }
}
