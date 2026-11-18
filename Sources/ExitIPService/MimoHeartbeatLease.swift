import Foundation

/// A received heartbeat must not wait behind synchronous profile/controller work.
/// Only the live core identity already authenticated by the supervisor can renew
/// this lease on XPC's queue; a heartbeat cannot establish its own authority.
final class MimoHeartbeatLease: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Int32?
    private var controller: UUID?
    private var sequence: UInt64 = 0
    private var received = ContinuousClock.now

    func authorize(_ stamp: MimoCommandStamp, process: Int32, at instant: ContinuousClock.Instant = .now) {
        lock.withLock {
            if self.process != process || controller != stamp.controller {
                self.process = process; controller = stamp.controller; sequence = 0
                received = instant
            }
            sequence = max(sequence, stamp.sequence)
            received = max(received, instant)
        }
    }

    @discardableResult
    func receive(_ stamp: MimoCommandStamp, process: Int32, at instant: ContinuousClock.Instant = .now) -> Bool {
        lock.withLock {
            guard self.process == process, controller == stamp.controller, stamp.sequence >= sequence else { return false }
            received = max(received, instant)
            return true
        }
    }

    func reset() {
        lock.withLock { process = nil; controller = nil; sequence = 0 }
    }

    func expired(at instant: ContinuousClock.Instant = .now) -> Bool {
        lock.withLock { process == nil || received.duration(to: instant) > .seconds(5) }
    }
}
