import CryptoKit
import Darwin
import Foundation

enum MimoRuntimeError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

struct MimoPFReference: Codable {
    let token: String
    let boot: String

    static func isLive(_ token: String, references: String) -> Bool {
        references.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 3 && fields[0].allSatisfy(\.isNumber) && fields[2] == token
        }
    }

    func token(forBoot currentBoot: String) throws -> String? {
        guard !token.isEmpty, token.count <= 32, token.utf8.allSatisfy({ (48...57).contains($0) }),
              UUID(uuidString: boot) != nil, UUID(uuidString: currentBoot) != nil else {
            throw MimoRuntimeError.unavailable("The saved firewall reference is invalid. Repair installation.")
        }
        return boot == currentBoot ? token : nil
    }
}

/// Immutable rules that passed PF syntax validation on the preparation worker.
/// Only this file can construct a receipt; no XPC caller supplies rules or proof.
struct MimoPreparedProbePolicy: Sendable, Equatable {
    fileprivate let rules: String
    fileprivate let group: UInt32
    fileprivate let activeRules: String?
}

/// Fixed-path privileged operations. No caller supplies a command, YAML, or executable path.
@MainActor
final class MimoSystemRuntime {
    private nonisolated let directory = MimoRuntime.directory
    private nonisolated var group: UInt32 {
        getgrnam(MimoRuntime.engineGroup).map { $0.pointee.gr_gid } ?? UInt32.max
    }
    private(set) var closed = false
    private var enableToken: String?
    private var loadedProfile: (digest: SHA256.Digest, process: Int32, started: String)?
    private var deliveredContents: String?
    private var installedPolicy: MimoPreparedProbePolicy?
    private var verifiedBaseline: (digest: Data, process: Int32)?
    private var expectedPolicies: [String: String] = [:]
    private nonisolated let nativeTransportWriter = MimoNativeTransportWriter()
    private let dns = MimoDNSConfiguration()
    nonisolated let readinessChecks = MimoReadinessChecks()
    private nonisolated let controllerLock = NSLock()
    private let cleanupQueue = MimoBlockingWorkQueue("com.mimo.clear-connections", qos: .userInitiated)
    private var cleanupRequest: (token: MimoGateRequest, task: Task<Void, Error>)?
    private nonisolated let firewallPreparationQueue = MimoBlockingWorkQueue("com.mimo.prepare-firewall")
    private nonisolated let applicationGate = MimoApplicationGate()
    private let infrastructureQueue = MimoBlockingWorkQueue("com.mimo.infrastructure-check")
    var profileWillChange: (() -> Void)?
    var profileDidChange: (() -> Void)?
    var maintenanceActive: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("maintenance").path) }

    private var infrastructureRepairPending: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("infrastructure-repair").path)
    }

    func ensureIndependentBootGuard() throws {
        try secureDirectory(MimoRuntime.guardDirectory)
        try secureFile(MimoRuntime.guardScript)
        try command("/usr/bin/perl", [MimoRuntime.guardScript.path, "--boot"], timeout: 20)
    }

    /// The same fixed checker also runs from its own system launchd job, so a
    /// missing supervisor cannot disable infrastructure inspection and repair.
    func repairInfrastructure() async throws -> Bool {
        try secureDirectory(MimoRuntime.guardDirectory)
        try secureFile(MimoRuntime.guardScript)
        guard let result = await infrastructureQueue.run({
            BoundedProcess.run("/usr/bin/perl", [MimoRuntime.guardScript.path, "--check"], timeout: 25, captureError: true)
        }) else { throw CancellationError() }
        try Task.checkCancellation()
        if result.status == 75 {
            RuntimeLog.shared.info("mimo_infrastructure_check_deferred", fields: ["reason": "pf_snapshot_changed_or_revocation"])
            return false
        }
        guard result.status == 0 else {
            RuntimeLog.shared.error("mimo_infrastructure_check_failed", fields: [
                "status": String(result.status), "detail": String(result.text.prefix(512))
            ])
            throw MimoRuntimeError.unavailable("Firewall or startup services need repair. Protected access remains closed.")
        }
        if result.text.split(separator: "\n").contains("repaired") {
            RuntimeLog.shared.info("mimo_infrastructure_repaired", fields: ["gate": gateState ?? "unknown"])
        }
        return true
    }

    func enforceIPv4Policy() throws {
        try withFirewallLock { try MimoIPv4Configuration.apply() }
    }

    func infrastructureStatus() -> MimoInfrastructureStatus {
        struct Record: Decodable {
            var boot: String
            var checkedAt: Double
            var pf: String
            var launchd: String
        }
        do {
            let path = MimoRuntime.guardDirectory.appendingPathComponent("health.json")
            try secureDirectory(MimoRuntime.guardDirectory)
            try secureFile(path)
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: path))
            guard record.boot == (try bootIdentifier()), record.checkedAt.isFinite else { return .init() }
            return MimoInfrastructureStatus(pf: record.pf == "enabled" ? .healthy : .failed,
                launchd: record.launchd == "healthy" ? .healthy : .failed,
                checkedAt: Date(timeIntervalSince1970: record.checkedAt)).current(at: .now)
        } catch { return .init() }
    }

    var gateState: String? {
        let url = directory.appendingPathComponent("gate.state")
        guard (try? secureFile(url)) != nil else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func servicePreferences() throws -> MimoServicePreferences {
        let url = directory.appendingPathComponent("services.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return MimoServicePreferences() }
        try secureFile(url)
        return try JSONDecoder().decode(MimoServicePreferences.self, from: Data(contentsOf: url))
    }

    func saveServicePreferences(_ preferences: MimoServicePreferences) throws {
        // The independent checker reads intent and repairs jobs under this same
        // lock. A saved Stop must supersede any repair already in progress.
        try withFirewallLock {
            _ = try writePrivate(JSONEncoder().encode(preferences), name: "services.json")
        }
    }

    func savedConfiguration() throws -> MimoConfiguration {
        try savedRouting().configuration
    }

    func savedTailnetEnabled() throws -> Bool {
        guard FileManager.default.fileExists(atPath: ExitIPService.storageURL.path) else { return false }
        try secureFile(ExitIPService.storageURL)
        let storage = try FilePreferenceStorage(url: ExitIPService.storageURL)
        guard let data = storage.data(forKey: "service.settings") else { return false }
        return try JSONDecoder().decode(MachineSettings.self, from: data).validated().tailscaleProviderEnabled
    }

    nonisolated func updateNativeTransport(_ value: MimoNativeTransport) throws {
        try nativeTransportWriter.update(value)
    }

    nonisolated var nativeTransportIsHealthy: Bool { nativeTransportWriter.isHealthy }

    func savedRouting() throws -> (configuration: MimoConfiguration, revision: Int) {
        guard FileManager.default.fileExists(atPath: ExitIPService.storageURL.path) else { return (MimoConfiguration(), 0) }
        try secureFile(ExitIPService.storageURL)
        let storage = try FilePreferenceStorage(url: ExitIPService.storageURL)
        let configuration: MimoConfiguration
        if let data = storage.data(forKey: "service.routing") {
            configuration = try JSONDecoder().decode(MimoConfiguration.self, from: data).validated()
        } else { configuration = MimoConfiguration() }
        return (configuration, storage.integer(forKey: "service.revision"))
    }

    func persistDirectRecovery() throws -> MimoConfiguration {
        let directory = ExitIPService.storageURL.deletingLastPathComponent()
        try secureDirectory(ExitIPService.support)
        try secureDirectory(directory)
        guard let lock = try SingleInstanceLock(url: directory.appendingPathComponent("instance.lock")) else {
            throw MimoRuntimeError.unavailable("Core still owns its settings. Direct recovery was not applied.")
        }
        return try withExtendedLifetime(lock) {
            if FileManager.default.fileExists(atPath: ExitIPService.storageURL.path) { try secureFile(ExitIPService.storageURL) }
            return try MimoRecoveryState.commitDirect(storage: FilePreferenceStorage(url: ExitIPService.storageURL))
        }
    }

    nonisolated func checkInstallation() throws {
        guard geteuid() == 0, group != UInt32.max else { throw MimoRuntimeError.unavailable("Repair the Mimo service installation.") }
        let users = BoundedProcess.run("/usr/bin/dscl", ["/Search", "-search", "/Users", "PrimaryGroupID", String(group)])
        let groups = BoundedProcess.run("/usr/bin/dscl", ["/Search", "-list", "/Groups", "PrimaryGroupID"])
        let matchingGroups = groups.text.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace) }
            .filter { $0.last == Substring(String(group)) }
        guard users.status == 0, users.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              groups.status == 0, matchingGroups.count == 1, matchingGroups[0].count == 2,
              matchingGroups[0].first == Substring(MimoRuntime.engineGroup),
              let record = getgrnam(MimoRuntime.engineGroup), record.pointee.gr_mem.pointee == nil else {
            throw MimoRuntimeError.unavailable("The private runtime group is shared with another account or group. Repair installation.")
        }
        try secureDirectory(ExitIPService.support)
        try secureDirectory(directory)
        try secureDirectory(MimoRuntime.profileDirectory.deletingLastPathComponent())
        try secureDirectory(MimoRuntime.profileDirectory)
        try secureFile(MimoRuntime.engine, executable: true)
        let manifest = directory.appendingPathComponent("engine.sha256")
        try secureFile(manifest)
        let expected = try String(contentsOf: manifest, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = SHA256.hash(data: try Data(contentsOf: MimoRuntime.engine)).map { String(format: "%02x", $0) }.joined()
        guard expected == actual else { throw MimoRuntimeError.unavailable("The staged mihomo checksum does not match. Repair installation.") }
        let result = BoundedProcess.run(MimoRuntime.engine.path, ["-v"])
        guard result.status == 0, result.text.contains("Mihomo Meta v\(MimoRuntime.version) ") else {
            throw MimoRuntimeError.unavailable("Install the pinned mihomo \(MimoRuntime.version) dependency.")
        }
    }


#if MIMO_VM_ACCEPTANCE
    static func requireAcceptanceVM() throws {
        let hardware = BoundedProcess.run("/usr/sbin/sysctl", ["-n", "hw.model"])
        guard geteuid() == 0, hardware.status == 0, hardware.text.hasPrefix("VirtualMac") else {
            throw MimoRuntimeError.unavailable("VM-only acceptance runtime requires the isolated macOS guest.")
        }
    }
#endif

    nonisolated func writePrivate(_ data: Data, name: String) throws -> URL {
        try writePrivate(data, name: name, directory: directory)
    }

    func writeBlockingProfile() throws {
        try secureDirectory(MimoRuntime.profileDirectory.deletingLastPathComponent())
        _ = try writePrivate(Data(MihomoProfile.blocking().utf8), name: "blocking.yaml", directory: MimoRuntime.profileDirectory)
    }

    private nonisolated func writePrivate(_ data: Data, name: String, directory: URL) throws -> URL {
        try secureDirectory(directory)
        let url = directory.appendingPathComponent(name)
        guard !name.contains("/"), !name.contains("..") else { throw DaemonFailure.invalidRequest }
        if FileManager.default.fileExists(atPath: url.path) { try secureFile(url) }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .ownerAccountID: 0], ofItemAtPath: url.path)
        return url
    }

    func cachedProbePolicy(endpoints: [String], proxyPort: Int?, mode: ProxyMode) throws -> MimoPreparedProbePolicy? {
        guard let installedPolicy else { return nil }
        let rules = try MimoFirewallPolicy.preparedPolicy(group: group, endpoints: endpoints, proxyPort: proxyPort)
        let active = endpoints.isEmpty ? nil : try MimoFirewallPolicy.preparedPolicy(group: group, endpoints: endpoints, proxyPort: proxyPort, mode: mode)
        return installedPolicy.rules == rules && installedPolicy.activeRules == active ? installedPolicy : nil
    }

    private func processIdentity(_ process: Int32) throws -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, size) == size else { throw DaemonFailure.unavailable }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    nonisolated func prepareProbePolicy(endpoints: [String], proxyPort: Int?, mode: ProxyMode) async throws -> MimoPreparedProbePolicy {
        guard let result = await firewallPreparationQueue.run({ Result {
            var timing = MimoTransitionTiming("firewall_preparation")
            let runtimeGroup = self.group
            guard runtimeGroup != UInt32.max, endpoints.allSatisfy({ !$0.contains(":") }) else {
                throw MimoRuntimeError.unavailable("A dedicated runtime group and IPv4 endpoint are required.")
            }
            let rules = try MimoFirewallPolicy.preparedPolicy(group: runtimeGroup, endpoints: endpoints, proxyPort: proxyPort)
            let active = endpoints.isEmpty ? nil : try MimoFirewallPolicy.preparedPolicy(group: runtimeGroup, endpoints: endpoints, proxyPort: proxyPort, mode: mode)
            timing.record("rule_generation")
            // -n checks syntax only. Immutable stdin bytes avoid shared-file
            // races with a concurrent close, Direct action or another attempt.
            for (name, bytes) in [("probe-policy", rules), ("open-policy", active ?? "")] {
                try self.command("/sbin/pfctl", ["-n", "-a", MimoFirewallPolicy.anchor + "/" + name, "-f", "-"], input: Data(bytes.utf8))
            }
            timing.record("rule_validation")
            return MimoPreparedProbePolicy(rules: rules, group: runtimeGroup, activeRules: active)
        } }) else { throw CancellationError() }
        return try result.get()
    }

    func installProbePolicy(_ policy: MimoPreparedProbePolicy) throws {
        guard closed, !maintenanceActive, !infrastructureRepairPending, policy.group == group else {
            throw MimoRuntimeError.unavailable("Blocking or the prepared firewall policy changed before installation.")
        }
        var timing = MimoTransitionTiming("firewall")
        if installedPolicy != policy {
            verifiedBaseline = nil
            try withFirewallLock {
                try MimoFirewallLock.mutate {
                    for (name, rules) in [("probe-policy", policy.rules), ("open-policy", policy.activeRules ?? "")] {
                        try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor + "/" + name, "-f", "-"], input: Data(rules.utf8))
                        let readback = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor + "/" + name, "-sr"])
                        guard readback.status == 0 else { throw MimoRuntimeError.unavailable("Prepared policy readback failed.") }
                        expectedPolicies[name] = readback.text
                        _ = try writePrivate(Data(readback.text.utf8), name: name + ".expected")
                    }
                }
                try installPF(MimoFirewallPolicy.permissionParent)
                try MimoIPv4Configuration.apply()
                _ = try writePrivate(Data("blocked".utf8), name: "gate.state")
                installedPolicy = policy
            }
        }
        timing.record("install_probe_policy")
    }

    func closeGate(endpoints: [String] = [], proxyPort: Int? = nil) throws {
        closed = false
        try closeGate(rules: MimoFirewallPolicy.render(group: group, endpoints: endpoints, proxyPort: proxyPort), applyIPv4Preferences: true)
    }

    /// Close the small sub-anchor first. Reuse a verified parent policy instead
    /// of replacing it with startup rules and then replacing it again for probing.
    /// A damaged/missing parent always takes the full blocking fallback.
    func requestApplicationGate() -> MimoGateRequest {
        closed = false
        return applicationGate.request { try self.holdGateUnderLock($0) }
    }

    nonisolated func requestEarlyApplicationGate() {
        // A new external event also revokes an earlier private-probe grant.
        // Its completed close request must not be reused as fresh confirmation.
        _ = applicationGate.request(replacing: true) { try self.holdGateUnderLock($0) }
    }

    func confirmApplicationGate(_ token: MimoGateRequest) async throws {
        let held = try await applicationGate.confirm(token)
        guard !closed else { return }
        if held { closed = true }
        else { try closeGate(rules: MimoFirewallPolicy.startupBlocking, applyIPv4Preferences: false, cancelPending: false) }
    }

    func cancelApplicationGate() {
        applicationGate.cancel()
    }

    func holdApplicationGate() throws {
        cancelApplicationGate()
        closed = false
        if try holdGateUnderLock(MimoGateRequest()) { closed = true }
        else { try closeStartupGate() }
    }

    private nonisolated func holdGateUnderLock(_ request: MimoGateRequest) throws -> Bool {
        var timing = MimoTransitionTiming("blocking")
        defer { timing.record("barrier_and_confirmation") }
        // Revocation must not wait behind the independent infrastructure
        // scanner's lifecycle lock. Cancellation is rechecked under the same
        // short PF mutation lock used by Direct's parent replacement.
        guard !request.isCancelled else { throw CancellationError() }
        return try MimoPowerGuard.closeBarrier(request: request) {
            var inspection = MimoTransitionTiming("deny")
            let main = BoundedProcess.run("/sbin/pfctl", ["-sr"])
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            let status = BoundedProcess.run("/sbin/pfctl", ["-s", "info"])
            let expected = directory.appendingPathComponent("guard.expected")
            guard main.status == 0, main.text.contains("anchor \"com.apple/*\""),
                  !main.text.contains("pass out quick"), !main.text.contains("pass quick"),
                  live.status == 0, live.text.contains("anchor \"power-guard\""),
                  live.text.contains("anchor \"permission\""),
                  status.status == 0, status.text.contains("Status: Enabled"),
                  (try? secureFile(expected)) != nil,
                  live.text == (try? String(contentsOf: expected, encoding: .utf8)) else { return false }
            inspection.record("deny_readback")
            guard !request.isCancelled else { throw CancellationError() }
            _ = try writePrivate(Data("blocked".utf8), name: "gate.state")
            inspection.record("deny_publish")
            return true
        }
    }

    func closeStartupGate() throws {
        try closeGate(rules: MimoFirewallPolicy.startupBlocking, applyIPv4Preferences: false)
    }

    private func closeGate(rules: String, applyIPv4Preferences: Bool, cancelPending: Bool = true, validated: MimoPreparedProbePolicy? = nil) throws {
        if cancelPending { cancelApplicationGate() }
        closed = false
        try withFirewallLock {
            _ = try writePrivate(Data("pending".utf8), name: "gate.state")
            try installPF(rules, requiresRuntimeGroup: applyIPv4Preferences, validated: validated)
            // States created before the guard existed must not override the newly closed policy.
            try command("/sbin/pfctl", ["-k", "0.0.0.0/0"])
            try command("/sbin/pfctl", ["-k", "::/0"])
            if applyIPv4Preferences { try MimoIPv4Configuration.apply() }
            _ = try writePrivate(Data("blocked".utf8), name: "gate.state")
            closed = true
        }
    }

    func permitPrivateProbe() throws {
        guard closed, installedPolicy != nil else { throw DaemonFailure.conflict }
        try MimoFirewallLock.mutate {
            guard !maintenanceActive, !infrastructureRepairPending else { throw DaemonFailure.conflict }
            try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.permissionAnchor, "-f", "-"],
                        input: Data(MimoFirewallPolicy.permission(open: false).utf8))
        }
        try MimoPowerGuard.clear()
    }

    func optimisticReceipt(profile: String) -> MimoReadinessReceipt? {
        guard let loadedProfile, let verifiedBaseline,
              verifiedBaseline.digest == Data(loadedProfile.digest), verifiedBaseline.process == loadedProfile.process,
              loadedProfile.digest == SHA256.hash(data: Data(profile.utf8)),
              installedPolicy?.activeRules != nil, nativeTransportIsHealthy, quickNetworkMatches,
              runningProcessID(MimoRuntime.engineLabel) == loadedProfile.process,
              (try? processIdentity(loadedProfile.process)) == loadedProfile.started else { return nil }
        return MimoReadinessReceipt(process: loadedProfile.process, profileDigest: Data(loadedProfile.digest), checkedAt: .now)
    }

    var hasVerifiedBaseline: Bool { verifiedBaseline != nil && installedPolicy?.activeRules != nil }

    /// In-process checks; functional DNS/TUN inspection remains in the full audit.
    private var quickNetworkMatches: Bool {
        if_nametoindex(MihomoProfile.tunnelDevice) != 0 && dns.matches
    }

    func revokeBaseline() { verifiedBaseline = nil }

    nonisolated func auditNative(since instant: ContinuousClock.Instant) async throws {
        while !nativeTransportWriter.hasObservation(since: instant) {
            try Task.checkCancellation()
            guard nativeTransportWriter.isHealthy else {
                throw MimoRuntimeError.unavailable("Native transport rules need recovery.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func acceptBaseline(_ receipt: MimoReadinessReceipt) throws {
        try confirmReadiness(receipt)
        guard receiptIsCurrent(receipt), nativeTransportIsHealthy else { throw DaemonFailure.conflict }
        verifiedBaseline = (receipt.profileDigest, receipt.process)
    }

    func auditPolicies() async throws {
        let expected = expectedPolicies
        guard let result = await firewallPreparationQueue.run({ Result {
            for (name, value) in expected {
                let actual = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor + "/" + name, "-sr"])
                guard actual.status == 0, actual.text == value else {
                    throw MimoRuntimeError.unavailable("A preinstalled firewall policy changed.")
                }
            }
            let root = BoundedProcess.run("/sbin/pfctl", ["-sr"])
            let enabled = BoundedProcess.run("/sbin/pfctl", ["-s", "info"])
            guard root.status == 0, root.text.contains("anchor \"com.apple/*\""),
                  !root.text.contains("pass out quick"), !root.text.contains("pass quick"),
                  enabled.status == 0, enabled.text.contains("Status: Enabled") else {
                throw MimoRuntimeError.unavailable("The effective PF root or enable state changed.")
            }
            let parent = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            let gate = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.permissionAnchor, "-sr"])
            let expectedParent = try String(contentsOf: MimoRuntime.directory.appendingPathComponent("guard.expected"), encoding: .utf8)
            guard parent.status == 0, parent.text == expectedParent,
                  gate.status == 0, gate.text.trimmingCharacters(in: .whitespacesAndNewlines) ==
                    "anchor \"/\(MimoFirewallPolicy.anchor)/open-policy\" out quick all" else {
                throw MimoRuntimeError.unavailable("The active firewall permission changed.")
            }
        } }) else { throw CancellationError() }
        try result.get()
    }

    func openGate(receipt: MimoReadinessReceipt) throws {
        cancelApplicationGate()
        var timing = MimoTransitionTiming("grant")
        // Opening shares only the short PF commit lock. Routine launchd/file
        // inspections must not hold this grant behind the lifecycle lock.
        // Actual repair publishes its marker under this same PF lock before
        // closing the parent or changing a job; a healthy scan clears it.
        try MimoFirewallLock.mutate {
            timing.record("grant_mutation_lock")
            guard !maintenanceActive, !infrastructureRepairPending, closed,
                  installedPolicy?.activeRules != nil, nativeTransportIsHealthy, quickNetworkMatches,
                  receiptIsCurrent(receipt) else {
                throw MimoRuntimeError.unavailable("The runtime is changing or being repaired. Fresh verification is required.")
            }
            timing.record("grant_identity")
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            let expected = try String(contentsOf: directory.appendingPathComponent("guard.expected"), encoding: .utf8)
            let final = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor + "/open-policy", "-sr"])
            guard live.status == 0, live.text == expected, live.text.contains("permission") else {
                throw MimoRuntimeError.unavailable("The default-deny firewall parent changed.")
            }
            guard final.status == 0, final.text == expectedPolicies["open-policy"] else {
                throw MimoRuntimeError.unavailable("The preinstalled final policy changed.")
            }
            timing.record("grant_parent_identity")
            try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.permissionAnchor, "-f", "-"],
                        input: Data(MimoFirewallPolicy.permission(open: true).utf8))
            timing.record("grant_permission")
            _ = try writePrivate(Data("active".utf8), name: "gate.state")
            closed = false
        }
    }

    func restoreDirect(maintenanceRecovery: Bool = false, uninstalling: Bool = false) throws {
        cancelApplicationGate()
        cancelConnectionCleanup()
        try withFirewallLock {
            guard maintenanceRecovery || !maintenanceActive else { throw MimoRuntimeError.unavailable("Service installation is in progress.") }
            _ = try writePrivate(Data("pending".utf8), name: "gate.state")
            if !uninstalling {
                // Saved Direct is already authorized. Release the protected IPv4
                // gate before removing TUN/DNS interception, keeping IPv6 blocked.
                // Do not flush IPv4 connections or wait for an allowlist check.
                try installPF(MimoFirewallPolicy.directIPv4, requiresRuntimeGroup: false)
                try command("/sbin/pfctl", ["-k", "::/0"])
                closed = false
                RuntimeLog.shared.info("mimo_direct_ipv4_released")
            }
            do { try loadProfile(MihomoProfile.blocking()) }
            catch { try changeJobUnderFirewallLock(.mihomo, operation: .stop) }
            profileWillChange?()
            do { try dns.remove() }
            catch { profileDidChange?(); throw error }
            profileDidChange?()
            // These children are unreachable from Direct. Optional cleanup
            // must never route a successful Direct release through close().
            do { try nativeTransportWriter.update(.init()); try MimoPowerGuard.clear() }
            catch { RuntimeLog.shared.info("mimo_direct_cleanup_deferred") }
            if !uninstalling {
                try MimoIPv4Configuration.apply()
                _ = try writePrivate(Data("direct".utf8), name: "gate.state")
                closed = false
                return
            }
            try MimoIPv4Configuration.apply(restoring: true)
            try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-F", "rules"])
            let tokenURL = directory.appendingPathComponent("pf-reference.json")
            enableToken = try currentEnableToken()
            if let token = enableToken {
                try command("/sbin/pfctl", ["-X", token])
                enableToken = nil
            }
            if FileManager.default.fileExists(atPath: tokenURL.path) { try FileManager.default.removeItem(at: tokenURL) }
            _ = try writePrivate(Data("direct".utf8), name: "gate.state")
            closed = false
        }
    }

    func configureProtectedDNS() throws {
        try dns.install(willChange: profileWillChange, didChange: profileDidChange)
        // openGate verifies the live resolver and engine-owned TCP/UDP
        // listeners immediately before activation. Avoid repeating that same
        // inspection here while application traffic is still blocked.
    }

    private func protectedDNSReady() -> Bool {
        guard dns.matches, let process = runningProcessID(MimoRuntime.engineLabel) else { return false }
        for transport in ["TCP", "UDP"] {
            var args = ["-nP", "-a", "-p", String(process), "-i\(transport):\(MimoRuntime.dnsPort)", "-Fn"]
            if transport == "TCP" { args += ["-sTCP:LISTEN"] }
            let result = BoundedProcess.run("/usr/sbin/lsof", args)
            guard result.status == 0, result.text.split(separator: "\n").contains("n127.0.0.1:\(MimoRuntime.dnsPort)") else { return false }
        }
        return true
    }

    private func installPF(_ rules: String, requiresRuntimeGroup: Bool = true, validated: MimoPreparedProbePolicy? = nil) throws {
        if let validated {
            guard requiresRuntimeGroup, validated.rules == rules, validated.group == group else {
                throw MimoRuntimeError.unavailable("The validated firewall rules changed before installation.")
            }
        }
        guard !requiresRuntimeGroup || group != UInt32.max else { throw MimoRuntimeError.unavailable("The dedicated runtime group is missing.") }
        let main = BoundedProcess.run("/sbin/pfctl", ["-sr"])
        guard main.status == 0, main.text.contains("anchor \"com.apple/*\""),
              !main.text.contains("pass out quick"), !main.text.contains("pass quick") else {
            throw MimoRuntimeError.unavailable("PF has no supported application anchor. Keep Direct selected and repair setup.")
        }
        installedPolicy = nil; verifiedBaseline = nil
        let bytes = Data(rules.utf8)
        _ = try writePrivate(bytes, name: "guard.pf")
        if validated == nil {
            try command("/sbin/pfctl", ["-n", "-a", MimoFirewallPolicy.anchor, "-f", "-"], input: bytes)
        }
        // Apply exactly the bytes that were checked, not a mutable file path.
        try MimoFirewallLock.mutate {
            try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: bytes)
        }
        let installed = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
        guard installed.status == 0, !installed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MimoRuntimeError.unavailable("The installed firewall rules could not be read back.")
        }
        _ = try writePrivate(Data(installed.text.utf8), name: "guard.expected")
        RuntimeLog.shared.info("mimo_pf_policy_installed", fields: ["policy": rules == MimoFirewallPolicy.startupBlocking ? "startup" : rules == MimoFirewallPolicy.directIPv4 ? "direct" : rules.contains("pass out quick on \(MihomoProfile.tunnelDevice)") ? "active" : "probe"])

        enableToken = try currentEnableToken()
        let status = BoundedProcess.run("/sbin/pfctl", ["-s", "info"])
        guard status.status == 0 else { throw MimoRuntimeError.unavailable("Could not inspect PF enable state.") }
        if enableToken == nil || !status.text.contains("Status: Enabled") {
            let previous = enableToken
            let result = BoundedProcess.run("/sbin/pfctl", ["-E"], captureError: true)
            guard result.status == 0, let line = result.text.split(separator: "\n").first(where: { $0.contains("Token :") }),
                  let token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), token.allSatisfy(\.isNumber), !token.isEmpty else {
                throw MimoRuntimeError.unavailable("Could not acquire the PF enable reference.")
            }
            enableToken = token
            let reference = MimoPFReference(token: token, boot: try bootIdentifier())
            _ = try writePrivate(JSONEncoder().encode(reference), name: "pf-reference.json")
            if let previous { try command("/sbin/pfctl", ["-X", previous]) }
        }
    }

    private func currentEnableToken() throws -> String? {
        let url = directory.appendingPathComponent("pf-reference.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try secureFile(url)
        guard let token = try JSONDecoder().decode(MimoPFReference.self, from: Data(contentsOf: url)).token(forBoot: bootIdentifier()) else { return nil }
        let references = BoundedProcess.run("/sbin/pfctl", ["-s", "References"])
        guard references.status == 0,
              references.text.contains("TOKENS:") || references.text.trimmingCharacters(in: .whitespacesAndNewlines) == "No pf starter references held" else {
            throw MimoRuntimeError.unavailable("Could not inspect PF enable references.")
        }
        // pfctl -d clears references even within the same boot. Another owner
        // can re-enable PF before us; never release or reuse our stale token.
        return MimoPFReference.isLive(token, references: references.text) ? token : nil
    }

    private func bootIdentifier() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0, size < 256 else {
            throw MimoRuntimeError.unavailable("The current boot identifier is unavailable.")
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            throw MimoRuntimeError.unavailable("The current boot identifier is unavailable.")
        }
        return String(cString: bytes)
    }

    func canReuseProfile(_ profile: String) -> Bool {
        guard let loadedProfile else { return false }
        return loadedProfile.digest == SHA256.hash(data: Data(profile.utf8)) &&
            loadedProfile.process == runningProcessID(MimoRuntime.engineLabel)
    }

    func loadProfile(_ profile: String) throws {
        try controllerLock.withLock { try loadProfileUnderControllerLock(profile) }
    }

    private func loadProfileUnderControllerLock(_ profile: String) throws {
        profileWillChange?()
        defer { profileDidChange?() }
        loadedProfile = nil
        deliveredContents = nil
        guard let process = runningProcessID(MimoRuntime.engineLabel) else {
            throw MimoRuntimeError.unavailable("The proxy engine is unavailable.")
        }
        let bytes = Data(profile.utf8)
        guard !bytes.isEmpty, bytes.count <= 524288 else { throw DaemonFailure.invalidRequest }
        try secureController()
        // Validate and send the same immutable bytes. Neither stdin nor the JSON
        // payload is written to disk, included in argv, or reported in errors.
        try command(MimoRuntime.engine.path, ["-t", "-d", MimoRuntime.profileDirectory.path, "-f", "-"], timeout: 5, input: bytes)
        let body = try JSONSerialization.data(withJSONObject: ["payload": profile])
        // A cold provider initialization can take almost three seconds even in
        // the isolated VM. Keep the gate closed while allowing a bounded reload.
        try command("/usr/bin/curl", ["--silent", "--fail", "--max-time", "10", "--unix-socket", MimoRuntime.controller.path,
            "-X", "PUT", "http://localhost/configs?force=true", "--header", "Content-Type: application/json", "--data-binary", "@-"], timeout: 11, input: body)
        try secureController()
        guard runningProcessID(MimoRuntime.engineLabel) == process else {
            throw MimoRuntimeError.unavailable("The profile or engine changed during activation.")
        }
        loadedProfile = (SHA256.hash(data: bytes), process, try processIdentity(process))
        deliveredContents = profile
    }

    func profileContents() throws -> String {
        guard let process = runningProcessID(MimoRuntime.engineLabel) else { throw DaemonFailure.unavailable }
        if loadedProfile?.process == process, let deliveredContents { return deliveredContents }
        // A supervisor restart cannot reconstruct an earlier in-memory profile.
        // Expose the bootstrap only after confirming that it is what is running.
        guard try matches(MihomoProfile.blocking(), active: false) else { throw DaemonFailure.unavailable }
        return MihomoProfile.blocking()
    }

    func requestConnectionCleanup() -> MimoGateRequest {
        cancelConnectionCleanup()
        let token = MimoGateRequest()
        let queue = cleanupQueue
        let task = Task {
            guard let result = await queue.run({ Result {
                try self.controllerLock.withLock {
                    guard !token.isCancelled else { throw CancellationError() }
                    var timing = MimoTransitionTiming("cleanup")
                    try self.disconnectUnderControllerLock()
                    timing.record("connection_cleanup")
                }
            } }) else { throw CancellationError() }
            try result.get()
        }
        cleanupRequest = (token, task)
        return token
    }

    func confirmConnectionCleanup(_ token: MimoGateRequest) async throws {
        guard let request = cleanupRequest, request.token === token else { throw CancellationError() }
        try await request.task.value
        guard cleanupRequest?.token === token, !token.isCancelled else { throw CancellationError() }
        cleanupRequest = nil
    }

    func cancelConnectionCleanup() {
        cleanupRequest?.token.cancel()
        cleanupRequest?.task.cancel()
        cleanupRequest = nil
    }

    func disconnectFlows() throws {
        cancelConnectionCleanup()
        try controllerLock.withLock { try disconnectUnderControllerLock() }
    }

    private nonisolated func disconnectUnderControllerLock() throws {
        guard runningProcessID(MimoRuntime.engineLabel) != nil else { return }
        try secureController()
        try command("/usr/bin/curl", ["--silent", "--fail", "--max-time", "2", "--unix-socket", MimoRuntime.controller.path,
                                     "-X", "DELETE", "http://localhost/connections"])
    }

    func waitForBlockingEngine() throws {
        // launchctl bootstrap returns before the engine creates its controller. A
        // stale socket file is not readiness: require the controller to accept reload.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? loadProfile(MihomoProfile.blocking())) != nil,
               (try? matches(MihomoProfile.blocking(), active: false)) == true { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw MimoRuntimeError.unavailable("Mihomo did not become ready with the blocking profile.")
    }

    func matches(_ profile: String, active: Bool, proxy: ClashProxySettings? = nil, verifyDNSListeners: Bool = true) throws -> Bool {
        if active, verifyDNSListeners, !protectedDNSReady() { return false }
        guard let process = runningProcessID(MimoRuntime.engineLabel) else { return false }
        let blocking = profile == MihomoProfile.blocking()
        if blocking, loadedProfile?.process != process { loadedProfile = nil }
        if blocking && loadedProfile == nil {
            try secureFile(MimoRuntime.blockingProfile)
            guard try Data(contentsOf: MimoRuntime.blockingProfile) == Data(profile.utf8) else { return false }
        } else {
            guard let loadedProfile, loadedProfile.process == process,
                  loadedProfile.digest == SHA256.hash(data: Data(profile.utf8)) else { return false }
        }
        try secureController()
        func get(_ path: String) throws -> [String: Any] {
            let result = BoundedProcess.run("/usr/bin/curl", ["--silent", "--fail", "--max-time", "2", "--unix-socket", MimoRuntime.controller.path, "http://localhost/\(path)"], timeout: 3)
            guard result.status == 0, let data = result.text.data(using: .utf8),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MimoRuntimeError.unavailable("Mihomo controller verification failed.") }
            return result
        }
        let config = try get("configs"), rules = try get("rules")["rules"] as? [[String: Any]] ?? []
        let proxies = try get("proxies")["proxies"] as? [String: Any] ?? [:]
        return runningProcessID(MimoRuntime.engineLabel) == process &&
            MihomoRuntimeInspection.matches(profile: profile, active: active, proxy: proxy.map(MimoProxy.init),
                                             config: config, rules: rules, proxies: proxies)
    }

    func receiptMatchesLoadedProfile(_ receipt: MimoReadinessReceipt) -> Bool {
        guard let loadedProfile else { return false }
        return loadedProfile.process == receipt.process && Data(loadedProfile.digest) == receipt.profileDigest &&
            receipt.checkedAt.duration(to: .now) < .seconds(15)
    }

    func receiptIsCurrent(_ receipt: MimoReadinessReceipt) -> Bool {
        receiptMatchesLoadedProfile(receipt) && runningProcessID(MimoRuntime.engineLabel) == receipt.process
            && (try? processIdentity(receipt.process)) == loadedProfile?.started
    }

    /// Start independent reads immediately. The detached task cannot be delayed
    /// behind main-actor PF commands. Live resolver and receipt checks are joined
    /// by the supervisor, and openGate still checks engine identity under PF lock.
    func startReadiness(profile: String, proxy: ClashProxySettings,
                        installation: Task<Void, Error>, recordTiming: Bool = true) throws -> Task<MimoReadinessReceipt, Error> {
        guard let loadedProfile, loadedProfile.digest == SHA256.hash(data: Data(profile.utf8)) else {
            throw MimoRuntimeError.unavailable("The loaded profile changed before inspection.")
        }
        try secureController()
        let process = loadedProfile.process
        let digest = Data(loadedProfile.digest)
        let checks = readinessChecks
        return Task.detached {
            try await checks.inspect(profile: profile, proxy: proxy, process: process, digest: digest,
                                     installation: installation, recordTiming: recordTiming,
                                     currentProcess: { self.runningProcessID(MimoRuntime.engineLabel) })
        }
    }

    func confirmReadiness(_ receipt: MimoReadinessReceipt) throws {
        guard dns.matches, receiptMatchesLoadedProfile(receipt) else {
            throw MimoRuntimeError.unavailable("The final profile, tunnel or protected DNS could not be confirmed.")
        }
        try secureController()
    }

    func inspectReadiness(profile: String, proxy: ClashProxySettings,
                          installation: Task<Void, Error>, recordTiming: Bool = true) async throws -> MimoReadinessReceipt {
        let inspection = try startReadiness(profile: profile, proxy: proxy, installation: installation, recordTiming: recordTiming)
        return try await withTaskCancellationHandler {
            let receipt = try await inspection.value
            try Task.checkCancellation()
            try confirmReadiness(receipt)
            return receipt
        } onCancel: { inspection.cancel() }
    }

    func service(_ service: MimoServiceID, operation: MimoServiceOperation) throws {
        try withFirewallLock { try changeJobUnderFirewallLock(service, operation: operation) }
        if service == .mihomo, operation != .stop {
            // Release the lock before the wrapper needs it for startup guarding.
            // A launchd PID alone is not a ready controller.
            try waitForBlockingEngine()
        }
    }

    /// Caller already owns the firewall lock, including offline Direct recovery.
    private func changeJobUnderFirewallLock(_ service: MimoServiceID, operation: MimoServiceOperation) throws {
        let label: String
        switch service { case .core: label = ExitIPService.label; case .mihomo: label = MimoRuntime.engineLabel; default: throw DaemonFailure.invalidRequest }
        let job = "system/\(label)", plist = MimoRuntime.jobDirectory.appendingPathComponent("\(label).plist")
        let inspection = BoundedProcess.run("/bin/launchctl", ["print", job], captureError: true)
        let loaded = inspection.status == 0
        guard loaded || (inspection.status == 113 && inspection.text.contains("Could not find service")) else {
            throw MimoRuntimeError.unavailable("Could not inspect the background service.")
        }
        if operation != .start, loaded { try command("/bin/launchctl", ["bootout", job], timeout: 8) }
        if operation != .stop, operation != .start || !loaded {
            try secureDirectory(MimoRuntime.jobDirectory)
            try secureFile(plist)
            try command("/bin/launchctl", ["enable", job])
            try command("/bin/launchctl", ["bootstrap", "system", plist.path], timeout: 8)
        }
    }

    func isRunning(_ label: String) -> Bool {
        let result = BoundedProcess.run("/bin/launchctl", ["print", "system/\(label)"])
        return result.status == 0 && result.text.contains("state = running")
    }

    nonisolated func runningProcessID(_ label: String) -> Int32? {
        let result = BoundedProcess.run("/bin/launchctl", ["print", "system/\(label)"])
        guard result.status == 0, result.text.contains("state = running") else { return nil }
        for line in result.text.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("pid = ") { return Int32(line.dropFirst(6)) }
        }
        return nil
    }

    private nonisolated func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3, input: Data? = nil) throws {
        let result = BoundedProcess.run(executable, arguments, timeout: timeout, input: input)
        guard result.status == 0 else {
#if MIMO_VM_ACCEPTANCE
            RuntimeLog.shared.error("mimo_vm_command_failed", fields: ["program": (executable as NSString).lastPathComponent, "status": String(result.status)])
#endif
            throw MimoRuntimeError.unavailable("A required \((executable as NSString).lastPathComponent) operation failed. Traffic was not approved.")
        }
    }

    private nonisolated func secureController() throws {
        for directory in [MimoRuntime.profileDirectory.deletingLastPathComponent(), MimoRuntime.profileDirectory] {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_uid == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
                throw MimoRuntimeError.unavailable("Mihomo's controller directory is not private. Repair installation.")
            }
        }
        var info = stat()
        guard lstat(MimoRuntime.controller.path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFSOCK else {
            throw MimoRuntimeError.unavailable("Mihomo's private controller is missing or unsafe. Repair installation.")
        }
        // Mihomo explicitly creates its Unix socket as 0666 despite the inherited
        // umask. Both root-only directories prevent access during creation;
        // narrow the socket itself before the first controller request as well.
        guard chmod(MimoRuntime.controller.path, 0o600) == 0 else { throw DaemonFailure.unavailable }
    }

    private nonisolated func secureFile(_ url: URL, executable: Bool = false) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
              !executable || info.st_mode & 0o111 != 0 else {
            throw MimoRuntimeError.unavailable("A root-owned runtime file is missing or unsafe. Repair installation.")
        }
    }

    private nonisolated func secureDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
            throw MimoRuntimeError.unavailable("A runtime directory is missing or unsafe. Repair installation.")
        }
    }

    private nonisolated func withFirewallLock<T>(_ operation: () throws -> T) throws -> T {
        try secureDirectory(directory)
        let lock = try MimoFirewallLock.acquire(at: directory.appendingPathComponent("firewall.lock"))
        return try withExtendedLifetime(lock, operation)
    }
}
