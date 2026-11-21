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
    private var lastPulse: ContinuousClock.Instant?
    private var lastPulseSequence: UInt64?
    private var lastPulseAccepted = false

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
            lastPulse = instant
            lastPulseSequence = stamp.sequence
            lastPulseAccepted = false
            guard self.process == process, controller == stamp.controller, stamp.sequence >= sequence else { return false }
            lastPulseAccepted = true
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

    func ageSeconds(at instant: ContinuousClock.Instant = .now) -> Double? {
        lock.withLock {
            guard process != nil else { return nil }
            let elapsed = received.duration(to: instant).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
    }

    func diagnostics(at instant: ContinuousClock.Instant = .now) -> [String: String] {
        lock.withLock {
            let age = lastPulse.map { $0.duration(to: instant).components }
            return ["lastPulseAgeSeconds": age.map { String(Double($0.seconds) + Double($0.attoseconds) / 1e18) } ?? "none",
                    "lastPulseSequence": lastPulseSequence.map(String.init) ?? "none",
                    "acceptedSequence": String(sequence), "lastPulseAccepted": String(lastPulseAccepted)]
        }
    }
}
