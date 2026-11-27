import Foundation

/// Orders human requests without holding a firewall or lifecycle lock. Only a
/// contiguous run of pending mode intents can replace one another. Admitted
/// operations and non-mode edits retain their ordering. Reads never queue here.
@MainActor
final class MimoControlQueue {
    private final class Ticket {
        let id: UUID
        let key: String?
        var supersededBy: UUID?
        init(id: UUID, key: String?) { self.id = id; self.key = key }
    }
    private var tickets: [Ticket] = []

    /// False is an ordinary superseded outcome, never permission to mutate.
    @discardableResult
    func wait(command: String, coalescingKey: String? = nil, requestID: UUID = UUID(),
              while busy: () -> Bool) async throws -> Bool {
        try Task.checkCancellation()
        if let key = coalescingKey {
            // A different edit is an ordering barrier. Never move a mode intent
            // across proxy, allowlist, credentials or service operations.
            while let previous = tickets.last, previous.key == key {
                previous.supersededBy = requestID
                tickets.removeLast()
                RuntimeLog.shared.info("mimo_control_superseded", fields: [
                    "command": command, "request": previous.id.uuidString,
                    "replacement": requestID.uuidString
                ])
            }
        }
        guard tickets.count < 32 else { throw DaemonFailure.conflict }
        let ticket = Ticket(id: requestID, key: coalescingKey)
        tickets.append(ticket)
        defer { tickets.removeAll { $0 === ticket } }
        let queued = tickets.first !== ticket || busy()
        if queued { RuntimeLog.shared.info("mimo_control_queued", fields: ["command": command, "request": requestID.uuidString]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(65))
        while true {
            try Task.checkCancellation()
            if ticket.supersededBy != nil { return false }
            if tickets.first === ticket, !busy() { break }
            guard ContinuousClock.now < deadline else { throw DaemonFailure.unavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
        if queued { RuntimeLog.shared.info("mimo_control_resumed", fields: ["command": command, "request": requestID.uuidString]) }
        return true
    }
}
