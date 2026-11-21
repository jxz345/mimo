import Foundation

/// Orders human requests without holding a firewall or lifecycle lock. Read-only
/// state, events and heartbeats never enter this queue.
@MainActor
final class MimoControlQueue {
    private var tickets: [UUID] = []

    func wait(command: String, while busy: () -> Bool) async throws {
        guard tickets.count < 32 else { throw DaemonFailure.conflict }
        let ticket = UUID()
        tickets.append(ticket)
        defer { tickets.removeAll { $0 == ticket } }
        let queued = tickets.first != ticket || busy()
        if queued { RuntimeLog.shared.info("mimo_control_queued", fields: ["command": command]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(65))
        while tickets.first != ticket || busy() {
            guard ContinuousClock.now < deadline else { throw DaemonFailure.unavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
        if queued { RuntimeLog.shared.info("mimo_control_resumed", fields: ["command": command]) }
    }
}
