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
/// Internal runtime workers construct these receipts; no XPC caller supplies rules or proof.
struct MimoPreparedProbePolicy: Sendable, Equatable {
    let rules: String
    let group: UInt32
    let activeRules: String?
    let nativeInterfaces: [String]
    let nativeEgress: MimoNativeEgress
}

/// Fixed-path privileged operations. No caller supplies a command, YAML, or executable path.
@MainActor
final class MimoSystemRuntime {
    private nonisolated let directory = MimoRuntime.directory
    private nonisolated var group: UInt32 {
        getgrnam(MimoRuntime.engineGroup).map { $0.pointee.gr_gid } ?? UInt32.max
    }
    private(set) var closed = false
    private(set) var nativeReleaseIssue: String?
    private var enableToken: String?
    private var loadedProfile: (digest: SHA256.Digest, process: Int32, started: String)?
    private var deliveredContents: String?
    private(set) var engineInspection = MimoServiceStatus(id: .mihomo, health: .unavailable, transport: "HTTP / SOCKS · Unix controller")
    private var verificationCloseEpoch: String?
    private var installedPolicy: MimoPreparedProbePolicy?
    private var verifiedBaseline: (digest: Data, process: Int32)?
    private var expectedPolicies: [String: String] = [:]
    private let dns = MimoDNSConfiguration()
    nonisolated let readinessChecks = MimoReadinessChecks()
    private nonisolated let controllerLock = NSLock()
    private let cleanupQueue = MimoBlockingWorkQueue("com.mimo.clear-connections", qos: .userInitiated)
    private var cleanupRequest: (token: MimoGateRequest, task: Task<Void, Error>)?
    private nonisolated let firewallPreparationQueue = MimoBlockingWorkQueue("com.mimo.prepare-firewall")
    private var nativePolicyOwner: MimoNativePolicyOwner?
    private var nativePolicyWorkCount = 0
    var nativePolicyDidCommit: (() -> Void)?
    private nonisolated let applicationGate = MimoApplicationGate()
    private let infrastructureQueue = MimoBlockingWorkQueue("com.mimo.infrastructure-check")
    private let directReleaseQueue = MimoBlockingWorkQueue("com.mimo.direct-release", qos: .userInitiated)
    private var onlineDirectRelease = false
    private let protectedQueue = MimoBlockingWorkQueue("com.mimo.protected-io", qos: .userInitiated)
    private let protectedDNS = MimoProtectedDNSIO()
    private var protectedLease: MimoProtectedLease?
    private var protectedDNSReceipt: Data?
    private var protectedLoadedReceipt: MimoLoadedProfileReceipt?
    private var protectedWorkCount = 0
    private var profileObservationOwner: UUID?
    private var profileObservationCompletion: Task<Void, Never>?
    private var profileObservationCompletionID = UUID()
    var hasProtectedOwnership: Bool { protectedLease != nil || protectedWorkCount != 0 || nativePolicyWorkCount != 0 }
    var protectedIOBusy: Bool { protectedWorkCount != 0 }

    private var infrastructureEpoch: UInt64 = 0
    private var infrastructureInspection: MimoInfrastructureInspection?
    private(set) var latestPFHealthReceipt: MimoPFHealthReceipt?
    private(set) var notificationEngineProcess: Int32?
    var profileWillChange: (() -> Void)?
    var profileDidChange: (() -> Void)?
    var profileDidChangeOnline: (() async -> Void)?
    var maintenanceActive: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("maintenance").path) }
    nonisolated var networkReleaseRequested: Bool { (try? servicePreferences().networkReleaseRequested) == true }

    private var infrastructureRepairPending: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("infrastructure-repair").path)
    }

    func ensureBootGuard() throws {
        try secureDirectory(MimoRuntime.guardDirectory)
        try secureFile(MimoRuntime.guardScript)
        try command("/usr/bin/perl", [MimoRuntime.guardScript.path, "--boot"], timeout: 20)
    }

    /// The supervisor alone owns network infrastructure audits and repair.
    func repairInfrastructure(generation: UInt64) async throws -> MimoInfrastructureCheckOutcome {
        let epoch = infrastructureEpoch
        let check = UUID().uuidString
        let started = ContinuousClock.now
        var outcome = MimoInfrastructureCheckOutcome.superseded
        infrastructureInspection = .init(id: check, generation: generation, startedAt: .now)
        RuntimeLog.shared.info("mimo_infrastructure_check_started", fields: ["check": check, "epoch": String(epoch), "generation": String(generation)])
        defer {
            let duration = started.duration(to: .now).components
            let milliseconds = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
            infrastructureInspection?.completedAt = .now
            infrastructureInspection?.outcome = outcome
            infrastructureInspection?.isCurrent = outcome != .superseded
            RuntimeLog.shared.info("mimo_infrastructure_check_finished", fields: [
                "check": check, "epoch": String(epoch), "generation": String(generation), "outcome": outcome.rawValue,
                "duration_ms": String(milliseconds)
            ])
        }
        guard !onlineDirectRelease else { return .superseded }
        outcome = .failed
        try secureDirectory(MimoRuntime.guardDirectory)
        try secureFile(MimoRuntime.guardScript)
        guard let inspected = await infrastructureQueue.run({ [self] in
            let result = BoundedProcess.run("/usr/bin/perl", [MimoRuntime.guardScript.path, "--check"], timeout: 25, captureError: true)
            // Inspection is bounded and off the control executor. A PID alone
            // cannot establish a responsive engine or profile delivery path.
            let wanted = (try? self.servicePreferences().engine) == true && !self.networkReleaseRequested
            let running = self.isRunning(MimoRuntime.engineLabel)
            let responsive = running && (try? self.checkInstalledController()) != nil
            let health: MimoServiceHealth = wanted ? (responsive ? .running : .unavailable) : (running ? .unavailable : .stopped)
            let engine = MimoServiceStatus(id: .mihomo, health: health, transport: "HTTP / SOCKS · Unix controller",
                address: "127.0.0.1", port: MimoRuntime.mixedPort, checkedAt: .now)
            return (result, engine)
        }) else { outcome = .superseded; throw CancellationError() }
        if Task.isCancelled { outcome = .superseded; throw CancellationError() }
        let (result, engine) = inspected
        guard !onlineDirectRelease, epoch == infrastructureEpoch else { outcome = .superseded; return outcome }
        if engineInspection.health != engine.health {
            RuntimeLog.shared.info("mimo_engine_health_changed", fields: ["health": engine.health.rawValue])
        }
        engineInspection = engine
        if result.status == 75 {
            outcome = .deferred
            let reasons = ["snapshot_changed", "revocation_pending", "mutation_busy"]
            let reason = reasons.first { result.text.contains("mimo_infrastructure_deferred reason=\($0)\n") } ?? "pf_snapshot_changed_or_revocation"
            infrastructureInspection?.reason = reason
            RuntimeLog.shared.info("mimo_infrastructure_check_deferred", fields: ["check": check, "generation": String(generation), "reason": reason])
            return outcome
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
        outcome = .completed
        return outcome
    }

    /// Upgrade while the startup barrier is closed. Retire every old child,
    /// persistent DNS key and saved IPv6 disable flag before loading a profile.
    func migrateLegacyNetworkControls() throws {
        guard !networkReleaseRequested else { return }
        guard closed else { throw DaemonFailure.conflict }
        try withFirewallLock {
            try clearOwnedPolicyChildren()
            try dns.remove()
            try MimoIPv4Configuration.apply(restoring: true)
        }
        RuntimeLog.shared.info("mimo_legacy_network_controls_removed")
    }

    /// The caller has replaced the parent, so children cannot grant old policy.
    /// Enumerate descendants, including unreferenced previous-version anchors.
    private func clearOwnedPolicyChildren() throws {
        try MimoFirewallLock.mutate {
            var paths = [MimoFirewallPolicy.anchor]
            var index = 0
            while index < paths.count {
                let parent = paths[index]; index += 1
                let result = BoundedProcess.run("/sbin/pfctl", ["-a", parent, "-s", "Anchors"])
                guard result.status == 0 else { throw MimoRuntimeError.unavailable("Could not inspect older Mimo firewall policies.") }
                for line in result.text.split(separator: "\n") {
                    let child = line.trimmingCharacters(in: .whitespaces)
                    guard !child.isEmpty else { continue }
                    let path = child.hasPrefix(MimoFirewallPolicy.anchor + "/") ? child : parent + "/" + child
                    let suffix = path.dropFirst(MimoFirewallPolicy.anchor.count + 1)
                    guard path.hasPrefix(parent + "/"), !suffix.isEmpty,
                          suffix.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                              !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy {
                                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
                              }
                          }), paths.count < 128, !paths.contains(path) else { throw DaemonFailure.invalidRequest }
                    paths.append(path)
                }
            }
            for path in paths.dropFirst() {
                for kind in ["rules", "nat", "Tables"] { try command("/sbin/pfctl", ["-a", path, "-F", kind]) }
                for kind in ["-sr", "-sn"] {
                    let actual = BoundedProcess.run("/sbin/pfctl", ["-a", path, kind])
                    guard actual.status == 0, actual.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw MimoRuntimeError.unavailable("An older Mimo firewall policy remains installed.")
                    }
                }
            }
        }
        installedPolicy = nil; verifiedBaseline = nil; expectedPolicies = [:]
    }

    func infrastructureStatus(generation: UInt64? = nil) -> MimoInfrastructureStatus {
        struct Record: Decodable {
            var boot: String
            var checkedAt: Double
            var pf: String
            var launchd: String
            var pfCheckedAt: Double?
            var launchdCheckedAt: Double?
            var completedAt: Double?
            var pfMutationEpoch: String?
            var pfState: String?
            var pfPolicyDigest: String?
        }
        var inspection = infrastructureInspection
        if let generation, inspection?.generation != generation { inspection?.isCurrent = false }
        do {
            let path = MimoRuntime.guardDirectory.appendingPathComponent("health.json")
            try secureDirectory(MimoRuntime.guardDirectory)
            try secureFile(path)
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: path))
            guard record.boot == (try bootIdentifier()), record.checkedAt.isFinite,
                  [record.pfCheckedAt, record.launchdCheckedAt, record.completedAt].allSatisfy({ $0?.isFinite != false }) else { return .init(inspection: inspection) }
            let pfHealth: MimoInfrastructureHealth = record.pf == "released" ? .released : record.pf == "enabled" ? .healthy : .failed
            var pfDate = Date(timeIntervalSince1970: record.pfCheckedAt ?? record.checkedAt)
            var receipts = latestPFHealthReceipt.map { [$0] } ?? []
            if let epoch = record.pfMutationEpoch, let state = record.pfState, let digest = record.pfPolicyDigest,
               let completed = record.completedAt {
                receipts.append(.init(mutationEpoch: epoch, state: state, policyDigest: digest,
                    observedAt: pfDate, completedAt: Date(timeIntervalSince1970: completed)))
            }
            let matching = receipts.sorted { $0.observedAt > $1.observedAt }.first { pfHealthReceiptIsCurrent($0) }
            if let matching, pfHealth == .healthy || pfHealth == .released {
                // A narrow policy readback does not recheck PF enablement,
                // the root anchor or reference ownership. Keep the older full
                // guard observation as the conservative freshness bound.
                pfDate = min(pfDate, matching.observedAt)
            }
            let pfEvidenceCurrent = (matching != nil && (pfHealth == .healthy || pfHealth == .released)) ||
                (pfHealth == .failed && inspection?.isCurrent == true && inspection?.outcome == .failed)
            let launchdDate = Date(timeIntervalSince1970: record.launchdCheckedAt ?? record.checkedAt)
            return MimoInfrastructureStatus(pf: pfHealth,
                launchd: record.launchd == "healthy" ? .healthy : record.launchd == "unknown" ? .unknown : .failed,
                checkedAt: min(pfDate, launchdDate), pfCheckedAt: pfDate, launchdCheckedAt: launchdDate,
                completedAt: record.completedAt.map(Date.init(timeIntervalSince1970:)), inspection: inspection,
                pfEvidenceCurrent: pfEvidenceCurrent).current(at: .now)
        } catch { return .init(inspection: inspection) }
    }

    private func pfHealthReceiptIsCurrent(_ receipt: MimoPFHealthReceipt) -> Bool {
        do {
            let epochURL = directory.appendingPathComponent("pf-mutation.epoch")
            let stateURL = directory.appendingPathComponent("gate.state")
            let policyURL = directory.appendingPathComponent("guard.expected")
            try secureFile(stateURL)
            let state = try String(contentsOf: stateURL, encoding: .utf8)
            func epoch() throws -> String {
                if state == "released", !FileManager.default.fileExists(atPath: epochURL.path) { return "absent" }
                try secureFile(epochURL)
                return try String(contentsOf: epochURL, encoding: .utf8)
            }
            let before = try epoch()
            let policy: Data
            if state == "released", !FileManager.default.fileExists(atPath: policyURL.path) { policy = Data() }
            else { try secureFile(policyURL); policy = try Data(contentsOf: policyURL) }
            guard before == (try epoch()), state == (try String(contentsOf: stateURL, encoding: .utf8)) else { return false }
            return receipt.matches(epoch: before, state: state, policy: policy, at: .now)
        } catch { return false }
    }

    var gateState: String? {
        let url = directory.appendingPathComponent("gate.state")
        guard (try? secureFile(url)) != nil else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    nonisolated func servicePreferences() throws -> MimoServicePreferences {
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

    nonisolated func savedProxy(configuration: MimoConfiguration, revision: Int) throws -> ClashProxySettings {
        try secureFile(MimoService.storageURL)
        let storage = try FilePreferenceStorage(url: MimoService.storageURL)
        guard storage.integer(forKey: "service.revision") == revision,
              let data = storage.data(forKey: "service.routing") else { throw DaemonFailure.conflict }
        let saved = try JSONDecoder().decode(MimoConfiguration.self, from: data).validated()
        guard saved == configuration, let id = saved.activeProxyID, let metadata = saved.proxy else { throw DaemonFailure.conflict }
        let password = try MimoLocalSettings.passwords(in: storage)[id] ?? ""
        return try metadata.settings(password: password)
    }

    func savedBypassBlocks() throws -> [MimoBypassBlock] {
        let storage = try FilePreferenceStorage(url: MimoService.storageURL)
        guard let data = storage.data(forKey: "service.settings") else { return MimoBypassBlock.defaults }
        return try JSONDecoder().decode(MachineSettings.self, from: data).validated().effectiveBypassBlocks
    }

    func nativeDNSRules() throws -> [MimoPrivateDNSRule] { try dns.nativeRules() }

    func savedAllowlist() throws -> AllowedIPList {
        try secureFile(MimoService.storageURL)
        let storage = try FilePreferenceStorage(url: MimoService.storageURL)
        guard let data = storage.data(forKey: "service.settings") else { throw DaemonFailure.invalidRequest }
        return try JSONDecoder().decode(MachineSettings.self, from: data).validated().allowlist
    }

    func savedRouting() throws -> (configuration: MimoConfiguration, revision: Int) {
        guard FileManager.default.fileExists(atPath: MimoService.storageURL.path) else { return (MimoConfiguration(), 0) }
        try secureFile(MimoService.storageURL)
        let storage = try FilePreferenceStorage(url: MimoService.storageURL)
        var configuration: MimoConfiguration
        if let data = storage.data(forKey: "service.routing") {
            configuration = try JSONDecoder().decode(MimoConfiguration.self, from: data).validated()
        } else { configuration = MimoConfiguration() }
        if networkReleaseRequested { configuration.mode = .direct; configuration.mihomoEnabled = false }
        return (configuration, storage.integer(forKey: "service.revision"))
    }

    func persistDirectRecovery(activateServices: Bool = false) throws -> MimoConfiguration {
        try persistRouting { try MimoRecoveryState.commitDirect(storage: $0, activateServices: activateServices) }
    }

    func prepareInstallation(startingInDirect: Bool) throws {
        _ = try persistRouting { try MimoRecoveryState.commitInstallation(storage: $0, startingInDirect: startingInDirect) }
        try saveServicePreferences(MimoServicePreferences())
    }

    private func persistRouting(_ commit: (FilePreferenceStorage) throws -> MimoConfiguration) throws -> MimoConfiguration {
        let directory = MimoService.storageURL.deletingLastPathComponent()
        try secureDirectory(MimoService.support)
        try secureDirectory(directory)
        guard let lock = try SingleInstanceLock(url: directory.appendingPathComponent("instance.lock")) else {
            throw MimoRuntimeError.unavailable("Core still owns its settings. Direct recovery was not applied.")
        }
        return try withExtendedLifetime(lock) {
            if FileManager.default.fileExists(atPath: MimoService.storageURL.path) { try secureFile(MimoService.storageURL) }
            return try commit(FilePreferenceStorage(url: MimoService.storageURL))
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
        try secureDirectory(MimoService.support)
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

    nonisolated func checkInstalledController() throws {
        try secureController()
        let result = BoundedProcess.run("/usr/bin/curl", ["--silent", "--fail", "--max-time", "2", "--unix-socket",
            MimoRuntime.controller.path, "http://localhost/version"], timeout: 3)
        guard result.status == 0, let data = result.text.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["version"] as? String == "v\(MimoRuntime.version)",
              Set(value["mimoCapabilities"] as? [String] ?? []).isSuperset(of: ["strict-ipv4-v1", "probe-acl-v1", "silent-echo-v1", "native-dns-route-v1"]) else {
            throw MimoRuntimeError.unavailable("The installed mihomo controller did not pass its version check.")
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

    func cachedProbePolicy(endpoints: [String], proxyPort: Int?, mode: ProxyMode) async throws -> MimoPreparedProbePolicy? {
        guard let installedPolicy else { return nil }
        guard let result = await firewallPreparationQueue.run({ Result { () -> MimoPreparedProbePolicy? in
            let rules = try MimoFirewallPolicy.preparedPolicy(group: self.group, endpoints: endpoints, proxyPort: proxyPort)
            let interfaces = try self.nativeTunnelInterfaces()
            let native = MimoNativeEgressProbe.snapshot()
            let active = endpoints.isEmpty ? nil : try MimoFirewallPolicy.activePolicy(group: self.group, nativeInterfaces: interfaces, nativeEgress: native)
            return installedPolicy.rules == rules && installedPolicy.activeRules == active ? installedPolicy : nil
        } }) else { throw CancellationError() }
        return try result.get()
    }

    /// Snapshot existing native tunnel addresses during preparation, not a
    /// provider/watcher or profile binding. Stale interface rules cannot grant
    /// Quad100 on a physical default route after native tunnel destruction.
    private nonisolated func nativeTunnelInterfaces() throws -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw DaemonFailure.unavailable }
        defer { freeifaddrs(first) }
        var names = Set<String>()
        var current = first
        while let entry = current {
            current = entry.pointee.ifa_next
            let item = entry.pointee
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("utun"), name != MihomoProfile.tunnelDevice,
                  item.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  let address = item.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                  MimoTailnetChangePolicy.addressFamily(String(cString: host)) != nil else { continue }
            names.insert(name)
        }
        return names.sorted()
    }

    private func processIdentity(_ process: Int32) throws -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, size) == size else { throw DaemonFailure.unavailable }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    /// A launchctl query can fail while the already-qualified engine is alive.
    /// Check its kernel identity directly in the frequent liveness watchdog;
    /// controller/profile/launchd readiness remains independently audited.
    func engineIsAlive() -> Bool {
        guard let loadedProfile else { return isRunning(MimoRuntime.engineLabel) }
        let reason = Self.processLivenessFailure(loadedProfile.process, started: loadedProfile.started,
                                                executable: MimoRuntime.engine.path, uid: 0, gid: group)
        if let reason {
            RuntimeLog.shared.error("mimo_engine_liveness_failed", fields: [
                "stage": reason, "enginePID": String(loadedProfile.process)
            ])
        }
        return reason == nil
    }

    nonisolated static func processLivenessFailure(_ process: Int32, started: String, executable: String,
                                                   uid: UInt32, gid: UInt32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard process > 0, proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, size) == size else { return "process_missing" }
        guard info.pbi_status != UInt32(SZOMB) else { return "process_exited" }
        guard "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" == started else { return "process_replaced" }
        guard info.pbi_uid == uid, info.pbi_gid == gid else { return "process_credentials_changed" }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(process, &path, UInt32(path.count)) > 0,
              String(cString: path) == executable else { return "process_executable_changed" }
        return nil
    }

    nonisolated func prepareProbePolicy(endpoints: [String], proxyPort: Int?, mode: ProxyMode) async throws -> MimoPreparedProbePolicy {
        guard let result = await firewallPreparationQueue.run({ Result {
            var timing = MimoTransitionTiming("firewall_preparation")
            let runtimeGroup = self.group
            guard runtimeGroup != UInt32.max, endpoints.allSatisfy({ !$0.contains(":") }) else {
                throw MimoRuntimeError.unavailable("A dedicated runtime group and IPv4 endpoint are required.")
            }
            let rules = try MimoFirewallPolicy.preparedPolicy(group: runtimeGroup, endpoints: endpoints, proxyPort: proxyPort)
            let nativeInterfaces = try self.nativeTunnelInterfaces()
            // Public VPN transport can be needed before a Tailnet interface
            // exists. Its signature/socket evidence is independent of native
            // private routing; private destinations still require that interface.
            let nativeEgress = MimoNativeEgressProbe.snapshot()
            let active = endpoints.isEmpty ? nil : try MimoFirewallPolicy.activePolicy(group: runtimeGroup, nativeInterfaces: nativeInterfaces, nativeEgress: nativeEgress)
            timing.record("rule_generation")
            // -n checks syntax only. Immutable stdin bytes avoid shared-file
            // races with a concurrent close, Direct action or another attempt.
            for (name, bytes) in [("probe-policy", rules), ("open-policy", active ?? "")] {
                try self.command("/sbin/pfctl", ["-n", "-a", MimoFirewallPolicy.anchor + "/" + name, "-f", "-"], input: Data(bytes.utf8))
            }
            timing.record("rule_validation")
            return MimoPreparedProbePolicy(rules: rules, group: runtimeGroup, activeRules: active, nativeInterfaces: nativeInterfaces, nativeEgress: nativeEgress)
        } }) else { throw CancellationError() }
        return try result.get()
    }

    func installProbePolicy(_ policy: MimoPreparedProbePolicy) throws {
        guard closed, !maintenanceActive, !infrastructureRepairPending, policy.group == group else { throw DaemonFailure.conflict }
        try installPF(MimoFirewallPolicy.startupBlocking)
        installedPolicy = policy
    }

    func closeGate(endpoints: [String] = [], proxyPort: Int? = nil) throws {
        closed = false
        try closeGate(rules: MimoFirewallPolicy.startupBlocking, applyIPv4Preferences: true)
    }

    /// Close the flat owned anchor and confirm it before preparation proceeds.
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
        else {
            guard let result = await protectedQueue.run({ Result { try MimoProtectedIO().close(request: token) } }) else { throw CancellationError() }
            try result.get()
            guard !token.isCancelled else { throw CancellationError() }
            closed = true
        }
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
        guard !request.isCancelled else { throw CancellationError() }
        return try MimoPowerGuard.closeBarrier(request: request) {
            let main = BoundedProcess.run("/sbin/pfctl", ["-sr"])
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            let status = BoundedProcess.run("/sbin/pfctl", ["-s", "info"])
            guard main.status == 0, main.text.contains("anchor \"com.apple/*\""),
                  !main.text.contains("pass out quick"), !main.text.contains("pass quick"),
                  live.status == 0, MimoFirewallPolicy.isClosedReadback(live.text),
                  status.status == 0, status.text.contains("Status: Enabled") else { return false }
            guard !request.isCancelled else { throw CancellationError() }
            _ = try writePrivate(Data(live.text.utf8), name: "guard.expected")
            _ = try writePrivate(Data("blocked".utf8), name: "gate.state")
            return true
        }
    }

    func closeStartupGate() throws {
        try closeGate(rules: MimoFirewallPolicy.startupBlocking, applyIPv4Preferences: false)
    }

    private func closeGate(rules: String, applyIPv4Preferences: Bool, cancelPending: Bool = true, validated: MimoPreparedProbePolicy? = nil) throws {
        guard !networkReleaseRequested else { closed = false; return }
        if cancelPending { cancelApplicationGate() }
        closed = false
        try withFirewallLock {
            _ = try writePrivate(Data("pending".utf8), name: "gate.state")
            try installPF(rules, requiresRuntimeGroup: applyIPv4Preferences, validated: validated)
            _ = try writePrivate(Data("blocked".utf8), name: "gate.state")
            closed = true
        }
    }

    func permitPrivateProbe() throws {
        guard closed, let policy = installedPolicy else { throw DaemonFailure.conflict }
        try MimoFirewallLock.mutate {
            guard !maintenanceActive, !infrastructureRepairPending else { throw DaemonFailure.conflict }
            try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: Data(policy.rules.utf8))
            let actual = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard actual.status == 0, MimoFirewallPolicy.isVerificationReadback(actual.text) else { throw DaemonFailure.conflict }
            _ = try writePrivate(Data(actual.text.utf8), name: "guard.expected")
            verificationCloseEpoch = try String(contentsOf: directory.appendingPathComponent("pf-close.epoch"), encoding: .utf8)
        }
    }

    private var quickNetworkMatches: Bool {
        if_nametoindex(MihomoProfile.tunnelDevice) != 0 && dns.matches
    }

    func revokeBaseline() { verifiedBaseline = nil }

    private var blockedNativeEgress = MimoNativeEgress()

    /// Keep signed Tailnet transport available for inbound management. Public
    /// application/engine flows remain denied and this cannot open the gate.
    func refreshBlockedNativeTransport() async throws {
        guard closed, gateState == "blocked", !maintenanceActive, !infrastructureRepairPending else { return }
        try await updateNativePolicy(blocked: true)
    }

    func acceptBaseline(_ receipt: MimoReadinessReceipt) throws {
        try confirmReadiness(receipt)
        guard receiptIsCurrent(receipt) else { throw DaemonFailure.conflict }
        verifiedBaseline = (receipt.profileDigest, receipt.process)
    }

    /// An observation uses the already installed private probe. It must never
    /// reload the profile, clear connections, or write a firewall permission.
    func validateObservation() throws {
        try MimoFirewallLock.read {
            guard !closed, gateState == "active", !maintenanceActive, !infrastructureRepairPending,
                  quickNetworkMatches, let baseline = verifiedBaseline, let loadedProfile,
                  baseline.digest == Data(loadedProfile.digest), baseline.process == loadedProfile.process,
                  runningProcessID(MimoRuntime.engineLabel) == baseline.process,
                  try processIdentity(baseline.process) == loadedProfile.started,
                  let policy = installedPolicy, try nativeTunnelInterfaces() == policy.nativeInterfaces else {
                throw MimoRuntimeError.unavailable("The approved network path changed. Fresh verification is required.")
            }
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard live.status == 0, live.text == policy.activeRules,
                  live.text == (try String(contentsOf: directory.appendingPathComponent("guard.expected"), encoding: .utf8)) else {
                throw MimoRuntimeError.unavailable("The active firewall guard changed. Fresh verification is required.")
            }
        }
    }

    func auditPolicies() async throws {
        guard !closed, gateState == "active", !maintenanceActive, !infrastructureRepairPending else { throw CancellationError() }
        try await updateNativePolicy(blocked: false)
    }

    func refreshDirectTracking() async throws {
        guard !closed, gateState == "direct", !onlineDirectRelease,
              !maintenanceActive, !infrastructureRepairPending, !networkReleaseRequested else { return }
        try await updateNativePolicy(blocked: false, direct: true)
    }

    private nonisolated func localTCPDestinations() throws -> [String] {
        try MimoFirewallPolicy.localTCPDestinations()
    }

    func cancelNativePolicyUpdates() {
        nativePolicyOwner?.cancel()
        nativePolicyOwner = nil
    }

    func drainNativePolicyUpdates() async {
        // A caller's cancellation must not skip the physical queue barrier.
        let queue = firewallPreparationQueue
        let join = Task { _ = await queue.run { true } }
        await join.value
    }

    private func updateNativePolicy(blocked: Bool, direct: Bool = false) async throws {
        // The watchdog awaits each call. Defensive overlapping callers coalesce
        // into that work; the next watchdog iteration inspects the latest state.
        guard nativePolicyOwner == nil else { return }
        let policy = installedPolicy
        guard direct || blocked || policy != nil else { throw DaemonFailure.conflict }
        let previousNative = direct ? MimoNativeEgress() : blocked ? blockedNativeEgress : policy!.nativeEgress
        let interfaces = direct || blocked ? [] : policy!.nativeInterfaces
        let state = direct ? "direct" : blocked ? "blocked" : "active"
        let owner = MimoNativePolicyOwner()
        nativePolicyOwner = owner; nativePolicyWorkCount += 1
        defer {
            nativePolicyWorkCount -= 1
            if nativePolicyOwner === owner { nativePolicyOwner = nil }
        }
        let started = ContinuousClock.now
        var fields = ["operation": owner.id.uuidString, "state": state, "stage": "preparation"]
        do {
            let group = self.group
            guard let preparation = await nativePolicyWork(owner, operation: {
                if direct { return try self.prepareDirectTrackingUpdate(owner: owner) }
                return try self.prepareNativePolicyUpdate(owner: owner, state: state, policy: policy,
                    previousNative: previousNative, interfaces: interfaces, group: group)
            }) else { throw CancellationError() }
            try owner.check()
            guard nativePolicyOwner === owner, closed == blocked, gateState == state,
                  !maintenanceActive, !infrastructureRepairPending, !networkReleaseRequested,
                  direct || (blocked ? blockedNativeEgress == previousNative : installedPolicy == policy) else { throw CancellationError() }
            guard let prepared = try preparation.get() else { return }
            fields["stage"] = "commit"
            fields["inputEpoch"] = prepared.scope.mutationEpoch
            fields["inputPolicyDigest"] = MimoPFHealthReceipt.digest(Data(prepared.scope.expectedRules.utf8))
            RuntimeLog.shared.info("mimo_native_policy_started", fields: fields)
            guard let committed = await nativePolicyWork(owner, operation: {
                try self.commitNativePolicyUpdate(prepared, owner: owner)
            }) else { throw CancellationError() }
            let commit = try committed.get()
            fields["stage"] = "adoption"
            try owner.check()
            guard nativePolicyOwner === owner, closed == blocked, gateState == state,
                  !maintenanceActive, !infrastructureRepairPending, !networkReleaseRequested,
                  direct || (blocked ? blockedNativeEgress == previousNative : installedPolicy == policy),
                  pfHealthReceiptIsCurrent(commit.health) else { throw CancellationError() }
            if blocked { blockedNativeEgress = prepared.native }
            else if !direct, let policy {
                installedPolicy = MimoPreparedProbePolicy(rules: policy.rules, group: policy.group,
                    activeRules: commit.readback, nativeInterfaces: interfaces, nativeEgress: prepared.native)
            }
            latestPFHealthReceipt = commit.health
            fields["outputEpoch"] = commit.health.mutationEpoch
            fields["outputPolicyDigest"] = commit.health.policyDigest
            fields["duration_ms"] = String(Self.nativePolicyMilliseconds(started.duration(to: .now)))
            RuntimeLog.shared.info("mimo_native_policy_committed", fields: fields)
            if direct {
                RuntimeLog.shared.info("mimo_direct_tracking_updated", fields: ["operation": owner.id.uuidString,
                    "destinations": String(MimoFirewallPolicy.inboundDestinations(in: commit.readback)?.count ?? 0)])
            } else {
                RuntimeLog.shared.info(blocked ? "mimo_blocked_native_transport_updated" : "mimo_native_egress_updated",
                    fields: ["udpScopes": String(prepared.native.datagrams.count), "httpsScopes": String(prepared.native.https.count)])
            }
            nativePolicyDidCommit?()
        } catch is CancellationError {
            fields["reason"] = "ownership_changed"
            RuntimeLog.shared.info("mimo_native_policy_superseded", fields: fields)
            throw CancellationError()
        } catch is MimoFirewallLockBusy {
            try owner.check()
            guard nativePolicyOwner === owner, closed == blocked, gateState == state else { throw CancellationError() }
            // No acquisition means no stamp or PF write. The sequential watchdog
            // retries on its next turn; it is not a failed path/IP verification.
            fields["reason"] = "pf_lock_busy"
            RuntimeLog.shared.info("mimo_native_policy_deferred", fields: fields)
        } catch {
            fields["reason"] = "policy_or_readback_failed"
            fields["errorType"] = String(describing: type(of: error))
            RuntimeLog.shared.info("mimo_native_policy_failed", fields: fields)
            throw error
        }
    }

    private func nativePolicyWork<T: Sendable>(_ owner: MimoNativePolicyOwner,
        operation: @escaping @Sendable () throws -> T) async -> Result<T, Error>? {
        await withTaskCancellationHandler {
            await firewallPreparationQueue.run { Result { try owner.check(); return try operation() } }
        } onCancel: { owner.cancel() }
    }

    private nonisolated static func nativePolicyMilliseconds(_ duration: Duration) -> Int64 {
        let value = duration.components
        return value.seconds * 1_000 + value.attoseconds / 1_000_000_000_000_000
    }

    private nonisolated func nativePolicyScope(state: String) throws -> MimoNativePolicyScope {
        try secureDirectory(directory)
        func read(_ name: String) throws -> String {
            let path = directory.appendingPathComponent(name)
            try secureFile(path)
            return try String(contentsOf: path, encoding: .utf8)
        }
        let epoch = try read("pf-mutation.epoch")
        let close = try read("pf-close.epoch")
        guard !epoch.isEmpty, !close.isEmpty, try read("gate.state") == state else { throw CancellationError() }
        let expected = try read("guard.expected")
        guard try read("pf-mutation.epoch") == epoch, try read("pf-close.epoch") == close,
              try read("gate.state") == state else { throw CancellationError() }
        return .init(state: state, mutationEpoch: epoch, closeEpoch: close, expectedRules: expected)
    }

    private nonisolated func prepareNativePolicyUpdate(owner: MimoNativePolicyOwner, state: String,
        policy: MimoPreparedProbePolicy?, previousNative: MimoNativeEgress,
        interfaces: [String], group: UInt32) throws -> MimoNativePolicyPreparation? {
        try owner.check()
        let scope = try nativePolicyScope(state: state)
        do {
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard live.status == 0, live.text == scope.expectedRules else { throw DaemonFailure.conflict }
            if state == "active" {
                guard let policy, try nativeTunnelInterfaces() == interfaces, live.text == policy.activeRules,
                      MimoFirewallPolicy.isActiveReadback(live.text, group: group, nativeInterfaces: interfaces,
                        nativeEgress: previousNative) else { throw DaemonFailure.conflict }
            } else {
                guard MimoFirewallPolicy.isBlockedSnapshot(live.text, nativeEgress: .init()) ||
                      MimoFirewallPolicy.isBlockedSnapshot(live.text, nativeEgress: previousNative) else { throw DaemonFailure.conflict }
            }
            let native = MimoNativeEgressProbe.snapshot()
            try validateNativePolicyScope(scope, owner: owner)
            let rules: String
            if state == "active" {
                guard native != previousNative else { return nil }
                rules = try MimoFirewallPolicy.activePolicy(group: group, nativeInterfaces: interfaces, nativeEgress: native)
            } else {
                let destinations = try localTCPDestinations()
                guard !MimoFirewallPolicy.isBlockedSnapshot(live.text, nativeEgress: native) ||
                      MimoFirewallPolicy.inboundDestinations(in: live.text) != destinations else { return nil }
                rules = try MimoFirewallPolicy.blockedPolicy(nativeEgress: native, destinations: destinations)
            }
            return .init(scope: scope, native: native, rules: rules, interfaces: interfaces)
        } catch {
            // A concurrent guard/close can change the readback while the probe
            // runs. Attribute errors only to an unchanged owned snapshot.
            try validateNativePolicyScope(scope, owner: owner)
            throw error
        }
    }

    private nonisolated func prepareDirectTrackingUpdate(owner: MimoNativePolicyOwner) throws -> MimoNativePolicyPreparation? {
        try owner.check()
        let scope = try nativePolicyScope(state: "direct")
        do {
            guard MimoFirewallPolicy.isDirectTrackingSnapshot(scope.expectedRules) else { throw DaemonFailure.conflict }
            let destinations = try localTCPDestinations()
            let rules = try MimoFirewallPolicy.directTracking(destinations: destinations)
            try validateNativePolicyScope(scope, owner: owner)
            // The periodic health-only comparison does not call PF or renew any
            // timestamps when the captured address inventory is unchanged.
            guard rules != scope.expectedRules else { return nil }
            let actual = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard actual.status == 0, actual.text == scope.expectedRules else { throw DaemonFailure.conflict }
            try validateNativePolicyScope(scope, owner: owner)
            return .init(scope: scope, native: .init(), rules: rules, interfaces: [])
        } catch {
            try validateNativePolicyScope(scope, owner: owner)
            throw error
        }
    }

    private nonisolated func validateNativePolicyScope(_ scope: MimoNativePolicyScope,
                                                       owner: MimoNativePolicyOwner) throws {
        try owner.check()
        guard try nativePolicyScope(state: scope.state) == scope else { throw CancellationError() }
    }

    private nonisolated func commitNativePolicyUpdate(_ prepared: MimoNativePolicyPreparation,
                                                       owner: MimoNativePolicyOwner) throws -> MimoNativePolicyCommit {
        let waiting = ContinuousClock.now
        return try MimoFirewallLock.mutate(directory: directory, admitting: {
            // All ownership checks precede epoch stamping, including same-policy
            // ABA. A rejected old worker must not invalidate newer health proof.
            try validateNativePolicyScope(prepared.scope, owner: owner)
            // Interface notifications may lag a physical address change. Fence
            // the captured prefix under the lock before changing any epoch.
            guard let destinations = MimoFirewallPolicy.inboundDestinations(in: prepared.rules),
                  try localTCPDestinations() == destinations else { throw CancellationError() }
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("maintenance").path),
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent("infrastructure-repair").path),
                  !networkReleaseRequested,
                  try prepared.scope.state != "active" || nativeTunnelInterfaces() == prepared.interfaces else { throw CancellationError() }
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard live.status == 0, live.text == prepared.scope.expectedRules else {
                try validateNativePolicyScope(prepared.scope, owner: owner)
                throw DaemonFailure.conflict
            }
        }) {
            let acquired = ContinuousClock.now
            // Cancellation may arrive after admission. Avoid starting a child;
            // stamping already occurred, so the newer owner must still reconcile.
            try owner.check()
            let epoch = try String(contentsOf: directory.appendingPathComponent("pf-mutation.epoch"), encoding: .utf8)
            do {
                try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: Data(prepared.rules.utf8))
                let observedAt = Date.now
                let readback = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
                guard readback.status == 0,
                      prepared.scope.state != "blocked" ? readback.text == prepared.rules :
                        (MimoFirewallPolicy.isBlockedSnapshot(readback.text, nativeEgress: prepared.native) &&
                         MimoFirewallPolicy.inboundDestinations(in: readback.text) == MimoFirewallPolicy.inboundDestinations(in: prepared.rules)) else { throw DaemonFailure.conflict }
                _ = try writePrivate(Data(readback.text.utf8), name: "guard.expected")
                let health = MimoPFHealthReceipt(mutationEpoch: epoch, state: prepared.scope.state,
                    policyDigest: MimoPFHealthReceipt.digest(Data(readback.text.utf8)), observedAt: observedAt, completedAt: .now)
                RuntimeLog.shared.info("mimo_native_policy_readback", fields: ["operation": owner.id.uuidString,
                    "state": prepared.scope.state, "lockWait_ms": String(Self.nativePolicyMilliseconds(waiting.duration(to: acquired))),
                    "physicalWork_ms": String(Self.nativePolicyMilliseconds(acquired.duration(to: .now)))])
                return .init(health: health, readback: readback.text)
            } catch {
                try owner.check()
                guard try String(contentsOf: directory.appendingPathComponent("pf-mutation.epoch"), encoding: .utf8) == epoch,
                      try String(contentsOf: directory.appendingPathComponent("pf-close.epoch"), encoding: .utf8) == prepared.scope.closeEpoch,
                      try String(contentsOf: directory.appendingPathComponent("gate.state"), encoding: .utf8) == prepared.scope.state else { throw CancellationError() }
                throw error
            }
        }
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
                  let activeRules = installedPolicy?.activeRules, quickNetworkMatches,
                  try nativeTunnelInterfaces() == installedPolicy?.nativeInterfaces,
                  receiptIsCurrent(receipt) else {
                throw MimoRuntimeError.unavailable("The runtime is changing or being repaired. Fresh verification is required.")
            }
            timing.record("grant_identity")
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            let expected = try String(contentsOf: directory.appendingPathComponent("guard.expected"), encoding: .utf8)
            guard live.status == 0, live.text == expected,
                  MimoFirewallPolicy.isVerificationReadback(live.text),
                  let verificationCloseEpoch,
                  verificationCloseEpoch == (try String(contentsOf: directory.appendingPathComponent("pf-close.epoch"), encoding: .utf8)) else {
                throw MimoRuntimeError.unavailable("A newer firewall closure revoked this verification.")
            }
            try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: Data(activeRules.utf8))
            let active = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard active.status == 0, MimoFirewallPolicy.isActiveReadback(active.text, group: group,
                nativeInterfaces: installedPolicy?.nativeInterfaces ?? [], nativeEgress: installedPolicy?.nativeEgress ?? .init()) else { throw DaemonFailure.conflict }
            _ = try writePrivate(Data(active.text.utf8), name: "guard.expected")
            timing.record("grant_permission")
            RuntimeLog.shared.info("mimo_active_firewall_installed", fields: ["policy": "deny-native-fallback"])
            _ = try writePrivate(Data("active".utf8), name: "gate.state")
            closed = false
        }
    }

    func restoreDirect(maintenanceRecovery: Bool = false, uninstalling: Bool = false, owner: MimoDirectReleaseRequest? = nil) throws {
        if networkReleaseRequested, !uninstalling { return }
        cancelApplicationGate(); cancelConnectionCleanup()
        var releasedEpoch: String?
        try withFirewallLock {
            if let owner { try validateDirectRelease(owner) }
            guard maintenanceRecovery || !maintenanceActive else { throw MimoRuntimeError.unavailable("Service installation is in progress.") }
            // Close and drain while the old TUN still exists. Release only after
            // the native resolver, legacy settings and tunnel have been restored.
            try installPF(MimoFirewallPolicy.startupBlocking, requiresRuntimeGroup: false)
            let releaseEpoch = try String(contentsOf: directory.appendingPathComponent("pf-close.epoch"), encoding: .utf8)
            closed = true
            _ = try writePrivate(Data("restoring".utf8), name: "gate.state")
            profileWillChange?()
            defer { profileDidChange?() }
            try dns.removeAndDrain()
            do { try loadProfile(MihomoProfile.blocking()) }
            catch {
                // A freshly repaired launchd job may still be the guarded core
                // wrapper, waiting for this lifecycle lock before exec. It has
                // no TUN to release. Stopping it here races every repair and can
                // prevent the engine from ever reaching its blocking controller.
                // libproc's PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; the
                // expression macro is not imported by Swift.
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let wrapper = runningProcessID(MimoRuntime.engineLabel).map {
                    proc_pidpath($0, &path, UInt32(path.count)) > 0 &&
                        String(cString: path) == MimoRuntime.engineLauncher.path
                } ?? false
                if !wrapper || if_nametoindex(MihomoProfile.tunnelDevice) != 0 {
                    try changeJobUnderFirewallLock(.mihomo, operation: .stop)
                }
            }
            guard if_nametoindex(MihomoProfile.tunnelDevice) == 0 else {
                throw MimoRuntimeError.unavailable("The previous tunnel has not finished closing.")
            }
            try clearOwnedPolicyChildren()
            try MimoIPv4Configuration.apply(restoring: true)
            try installPF(uninstalling ? MimoFirewallPolicy.direct : MimoFirewallPolicy.directTracking, requiresRuntimeGroup: false,
                          releaseEpoch: releaseEpoch, maintenanceRelease: maintenanceRecovery || uninstalling, releaseOwner: owner)
            releasedEpoch = releaseEpoch
            if uninstalling {
                if let token = try currentEnableToken() { try command("/sbin/pfctl", ["-X", token]) }
                enableToken = nil
                let reference = directory.appendingPathComponent("pf-reference.json")
                if FileManager.default.fileExists(atPath: reference.path) { try FileManager.default.removeItem(at: reference) }
            }
            RuntimeLog.shared.info(uninstalling ? "mimo_direct_network_released" : "mimo_direct_tracking_ready")
        }
        // Native connectivity is evidence after release, not a firewall mutation.
        // Do not hold the lifecycle lock across a slow/disconnected Tailnet query.
        let native = BoundedProcess.run("/usr/bin/perl", [MimoService.support.appendingPathComponent("release-network.pl").path, "--verify-native"], timeout: 20)
        nativeReleaseIssue = native.status == 0 ? nil : "Native networking restored. Tailnet DNS could not be verified; check Tailscale."
        if nativeReleaseIssue != nil { RuntimeLog.shared.error("mimo_native_release_check_failed") }
        else { RuntimeLog.shared.info("mimo_native_release_checked") }
        if let owner, let releasedEpoch { try confirmDirectRelease(owner, epoch: releasedEpoch) }
    }

    private func confirmDirectRelease(_ owner: MimoDirectReleaseRequest, epoch: String) throws {
        // Native verification may take time. A maintenance or power closure in
        // that interval owns the network now; never return an old success receipt.
        try MimoFirewallLock.read {
            try validateDirectRelease(owner)
            guard gateState == "direct",
                  epoch == (try String(contentsOf: directory.appendingPathComponent("pf-close.epoch"), encoding: .utf8)) else {
                throw DaemonFailure.conflict
            }
            let observedAt = Date.now
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard live.status == 0, MimoFirewallPolicy.isDirectTrackingSnapshot(live.text),
                  live.text == (try String(contentsOf: directory.appendingPathComponent("guard.expected"), encoding: .utf8)) else {
                throw DaemonFailure.conflict
            }
            latestPFHealthReceipt = .init(mutationEpoch: try String(contentsOf: directory.appendingPathComponent("pf-mutation.epoch"), encoding: .utf8),
                state: "direct", policyDigest: MimoPFHealthReceipt.digest(Data(live.text.utf8)), observedAt: observedAt, completedAt: .now)
        }
    }

    /// Keep all live control/state work responsive while the existing privileged
    /// transaction runs in a short-lived copy of the signed core executable.
    func restoreDirectOnline() async throws {
        cancelNativePolicyUpdates()
        await drainNativePolicyUpdates()
        let saved = try savedRouting()
        guard saved.configuration.mode == .direct, !maintenanceActive, !networkReleaseRequested else {
            throw DaemonFailure.conflict
        }
        let owner = MimoDirectReleaseRequest(id: UUID(), parentPID: getpid(),
            parentIdentity: try processIdentity(getpid()), revision: saved.revision)
        let path = directory.appendingPathComponent("direct-release.json")
        _ = try writePrivate(JSONEncoder().encode(owner), name: "direct-release.json")
        cancelApplicationGate(); cancelConnectionCleanup(); revokeBaseline()
        loadedProfile = nil; deliveredContents = nil; installedPolicy = nil
        expectedPolicies = [:]; verificationCloseEpoch = nil
        dns.discardReceipt()
        closed = false
        onlineDirectRelease = true
        infrastructureEpoch &+= 1
        profileWillChange?()
        defer {
            profileDidChange?()
            onlineDirectRelease = false
            if (try? Data(contentsOf: path)).flatMap({ try? JSONDecoder().decode(MimoDirectReleaseRequest.self, from: $0) }) == owner {
                try? FileManager.default.removeItem(at: path)
            }
        }
        RuntimeLog.shared.info("mimo_direct_worker_started", fields: ["operation": owner.id.uuidString, "parentPID": String(owner.parentPID)])
        // This task is owned/joined by the supervisor, not by an XPC caller's
        // cancellation. run() returns only after the child has physically exited.
        guard let joined = await directReleaseQueue.run({
            let result = Result { try MimoJoinedDirectProcess.run(owner) }
            if case .failure = result {
                // A failed or malformed result cannot leave released networking
                // unconfirmed. Reclose on the same worker, while the live owner
                // token still forbids either child from mutating a newer intent.
                let closed = (try? MimoJoinedDirectProcess.run(owner, closingAfterFailure: true)) != nil
                return (result, closed)
            }
            return (result, false)
        }) else { throw CancellationError() }
        let (outcome, failureClosed) = joined
        if case .failure = outcome { closed = failureClosed && gateState == "blocked" }
        let result = try outcome.get()
        guard gateState == "direct", if_nametoindex(MihomoProfile.tunnelDevice) == 0 else {
            let closure = await directReleaseQueue.run {
                (try? MimoJoinedDirectProcess.run(owner, closingAfterFailure: true)) != nil
            }
            closed = closure == true && gateState == "blocked"
            throw MimoRuntimeError.unavailable("Direct cleanup could not be confirmed. Retry Direct.")
        }
        closed = false
        if let receipt = result.pfHealth, pfHealthReceiptIsCurrent(receipt) { latestPFHealthReceipt = receipt }
        nativeReleaseIssue = result.nativeVerified ? nil : "Native networking restored. Tailnet DNS could not be verified; check Tailscale."
        RuntimeLog.shared.info("mimo_direct_worker_finished", fields: ["operation": owner.id.uuidString, "parentPID": String(owner.parentPID)])
    }

    func closeDirectFailure(owner: MimoDirectReleaseRequest) throws {
        // Close is safe only for the still-live Direct owner. An abandoned child
        // must not close a replacement supervisor's newly approved profile.
        try withFirewallLock {
            try validateDirectRelease(owner)
            try installPF(MimoFirewallPolicy.startupBlocking, requiresRuntimeGroup: false, closeOwner: owner)
            _ = try writePrivate(Data("blocked".utf8), name: "gate.state")
            closed = true
        }
    }

    func directReleaseRequest(id: UUID) throws -> MimoDirectReleaseRequest {
        let request = try readDirectReleaseRequest()
        guard request.id == id else { throw DaemonFailure.conflict }
        try validateDirectRelease(request)
        return request
    }

    private func readDirectReleaseRequest() throws -> MimoDirectReleaseRequest {
        let path = directory.appendingPathComponent("direct-release.json")
        try secureFile(path)
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 4096 else { throw DaemonFailure.unavailable }
        return try JSONDecoder().decode(MimoDirectReleaseRequest.self, from: Data(contentsOf: path))
    }

    private func validateDirectRelease(_ owner: MimoDirectReleaseRequest) throws {
        let current = try readDirectReleaseRequest()
        let saved = try savedRouting()
        guard try owner.isCurrent(record: current, parent: getppid(), identity: processIdentity(owner.parentPID),
                                  savedRevision: saved.revision, mode: saved.configuration.mode,
                                  maintenance: maintenanceActive, released: networkReleaseRequested) else {
            throw MimoRuntimeError.unavailable("A newer operation superseded Direct cleanup.")
        }
    }

    func configureProtectedDNS() throws {
        try dns.install(willChange: profileWillChange, didChange: profileDidChange)
        // openGate verifies the live resolver and engine-owned TCP/UDP
        // listeners immediately before activation. Avoid repeating that same
        // inspection here while application traffic is still blocked.
    }

    var protectedDNSConfigurationMatches: Bool { dns.matches }

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

    private func installPF(_ rules: String, requiresRuntimeGroup: Bool = true, validated: MimoPreparedProbePolicy? = nil,
                           releaseEpoch: String? = nil, maintenanceRelease: Bool = false, releaseOwner: MimoDirectReleaseRequest? = nil, closeOwner: MimoDirectReleaseRequest? = nil) throws {
        if let validated {
            guard requiresRuntimeGroup, validated.rules == rules, validated.group == group else {
                throw MimoRuntimeError.unavailable("The validated firewall rules changed before installation.")
            }
        }
        guard !requiresRuntimeGroup || group != UInt32.max else { throw MimoRuntimeError.unavailable("The dedicated runtime group is missing.") }
        let main = BoundedProcess.run("/sbin/pfctl", ["-sr"])
        guard main.status == 0, main.text.contains("anchor \"com.apple/*\""),
              !main.text.contains("pass out quick"), !main.text.contains("pass quick") else {
            RuntimeLog.shared.error("mimo_pf_parent_inspection_failed", fields: [
                "status": String(main.status), "applicationAnchor": String(main.text.contains("anchor \"com.apple/*\"")),
                "earlyPass": String(main.text.contains("pass out quick") || main.text.contains("pass quick"))
            ])
            throw MimoRuntimeError.unavailable("PF has no supported application anchor. Keep Direct selected and repair setup.")
        }
        installedPolicy = nil; verifiedBaseline = nil
        let bytes = Data(rules.utf8)
        _ = try writePrivate(bytes, name: "guard.pf")
        if validated == nil {
            try command("/sbin/pfctl", ["-n", "-a", MimoFirewallPolicy.anchor, "-f", "-"], input: bytes)
        }
        // Apply exactly the bytes that were checked, not a mutable file path.
        let tracksIncoming = MimoFirewallPolicy.isDirectTrackingSnapshot(rules)
        let closesOutgoing = MimoFirewallPolicy.isStartupBlockingSnapshot(rules)
        let restoresNative = rules.isEmpty || tracksIncoming
        _ = try MimoFirewallLock.mutate(revoking: closesOutgoing, admitting: {
            if let closeOwner { try validateDirectRelease(closeOwner) }
            if let releaseOwner { try validateDirectRelease(releaseOwner) }
            if restoresNative {
                guard maintenanceRelease || !maintenanceActive, let releaseEpoch,
                      releaseEpoch == (try String(contentsOf: directory.appendingPathComponent("pf-close.epoch"), encoding: .utf8)) else {
                    throw MimoRuntimeError.unavailable("A newer transition superseded network release. Retry cleanup.")
                }
            }
        }) {
            try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: bytes)
            if closesOutgoing {
                try MimoPowerGuard.revokeOutboundStates()
            }
            let readback = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            let matches = rules.isEmpty ? readback.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty :
                tracksIncoming ? readback.text == rules :
                closesOutgoing ? (MimoFirewallPolicy.isClosedSnapshot(readback.text) &&
                    MimoFirewallPolicy.inboundDestinations(in: readback.text) == MimoFirewallPolicy.inboundDestinations(in: rules)) :
                MimoFirewallPolicy.isVerificationReadback(readback.text)
            guard readback.status == 0, matches else {
                throw MimoRuntimeError.unavailable("The installed firewall rules could not be read back.")
            }
            _ = try writePrivate(Data(readback.text.utf8), name: "guard.expected")
            if restoresNative {
                // Publish the Direct marker under the same owner/epoch guard
                // as packet policy. A later closure must retain its own marker.
                _ = try writePrivate(Data("direct".utf8), name: "gate.state")
                closed = false
            }
            return readback
        }
        RuntimeLog.shared.info("mimo_pf_policy_installed", fields: ["policy": closesOutgoing ? "startup" : tracksIncoming ? "direct-tracking" : rules == MimoFirewallPolicy.direct ? "released" : "probe"])

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
            Self.processLivenessFailure(loadedProfile.process, started: loadedProfile.started,
                executable: MimoRuntime.engine.path, uid: 0, gid: group) == nil
    }

    func loadProfile(_ profile: String) throws {
        try controllerLock.withLock { try loadProfileUnderControllerLock(profile) }
    }

    func prepareHostnameBootstrap() throws {
        guard closed else { throw DaemonFailure.unavailable }
        revokeBaseline()
        try dns.removeAndDrain()
        let blocking = MihomoProfile.blocking()
        try loadProfile(blocking)
        guard try matches(blocking, active: false), if_nametoindex(MihomoProfile.tunnelDevice) == 0 else {
            throw MimoRuntimeError.unavailable("The previous proxy tunnel could not be removed before bootstrap DNS.")
        }
        RuntimeLog.shared.info("mimo_hostname_bootstrap_ready")
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
        let dnsMatches = dns.matches, receiptMatches = receiptMatchesLoadedProfile(receipt)
        guard dnsMatches, receiptMatches else {
            RuntimeLog.shared.info("mimo_readiness_probe_unavailable", fields: [
                "stage": "confirmation", "dns": String(dnsMatches), "receipt": String(receiptMatches)
            ])
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

    /// Release only Mimo's ownership. Never flush global PF state, disable PF,
    /// remove another VPN's routes, or require a working engine controller.
    func releaseNetworking() async throws {
        guard networkReleaseRequested else { throw DaemonFailure.conflict }
        _ = try writePrivate(Data("releasing".utf8), name: "gate.state")
        cancelApplicationGate(); cancelConnectionCleanup(); revokeBaseline()
        try holdApplicationGate()
        try dns.removeAndDrain()
        loadedProfile = nil; deliveredContents = nil; installedPolicy = nil
        let process = runningProcessID(MimoRuntime.engineLabel)
        try withFirewallLock {
            try command("/bin/launchctl", ["disable", "system/\(MimoRuntime.engineLabel)"])
            try changeJobUnderFirewallLock(.mihomo, operation: .stop)
        }
        // bootout may return before the old process has relinquished its TUN.
        for _ in 0..<40 {
            if process == nil || kill(process!, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // A failed step must not prevent the remaining restoration attempts.
        var errors: [String] = []
        if let process, kill(process, 0) == 0 { errors.append("The engine has not exited. Retry Stop engine.") }
        func attempt(_ operation: () throws -> Void) {
            do { try operation() } catch { errors.append(error.localizedDescription) }
        }
        attempt { try dns.remove() }
        // The guard takes the same lifecycle lock itself.
        attempt { try command("/usr/bin/perl", [MimoRuntime.guardScript.path, "--remove"], timeout: 20) }
        attempt {
            try withFirewallLock {
                try MimoFirewallLock.mutate {
                    try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-F", "rules"])
                    if let token = try currentEnableToken() { try command("/sbin/pfctl", ["-X", token]) }
                    enableToken = nil
                    let reference = directory.appendingPathComponent("pf-reference.json")
                    if FileManager.default.fileExists(atPath: reference.path) { try FileManager.default.removeItem(at: reference) }
                }
                try MimoIPv4Configuration.apply(restoring: true)
            }
        }
        attempt {
            guard runningProcessID(MimoRuntime.engineLabel) == nil,
                  if_nametoindex(MihomoProfile.tunnelDevice) == 0 else {
                throw MimoRuntimeError.unavailable("The engine or its tunnel is still present.")
            }
            let processes = BoundedProcess.run("/bin/ps", ["-axo", "comm="])
            guard processes.status == 0, !processes.text.split(separator: "\n").contains(Substring(MimoRuntime.engine.path)) else {
                throw MimoRuntimeError.unavailable("An owned engine process is still present.")
            }
            let rules = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard rules.status == 0, rules.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MimoRuntimeError.unavailable("Mimo's firewall rules have not been released.")
            }
            var info = stat()
            if lstat(MimoRuntime.controller.path, &info) == 0 {
                guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFSOCK else { throw DaemonFailure.unavailable }
                try FileManager.default.removeItem(at: MimoRuntime.controller)
            }
        }
        guard errors.isEmpty else { throw MimoRuntimeError.unavailable(errors.joined(separator: " ")) }
        _ = try writePrivate(Data("released".utf8), name: "gate.state")
        closed = false
        RuntimeLog.shared.info("mimo_network_released")
    }

    /// Preflight before withdrawing the saved release intent. A conflict leaves
    /// networking released; the user can stop the competing service and retry.
    func checkEngineStartConflicts() throws {
        let processes = BoundedProcess.run("/bin/ps", ["-axo", "pid=,comm="])
        guard processes.status == 0 else { throw DaemonFailure.unavailable }
        for line in processes.text.split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let path = String(fields[1]).trimmingCharacters(in: .whitespaces)
            let name = (path as NSString).lastPathComponent.lowercased()
            if path == MimoRuntime.engine.path {
                throw MimoRuntimeError.unavailable("Mimo's previous engine is still stopping. Retry network cleanup first.")
            }
            if path != MimoRuntime.engine.path, name.contains("mihomo") || ["clash", "clash-meta", "sing-box"].contains(name) {
                throw MimoRuntimeError.unavailable("Another VPN engine (\(name), PID \(fields[0])) is running. Stop it and try Start engine again. Mimo networking remains released.")
            }
        }
        for port in [MimoRuntime.mixedPort, MimoRuntime.dnsPort, MimoRuntime.probePort] {
            let result = BoundedProcess.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
            guard result.status == 1, result.text.isEmpty else {
                throw MimoRuntimeError.unavailable("Port \(port) is in use or could not be checked. Stop the other network service and retry. Mimo networking remains released.")
            }
        }
        let udpDNS = BoundedProcess.run("/usr/sbin/lsof", ["-nP", "-iUDP:\(MimoRuntime.dnsPort)", "-t"])
        guard udpDNS.status == 1, udpDNS.text.isEmpty else {
            throw MimoRuntimeError.unavailable("UDP port \(MimoRuntime.dnsPort) is in use or could not be checked. Stop the other network service and retry. Mimo networking remains released.")
        }
        guard if_nametoindex(MihomoProfile.tunnelDevice) == 0 else {
            throw MimoRuntimeError.unavailable("The tunnel interface is in use. Mimo networking remains released.")
        }
    }

    /// Caller already owns the firewall lock, including offline Direct recovery.
    private func changeJobUnderFirewallLock(_ service: MimoServiceID, operation: MimoServiceOperation) throws {
        let label: String
        switch service { case .core: throw DaemonFailure.invalidRequest; case .mihomo: label = MimoRuntime.engineLabel; default: throw DaemonFailure.invalidRequest }
        let job = "system/\(label)", plist = MimoRuntime.jobDirectory.appendingPathComponent("\(label).plist")
        let inspection = BoundedProcess.run("/bin/launchctl", ["print", job], captureError: true)
        let loaded = inspection.status == 0
        guard loaded || (inspection.status == 113 && inspection.text.contains("Could not find service")) else {
            throw MimoRuntimeError.unavailable("Could not inspect the background service.")
        }
        if operation == .stop { try command("/bin/launchctl", ["disable", job]) }
        if operation != .start, loaded { try command("/bin/launchctl", ["bootout", job], timeout: 8) }
        if operation != .stop, operation != .start || !loaded {
            try secureDirectory(MimoRuntime.jobDirectory)
            try secureFile(plist)
            try command("/bin/launchctl", ["enable", job])
            try command("/bin/launchctl", ["bootstrap", "system", plist.path], timeout: 8)
        }
        // Publish Stop only after launchd accepted the operation. Intent alone
        // cannot prove that the process or its controller actually stopped.
        engineInspection = .init(id: .mihomo, health: operation == .stop ? .stopped : .restarting,
                                 transport: "HTTP / SOCKS · Unix controller", checkedAt: .now)
    }

    nonisolated func isRunning(_ label: String) -> Bool {
        let result = BoundedProcess.run("/bin/launchctl", ["print", "system/\(label)"])
        return result.status == 0 && result.text.contains("state = running")
    }

    nonisolated func runningProcessID(_ label: String) -> Int32? {
        let result = BoundedProcess.run("/bin/launchctl", ["print", "system/\(label)"])
        guard result.status == 0, result.text.contains("state = running") else {
            RuntimeLog.shared.info("mimo_process_readback_unavailable", fields: [
                "service": label, "status": String(result.status),
                "running": String(result.text.contains("state = running"))
            ])
            return nil
        }
        for line in result.text.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("pid = ") { return Int32(line.dropFirst(6)) }
        }
        RuntimeLog.shared.info("mimo_process_readback_unavailable", fields: ["service": label, "stage": "missing_pid"])
        return nil
    }

    private nonisolated func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3, input: Data? = nil) throws {
        let started = ContinuousClock.now
        let result = BoundedProcess.run(executable, arguments, timeout: timeout, input: input)
        guard result.status == 0 else {
            // Report the command outcome without arguments, stdin, paths or
            // captured output, which can contain private profile data.
            let elapsed = started.duration(to: .now).components
            RuntimeLog.shared.error("mimo_runtime_command_failed", fields: [
                "program": (executable as NSString).lastPathComponent,
                "operation": executable == "/sbin/pfctl" ? (arguments.first ?? "unknown") : "system",
                "status": String(result.status), "timeoutSeconds": String(timeout),
                "durationMS": String(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
            ])
            throw MimoRuntimeError.unavailable("A required \((executable as NSString).lastPathComponent) operation failed. Traffic was not approved.")
        }
    }

    private nonisolated func secureController() throws {
        // The shared support root is traversable for installer discovery. The
        // controller's own directory remains root-only, including at creation.
        try secureDirectory(MimoRuntime.profileDirectory.deletingLastPathComponent())
        var directoryInfo = stat()
        guard lstat(MimoRuntime.profileDirectory.path, &directoryInfo) == 0, directoryInfo.st_uid == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR, directoryInfo.st_mode & 0o077 == 0 else {
            throw MimoRuntimeError.unavailable("Mihomo's controller directory is not private. Repair installation.")
        }
        var info = stat()
        guard lstat(MimoRuntime.controller.path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFSOCK else {
            throw MimoRuntimeError.unavailable("Mihomo's private controller is missing or unsafe. Repair installation.")
        }
        // Mihomo explicitly creates its Unix socket as 0666 despite the inherited
        // umask. Its root-only directory prevents access during creation;
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

// Protected operations yield the state actor while a single owned queue executes
// immutable fixed-path work. Cancellation revokes admission immediately but never
// abandons a running mutation; newer profile/Direct operations join this queue.
extension MimoSystemRuntime {
    func cancelProtectedIO() { cancelNativePolicyUpdates(); protectedLease?.cancel(); verifiedBaseline = nil }

    func drainProtectedIO() async {
        await drainNativePolicyUpdates()
        // Use an unstructured join so a cancelled caller cannot skip the barrier.
        let queue = protectedQueue
        let join = Task { _ = await queue.run { true } }
        await join.value
        await finishProtectedObservation()
    }

    private func beginProtectedObservation(_ lease: MimoProtectedLease) async throws {
        await profileObservationCompletion?.value
        if profileObservationOwner != nil, profileObservationOwner != lease.id { await finishProtectedObservation() }
        try lease.check()
        if profileObservationOwner == nil { profileObservationOwner = lease.id; profileWillChange?() }
    }

    private func finishProtectedObservation(owner: UUID? = nil) async {
        if let pending = profileObservationCompletion { await pending.value; return }
        guard let current = profileObservationOwner, owner == nil || current == owner else { return }
        profileObservationOwner = nil
        let id = UUID(); profileObservationCompletionID = id
        let callback = profileDidChangeOnline
        let task = Task<Void, Never> { await callback?() }
        profileObservationCompletion = task
        await task.value
        if profileObservationCompletionID == id { profileObservationCompletion = nil }
    }

    func beginProtectedIO(configuration: MimoConfiguration, revision: Int) -> MimoProtectedLease {
        cancelNativePolicyUpdates()
        protectedLease?.cancel()
        let lease = MimoProtectedLease(configuration: configuration, revision: revision)
        protectedLease = lease
        return lease
    }

    private func protectedWork<T: Sendable>(_ lease: MimoProtectedLease,
        operation: @escaping @Sendable () throws -> T) async throws -> T {
        guard protectedLease === lease else { throw CancellationError() }
        try lease.check()
        protectedWorkCount += 1
        defer { protectedWorkCount -= 1 }
        let result = await withTaskCancellationHandler {
            await protectedQueue.run { Result { try lease.check(); return try operation() } }
        } onCancel: { lease.cancel() }
        guard protectedLease === lease else { throw CancellationError() }
        try lease.check()
        guard let result else { throw CancellationError() }
        return try result.get()
    }

    func installProbePolicyOnline(_ policy: MimoPreparedProbePolicy, lease: MimoProtectedLease) async throws {
        guard closed, policy.group == group else { throw DaemonFailure.conflict }
        let receipt = try await protectedWork(lease) { try MimoProtectedIO().install(policy, lease: lease) }
        installedPolicy = policy; enableToken = receipt.enableToken; verificationCloseEpoch = receipt.closeEpoch
    }

    func loadProtectedProfile(_ profile: String, lease: MimoProtectedLease, untilDNS: Bool = true) async throws {
        notificationEngineProcess = try await protectedWork(lease) { MimoProtectedIO().runningProcess() }
        loadedProfile = nil; deliveredContents = nil; protectedLoadedReceipt = nil
        try await beginProtectedObservation(lease)
        let lock = controllerLock
        let receipt: MimoLoadedProfileReceipt
        do {
            receipt = try await protectedWork(lease) {
                try lock.withLock { try MimoProtectedIO().loadProfile(profile, lease: lease) }
            }
        } catch {
            await finishProtectedObservation(owner: lease.id)
            throw error
        }
        if !untilDNS { await finishProtectedObservation(owner: lease.id) }
        try lease.check()
        loadedProfile = (SHA256.hash(data: Data(profile.utf8)), receipt.process, receipt.identity)
        protectedLoadedReceipt = receipt; deliveredContents = profile
    }

    func configureProtectedDNSOnline(lease: MimoProtectedLease) async throws {
        let owner = protectedDNS
        try await beginProtectedObservation(lease)
        let receipt: Data
        do { receipt = try await protectedWork(lease) { try owner.install { try MimoProtectedIO().check(lease) } } }
        catch { await finishProtectedObservation(owner: lease.id); throw error }
        await finishProtectedObservation(owner: lease.id)
        try lease.check()
        try dns.adoptReceipt(receipt)
        protectedDNSReceipt = receipt
    }

    func prepareHostnameBootstrapOnline(lease: MimoProtectedLease) async throws {
        guard closed else { throw DaemonFailure.conflict }
        revokeBaseline()
        let owner = protectedDNS
        try await beginProtectedObservation(lease)
        do { try await protectedWork(lease) { try owner.removeAndDrain { try MimoProtectedIO().check(lease) } } }
        catch { await finishProtectedObservation(owner: lease.id); throw error }
        dns.discardReceipt(); protectedDNSReceipt = nil
        try await loadProtectedProfile(MihomoProfile.blocking(), lease: lease, untilDNS: false)
        guard if_nametoindex(MihomoProfile.tunnelDevice) == 0 else { throw DaemonFailure.conflict }
        RuntimeLog.shared.info("mimo_hostname_bootstrap_ready")
    }

    func permitPrivateProbeOnline(lease: MimoProtectedLease, fence: MimoPowerFence, powerEpoch: UInt64) async throws {
        guard closed, let policy = installedPolicy, let closeEpoch = verificationCloseEpoch else { throw DaemonFailure.conflict }
        let epoch = try await protectedWork(lease) {
            try MimoProtectedIO().permit(policy, closeEpoch: closeEpoch, lease: lease, fence: fence, powerEpoch: powerEpoch)
        }
        verificationCloseEpoch = epoch
    }

    func confirmReadinessOnline(_ receipt: MimoReadinessReceipt, lease: MimoProtectedLease) async throws {
        guard receiptMatchesLoadedProfile(receipt), let loaded = protectedLoadedReceipt, let dnsReceipt = protectedDNSReceipt else { throw DaemonFailure.conflict }
        try await protectedWork(lease) {
            try MimoProtectedIO().check(lease)
            guard receipt.checkedAt.duration(to: .now) < .seconds(15),
                  MimoProtectedDNSIO.matches(dnsReceipt),
                  Self.processLivenessFailure(loaded.process, started: loaded.identity,
                    executable: MimoRuntime.engine.path, uid: 0, gid: self.group) == nil else { throw DaemonFailure.conflict }
            try self.secureController()
        }
    }

    func acceptBaselineOnline(_ receipt: MimoReadinessReceipt, lease: MimoProtectedLease) async throws {
        try await confirmReadinessOnline(receipt, lease: lease)
        verifiedBaseline = (receipt.profileDigest, receipt.process)
    }

    func openGateOnline(receipt: MimoReadinessReceipt, address: String, lease: MimoProtectedLease, fence: MimoPowerFence, powerEpoch: UInt64) async throws {
        guard closed, let loaded = protectedLoadedReceipt, let dnsReceipt = protectedDNSReceipt,
              let policy = installedPolicy, let closeEpoch = verificationCloseEpoch else { throw DaemonFailure.conflict }
        cancelApplicationGate()
        do {
            try await protectedWork(lease) {
                try MimoProtectedIO().grant(policy, loaded: loaded, dns: dnsReceipt, closeEpoch: closeEpoch,
                    readiness: receipt, address: address, nativeInterfaces: { try self.nativeTunnelInterfaces() }, lease: lease, fence: fence, powerEpoch: powerEpoch)
            }
        } catch {
            let original = error
            // Cancellation can win after a child commits but before its receipt
            // resumes this actor. Join compensation only for that exact mutation.
            let queue = protectedQueue
            let cleanup = Task { await queue.run { Result { try MimoProtectedIO().closeOwnedGrant(lease) } } }
            if let result = await cleanup.value { try result.get() }
            throw original
        }
        if let receipt = lease.ownedGrantHealth, pfHealthReceiptIsCurrent(receipt) { latestPFHealthReceipt = receipt }
        closed = false
    }

    func holdApplicationGateOnline() async throws {
        let token = requestApplicationGate()
        try await confirmApplicationGate(token)
    }
}
