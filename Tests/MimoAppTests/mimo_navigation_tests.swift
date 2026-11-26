import AppKit
import SwiftUI

/// Exercise one retained native window, rather than rendering a new view for
/// every screenshot. Status delivery and navigation share the real main actor.
@MainActor
enum MimoNavigationTests {
    static func run(output: URL) async throws {
        var settings = MachineSettings()
        settings.allowlist = AllowedIPList()
        var presentation = UserPresentationPreferences(); presentation.imported = true
        var state = DaemonState(instanceID: UUID(), build: "navigation fixture", initialized: true, revision: 1,
            settings: settings, presentation: presentation,
            snapshot: MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore",
                provider: .ipWhois, checkedAt: .now), status: .ready,
            indicators: MonitorIndicatorState(), authorizationState: .notAllowed("192.0.2.10"),
            providerHealth: [:], budget: LookupBudget(), nextProvider: .ipWhois, cooldowns: [:], hasIPinfoToken: false)
        var routing = MimoRoutingState()
        routing.configuration.mode = .global; routing.configuration.networkFamily = .dual
        routing.phase = .blocked
        routing.reason = "No exit IPs are approved. Review Allowed IPs in Settings."
        routing.observedIP = .init(address: "192.0.2.10", checkedAt: .now)
        routing.blockingIP = routing.observedIP
        state.routing = routing
        let monitor = PublicIPMonitor(readDeactivation: { false }); monitor.receive(state)
        let statusItem = StatusItemController(monitor: monitor)
        defer { withExtendedLifetime(statusItem) {} }
        let nav = MimoSettingsNavigation.shared
        nav.tab = .dashboard; nav.section = .general
        let size = NSSize(width: 1040, height: 660)
        let host = NSHostingView(rootView: DashboardView(monitor: monitor))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close(); nav.tab = .dashboard; nav.section = .general }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        var samples: [[String: Any]] = []
        for round in 0..<3 {
            for section in MimoSettingsSection.allCases {
                for tab in [MimoMainTab.settings, .dashboard] {
                    let start = ProcessInfo.processInfo.systemUptime
                    nav.section = section; nav.tab = tab
                    monitor.receive(state)
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    samples.append(["round": round, "tab": tab.rawValue, "section": section.rawValue, "milliseconds": ms])
                    try await Task.sleep(for: .milliseconds(30))
                }
            }
        }
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("navigation-timing.json"))
        let values = samples.compactMap { $0["milliseconds"] as? Double }.sorted()
        print("Navigation timing: count=\(values.count), p95=\(values[Int(Double(values.count - 1) * 0.95)]), max=\(values.last!) ms")
        CredentialAppTests.require(values.last! < 250, "Warm native navigation must not block the main actor for 250 ms")
        let before = statusItem.updateCount
        let layoutsBefore = statusItem.labelLayoutCount
        for _ in 0..<10 { monitor.receive(state) }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let redraws = statusItem.updateCount - before
        print("Status burst: ten complete states queued \(redraws) native menu updates")
        CredentialAppTests.require(redraws <= 1,
            "A burst of completed states must not queue duplicate native menu layouts ahead of user input (got \(redraws))")
        CredentialAppTests.require(statusItem.labelLayoutCount == layoutsBefore,
            "Unchanged health publications must not synchronously lay out the native status label")
        // Coalescing may omit intermediate frames, never the final verdict.
        state.routing?.phase = .checking
        monitor.receive(state)
        state.routing?.phase = .blocked
        state.routing?.reason = "Proxy unavailable. Retry verification or select Direct."
        monitor.receive(state)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        CredentialAppTests.require(statusItem.displayedPresentation == monitor.statusPresentation,
            "Coalesced native menus must present the latest completed failure state")
        print("PASS: all six Settings sections and Dashboard navigate during blocked-state delivery; menu updates coalesce without losing the final verdict")
    }
}
