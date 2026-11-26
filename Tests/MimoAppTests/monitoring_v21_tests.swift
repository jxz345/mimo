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
        monitor.accessBlockReason = { "The observed IPv4 exit IP is not approved." }
        clock.advance(1)
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        require(monitor.status == .ready && monitor.manualRefresh?.phase == .failed &&
                monitor.manualRefresh?.message.contains("Exit IP checked. Outbound access remains blocked.") == true,
                "a successful lookup with a rejected exit must report the access rejection, not a provider failure or access success")
        monitor.accessBlockReason = nil
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
        await monitor.refresh(force: true, bypassMinimumInterval: true, trigger: .retry)
        require(await client.count == calls && monitor.isCoolingDown,
                "automatic retries must keep the ten-minute local backoff")
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        require(await client.count == calls + 1 && monitor.manualRefresh?.phase == .succeeded && monitor.snapshot!.checkedAt > lastSuccess,
                "explicit Retry must check a repaired local connection without a clock/token/reset workaround")
        await client.failNext(.rateLimited(retryAfter: clock.now.addingTimeInterval(900)))
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        let limitedCalls = await client.count
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        require(await client.count == limitedCalls && monitor.manualRefresh?.phase == .deferred,
                "explicit Retry must preserve real provider Retry-After")
        require(monitor.manualRefresh?.startedAt == nil && monitor.manualRefresh?.message.contains("No lookup ran") == true,
                "provider restriction feedback must distinguish refusal from an actual lookup")
        clock.advance(901)
        await monitor.refresh(force: true, bypassMinimumInterval: true)
        require(monitor.manualRefresh?.phase == .succeeded, "provider restriction expires normally")
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
    private var nextFailure: LookupError?
    init(clock: MonitorTestClock) { self.clock = clock }
    func failNext(_ error: LookupError = .transport("fixture unavailable")) { nextFailure = error }
    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        count += 1
        if let error = nextFailure { nextFailure = nil; throw error }
        return MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: configuration.provider, checkedAt: clock.now)
    }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
        try await lookup(configuration: .init(provider: primaryProvider, ipinfoToken: nil))
    }
}
