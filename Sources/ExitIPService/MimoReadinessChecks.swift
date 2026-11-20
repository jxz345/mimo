import Foundation

/// Read-only system commands have separate bounded workers, so controller,
/// installation and socket inspection can overlap the core's exit-IP request.
/// They never mutate the firewall, profile or DNS configuration.
final class MimoReadinessChecks: Sendable {
    private let installation = MimoBlockingWorkQueue("com.mimo.check-installation")
    private let config = MimoBlockingWorkQueue("com.mimo.check-config")
    private let rules = MimoBlockingWorkQueue("com.mimo.check-rules")
    private let proxies = MimoBlockingWorkQueue("com.mimo.check-proxies")
    private let dns = MimoBlockingWorkQueue("com.mimo.check-dns")

    func validateInstallation(_ operation: @escaping @Sendable () throws -> Void) async throws {
        guard let result = await installation.run({ Result { try operation() } }) else { throw CancellationError() }
        try result.get()
    }

    func controller(_ path: String) async throws -> Data {
        let queue: MimoBlockingWorkQueue
        switch path {
        case "configs": queue = config
        case "rules": queue = rules
        case "proxies": queue = proxies
        default: throw DaemonFailure.invalidRequest
        }
        guard let result = await queue.run({
            BoundedProcess.run("/usr/bin/curl", ["--silent", "--fail", "--max-time", "2",
                "--unix-socket", MimoRuntime.controller.path, "http://localhost/\(path)"], timeout: 3)
        }) else { throw CancellationError() }
        guard result.status == 0, let data = result.text.data(using: .utf8) else {
            throw MimoRuntimeError.unavailable("Mihomo controller verification failed.")
        }
        return data
    }

    func listeners(process: Int32) async throws -> Bool {
        guard let result = await dns.run({
            for transport in ["TCP", "UDP"] {
                var args = ["-nP", "-a", "-p", String(process), "-i\(transport):\(MimoRuntime.dnsPort)", "-Fn"]
                if transport == "TCP" { args += ["-sTCP:LISTEN"] }
                let result = BoundedProcess.run("/usr/sbin/lsof", args)
                guard result.status == 0,
                      result.text.split(separator: "\n").contains("n127.0.0.1:\(MimoRuntime.dnsPort)") else { return false }
            }
            let tunnel = BoundedProcess.run("/sbin/ifconfig", [MihomoProfile.tunnelDevice])
            return tunnel.status == 0 && tunnel.text.contains("UP")
        }) else { throw CancellationError() }
        return result
    }
}

/// An in-memory receipt for this exact profile and engine. The supervisor also
/// checks the configuration/network/session attempt before consuming it.
struct MimoReadinessReceipt: Sendable {
    let process: Int32
    let profileDigest: Data
    let checkedAt: ContinuousClock.Instant
}
