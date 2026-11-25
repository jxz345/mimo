import Foundation

/// Firewall transitions span several short child processes. Another privileged
/// command may arrive during one; wait briefly without bypassing the kernel lock.
enum MimoFirewallLock {
    /// Separate from the lifecycle lock: only bounded PF transactions belong
    /// here. Native updates and independent power/deadline revocation share it.
    static func mutate<T>(revoking: Bool = false, _ operation: () throws -> T) throws -> T {
        let priority = MimoRuntime.directory.appendingPathComponent("pf-revocation.lock")
        let mutation = MimoRuntime.directory.appendingPathComponent("pf-mutation.lock")
        if revoking {
            // Hold admission while waiting: later grants/ordinary writers yield.
            // This cannot interrupt a running pfctl. Wait longer than the bounded
            // normal transaction, rather than abandoning denial after two seconds.
            let admission = try acquire(at: priority, timeout: .seconds(60))
            return try withExtendedLifetime(admission) {
                let lock = try acquire(at: mutation, timeout: .seconds(30))
                return try withExtendedLifetime(lock) {
                    try stampMutation(revoking: true)
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
                    try stampMutation()
                    return try operation()
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while ContinuousClock.now < deadline
        throw MimoRuntimeError.unavailable("Firewall revocation or another mutation is pending. Retry shortly.")
    }

    /// Written under mutation before touching PF. The checker reads rules without
    /// holding the lock, then rejects its snapshot if this token changed. Kernel
    /// flock plus the token also detects a writer that crashes during its operation.
    private static func stampMutation(revoking: Bool = false) throws {
        if revoking {
            let closed = MimoRuntime.directory.appendingPathComponent("pf-close.epoch")
            try Data(UUID().uuidString.utf8).write(to: closed, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: closed.path)
        }
        let url = MimoRuntime.directory.appendingPathComponent("pf-mutation.epoch")
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
