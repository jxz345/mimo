import CryptoKit
import Darwin
import Foundation

/// Logical ownership can be revoked immediately without abandoning a physical
/// child. All mutable runtime caches stay on the control actor.
final class MimoProtectedLease: @unchecked Sendable {
    let id = UUID()
    let revision: Int
    let configuration: MimoConfiguration
    private let lock = NSLock()
    private var cancelled = false
    private var grantMutation: String?
    private var grantHealth: MimoPFHealthReceipt?

    init(configuration: MimoConfiguration, revision: Int) {
        self.configuration = configuration; self.revision = revision
    }
    func cancel() { lock.withLock { cancelled = true } }
    func recordGrant(_ mutation: String, health: MimoPFHealthReceipt? = nil) { lock.withLock { grantMutation = mutation; grantHealth = health } }
    var ownedGrantMutation: String? { lock.withLock { grantMutation } }
    var ownedGrantHealth: MimoPFHealthReceipt? { lock.withLock { grantHealth } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

struct MimoLoadedProfileReceipt: Sendable {
    let process: Int32
    let identity: String
    let digest: Data
}

struct MimoPFCommitReceipt: Sendable {
    let closeEpoch: String
    let enableToken: String?
}

/// Fixed-path I/O only. This value owns no actor state; inputs and receipts are
/// immutable. The supervisor serializes these operations and joins them before
/// starting a newer profile or Direct cleanup.
struct MimoProtectedIO: Sendable {
    private let directory = MimoRuntime.directory

    func check(_ lease: MimoProtectedLease) throws {
        try lease.check()
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("maintenance").path),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("infrastructure-repair").path) else { throw DaemonFailure.conflict }
        try secureFile(MimoService.storageURL)
        let storage = try FilePreferenceStorage(url: MimoService.storageURL)
        guard storage.integer(forKey: "service.revision") >= lease.revision,
              let data = storage.data(forKey: "service.routing") else { throw DaemonFailure.conflict }
        let saved = try JSONDecoder().decode(MimoConfiguration.self, from: data).validated()
        // Policy-only edits and inactive catalog edits do not change this path.
        let expected = lease.configuration
        guard saved.mode == expected.mode, saved.mode.requiresVerification,
              saved.networkFamily == expected.networkFamily, saved.proxy == expected.proxy,
              saved.activeProxyID == expected.activeProxyID,
              saved.profileHostingEnabled, saved.mihomoEnabled else { throw CancellationError() }
        let preferences = directory.appendingPathComponent("services.json")
        if FileManager.default.fileExists(atPath: preferences.path) {
            try secureFile(preferences)
            let flags = try JSONDecoder().decode(MimoServicePreferences.self, from: Data(contentsOf: preferences))
            guard flags.engine, !flags.networkReleaseRequested else { throw CancellationError() }
        }
    }

    private func validateGroup(_ policy: MimoPreparedProbePolicy) throws {
        guard let group = getgrnam(MimoRuntime.engineGroup), group.pointee.gr_gid == policy.group else { throw DaemonFailure.conflict }
    }

    func install(_ policy: MimoPreparedProbePolicy, lease: MimoProtectedLease) throws -> MimoPFCommitReceipt {
        try check(lease)
        try validateGroup(policy)
        let main = BoundedProcess.run("/sbin/pfctl", ["-sr"])
        guard main.status == 0, main.text.contains("anchor \"com.apple/*\""),
              !main.text.contains("pass out quick"), !main.text.contains("pass quick") else { throw DaemonFailure.unavailable }
        let rules = MimoFirewallPolicy.startupBlocking
        try command("/sbin/pfctl", ["-n", "-a", MimoFirewallPolicy.anchor, "-f", "-"], input: Data(rules.utf8))
        let epoch = try MimoFirewallLock.mutate(revoking: true, admitting: { try check(lease) }) {
            try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: Data(rules.utf8))
            try MimoPowerGuard.revokeOutboundStates()
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard live.status == 0, MimoFirewallPolicy.isClosedReadback(live.text) else { throw DaemonFailure.unavailable }
            try write(Data(live.text.utf8), "guard.expected")
            try write(Data("blocked".utf8), "gate.state")
            return try closeEpoch()
        }
        let token = try MimoFirewallLock.mutate(admitting: { try check(lease) }) { try ensurePFReference() }
        try check(lease)
        RuntimeLog.shared.info("mimo_pf_policy_installed", fields: ["policy": "startup"])
        return MimoPFCommitReceipt(closeEpoch: epoch, enableToken: token)
    }

    func close(request: MimoGateRequest) throws {
        guard !request.isCancelled else { throw CancellationError() }
        try MimoFirewallLock.mutate(revoking: true, admitting: {
            guard !request.isCancelled else { throw CancellationError() }
        }) {
            try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: Data(MimoFirewallPolicy.startupBlocking.utf8))
            try MimoPowerGuard.revokeOutboundStates()
            let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
            guard live.status == 0, MimoFirewallPolicy.isClosedReadback(live.text) else { throw DaemonFailure.unavailable }
            _ = try ensurePFReference()
            try write(Data(live.text.utf8), "guard.expected")
            try write(Data("blocked".utf8), "gate.state")
        }
    }

    func loadProfile(_ profile: String, lease: MimoProtectedLease) throws -> MimoLoadedProfileReceipt {
        try check(lease)
        guard let process = runningProcess() else { throw DaemonFailure.unavailable }
        let identity = try processIdentity(process)
        let bytes = Data(profile.utf8)
        guard !bytes.isEmpty, bytes.count <= 524288 else { throw DaemonFailure.invalidRequest }
        try secureController()
        try command(MimoRuntime.engine.path, ["-t", "-d", MimoRuntime.profileDirectory.path, "-f", "-"], timeout: 5, input: bytes)
        try check(lease)
        let body = try JSONSerialization.data(withJSONObject: ["payload": profile])
        try command("/usr/bin/curl", ["--silent", "--fail", "--max-time", "10", "--unix-socket", MimoRuntime.controller.path,
            "-X", "PUT", "http://localhost/configs?force=true", "--header", "Content-Type: application/json", "--data-binary", "@-"], timeout: 11, input: body)
        try check(lease)
        try secureController()
        guard runningProcess() == process, try processIdentity(process) == identity else { throw DaemonFailure.conflict }
        return MimoLoadedProfileReceipt(process: process, identity: identity, digest: Data(SHA256.hash(data: bytes)))
    }

    func permit(_ policy: MimoPreparedProbePolicy, closeEpoch expected: String,
                lease: MimoProtectedLease, fence: MimoPowerFence, powerEpoch: UInt64) throws -> String {
        try check(lease)
        try validateGroup(policy)
        return try fence.activate(epoch: powerEpoch) {
            try MimoFirewallLock.mutate(admitting: { try check(lease) }) {
                guard try closeEpoch() == expected else { throw CancellationError() }
                try guardedCommit(lease: lease) {
                    try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: Data(policy.rules.utf8))
                    let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
                    guard live.status == 0, MimoFirewallPolicy.isVerificationReadback(live.text) else { throw DaemonFailure.unavailable }
                    try write(Data(live.text.utf8), "guard.expected")
                }
                return try closeEpoch()
            }
        }
    }

    func grant(_ policy: MimoPreparedProbePolicy, loaded: MimoLoadedProfileReceipt, dns: Data,
               closeEpoch expected: String, readiness: MimoReadinessReceipt, address: String, nativeInterfaces: @Sendable () throws -> [String], lease: MimoProtectedLease,
               fence: MimoPowerFence, powerEpoch: UInt64) throws {
        try check(lease)
        try validateGroup(policy)
        var committedMutation: String?
        var observedAt: Date?
        var verifiedPolicy: Data?
        do { try fence.completeCycle(epoch: powerEpoch) {
            try MimoFirewallLock.mutate(admitting: { try check(lease) }) {
                try allowed(address)
                guard let active = policy.activeRules, try closeEpoch() == expected,
                      readiness.process == loaded.process, readiness.profileDigest == loaded.digest,
                      readiness.checkedAt.duration(to: .now) < .seconds(15),
                      try nativeInterfaces() == policy.nativeInterfaces,
                      runningProcess() == loaded.process, try processIdentity(loaded.process) == loaded.identity,
                      if_nametoindex(MihomoProfile.tunnelDevice) != 0,
                      MimoProtectedDNSIO.matches(dns) else { throw DaemonFailure.conflict }
                let before = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
                guard before.status == 0, MimoFirewallPolicy.isVerificationReadback(before.text),
                      before.text == (try String(contentsOf: directory.appendingPathComponent("guard.expected"), encoding: .utf8)) else { throw DaemonFailure.conflict }
                try guardedCommit(lease: lease) {
                    try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: Data(active.utf8))
                    observedAt = .now
                    let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
                    guard live.status == 0, MimoFirewallPolicy.isActiveReadback(live.text, group: policy.group,
                        nativeInterfaces: policy.nativeInterfaces, nativeEgress: policy.nativeEgress) else { throw DaemonFailure.unavailable }
                    try allowed(address)
                    try fence.validateCycleEvents()
                    try write(Data(live.text.utf8), "guard.expected")
                    try write(Data("active".utf8), "gate.state")
                    try fence.validateCycleEvents()
                    verifiedPolicy = Data(live.text.utf8)
                }
                committedMutation = try String(contentsOf: directory.appendingPathComponent("pf-mutation.epoch"), encoding: .utf8)
                if let committedMutation, let observedAt, let verifiedPolicy {
                    lease.recordGrant(committedMutation, health: .init(mutationEpoch: committedMutation, state: "active",
                        policyDigest: MimoPFHealthReceipt.digest(verifiedPolicy), observedAt: observedAt, completedAt: .now))
                }
            }
        }
        try check(lease)
        } catch {
            let original = error
            if let committedMutation {
                try MimoFirewallLock.mutateIfNeeded(when: {
                    try String(contentsOf: directory.appendingPathComponent("pf-mutation.epoch"), encoding: .utf8) == committedMutation &&
                        String(contentsOf: directory.appendingPathComponent("gate.state"), encoding: .utf8) == "active"
                }) { try compensateClosed() }
            }
            throw original
        }
        RuntimeLog.shared.info("mimo_active_firewall_installed", fields: ["policy": "deny-native-fallback"])
    }

    func closeOwnedGrant(_ lease: MimoProtectedLease) throws {
        guard let mutation = lease.ownedGrantMutation else { return }
        try MimoFirewallLock.mutateIfNeeded(when: {
            try String(contentsOf: directory.appendingPathComponent("pf-mutation.epoch"), encoding: .utf8) == mutation &&
                String(contentsOf: directory.appendingPathComponent("gate.state"), encoding: .utf8) == "active"
        }) { try compensateClosed() }
    }

    private func allowed(_ address: String) throws {
        try secureFile(MimoService.storageURL)
        let storage = try FilePreferenceStorage(url: MimoService.storageURL)
        guard let data = storage.data(forKey: "service.settings"),
              try JSONDecoder().decode(MachineSettings.self, from: data).validated().allowlist.contains(address) else { throw DaemonFailure.conflict }
    }

    // Called only while the PF mutation lock is held. A cancellation arriving
    // during a physical pfctl cannot abandon that child or publish its grant.
    private func guardedCommit(lease: MimoProtectedLease, operation: () throws -> Void) throws {
        do { try check(lease); try operation(); try check(lease) }
        catch {
            let original = error
            try compensateClosed()
            throw original
        }
    }

    private func compensateClosed() throws {
        try write(Data(UUID().uuidString.utf8), "pf-close.epoch")
        try command("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-f", "-"], input: Data(MimoFirewallPolicy.startupBlocking.utf8))
        try MimoPowerGuard.revokeOutboundStates()
        let live = BoundedProcess.run("/sbin/pfctl", ["-a", MimoFirewallPolicy.anchor, "-sr"])
        guard live.status == 0, MimoFirewallPolicy.isClosedReadback(live.text) else { throw DaemonFailure.unavailable }
        try write(Data(live.text.utf8), "guard.expected")
        try write(Data("blocked".utf8), "gate.state")
    }

    private func closeEpoch() throws -> String { try String(contentsOf: directory.appendingPathComponent("pf-close.epoch"), encoding: .utf8) }
    private func write(_ data: Data, _ name: String) throws {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: url.path)
    }
    func runningProcess() -> Int32? {
        let result = BoundedProcess.run("/bin/launchctl", ["print", "system/" + MimoRuntime.engineLabel])
        guard result.status == 0, result.text.contains("state = running") else { return nil }
        return result.text.split(separator: "\n").compactMap { line -> Int32? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=")
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "pid" else { return nil }
            return Int32(parts[1].trimmingCharacters(in: .whitespaces))
        }.first
    }
    private func processIdentity(_ pid: Int32) throws -> String {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { throw DaemonFailure.unavailable }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }
    private func secureFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0 else { throw DaemonFailure.unavailable }
    }
    private func secureController() throws {
        var dir = stat(), socket = stat()
        guard lstat(MimoRuntime.profileDirectory.path, &dir) == 0, dir.st_uid == 0,
              dir.st_mode & S_IFMT == S_IFDIR, dir.st_mode & 0o077 == 0,
              lstat(MimoRuntime.controller.path, &socket) == 0, socket.st_uid == 0,
              socket.st_mode & S_IFMT == S_IFSOCK, chmod(MimoRuntime.controller.path, 0o600) == 0 else { throw DaemonFailure.unavailable }
    }
    private func command(_ tool: String, _ arguments: [String], timeout: TimeInterval = 3, input: Data? = nil) throws {
        let result = BoundedProcess.run(tool, arguments, timeout: timeout, input: input)
        guard result.status == 0 else {
            RuntimeLog.shared.error("mimo_protected_io_failed", fields: ["tool": URL(fileURLWithPath: tool).lastPathComponent, "status": String(result.status)])
            throw MimoRuntimeError.unavailable("Protected network operation failed (status \(result.status)).")
        }
    }
    private func ensurePFReference() throws -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0, size < 256 else { throw DaemonFailure.unavailable }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { throw DaemonFailure.unavailable }
        let boot = String(cString: bytes), path = directory.appendingPathComponent("pf-reference.json")
        var previous: String?
        if FileManager.default.fileExists(atPath: path.path) {
            try secureFile(path)
            previous = try JSONDecoder().decode(MimoPFReference.self, from: Data(contentsOf: path)).token(forBoot: boot)
        }
        let references = BoundedProcess.run("/sbin/pfctl", ["-s", "References"])
        let status = BoundedProcess.run("/sbin/pfctl", ["-s", "info"])
        guard references.status == 0, status.status == 0 else { throw DaemonFailure.unavailable }
        if let previous, status.text.contains("Status: Enabled"), MimoPFReference.isLive(previous, references: references.text) { return previous }
        let enabled = BoundedProcess.run("/sbin/pfctl", ["-E"], captureError: true)
        guard enabled.status == 0, let line = enabled.text.split(separator: "\n").first(where: { $0.contains("Token :") }),
              let token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
              !token.isEmpty, token.allSatisfy(\.isNumber) else { throw DaemonFailure.unavailable }
        try write(JSONEncoder().encode(MimoPFReference(token: token, boot: boot)), "pf-reference.json")
        if let previous, MimoPFReference.isLive(previous, references: references.text) { try command("/sbin/pfctl", ["-X", previous]) }
        return token
    }
}
