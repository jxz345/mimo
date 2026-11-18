import Foundation

/// Applied before any command side effect. Replies alone cannot fence a delayed
/// Direct request: the supervisor must reject it before changing the firewall.
struct MimoCommandFence {
    private(set) var processID: Int32?
    private var controller: UUID?
    private var sequence: UInt64 = 0

    mutating func accept(_ stamp: MimoCommandStamp, peer: Int32, currentCore: Int32?,
                         enabled: Bool, heartbeat: Bool) -> Bool {
        guard enabled, peer > 0, currentCore == peer else { return false }
        if processID != peer {
            processID = peer; controller = stamp.controller; sequence = 0
        }
        guard controller == stamp.controller else { return false }
        // A poll may overtake a command on independent XPC connections. It must
        // not consume that command's sequence or revive an older heartbeat.
        if heartbeat { return stamp.sequence >= sequence }
        guard stamp.sequence > sequence else { return false }
        sequence = stamp.sequence
        return true
    }

    static func matchesSavedRouting(_ message: MimoSupervisorRequest,
                                    configuration: MimoConfiguration, revision: Int) -> Bool {
        guard message.revision == revision else { return false }
        switch message.command {
        case .direct: return configuration.mode == .direct
        case .prepare: return message.configuration == configuration
        case .approve: return configuration.mode.requiresVerification
        default: return true
        }
    }
}
