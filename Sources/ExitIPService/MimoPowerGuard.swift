import Foundation
import IOKit.pwr_mgt

/// Shared by the independent IOKit queue and the supervisor. An approval from
/// before sleep must never release the sleep barrier, even if its XPC reply is late.
final class MimoPowerFence: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var sleeping = false
    private var protected = false

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

    func wake() { lock.withLock { sleeping = false; epoch &+= 1 } }

    func activate(epoch candidate: UInt64, operation: () throws -> Void) throws {
        try lock.withLock {
            guard protected, !sleeping, candidate == epoch else {
                throw MimoRuntimeError.unavailable("Power state changed. A fresh IP verification is required.")
            }
            try operation()
        }
    }

    func direct(operation: () throws -> Void) throws {
        try lock.withLock {
            try operation()
            protected = false
            epoch &+= 1
        }
    }
}

/// IOKit delivery has its own queue. Profile loading and core XPC cannot delay
/// the pre-sleep barrier. The sub-anchor remains closed on wake until a new
/// verification explicitly releases it under the same power-state lock.
final class MimoPowerGuard: @unchecked Sendable {
    static let anchor = MimoFirewallPolicy.anchor + "/power-guard"
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
                    try Self.command(["-a", Self.anchor, "-f", "-"], input: Data(MimoFirewallPolicy.startupBlocking.utf8))
                    try Self.command(["-k", "0.0.0.0/0"])
                    try Self.command(["-k", "::/0"])
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
            fence.wake()
            Task { @MainActor in changed("wake") }
        default: break
        }
    }

    static func clear() throws { try command(["-a", anchor, "-F", "rules"]) }

    private static func command(_ arguments: [String], input: Data? = nil) throws {
        guard BoundedProcess.run("/sbin/pfctl", arguments, timeout: 2, input: input).status == 0 else {
            throw MimoRuntimeError.unavailable("The power-state firewall barrier could not be updated.")
        }
    }
}
