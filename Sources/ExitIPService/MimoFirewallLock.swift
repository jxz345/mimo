import Foundation

/// Firewall transitions span several short child processes. Another privileged
/// command may arrive during one; wait briefly without bypassing the kernel lock.
enum MimoFirewallLock {
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
