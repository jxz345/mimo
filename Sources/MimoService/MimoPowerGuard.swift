import Foundation
import IOKit.pwr_mgt

struct MimoEarlyNetworkEvent: Sendable {
    let blocked: Bool
    let awaitingClassification: Bool
    let resolve: @Sendable (Bool) -> Void
}

/// Shared by the independent power/session queues and the supervisor. An
/// approval from before a system event must never release its barrier, even
/// if its XPC reply is late. Session invalidation cannot clear the sleep hold.
final class MimoPowerFence: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var sleeping = false
    private var protected = false
    private let eventLock = NSLock()
    private var cycleActive = false
    private var cycleChanged = false
    private var pendingNetworkEvents = Set<UUID>()

    var isCycleActive: Bool { eventLock.withLock { cycleActive } }

    /// Admission polls must yield while a power callback owns the fence; they
    /// cannot synchronously wait on the control actor for that callback's PF I/O.
    var isCycleActiveOrBusy: Bool {
        guard lock.try() else { return true }
        defer { lock.unlock() }
        return eventLock.withLock { cycleActive }
    }

    func beginCycle() {
        eventLock.withLock {
            if !cycleActive { cycleActive = true; cycleChanged = false }
        }
    }

    /// Called only for an external event after the owned-event filter. Keep the
    /// current work running, but never grant its now-outdated result.
    func deferCycleEvent() -> Bool {
        eventLock.withLock {
            guard cycleActive else { return false }
            cycleChanged = true
            return true
        }
    }

    func finishCycle() -> Bool {
        eventLock.withLock {
            let changed = cycleChanged || !pendingNetworkEvents.isEmpty
            cycleActive = false; cycleChanged = false
            pendingNetworkEvents.removeAll()
            return changed
        }
    }

    /// Early route classification can precede the tunnel inventory update.
    /// Hold approval until actor-side classification, then keep only external
    /// events dirty. An unresolved callback still prevents opening traffic.
    func observeNetworkChange(close: () throws -> Void) throws -> MimoEarlyNetworkEvent {
        try lock.withLock {
            if let id = eventLock.withLock({ () -> UUID? in
                guard cycleActive else { return nil }
                let id = UUID(); pendingNetworkEvents.insert(id); return id
            }) {
                return MimoEarlyNetworkEvent(blocked: false, awaitingClassification: true) { [weak self] external in
                    guard let self else { return }
                    // Classification runs on the state actor. This lock never
                    // surrounds PF, child processes or power callback work.
                    self.eventLock.withLock {
                        guard self.pendingNetworkEvents.remove(id) != nil else { return }
                        if external { self.cycleChanged = true }
                    }
                }
            }
            epoch &+= 1
            if protected { try close() }
            return MimoEarlyNetworkEvent(blocked: protected, awaitingClassification: false, resolve: { _ in })
        }
    }

    func completeCycle(epoch candidate: UInt64, operation: () throws -> Void) throws {
        try lock.withLock {
            try validateCycleEvents()
            guard protected, !sleeping, candidate == epoch else {
                throw MimoRuntimeError.unavailable("System state changed. A fresh IP verification is required.")
            }
            try operation()
            try eventLock.withLock {
                guard !cycleChanged, pendingNetworkEvents.isEmpty else { throw MimoDeferredNetworkChange() }
                cycleActive = false
            }
        }
    }

    func validateCycleEvents() throws {
        try eventLock.withLock {
            guard !cycleChanged, pendingNetworkEvents.isEmpty else { throw MimoDeferredNetworkChange() }
        }
    }

    func arm() throws -> UInt64 {
        try lock.withLock {
            guard !sleeping else { throw MimoRuntimeError.unavailable("The Mac is preparing to sleep.") }
            protected = true
            return epoch
        }
    }

    @discardableResult
    func sleep(close: () throws -> Void) throws -> Bool {
        try lock.withLock {
            sleeping = true
            epoch &+= 1
            if protected { try close() }
            return protected
        }
    }

    @discardableResult
    func wake(close: () throws -> Void = {}) throws -> Bool {
        try lock.withLock {
            sleeping = false
            epoch &+= 1
            if protected { try close() }
            return protected
        }
    }

    @discardableResult
    func invalidate(close: () throws -> Void) throws -> Bool {
        try lock.withLock {
            epoch &+= 1
            if protected { try close() }
            return protected
        }
    }

    func activate<T>(epoch candidate: UInt64, operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard protected, !sleeping, candidate == epoch else {
                throw MimoRuntimeError.unavailable("System state changed. A fresh IP verification is required.")
            }
            return try operation()
        }
    }

    func direct(operation: () throws -> Void) throws {
        try lock.withLock {
            try operation()
            protected = false
            eventLock.withLock {
                cycleActive = false; cycleChanged = false
                pendingNetworkEvents.removeAll()
            }
            epoch &+= 1
        }
    }
}

struct MimoDeferredNetworkChange: Error {}

/// IOKit delivery has its own queue. Profile loading and core XPC cannot delay
/// the pre-sleep barrier. The flat transition anchor remains closed on wake until a new
/// verification explicitly releases it under the same power-state lock.
final class MimoPowerGuard: @unchecked Sendable {
    static let anchor = MimoFirewallPolicy.anchor
    let fence = MimoPowerFence()
    private let queue = DispatchQueue(label: "app.mimo.power-guard", qos: .userInitiated)
    private var port: IONotificationPortRef?
    private var connection: io_connect_t = 0
    private var notifier: io_object_t = 0
    private let changed: @MainActor @Sendable (String) -> Void
#if MIMO_VM_ACCEPTANCE
    private var testSignals: [DispatchSourceSignal] = []
#endif

    init(changed: @escaping @MainActor @Sendable (String) -> Void) { self.changed = changed }
    var isRunning: Bool { connection != 0 && port != nil }

    func start() {
        guard connection == 0 else { return }
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, type, argument in
            guard let context else { return }
            let observer = Unmanaged<MimoPowerGuard>.fromOpaque(context).takeUnretainedValue()
            observer.receive(type) { IOAllowPowerChange(observer.connection, Int(bitPattern: argument)) }
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, queue) }
#if MIMO_VM_ACCEPTANCE
        // The VM-only helper accepts deterministic event injection on the real
        // IOKit delivery queue. These signals do not exist in release builds
        // and are never counted as physical sleep/wake evidence.
        for (number, message): (Int32, UInt32) in [(SIGUSR1, 0xe0000280), (SIGUSR2, 0xe0000300)] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.receive(message) { RuntimeLog.shared.info("mimo_vm_power_acknowledged") }
            }
            source.resume(); testSignals.append(source)
        }
#endif
    }

    func stop() {
#if MIMO_VM_ACCEPTANCE
        testSignals.forEach { $0.cancel() }; testSignals.removeAll()
#endif
        if let port { IONotificationPortSetDispatchQueue(port, nil) }
        queue.sync {
            if notifier != 0 { IODeregisterForSystemPower(&notifier); notifier = 0 }
            if connection != 0 { IOServiceClose(connection); connection = 0 }
            if let port { IONotificationPortDestroy(port) }
            port = nil
        }
    }

    func receive(_ type: UInt32, acknowledge: () -> Void) {
        switch type {
        case 0xe0000270: acknowledge() // CanSystemSleep
        case 0xe0000280: // SystemWillSleep: close first, acknowledge second.
            do {
                let guarded = try fence.sleep {
                    try Self.closeBarrier()
                }
                RuntimeLog.shared.info(guarded ? "mimo_sleep_guard_closed" : "mimo_direct_sleep_prepared")
                acknowledge()
                Task { @MainActor in changed("sleep") }
            } catch {
                // Do not confirm readiness on failure. macOS may still force
                // sleep after its deadline; report that as a failed guard.
                RuntimeLog.shared.info("mimo_sleep_guard_failed", fields: ["error": error.localizedDescription])
                Task { @MainActor in changed("sleep_guard_failed") }
            }
        case 0xe0000300, 0xe0000290: // HasPoweredOn / WillNotSleep
            do {
                let guarded = try fence.wake { try Self.closeBarrier() }
                RuntimeLog.shared.info(guarded ? "mimo_wake_guard_closed" : "mimo_direct_wake_prepared")
                Task { @MainActor in changed("wake") }
            } catch {
                RuntimeLog.shared.error("mimo_wake_guard_failed", fields: ["error": error.localizedDescription])
                Task { @MainActor in changed("wake_guard_failed") }
            }
        default: break
        }
    }

    static func closeBarrier(request: MimoGateRequest? = nil) throws {
        try closeBarrier(request: request) {
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", anchor, "-sr"])
            let status = BoundedProcess.run("/sbin/pfctl", ["-s", "info"])
            guard live.status == 0, MimoFirewallPolicy.isClosedReadback(live.text),
                  status.status == 0, status.text.contains("Status: Enabled") else {
                throw MimoRuntimeError.unavailable("The transition barrier could not be confirmed.")
            }
        }
    }

    /// Keep priority and mutation through the caller's readback/publication.
    /// A background scanner cannot slip between denial and its confirmation.
    static func closeBarrier<Value>(request: MimoGateRequest?, confirm: () throws -> Value) throws -> Value {
        var timing = MimoTransitionTiming("deny")
        return try MimoFirewallLock.mutate(revoking: true) {
            timing.record("deny_mutation_wait")
            guard request?.isCancelled != true else { throw CancellationError() }
            // One atomic root replacement also revokes private-probe access.
            try command(["-a", anchor, "-f", "-"], input: Data(MimoFirewallPolicy.startupBlocking.utf8))
            timing.record("deny_barrier")
            try revokeOutboundStates()
            timing.record("deny_states")
            return try confirm()
        }
    }

    static func revokeOutboundStates() throws {
        let result = BoundedProcess.run("/sbin/pfctl", ["-ss"], timeout: 2, outputLimit: 1_048_576)
        guard result.status == 0 else {
            throw MimoRuntimeError.unavailable("Outbound connection revocation could not be confirmed. Incoming sessions were retained.")
        }
        for source in try MimoFirewallPolicy.outboundStateSources(result.text) {
            try command(["-k", source])
        }
    }

    private static func command(_ arguments: [String], input: Data? = nil) throws {
        guard BoundedProcess.run("/sbin/pfctl", arguments, timeout: 2, input: input).status == 0 else {
            throw MimoRuntimeError.unavailable("The power-state firewall barrier could not be updated.")
        }
    }
}
