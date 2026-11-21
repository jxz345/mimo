import Foundation
import CoreGraphics
import IOKit

/// A root-daemon observer, independent of every user's GUI. Sampling also
/// recovers missed session notifications. Only actual OS state changes trigger
/// verification; focusing Mimo or opening its dashboard does not.
final class MimoSessionObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.mimo.session-observer", qos: .userInitiated)
    private let statusLock = NSLock()
    private var healthy = false
    private var enabled = false
    private var timer: DispatchSourceTimer?
    private var previous: MimoSessionSnapshot?
    private var unavailable = false
    private var pending: Set<String> = []
    private let powerGuard: MimoPowerGuard
    private let displayObserver = MimoSessionDisplayObserver()
    private let changed: @MainActor @Sendable (String) -> Void

    init(powerGuard: MimoPowerGuard, changed: @escaping @MainActor @Sendable (String) -> Void) {
        self.powerGuard = powerGuard
        self.changed = changed
    }

    var isRunning: Bool { statusLock.withLock { healthy } }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            statusLock.withLock { enabled = true }
            sample()
            RuntimeLog.shared.info("mimo_session_observer_ready", fields: ["healthy": String(isRunning), "intervalMilliseconds": "500"])
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(50))
            source.setEventHandler { [weak self] in self?.sample() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            previous = nil; pending.removeAll(); unavailable = false
            displayObserver.invalidate()
            statusLock.withLock { healthy = false; enabled = false }
        }
    }

    private func sample() {
        let snapshot = Self.read().map { $0.withDisplaysAsleep(displayObserver.value(for: $0)) }
        if let snapshot {
            if unavailable { pending.insert("session_observation_restored") }
            if let previous { pending.formUnion(snapshot.changes(from: previous)) }
            previous = snapshot
            unavailable = false
        } else {
            if !unavailable { pending.insert("session_observation_lost") }
            unavailable = true
        }
        statusLock.withLock { healthy = snapshot != nil && pending.isEmpty }
        guard !pending.isEmpty else { return }
        let reason = pending.sorted().joined(separator: ",")
        do {
            // Revoke old approvals and close PF on this queue before waiting
            // for profile work or an XPC request on the supervisor's actor.
            let guarded = try powerGuard.fence.invalidate { try MimoPowerGuard.closeBarrier() }
            pending.removeAll()
            statusLock.withLock { healthy = snapshot != nil }
            RuntimeLog.shared.info("mimo_session_changed", fields: ["source": reason, "action": guarded ? "blocked_reverify" : "direct_refresh"])
            notify(reason)
        } catch {
            // Retain the transition and retry closure on the next sample.
            RuntimeLog.shared.error("mimo_session_guard_failed", fields: ["source": reason, "error": error.localizedDescription])
            notify("session_guard_failed")
        }
    }

    private func notify(_ reason: String) {
        Task { @MainActor [weak self] in
            guard let self, self.statusLock.withLock({ self.enabled }) else { return }
            self.changed(reason)
        }
    }

    static func read() -> MimoSessionSnapshot? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(root, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let registry = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return MimoSessionSnapshot(registry: registry, displaysAsleep: nil)
    }
}

/// WindowServer may stop replying during fast user switching. Its optional
/// display sample must never hold the session observer or delay lock/login
/// detection. At most one query can be outstanding; old-session replies expire.
final class MimoSessionDisplayObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.mimo.display-observer", qos: .utility)
    private let read: @Sendable () -> Bool?
    private var console: Set<MimoSessionSnapshot.Session> = []
    private var generation = 0
    private var stableAt = Date.now
    private var sampledAt: Date?
    private var asleep: Bool?
    private var inFlight = false

    init(read: @escaping @Sendable () -> Bool? = MimoSessionDisplayObserver.readDisplay) { self.read = read }

    func invalidate() {
        lock.withLock { generation += 1; console = []; asleep = nil; sampledAt = nil; stableAt = .now }
    }

    func value(for snapshot: MimoSessionSnapshot, at date: Date = .now) -> Bool? {
        lock.withLock {
            guard !snapshot.locked, !snapshot.console.isEmpty else {
                generation += 1; console = []; asleep = nil; sampledAt = nil; stableAt = date
                return nil
            }
            if console != snapshot.console {
                generation += 1; console = snapshot.console; stableAt = date; sampledAt = nil; asleep = nil
            }
            // Do not contact WindowServer while the login session is settling.
            guard date.timeIntervalSince(stableAt) >= 2 else { return nil }
            if !inFlight, sampledAt.map({ date.timeIntervalSince($0) >= 1 }) ?? true {
                inFlight = true
                let requestedGeneration = generation
                queue.async { [weak self] in
                    guard let self else { return }
                    // The account may have changed while this work was queued.
                    guard self.lock.withLock({ self.generation == requestedGeneration }) else {
                        self.lock.withLock { self.inFlight = false }; return
                    }
                    let value = self.read()
                    self.lock.withLock {
                        self.inFlight = false
                        guard self.generation == requestedGeneration else { return }
                        self.asleep = value; self.sampledAt = .now
                    }
                }
            }
            guard let sampledAt, date.timeIntervalSince(sampledAt) < 5 else { return nil }
            return asleep
        }
    }

    private static func readDisplay() -> Bool? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let result = CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)
        // Headless/early-boot systems need not expose a display. Session and
        // system-power observation remain mandatory and independent of this.
        return result == .success && count > 0
            ? displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 } : nil
    }
}
