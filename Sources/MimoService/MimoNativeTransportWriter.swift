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
    private var lastTransport: MimoNativeTransport?

    var isHealthy: Bool { healthLock.withLock { !updateFailed } }
    func hasObservation(since instant: ContinuousClock.Instant) -> Bool {
        healthLock.withLock { !updateFailed && lastSuccess.map { $0 >= instant } == true }
    }

    func preparedTransport(since instant: ContinuousClock.Instant) -> MimoNativeTransport? {
        healthLock.withLock {
            guard !updateFailed, lastSuccess.map({ $0 >= instant }) == true else { return nil }
            return lastTransport
        }
    }

    func update(_ transport: MimoNativeTransport) throws {
        try lock.withLock {
            do {
                let served: TailscaleVergeStatus.Served = transport.interface.map { .direct(interface: $0) } ?? .reject(reason: "native-transport-unavailable")
                let provider = Data(NativeProviderProtocol.yaml(served).utf8)
                try apply(transport)
                // Publish the exact interface whose native firewall rules just
                // succeeded. The core's diagnostic HTTP provider is independent
                // and must not race this runtime file with a different probe.
                try publishProvider(provider, interface: transport.interface)
                healthLock.withLock { updateFailed = false; lastTransport = transport; lastSuccess = .now }
            } catch {
                healthLock.withLock { updateFailed = true }
                throw error
            }
        }
    }

    private func publishProvider(_ bytes: Data, interface: String?) throws {
        let file = TailscaleVergeProvider.runtimeProviderFileURL
        let directory = file.deletingLastPathComponent()
        for parent in [MimoRuntime.profileDirectory.deletingLastPathComponent(), MimoRuntime.profileDirectory] {
            var info = stat()
            guard lstat(parent.path, &info) == 0, info.st_uid == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
                throw MimoRuntimeError.unavailable("The native provider directory is unsafe.")
            }
        }
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw MimoRuntimeError.unavailable("The native provider directory cannot be inspected.") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory.path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw MimoRuntimeError.unavailable("The native provider directory is unsafe.")
        }
        if lstat(file.path, &info) == 0 {
            guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0 else {
                throw MimoRuntimeError.unavailable("The native provider file is unsafe.")
            }
            if try Data(contentsOf: file) == bytes { return }
        } else if errno != ENOENT {
            throw MimoRuntimeError.unavailable("The native provider file cannot be inspected.")
        }
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .ownerAccountID: 0], ofItemAtPath: file.path)
        RuntimeLog.shared.info("mimo_native_provider_published", fields: ["interface": interface ?? "", "state": interface == nil ? "reject" : "direct"])
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
