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
            statusLock.withLock { healthy = false; enabled = false }
        }
    }

    private func sample() {
        let snapshot = Self.read()
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
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let result = CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)
        // Headless/early-boot systems need not expose a display. Session and
        // system-power observation remain mandatory and independent of this.
        let asleep: Bool? = result == .success && count > 0
            ? displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 } : nil
        return MimoSessionSnapshot(registry: registry, displaysAsleep: asleep)
    }
}
