import Foundation

/// Acquisition congestion is distinct from a failed PF command/readback. A
/// background native-policy audit may defer it without starting exit recovery.
struct MimoFirewallLockBusy: LocalizedError {
    var errorDescription: String? { "Firewall revocation or another mutation is pending. Retry shortly." }
}

/// Firewall transitions span several short child processes. Another privileged
/// command may arrive during one; wait briefly without bypassing the kernel lock.
enum MimoFirewallLock {
    /// Separate from the lifecycle lock: only bounded PF transactions belong
    /// here. Native updates and independent power/deadline revocation share it.
    static func mutate<T>(revoking: Bool = false, directory: URL = MimoRuntime.directory,
                          admitting: () throws -> Void = {}, _ operation: () throws -> T) throws -> T {
        try withLock(revoking: revoking, directory: directory) {
            // A stale worker must not even invalidate a newer audit/closure epoch.
            try admitting()
            try stampMutation(revoking: revoking, directory: directory)
            return try operation()
        }
    }

    /// Read without advancing mutation/closure epochs or touching packet policy.
    static func read<T>(_ operation: () throws -> T) throws -> T {
        try withLock(revoking: false, directory: MimoRuntime.directory, operation)
    }

    /// Inspect under the same lock, but invalidate concurrent audit snapshots
    /// only when a write is actually needed. A no-op is not a PF mutation.
    static func mutateIfNeeded(directory: URL = MimoRuntime.directory,
                               when needed: () throws -> Bool, operation: () throws -> Void) throws {
        try withLock(revoking: false, directory: directory) {
            guard try needed() else { return }
            try stampMutation(directory: directory)
            try operation()
        }
    }

    private static func withLock<T>(revoking: Bool, directory: URL, _ operation: () throws -> T) throws -> T {
        let priority = directory.appendingPathComponent("pf-revocation.lock")
        let mutation = directory.appendingPathComponent("pf-mutation.lock")
        if revoking {
            // Hold admission while waiting: later grants/ordinary writers yield.
            // This cannot interrupt a running pfctl. Wait longer than the bounded
            // normal transaction, rather than abandoning denial after two seconds.
            let admission = try acquire(at: priority, timeout: .seconds(60))
            return try withExtendedLifetime(admission) {
                let lock = try acquire(at: mutation, timeout: .seconds(30))
                return try withExtendedLifetime(lock) {
                    return try operation()
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            // Never hold admission while an ordinary writer waits for mutation.
            // Release it before executing so revocation can announce priority.
            let lock: SingleInstanceLock? = try {
                guard let admission = try SingleInstanceLock(url: priority) else { return nil }
                return try withExtendedLifetime(admission) { try SingleInstanceLock(url: mutation) }
            }()
            if let lock {
                return try withExtendedLifetime(lock) {
                    return try operation()
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while ContinuousClock.now < deadline
        throw MimoFirewallLockBusy()
    }

    /// Written under mutation before touching PF. The checker reads rules without
    /// holding the lock, then rejects its snapshot if this token changed. Kernel
    /// flock plus the token also detects a writer that crashes during its operation.
    private static func stampMutation(revoking: Bool = false, directory: URL) throws {
        if revoking {
            let closed = directory.appendingPathComponent("pf-close.epoch")
            try Data(UUID().uuidString.utf8).write(to: closed, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: closed.path)
        }
        let url = directory.appendingPathComponent("pf-mutation.epoch")
        try Data(UUID().uuidString.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func acquire(at url: URL, timeout: Duration = .seconds(5)) throws -> SingleInstanceLock {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if let lock = try SingleInstanceLock(url: url) { return lock }
            guard ContinuousClock.now < deadline else { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        throw MimoRuntimeError.unavailable("Another firewall transition did not finish. Retry shortly.")
    }
}
