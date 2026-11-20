import Foundation

/// Read-only system commands have separate bounded workers, so controller,
/// installation and socket inspection can overlap the core's exit-IP request.
/// They never mutate the firewall, profile or DNS configuration.
final class MimoReadinessChecks: Sendable {
    private let installation = MimoBlockingWorkQueue("com.mimo.check-installation")
    private let config = MimoBlockingWorkQueue("com.mimo.check-config")
    private let rules = MimoBlockingWorkQueue("com.mimo.check-rules")
    private let proxies = MimoBlockingWorkQueue("com.mimo.check-proxies")
    private let identity = MimoBlockingWorkQueue("com.mimo.check-engine-identity")
    private let dns = MimoBlockingWorkQueue("com.mimo.check-dns")

    func inspect(profile: String, proxy: ClashProxySettings, process: Int32, digest: Data,
                 installation: Task<Void, Error>, recordTiming: Bool,
                 currentProcess: @escaping @Sendable () -> Int32?) async throws -> MimoReadinessReceipt {
        var timing = MimoTransitionTiming("readiness")
        let checkedAt = ContinuousClock.now
        if recordTiming { RuntimeLog.shared.info("mimo_runtime_inspection_started") }
        async let configData = controller("configs")
        async let rulesData = controller("rules")
        async let proxiesData = controller("proxies")
        async let sockets = listeners(process: process)
        async let engine = identity.run { currentProcess() == process }
        try await installation.value
        let (config, rules, proxies, listenersReady, sameEngine) = try await (configData, rulesData, proxiesData, sockets, engine)
        try Task.checkCancellation()
        func object(_ data: Data) throws -> [String: Any] {
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MimoRuntimeError.unavailable("Mihomo controller returned an invalid inspection.")
            }
            return result
        }
        guard listenersReady, sameEngine == true,
              MihomoRuntimeInspection.matches(profile: profile, active: true, proxy: MimoProxy(proxy),
                config: try object(config), rules: try object(rules)["rules"] as? [[String: Any]] ?? [],
                proxies: try object(proxies)["proxies"] as? [String: Any] ?? [:]) else {
            throw MimoRuntimeError.unavailable("The final profile, tunnel or protected DNS could not be confirmed.")
        }
        if recordTiming { timing.record("critical_checks") }
        return MimoReadinessReceipt(process: process, profileDigest: digest, checkedAt: checkedAt)
    }

    func validateInstallation(_ operation: @escaping @Sendable () throws -> Void) async throws {
        guard let result = await installation.run({ Result {
            var timing = MimoTransitionTiming("installation")
            try operation()
            timing.record("installation_inspection")
        } }) else { throw CancellationError() }
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
