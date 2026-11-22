import Foundation

@MainActor
enum MonitoringV21Tests {
    static func run() async throws {
        let defaults = MimoAppGroup.defaults
        defaults.removePersistentDomain(forName: MimoAppGroup.identifier)
        MonitoringPreferences(provider: .ipWhois, providerPool: [.ipWhois], refreshInterval: .never).save()
        let clock = MonitorTestClock()
        let client = MonitorV21Client(clock: clock)
        let monitor = MonitoringEngine(observeSystem: false, client: client, now: { clock.now })
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<100 where monitor.status != .ready { try await Task.sleep(for: .milliseconds(10)) }
        require(monitor.status == .ready && !monitor.periodicRefreshScheduled, "Never must allow startup lookup without scheduling a periodic timer")
        let original = monitor.snapshot!.checkedAt
        clock.advance(1)
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        require(monitor.manualRefresh?.phase == .succeeded && monitor.snapshot!.checkedAt > original,
                "same-IP manual refresh must advance checked time and publish success")
        var preferences = monitor.preferences; preferences.refreshInterval = .sixtyMinutes
        monitor.apply(preferences, requestRefresh: false)
        require(monitor.periodicRefreshScheduled, "selecting an interval enables the timer")
        preferences.refreshInterval = .never; monitor.apply(preferences, requestRefresh: false)
        require(!monitor.periodicRefreshScheduled, "selecting Never cancels the existing timer")
        clock.advance(1)
        let lastSuccess = monitor.snapshot!.checkedAt
        await client.failNext()
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        require(monitor.manualRefresh?.phase == .failed && monitor.manualRefresh?.startedAt != nil,
                "an attempted failed lookup must not be called a skipped lookup")
        require(monitor.snapshot!.checkedAt == lastSuccess, "failure must not advance checked time")
        let calls = await client.count
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        require(await client.count == calls && monitor.manualRefresh?.phase == .deferred,
                "manual refresh respects cooldown and reports that it did not run")
        require(monitor.manualRefresh?.startedAt == nil && monitor.manualRefresh?.message.contains("No lookup ran") == true,
                "cooldown feedback must distinguish a request from an actual lookup")
        clock.advance(601)
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        require(monitor.manualRefresh?.phase == .succeeded && monitor.snapshot!.checkedAt > lastSuccess,
                "fresh lookup is available when the ten-minute local cooldown expires")
        monitor.holdForControl()
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        require(monitor.manualRefresh?.phase == .queued, "manual request waits visibly behind shared controls")
        monitor.releaseControl()
        for _ in 0..<100 where monitor.manualRefresh?.pending == true { try await Task.sleep(for: .milliseconds(10)) }
        require(monitor.manualRefresh?.phase == .succeeded, "queued request receives the eventual result")
        preferences.providerPool = [.ipWhois, .ipapiCo]
        preferences.provider = .ipWhois
        monitor.apply(preferences, requestRefresh: false)
        await client.failNext()
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        for _ in 0..<100 where monitor.manualRefresh?.pending == true { try await Task.sleep(for: .milliseconds(10)) }
        require(monitor.manualRefresh?.phase == .succeeded && monitor.snapshot?.provider == .ipapiCo,
                "manual outcome must wait for the next provider after a failed attempt")
        monitor.holdForControl()
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        monitor.stop()
        require(monitor.manualRefresh?.phase == .failed && monitor.manualRefresh?.pending == false,
                "stopping must cancel a queued manual request instead of leaving it pending")
        print("PASS: Never timer lifecycle, manual same-IP timestamp, failure, cooldown deferral, retry and queued outcomes")
    }
    private static func require(_ condition: Bool, _ message: String) { CredentialAppTests.require(condition, message) }
}

private final class MonitorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor MonitorV21Client: PublicIPLookupClientProtocol {
    let clock: MonitorTestClock
    var count = 0
    private var shouldFail = false
    init(clock: MonitorTestClock) { self.clock = clock }
    func failNext() { shouldFail = true }
    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        count += 1
        if shouldFail { shouldFail = false; throw LookupError.transport("fixture unavailable") }
        return MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: configuration.provider, checkedAt: clock.now)
    }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
        try await lookup(configuration: .init(provider: primaryProvider, ipinfoToken: nil))
    }
}
