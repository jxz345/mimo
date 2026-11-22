import AppKit
import SwiftUI

@MainActor
enum MimoDashboardTests {
    static func run(output: URL) throws {
        let now = Date()
        var settings = MachineSettings()
        settings.allowlist = AllowedIPList(addresses: ["192.0.2.10"])
        settings.tailscaleProviderEnabled = true
        var presentation = UserPresentationPreferences(); presentation.imported = true
        var state = DaemonState(instanceID: UUID(), build: "UI acceptance fixture", initialized: true, revision: 1,
            settings: settings, presentation: presentation,
            snapshot: MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore",
                city: "Singapore", organization: "Example Network", provider: .ipWhois, checkedAt: now),
            status: .ready, indicators: MonitorIndicatorState(), authorizationState: .allowed,
            providerHealth: [:], budget: LookupBudget(), nextProvider: .ipWhois, cooldowns: [:], hasIPinfoToken: false)
        var routing = MimoRoutingState()
        routing.configuration.proxy = MimoProxy(ClashProxySettings(name: "Personal proxy", type: .socks5,
            server: "192.0.2.20", port: 1080))
        routing.observedIP = MimoIPObservation(address: "192.0.2.10", checkedAt: now)
        routing.infrastructure = .init(pf: .healthy, launchd: .healthy, checkedAt: now)
        routing.services = [
            .init(id: .core, health: .running, transport: "XPC / Mach"),
            .init(id: .mihomo, health: .running, transport: "HTTP / SOCKS · Unix controller", address: "127.0.0.1", port: 7890, bindingConfirmed: true),
            .init(id: .profileHosting, health: .running, transport: "Private file delivery"),
            .init(id: .tailnetProvider, health: .running, transport: "HTTP", address: "127.0.0.1", port: 18766, bindingConfirmed: true)
        ]
        for index in routing.services.indices { routing.services[index].checkedAt = now.addingTimeInterval(Double(-index - 2)) }
        for dark in [false, true] {
            for scenario in ["released", "releasing", "release-failed", "direct", "rule", "background-audit", "global", "blocked", "checking", "empty", "tailnet-stopped", "long-text", "direct-checking", "direct-failed", "unqualified", "infrastructure-failed", "infrastructure-stale", "services-stale", "services-unknown"] {
                var value = routing
                value.configuration.mode = scenario.hasPrefix("direct") ? .direct : scenario == "global" ? .global : .rule
                value.phase = .active; value.effectiveMode = value.configuration.mode
                value.backgroundVerification = scenario == "background-audit"
                value.reason = scenario == "direct" ? "Normal networking is restored." : "Exit IP approved."
                if ["blocked", "checking", "empty", "long-text"].contains(scenario) {
                    value.phase = scenario == "checking" ? .checking : .blocked
                    value.effectiveMode = nil
                    value.reason = scenario == "empty" ? "The allowed exit IP list is empty." : "Exit IP 198.51.100.77 is not on the allowed list."
                    if scenario != "empty" { value.blockingIP = .init(address: "198.51.100.77", checkedAt: now) }
                }
                if ["released", "releasing", "release-failed"].contains(scenario) {
                    value.configuration.mode = .direct; value.networkReleaseRequested = true
                    value.networkReleased = scenario == "released"
                    value.phase = scenario == "released" ? .active : scenario == "releasing" ? .restoringDirect : .unavailable
                    value.effectiveMode = scenario == "released" ? .direct : nil
                    value.reason = scenario == "released" ? "Mimo routing is off. Other VPNs can manage networking." : scenario == "releasing" ? "Stopping engine and restoring system networking…" : "Network cleanup incomplete: DNS cleanup failed. Retry Stop engine."
                    value.services[1].health = .stopped; value.services[2].health = .suspended; value.services[3].health = .suspended
                    value.infrastructure = .init(pf: .released, launchd: .healthy, checkedAt: now)
                }
                if scenario == "tailnet-stopped" { value.services[3].health = .stopped; value.services[3].bindingConfirmed = false }
                if scenario == "infrastructure-failed" {
                    value.infrastructure = .init(pf: .failed, launchd: .failed, checkedAt: now)
                    value.phase = .unavailable; value.effectiveMode = nil
                    value.reason = "The independent firewall check failed. Service repair is required."
                }
                if scenario == "infrastructure-stale" { value.infrastructure?.checkedAt = now.addingTimeInterval(-60) }
                if scenario == "services-stale" { for index in value.services.indices { value.services[index].checkedAt = now.addingTimeInterval(-60) } }
                if scenario == "services-unknown" { for index in value.services.indices { value.services[index].checkedAt = nil } }
                if scenario == "long-text" {
                    value.configuration.proxy?.name = "A deliberately long profile name for the primary travel connection"
                    value.reason += " Open Settings to review the proxy configuration and add the expected exit address before retrying."
                }
                state.status = scenario == "direct-checking" ? .refreshing : scenario == "direct-failed" ? .failed("The network connection was lost. Check Wi-Fi and try again.") : .ready
                if scenario == "unqualified" {
                    value.phase = .blocked; value.effectiveMode = nil; value.observedIP = nil
                    value.reason = "Network or configuration changed. Verification is required."
                    state.status = .failed("Protected routing is not qualified on this build. Direct remains available.")
                }
                state.routing = value
                state.settings.allowlist = scenario == "empty" ? AllowedIPList() : settings.allowlist
                let monitor = PublicIPMonitor(readDeactivation: { false }); monitor.receive(state)
                try CredentialAppTests.render(DashboardView(monitor: monitor), size: NSSize(width: 1040, height: 660), dark: dark,
                    to: output.appendingPathComponent("dashboard-\(scenario)-\(dark ? "dark" : "light").png"), padding: 0)
            }
            state.routing = routing
            let monitor = PublicIPMonitor(readDeactivation: { false }); monitor.receive(state)
            for section in MimoSettingsSection.allCases {
                MimoSettingsNavigation.shared.section = section
                try CredentialAppTests.render(SettingsView(monitor: monitor), size: NSSize(width: 880, height: 620), dark: dark,
                    to: output.appendingPathComponent("settings-populated-\(section.id)-\(dark ? "dark" : "light").png"))
            }
        }
        MimoSettingsNavigation.shared.section = .general
        print("PASS: native dashboard scenarios and populated Settings render in both appearances")
    }
}
