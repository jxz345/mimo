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
            snapshot: ExitIPSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore",
                city: "Singapore", organization: "Example Network", provider: .ipWhois, checkedAt: now),
            status: .ready, indicators: MonitorIndicatorState(), authorizationState: .allowed,
            providerHealth: [:], budget: LookupBudget(), nextProvider: .ipWhois, cooldowns: [:], hasIPinfoToken: false)
        var routing = MimoRoutingState()
        routing.configuration.proxy = MimoProxy(ClashProxySettings(name: "Personal proxy", type: .socks5,
            server: "192.0.2.20", port: 1080))
        routing.observedIP = MimoIPObservation(address: "192.0.2.10", checkedAt: now)
        routing.services = [
            .init(id: .core, health: .running, transport: "XPC / Mach"),
            .init(id: .mihomo, health: .running, transport: "HTTP / SOCKS · Unix controller", address: "127.0.0.1", port: 7890, bindingConfirmed: true),
            .init(id: .profileHosting, health: .running, transport: "Private file delivery"),
            .init(id: .tailnetProvider, health: .running, transport: "HTTP", address: "127.0.0.1", port: 18766, bindingConfirmed: true)
        ]
        for dark in [false, true] {
            for scenario in ["direct", "rule", "global", "blocked", "checking", "empty", "tailnet-stopped", "long-text"] {
                var value = routing
                value.configuration.mode = scenario == "direct" ? .direct : scenario == "global" ? .global : .rule
                value.phase = .active; value.effectiveMode = value.configuration.mode
                value.reason = scenario == "direct" ? "Normal networking is restored." : "Exit IP approved."
                if ["blocked", "checking", "empty", "long-text"].contains(scenario) {
                    value.phase = scenario == "checking" ? .checking : .blocked
                    value.effectiveMode = nil
                    value.reason = scenario == "empty" ? "The allowed exit IP list is empty." : "Exit IP 2001:db8:abcd:1234:5678:9abc:def0:1234 is not on the allowed list."
                    if scenario != "empty" { value.blockingIP = .init(address: "2001:db8:abcd:1234:5678:9abc:def0:1234", checkedAt: now) }
                }
                if scenario == "tailnet-stopped" { value.services[3].health = .stopped; value.services[3].bindingConfirmed = false }
                if scenario == "long-text" {
                    value.configuration.proxy?.name = "A deliberately long profile name for the primary travel connection"
                    value.reason += " Open Settings to review the proxy configuration and add the expected exit address before retrying."
                }
                state.routing = value
                state.settings.allowlist = scenario == "empty" ? AllowedIPList() : settings.allowlist
                let monitor = PublicIPMonitor(); monitor.receive(state)
                try CredentialAppTests.render(DashboardView(monitor: monitor), size: NSSize(width: 1040, height: 570), dark: dark,
                    to: output.appendingPathComponent("dashboard-\(scenario)-\(dark ? "dark" : "light").png"))
            }
            state.routing = routing
            let monitor = PublicIPMonitor(); monitor.receive(state)
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
