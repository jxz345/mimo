import AppKit
import SwiftUI

@MainActor
enum MimoDashboardTests {
    static func run(output: URL) throws {
        let now = Date()
        var settings = MachineSettings()
        settings.allowlist = AllowedIPList(addresses: ["192.0.2.10"])
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
        let entry = MimoSavedProxy(proxy: routing.configuration.proxy!)
        let alternative = MimoSavedProxy(proxy: MimoProxy(ClashProxySettings(name: "Backup proxy", type: .http, server: "192.0.2.30", port: 8080)))
        routing.configuration.proxies = [entry, alternative]
        routing.configuration.activeProxyID = entry.id
        routing.observedIP = MimoIPObservation(address: "192.0.2.10", checkedAt: now)
        routing.infrastructure = .init(pf: .healthy, launchd: .healthy, checkedAt: now)
        routing.services = [
            .init(id: .core, health: .running, transport: "XPC / Mach"),
            .init(id: .mihomo, health: .running, transport: "HTTP / SOCKS · Unix controller", address: "127.0.0.1", port: 7890, bindingConfirmed: true),
            .init(id: .profileHosting, health: .running, transport: "Private file delivery")
        ]
        for index in routing.services.indices { routing.services[index].checkedAt = now.addingTimeInterval(Double(-index - 2)) }
        for dark in [false, true] {
            for scenario in ["released", "releasing", "release-failed", "direct", "rule", "background-audit", "global", "blocked", "checking", "empty", "long-text", "proxy-failed", "provider-paused", "last-known", "direct-checking", "direct-failed", "unqualified", "infrastructure-failed", "infrastructure-stale", "services-stale", "services-unknown"] {
                var value = routing
                value.configuration.mode = scenario.hasPrefix("direct") ? .direct : scenario == "global" ? .global : .rule
                value.phase = .active; value.effectiveMode = value.configuration.mode
                value.backgroundVerification = scenario == "background-audit"
                value.reason = scenario == "direct" ? "Normal networking is restored." : "Exit IP approved."
                if ["blocked", "checking", "empty", "long-text"].contains(scenario) {
                    value.phase = scenario == "checking" ? .checking : .blocked
                    value.effectiveMode = nil
                    value.reason = scenario == "empty" ? "No exit IPs are approved. Review Allowed IPs in Settings." : "Exit IP 198.51.100.77 is not on the allowed list."
                    value.blockingIP = .init(address: "198.51.100.77", checkedAt: now)
                }
                if ["released", "releasing", "release-failed"].contains(scenario) {
                    value.configuration.mode = .direct; value.networkReleaseRequested = true
                    value.networkReleased = scenario == "released"
                    value.phase = scenario == "released" ? .active : scenario == "releasing" ? .restoringDirect : .unavailable
                    value.effectiveMode = scenario == "released" ? .direct : nil
                    value.reason = scenario == "released" ? "Mimo routing is off. Other VPNs can manage networking." : scenario == "releasing" ? "Stopping engine and restoring system networking…" : "Network cleanup incomplete: DNS cleanup failed. Retry Stop engine."
                    value.services[1].health = .stopped; value.services[2].health = .suspended
                    value.infrastructure = .init(pf: .released, launchd: .healthy, checkedAt: now)
                }
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
                if ["proxy-failed", "provider-paused"].contains(scenario) {
                    value.phase = .blocked; value.effectiveMode = nil; value.observedIP = nil
                    value.reason = "Network or configuration changed. Verification is required."
                    state.status = scenario == "proxy-failed"
                        ? .failed("The proxy connection failed. Review the proxy server and credentials, or use Direct.")
                        : .providerPaused(.ipinfoLite, now.addingTimeInterval(600))
                }
                if scenario == "last-known" {
                    value.configuration.mode = .global; value.configuration.networkFamily = .dual
                    value.phase = .blocked; value.effectiveMode = nil; value.observedIP = nil
                    value.lastExitObservation = state.snapshot
                    value.reason = "The IPv4 exit-IP check failed. Retry or use Direct."
                    state.status = .failed("Proxy connection refused")
                }
                state.indicators = MonitorIndicatorState(errorMessage: scenario == "provider-paused"
                    ? "Unable to check the exit IP with IPinfo Lite: The proxy connection timed out." : nil)
                if scenario == "unqualified" {
                    value.phase = .blocked; value.effectiveMode = nil; value.observedIP = nil
                    value.reason = "Network or configuration changed. Verification is required."
                    state.status = .failed("Protected routing is not qualified on this build. Direct remains available.")
                }
                state.routing = value
                state.settings.allowlist = scenario == "empty" ? AllowedIPList() : settings.allowlist
                let monitor = PublicIPMonitor(readDeactivation: { false }); monitor.receive(state)
                if ["blocked", "checking", "empty", "proxy-failed", "provider-paused"].contains(scenario) {
                    CredentialAppTests.require(monitor.canChangeSharedSettings,
                        "Blocked/pending verification must leave the Direct mode action enabled")
                }
                if scenario == "last-known" {
                    CredentialAppTests.require(monitor.statusPresentation.address == state.snapshot?.ipAddress &&
                        monitor.statusPresentation.detail.contains("Last known IPv4"), "Failed checks show clearly stale history")
                }
                if scenario == "provider-paused" {
                    CredentialAppTests.require(monitor.statusPresentation.detail.contains("proxy connection timed out") &&
                        monitor.statusPresentation.detail.contains("paused until") && monitor.statusPresentation.detail.contains("use Direct"),
                        "Dashboard must retain the cause, deadline and Direct escape during cooldown")
                }
                try CredentialAppTests.render(DashboardView(monitor: monitor), size: NSSize(width: 1040, height: 640), dark: dark,
                    to: output.appendingPathComponent("dashboard-\(scenario)-\(dark ? "dark" : "light").png"), padding: 0)
                if ["rule", "checking", "blocked", "long-text", "provider-paused"].contains(scenario) && !dark {
                    for width in [880] {
                        try CredentialAppTests.render(DashboardView(monitor: monitor), size: NSSize(width: width, height: 760), dark: false,
                            to: output.appendingPathComponent("dashboard-\(scenario)-width-\(width).png"), padding: 0)
                    }
                }
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
