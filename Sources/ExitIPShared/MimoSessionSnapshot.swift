import Foundation

/// Only numeric session identity is retained. Names and registry UUIDs are never logged.
public struct MimoSessionSnapshot: Equatable, Sendable {
    public struct Session: Hashable, Sendable {
        public let user: Int
        public let audit: Int
        public let identifier: Int
    }

    public let locked: Bool
    public let sessions: Set<Session>
    public let console: Set<Session>
    public let displaysAsleep: Bool?

    /// These registry keys are macOS implementation details. An unknown schema
    /// is observation failure, never an unlocked/unchanged default.
    public init?(registry: [String: Any], displaysAsleep: Bool?) {
        guard let locked = registry["IOConsoleLocked"] as? Bool,
              let users = registry["IOConsoleUsers"] as? [[String: Any]] else { return nil }
        var sessions = Set<Session>()
        var console = Set<Session>()
        for user in users {
            guard let loggedIn = user["kCGSessionLoginDoneKey"] as? Bool else { return nil }
            guard loggedIn else { continue }
            guard let uid = user["kCGSSessionUserIDKey"] as? Int,
                  let audit = user["kCGSSessionAuditIDKey"] as? Int,
                  let identifier = user["kCGSSessionIDKey"] as? Int,
                  let active = user["kCGSSessionOnConsoleKey"] as? Bool else { return nil }
            let session = Session(user: uid, audit: audit, identifier: identifier)
            sessions.insert(session)
            if active { console.insert(session) }
        }
        self.locked = locked
        self.sessions = sessions
        self.console = console
        self.displaysAsleep = displaysAsleep
    }

    public func changes(from previous: Self) -> [String] {
        var events: [String] = []
        if locked != previous.locked { events.append(locked ? "screen_locked" : "screen_unlocked") }
        if !sessions.subtracting(previous.sessions).isEmpty { events.append("user_login") }
        if !previous.sessions.subtracting(sessions).isEmpty { events.append("user_logout") }
        if console != previous.console { events.append("console_session_changed") }
        if let displaysAsleep, let old = previous.displaysAsleep, displaysAsleep != old {
            events.append(displaysAsleep ? "display_sleep" : "display_wake")
        }
        return events
    }
}
