import Darwin
import Foundation

/// Native socket rules have their own execution path. Waiting for the
/// supervisor's main actor can outlive a new Tailscale connection attempt.
final class MimoNativeTransportWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var installed: String?
    private let healthLock = NSLock()
    private var updateFailed = false
    private var lastSuccess: ContinuousClock.Instant?

    var isHealthy: Bool { healthLock.withLock { !updateFailed } }
    func hasObservation(since instant: ContinuousClock.Instant) -> Bool {
        healthLock.withLock { !updateFailed && lastSuccess.map { $0 >= instant } == true }
    }

    func update(_ transport: MimoNativeTransport) throws {
        try lock.withLock {
            do {
                try apply(transport)
                healthLock.withLock { updateFailed = false; lastSuccess = .now }
            } catch {
                healthLock.withLock { updateFailed = true }
                throw error
            }
        }
    }

    private func apply(_ transport: MimoNativeTransport) throws {
        let rules = try transport.render()
        let directory = MimoRuntime.directory
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
            throw MimoRuntimeError.unavailable("The native transport runtime directory is unsafe.")
        }
        // This sub-anchor has its own atomic PF transaction. Parent-gate work
        // (including networksetup/profile recovery) must not postpone short-
        // lived native sockets. The parent decides whether this anchor is
        // reachable; Direct and the startup/sleep barriers grant no access
        // through it. Direct cleanup uses this writer too, under this lock.
        let firewall = try MimoFirewallLock.acquire(at: directory.appendingPathComponent("native-transport.lock"))
        try withExtendedLifetime(firewall) {
            guard rules != installed else { return }
            let anchor = MimoFirewallPolicy.anchor + "/native-transport"
            let data = Data(rules.utf8)
            for arguments in [["-n", "-a", anchor, "-f", "-"], ["-a", anchor, "-f", "-"]] {
                let apply = {
                    let result = BoundedProcess.run("/sbin/pfctl", arguments, timeout: 3, captureError: true, input: data)
                    guard result.status == 0 else {
                        RuntimeLog.shared.error("mimo_native_transport_write_failed", fields: [
                            "stage": arguments.contains("-n") ? "validate" : "apply", "status": String(result.status)
                        ])
#if MIMO_VM_ACCEPTANCE
                        RuntimeLog.shared.error("mimo_vm_native_write_diagnostic", fields: ["detail": result.text])
#endif
                        throw MimoRuntimeError.unavailable("Native transport firewall rules could not be updated.")
                    }
                }
                // Immutable stdin syntax validation does not mutate PF.
                if arguments.contains("-n") { try apply() }
                else { try MimoFirewallLock.mutate(apply) }
            }
            installed = rules
        }
    }
}
