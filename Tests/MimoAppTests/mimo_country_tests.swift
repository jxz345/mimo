import AppKit
import SwiftUI

@MainActor
enum MimoCountryTests {
    static func run() async throws {
        try await countryAndDirectEvents()
        try await providerFailure()
    }

    static func renderProviderPause(output: URL) throws {
        var presentation = UserPresentationPreferences(); presentation.imported = true
        let now = Date()
        let state = DaemonState(instanceID: UUID(), build: "Provider pause fixture", initialized: true, revision: 1,
            settings: MachineSettings(), presentation: presentation, status: .ready,
            indicators: MonitorIndicatorState(), authorizationState: .allowed,
            providerHealth: [.ipWhois: .init(lastFailure: now, lastError: "transport", consecutiveFailures: 1)],
            budget: LookupBudget(), nextProvider: .ipapiCo,
            cooldowns: [.ipWhois: now.addingTimeInterval(8 * 3600)], hasIPinfoToken: false)
        let monitor = PublicIPMonitor(readDeactivation: { false }); monitor.receive(state)
        MimoSettingsNavigation.shared.section = .monitoring
        try CredentialAppTests.render(SettingsView(monitor: monitor), size: NSSize(width: 1040, height: 740), dark: true,
            to: output.appendingPathComponent("monitoring-provider-pause.png"))
        print("PASS: Monitoring provider pause rendered with failure reason, retry time and eight-hour policy")
    }

    private static func countryAndDirectEvents() async throws {
        let defaults = MimoAppGroup.defaults
        defaults.removePersistentDomain(forName: MimoAppGroup.identifier)
        MonitoringPreferences(provider: .ipWhois, providerPool: [.ipWhois]).save()
        let client = GeographyClient()
        let monitor = MonitoringEngine(observeSystem: false, client: client)
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<100 {
            if monitor.status == .ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        require(monitor.status == .ready, "the initial known-country lookup must succeed")
        for country in ["--", "JP", "SG"] {
            await monitor.refresh(force: true, bypassMinimumInterval: true, trigger: .manual)
            require(monitor.status == .ready && monitor.snapshot?.countryCode == country,
                    "a changed/missing country must publish metadata without awaiting confirmation")
            require(monitor.snapshot?.countryChange == nil, "same-IP country changes must not create a country event")
        }
        try await Task.sleep(for: .seconds(12))
        require(await client.lookups == 4, "country-only changes must not schedule a retry inside the reported 5–10 second cycle")
        require(await client.confirmations == 0, "geography must never start a secondary check")
        require(monitor.status == .ready, "successful IP checks must stay ready")
        print("PASS: constant IP with unknown/changing countries; zero confirmations or automatic retries over 12 seconds")
        monitor.networkEventChecksEnabled = false
        for _ in 0..<10 { monitor.supervisorNetworkChanged() }
        try await Task.sleep(for: .milliseconds(100))
        require(await client.lookups == 4, "Direct must ignore ordinary system/network events")
        monitor.holdForControl()
        await monitor.refresh(force: true, bypassMinimumInterval: true, trigger: .manual)
        require(await client.lookups == 4, "a held control must not start a competing check")
        monitor.releaseControl()
        for _ in 0..<100 {
            if await client.lookups == 5 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        require(await client.lookups == 5, "the queued human check must run when released")
        print("PASS: Direct ignores system events, human refresh remains available and queued checks resume")
    }

    private static func providerFailure() async throws {
        let defaults = MimoAppGroup.defaults
        defaults.removePersistentDomain(forName: MimoAppGroup.identifier)
        MonitoringPreferences(provider: .ipWhois, providerPool: [.ipWhois, .ipapiCo]).save()
        let client = FailureClient()
        let monitor = MonitoringEngine(observeSystem: false, client: client)
        let began = Date()
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<150 {
            if monitor.status == .ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        require(monitor.status == .ready, "the next provider must recover the lookup")
        require(await client.providers == [.ipWhois, .ipapiCo], "a failure must rotate immediately without retrying the failed provider")
        let persistedPause = ProviderCooldownStore(defaults: defaults).retryNotBefore(for: .ipWhois)
        require((persistedPause?.timeIntervalSince(began) ?? 0) >= 8 * 3600, "the eight-hour exclusion must persist")
        require(ProviderHealthStore(defaults: defaults).load(for: .ipWhois).lastError == "transport", "Settings must retain the failure reason")
        await monitor.refresh(force: true, bypassMinimumInterval: true, trigger: .manual)
        require(await client.providers == [.ipWhois, .ipapiCo, .ipapiCo], "manual refresh must also skip the failed provider")
        print("PASS: failed provider rotates immediately, persists its eight-hour pause/reason and is skipped on manual refresh")
    }

    private static func require(_ condition: Bool, _ message: String) {
        CredentialAppTests.require(condition, message)
    }
}

private actor FailureClient: PublicIPLookupClientProtocol {
    private(set) var providers: [ProviderID] = []
    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        providers.append(configuration.provider)
        if configuration.provider == .ipWhois { throw LookupError.transport("fixture timeout") }
        return MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: configuration.provider)
    }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
        fatalError("country metadata must not cause confirmation")
    }
}

private actor GeographyClient: PublicIPLookupClientProtocol {
    private(set) var lookups = 0
    private(set) var confirmations = 0

    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        let countries = [("SG", "Singapore"), ("--", "Unknown"), ("JP", "Japan"), ("SG", "Singapore")]
        let country = countries[min(lookups, countries.count - 1)]
        lookups += 1
        return MimoSnapshot(ipAddress: "192.0.2.10", countryCode: country.0, countryName: country.1, provider: configuration.provider)
    }

    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
        confirmations += 1
        throw LookupError.invalidResponse
    }
}
