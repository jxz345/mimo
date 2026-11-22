import Darwin
import Foundation

/// Publish a verified native interface without adding a second routing policy
/// in PF. Publication remains serialized and fenced against stale observations.
final class MimoNativeTransportWriter: @unchecked Sendable {
    private let lock = NSLock()
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
                // The profile owns native routing. Provider updates never write
                // PF rules, and the core cannot publish a conflicting observation.
                if let interface = transport.interface {
                    guard interface != MihomoProfile.tunnelDevice, interface.hasPrefix("utun"),
                          !interface.dropFirst(4).isEmpty, interface.dropFirst(4).allSatisfy(\.isNumber) else { throw DaemonFailure.invalidRequest }
                }
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

}
