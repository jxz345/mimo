import Foundation

/// Transport availability is separate from the health of the processes it reports.
struct MimoClientConnectionStatus {
    enum Phase { case connecting, connected, interrupted, incompatible, inactive }
    var phase: Phase = .connecting
    var lastReplyAt: Date?

    var title: String {
        switch phase {
        case .connecting: "Connecting to background service…"
        case .connected: "Connected to background service"
        case .interrupted: lastReplyAt == nil ? "Cannot connect to background service" : "Connection to background service lost"
        case .incompatible: "Service connection needs an update"
        case .inactive: "Updates paused for inactive account"
        }
    }

    var rowTitle: String { phase == .connecting ? "Connecting…" : phase == .incompatible ? "Update required" : phase == .inactive ? "Account inactive" : "No connection" }

    var detail: String {
        switch phase {
        case .connected: "Receiving updates from mimo-core."
        case .connecting: "Waiting for mimo-core to reply. Live service health and internet access are unconfirmed."
        case .interrupted: "Not receiving updates from mimo-core. Reconnecting automatically; live service health and internet access are unconfirmed."
        case .incompatible: "The app and background service use incompatible protocols. Update or repair the installation to reconnect."
        case .inactive: "This account is inactive. Updates resume when you return; background services continue independently."
        }
    }

    func lastReplyText(at date: Date) -> String {
        guard let age = MimoHealthLabel.age(checkedAt: lastReplyAt, at: date) else { return "No background-service reply received yet." }
        return "Last background-service reply: \(age) secs ago."
    }
}
