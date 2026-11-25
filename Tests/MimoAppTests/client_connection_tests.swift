import AppKit
import SwiftUI

@MainActor
enum ClientConnectionTests {
    static func state() -> DaemonState {
        var presentation = UserPresentationPreferences(); presentation.imported = true
        var state = DaemonState(instanceID: UUID(), build: "Connection fixture", initialized: true, revision: 1,
            settings: MachineSettings(), presentation: presentation, snapshot: nil, status: .ready,
            indicators: MonitorIndicatorState(), authorizationState: .unavailable, providerHealth: [:],
            budget: LookupBudget(), nextProvider: .ipWhois, cooldowns: [:], hasIPinfoToken: false)
        var routing = MimoRoutingState()
        routing.phase = .active; routing.effectiveMode = .rule; routing.configuration.mode = .rule
        routing.reason = "Exit IP approved."
        routing.services = MimoServiceID.allCases.map {
            var service = MimoServiceStatus(id: $0, health: .running, transport: "Test")
            service.checkedAt = .now
            return service
        }
        routing.infrastructure = .init(pf: .healthy, launchd: .healthy, checkedAt: .now)
        state.routing = routing
        return state
    }

    static func run(output: URL) async throws {
        let require = CredentialAppTests.require
        let transport = Transport()
        let monitor = PublicIPMonitor(subscribe: transport.subscribe, readStatus: transport.read, reconnectDelay: .seconds(60), readDeactivation: { false })
        defer { monitor.stop(); transport.finishAll() }
        require(monitor.connection.phase == .connecting, "Initial UI must describe connection setup, not a failed service")
        require(monitor.serviceHealthLabel(.core, at: .now) == "Connecting…", "No initial service inspection is available")
        monitor.start()
        try await settle()
        require(transport.pending.count == 1, "Startup must issue one bounded status probe")
        monitor.applicationDidBecomeActive()
        try await settle()
        // Activation during connection setup replaces the subscription, cancelling the old probe.
        require(transport.subscribers.count == 2 && transport.cancelled == [0], "Activation must retry a disconnected client immediately")
        monitor.requestStatus(); monitor.requestStatus()
        try await settle()
        require(transport.pending.count == 2, "Concurrent probes in the same generation must coalesce")
        require(transport.requests.allSatisfy { $0.0 == .state && $0.1 == 3 && $0.2 == MimoService.label }, "Status must use a 3-second read-only request")

        var old = state(); old.revision = 10
        transport.reply(0, state: old)
        transport.subscribers[0](.state(old))
        try await settle()
        require(!monitor.connected && monitor.daemonState == nil, "Replies from the replaced connection must be ignored")
        let current = state()
        transport.subscribers[1](.state(current))
        transport.reply(1, state: current)
        try await settle()
        require(monitor.connected && monitor.daemonState?.revision == 1, "The new subscription must recover immediately")
        require(monitor.serviceHealthLabel(.core, at: .now).hasPrefix("Healthy("), "Live inspections keep the uniform age format")
        let lastReply = monitor.connection.lastReplyAt

        // A failed probe must not discard a newer, successful subscription update.
        monitor.requestStatus()
        try await settle()
        transport.subscribers[1](.state(current))
        try await settle()
        transport.fail(2)
        try await settle()
        require(monitor.connected, "A fresh subscription update wins over a failing probe")

        transport.subscribers[1](.failed(.unavailable))
        try await settle()
        require(!monitor.connected && monitor.connection.phase == .interrupted, "Disconnection must identify communication loss")
        require(monitor.connection.lastReplyAt != nil && monitor.connection.lastReplyAt! >= lastReply!, "Disconnection retains the actual last reply time")
        require(monitor.routingState.phase == .unavailable && !monitor.routingState.allowsTraffic, "Cached approval must not claim current internet access")
        for id in MimoServiceID.allCases {
            require(monitor.serviceHealthLabel(id, at: .now) == "No connection", "Cached health must not be shown as Stale or Healthy while disconnected")
        }
        require(monitor.serviceMessage?.contains("Not receiving updates") == true, "The explanation must describe transport, not service failure")
        for dark in [false, true] {
            try CredentialAppTests.render(DashboardView(monitor: monitor), size: NSSize(width: 1040, height: 660), dark: dark,
                to: output.appendingPathComponent("dashboard-disconnected-\(dark ? "dark" : "light").png"), padding: 0)
        }

        // The supervisor can independently report processes/PF while the core channel fails.
        transport.supervisor = current.routing
        monitor.reconnect()
        try await settle()
        transport.subscribers[2](.failed(.unavailable))
        try await settle()
        require(monitor.hasSupervisorReply(), "A fresh supervisor reply must remain distinguishable")
        require(monitor.serviceHealthLabel(.core, at: .now).hasPrefix("Running("), "Process running must not claim healthy core communication")
        require(!monitor.hasSupervisorReply(at: Date.now.addingTimeInterval(11)), "Supervisor replies must expire")
        require(monitor.serviceHealthLabel(.core, at: Date.now.addingTimeInterval(11)) == "No connection", "Expired supervisor data must not imply live health")
        for dark in [false, true] {
            try CredentialAppTests.render(DashboardView(monitor: monitor), size: NSSize(width: 1040, height: 660), dark: dark,
                to: output.appendingPathComponent("dashboard-supervisor-only-\(dark ? "dark" : "light").png"), padding: 0)
        }

        monitor.reconnect()
        try await settle()
        transport.subscribers[3](.failed(.incompatible))
        try await settle()
        require(monitor.connection.phase == .incompatible, "Protocol mismatch must retain an actionable, distinct explanation")
        monitor.sessionDidResignActive()
        let inactiveCount = transport.subscribers.count
        monitor.applicationDidBecomeActive(); monitor.requestStatus(); monitor.reconnect()
        transport.subscribers[3](.state(current))
        try await settle()
        require(monitor.connection.phase == .inactive && transport.subscribers.count == inactiveCount,
                "An inactive account must ignore late updates and stop polling/reconnecting")
        monitor.sessionDidBecomeActive()
        try await settle()
        require(transport.subscribers.count == inactiveCount + 1, "Returning to an account must immediately create a fresh subscription")
        transport.subscribers.last?(.state(current))
        try await settle()
        require(monitor.connected, "Returning account must display the fresh service report")
        monitor.stop()
        let count = transport.subscribers.count
        transport.subscribers[3](.state(current))
        transport.finishAll()
        try await settle()
        require(!monitor.connected && transport.subscribers.count == count, "Stop must reject late callbacks without reconnecting")
        require(transport.requests.allSatisfy { $0.0 == .state || $0.0 == .supervisor }, "Reconnecting must never issue routing, lookup or service commands")
        require(transport.requests.filter { $0.0 == .supervisor }.allSatisfy { $0.1 == 2 }, "Supervisor fallback must also have a short deadline")
        print("PASS: GUI connection lifecycle, bounded/coalesced probes, obsolete callbacks, communication labels, independent supervisor status, protocol mismatch and stop")
    }

    private static func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

    @MainActor
    private final class Transport {
        var subscribers: [@Sendable (DaemonConnectionEvent) -> Void] = []
        var cancelled: [Int] = []
        var requests: [(DaemonCommand, TimeInterval, String)] = []
        var pending: [CheckedContinuation<DaemonResponse, any Error>?] = []
        var supervisor: MimoRoutingState?

        func subscribe(_ receive: @escaping @Sendable (DaemonConnectionEvent) -> Void) -> () -> Void {
            let index = subscribers.count
            subscribers.append(receive)
            return { self.cancelled.append(index) }
        }

        func read(_ request: DaemonRequest, timeout: TimeInterval, label: String) async throws -> DaemonResponse {
            requests.append((request.command, timeout, label))
            if request.command == .supervisor {
                guard let supervisor else { throw DaemonFailure.unavailable }
                var response = DaemonResponse(); response.routing = supervisor
                return response
            }
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }

        func reply(_ index: Int, state: DaemonState) {
            pending[index]?.resume(returning: DaemonResponse(state: state)); pending[index] = nil
        }
        func fail(_ index: Int) { pending[index]?.resume(throwing: DaemonFailure.unavailable); pending[index] = nil }
        func finishAll() { for index in pending.indices { fail(index) } }
    }
}
