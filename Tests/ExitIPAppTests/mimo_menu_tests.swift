import AppKit
import SwiftUI

@MainActor
enum MimoMenuTests {
    static func run(output: URL) throws {
        let now = Date()
        let snapshot = ExitIPSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore",
                                      provider: .ipWhois, checkedAt: now)
        let preferences = MonitoringPreferences()
        func presentation(_ state: MimoRoutingState) -> MimoMenuPresentation {
            MimoMenuPresentation(routing: state, snapshot: snapshot, preferences: preferences, date: now)
        }
        var policy = MimoAccessPolicy()
        policy.directRestored(configuration: MimoConfiguration())
        let direct = presentation(policy.state)
        require(direct.kind == .direct && direct.country == nil, "Direct must have its own arrow, not an approval flag")
        var protected = MimoConfiguration(); protected.mode = .rule
        protected.proxy = MimoProxy(ClashProxySettings(name: "Fixture", type: .http, server: "192.0.2.20", port: 443))
        let proof = policy.begin(configuration: protected, revision: 1, networkGeneration: 1)
        let startup = presentation(policy.state)
        require(startup.kind == .checking && startup.country == nil, "startup validation must display a clock")
        policy.checking(proof)
        require(presentation(policy.state).kind == .checking, "private verification must remain a checking state")
        _ = policy.approve(address: snapshot.ipAddress, at: now, allowlist: AllowedIPList(addresses: [snapshot.ipAddress]),
                           verification: proof, runtimeMatches: true)
        let verified = presentation(policy.state)
        require(verified.kind == .verified && verified.country == snapshot.countryFlag, "approved Rule must show the matching exit country")
        var global = policy.state; global.configuration.mode = .global; global.effectiveMode = .global
        require(presentation(global).kind == .verified, "approved Global uses the same location semantics")
        var mismatch = policy.state
        mismatch.observedIP = MimoIPObservation(address: "198.51.100.23", checkedAt: now)
        require(presentation(mismatch).country == nil, "a cached country for another IP cannot represent the approved exit")
        var tailnet = policy.state
        tailnet.services = [.init(id: .tailnetProvider, health: .stopped, transport: "HTTP")]
        let warning = presentation(tailnet)
        require(warning.kind == .tailnetWarning && warning.country == snapshot.countryFlag,
                "stopped tailnet must warn without calling approved public access blocked")
        var blocked = policy.state
        blocked.phase = .blocked; blocked.effectiveMode = nil
        blocked.blockingIP = MimoIPObservation(address: "2001:db8::42", checkedAt: now)
        blocked.reason = "The exit IP is not on the allowed list."
        let rejected = presentation(blocked)
        require(rejected.kind == .blocked && rejected.country == snapshot.countryFlag, "blocked state retains the last known country beside its stop icon")
        require(rejected.address == "2001:db8::42" && rejected.accessibilityText.contains("2001:db8::42"),
                "the exact triggering IPv6 address must be accessible")
        blocked.phase = .checking
        require(presentation(blocked).kind == .checking && presentation(blocked).address == "2001:db8::42",
                "retry must retain the blocking IP while displaying the checking clock")
        blocked.phase = .unavailable
        blocked.reason = "The background service is unavailable."
        let unavailable = presentation(blocked)
        require(unavailable.kind == .unavailable && unavailable.country == nil && unavailable.address == nil,
                "unconfirmed status must use neutral information without a stale IP")
        var inconsistent = policy.state; inconsistent.effectiveMode = .direct
        require(presentation(inconsistent).kind == .unavailable && presentation(inconsistent).address == nil
                && !presentation(inconsistent).detail.contains("approved"), "inconsistent mode/approval must not claim allowed access")

        let native = MimoStatusMenu(monitor: PublicIPMonitor())
        let identities = native.menu.items.map(ObjectIdentifier.init)
        for _ in 0..<5 { native.update() }
        require(native.menu.items.map(ObjectIdentifier.init) == identities, "status updates must preserve native menu item identity and focus")
        require(native.modeItems.count == 3 && native.modeItems.values.allSatisfy { !$0.isEnabled },
                "all modes must exist and be disabled while core is unavailable")
        require(native.menu.items.contains(where: { $0.title == "Open Dashboard" }) &&
                native.menu.items.contains(where: { $0.title == "Settings…" }) &&
                native.loginItem.title == "Open Mimo at login" && native.refreshItem.title == "Refresh now",
                "dashboard, settings, refresh and login actions must stay present")

        let scenarios = [direct, startup, verified, rejected, warning, unavailable]
        let dock = DockIconController()
        for dark in [false, true] {
            for scenario in scenarios {
                let label = MimoMenuBarLabel(presentation: scenario)
                let host = NSHostingView(rootView: label)
                require(host.fittingSize.height <= 24 && host.fittingSize.width <= 100,
                        "default routing symbols must fit the native menu bar")
                require(dock.update(label: label, darkAppearance: dark, apply: false), "each new routing scenario must render a Dock image")
                require(!dock.update(label: label, darkAppearance: dark, apply: false), "unchanged routing must not redraw the Dock")
            }
            let gallery = VStack(alignment: .leading, spacing: 20) {
                Text("Mimo · Native menu-bar states").font(.title2.weight(.semibold))
                ForEach(Array(scenarios.enumerated()), id: \.offset) { _, value in
                    HStack(alignment: .center, spacing: 20) {
                        MimoMenuBarLabel(presentation: value).frame(width: 90, height: 28)
                            .background(.bar, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(value.title).font(.headline)
                            Text(value.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            try CredentialAppTests.render(gallery, size: NSSize(width: 700, height: 530), dark: dark,
                                          to: output.appendingPathComponent("mimo-menu-states-\(dark ? "dark" : "light").png"))
        }
        print("PASS: native routing icons, exact blocked IP, country/proof matching, stable menu actions and Dock rendering")
    }

    private static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
}
