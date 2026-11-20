import Foundation

/// Firewall transitions span several short child processes. Another privileged
/// command may arrive during one; wait briefly without bypassing the kernel lock.
enum MimoFirewallLock {
    /// Separate from the lifecycle lock: only bounded PF transactions belong
    /// here. Native updates and independent power/deadline revocation share it.
    static func mutate<T>(_ operation: () throws -> T) throws -> T {
        let lock = try acquire(at: MimoRuntime.directory.appendingPathComponent("pf-mutation.lock"), timeout: .seconds(2))
        return try withExtendedLifetime(lock, operation)
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
