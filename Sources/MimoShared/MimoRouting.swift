import Foundation

public enum ProxyMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case direct, rule, global
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var requiresVerification: Bool { self != .direct }
}

public enum MimoAccessPhase: String, Codable, Sendable {
    case closing, blocked, validating, checking, restoringDirect, active, unavailable
}

/// Public metadata only. Passwords stay in core-owned local storage.
public struct MimoProxy: Codable, Equatable, Sendable {
    public var name: String
    public var type: ClashProxySettings.ProxyType
    public var server: String
    public var port: Int
    public var username: String
    public init(_ proxy: ClashProxySettings) {
        name = proxy.name; type = proxy.type; server = proxy.server
        port = proxy.port; username = proxy.username
    }
    public func settings(password: String = "") throws -> ClashProxySettings {
        try ClashProxySettings(name: name, type: type, server: server, port: port,
                               username: username, password: password).validated()
    }
}

public struct MimoSavedProxy: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var proxy: MimoProxy
    public var hasPassword: Bool
    public init(id: UUID = UUID(), proxy: MimoProxy, hasPassword: Bool = false) {
        self.id = id; self.proxy = proxy; self.hasPassword = hasPassword
    }
}

public struct MimoConfiguration: Codable, Equatable, Sendable {
    public var mode: ProxyMode = .direct
    public var networkFamily: MimoNetworkFamily = .ipv4
    /// Selected metadata, retained for runtime consumers and legacy-state migration.
    public var proxy: MimoProxy?
    /// nil identifies the pre-2.1 single-proxy format. An empty list is intentional.
    public var proxies: [MimoSavedProxy]?
    public var activeProxyID: UUID?
    public var profileHostingEnabled = true
    public var mihomoEnabled = true
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case mode, networkFamily, proxy, proxies, activeProxyID, profileHostingEnabled, mihomoEnabled
    }
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        mode = try value.decodeIfPresent(ProxyMode.self, forKey: .mode) ?? .direct
        networkFamily = try value.decodeIfPresent(MimoNetworkFamily.self, forKey: .networkFamily) ?? .ipv4
        proxy = try value.decodeIfPresent(MimoProxy.self, forKey: .proxy)
        proxies = try value.decodeIfPresent([MimoSavedProxy].self, forKey: .proxies)
        activeProxyID = try value.decodeIfPresent(UUID.self, forKey: .activeProxyID)
        profileHostingEnabled = try value.decodeIfPresent(Bool.self, forKey: .profileHostingEnabled) ?? true
        mihomoEnabled = try value.decodeIfPresent(Bool.self, forKey: .mihomoEnabled) ?? true
    }
    public func validated() throws -> Self {
        var result = self
        if let proxy { result.proxy = MimoProxy(try proxy.settings()) }
        if var entries = proxies {
            guard entries.count <= 256, Set(entries.map(\.id)).count == entries.count else { throw DaemonFailure.invalidRequest }
            for index in entries.indices { entries[index].proxy = MimoProxy(try entries[index].proxy.settings()) }
            guard Set(entries.map { $0.proxy.name.lowercased() }).count == entries.count else { throw DaemonFailure.invalidRequest }
            if let activeProxyID, !entries.contains(where: { $0.id == activeProxyID }) { throw DaemonFailure.invalidRequest }
            result.proxies = entries
            result.proxy = entries.first(where: { $0.id == activeProxyID })?.proxy
        }
        return result
    }
}

public enum MimoServiceID: String, CaseIterable, Codable, Sendable, Identifiable {
    case core, mihomo, profileHosting
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .core: "IP monitor"
        case .mihomo: "mihomo"
        case .profileHosting: "Profile hosting"
        }
    }
}

public enum MimoServiceOperation: String, Codable, Sendable { case start, stop, restart }

/// Persisted lifecycle intent. Stopping a job survives supervisor restarts and reboot.
public struct MimoServicePreferences: Codable, Equatable, Sendable {
    public var core = true
    public var engine = true
    public var profile = true
    /// Persisted before teardown; absent in version 1 means managed networking.
    public var releaseNetwork: Bool?
    public var networkReleaseRequested: Bool { releaseNetwork == true }
    public init() {}
}
public enum MimoServiceHealth: String, Codable, Sendable { case running, stopped, suspended, restarting, unavailable, notInstalled }
public struct MimoServiceStatus: Codable, Equatable, Sendable, Identifiable {
    public var id: MimoServiceID
    public var health: MimoServiceHealth
    public var transport: String
    public var address: String?
    public var port: Int?
    public var bindingConfirmed: Bool
    /// Time the service owner inspected this status, retained through cached replies.
    public var checkedAt: Date?
    public init(id: MimoServiceID, health: MimoServiceHealth, transport: String,
                address: String? = nil, port: Int? = nil, bindingConfirmed: Bool = false, checkedAt: Date? = nil) {
        self.id = id; self.health = health; self.transport = transport
        self.address = address; self.port = port; self.bindingConfirmed = bindingConfirmed
        self.checkedAt = checkedAt
    }

    public func healthTitle(at date: Date) -> String {
        switch health {
        case .running:
            guard let age = MimoHealthLabel.age(checkedAt: checkedAt, at: date) else { return "Unavailable" }
            return age <= 35 ? "Healthy" : "Check overdue"
        case .stopped: return "Stopped"
        case .suspended: return "Suspended"
        case .restarting: return "Restarting"
        case .unavailable: return "Unavailable"
        case .notInstalled: return "Not installed"
        }
    }
}

public enum MimoHealthLabel {
    public static func age(checkedAt: Date?, at date: Date) -> Int? {
        guard let checkedAt else { return nil }
        let seconds = date.timeIntervalSince(checkedAt)
        guard seconds.isFinite, seconds >= -5, seconds < Double(Int.max) else { return nil }
        return Int(max(0, seconds))
    }

    public static func text(_ title: String, checkedAt: Date?, at date: Date) -> String {
        let age = age(checkedAt: checkedAt, at: date).map { "\($0) secs" } ?? "—"
        return "\(title)(\(age))"
    }
}

public struct MimoIPObservation: Codable, Equatable, Sendable {
    public var address: String
    public var checkedAt: Date
    public init(address: String, checkedAt: Date) { self.address = address; self.checkedAt = checkedAt }
}

public enum MimoInfrastructureHealth: String, Codable, Sendable {
    case healthy, released, failed, stale, unknown
    public var title: String {
        switch self { case .healthy: "Healthy"; case .released: "Released"; case .failed: "Needs repair"; case .stale: "Check overdue"; case .unknown: "Unavailable" }
    }
}

/// Last supervisor inspection, never inferred from the selected routing mode.
public enum MimoInfrastructureCheckOutcome: String, Codable, Sendable {
    case completed, deferred, superseded, failed
}

public struct MimoInfrastructureInspection: Codable, Equatable, Sendable {
    public var id: String
    public var generation: UInt64
    public var startedAt: Date
    public var completedAt: Date?
    public var outcome: MimoInfrastructureCheckOutcome?
    public var reason: String?
    public var isCurrent: Bool
    public init(id: String, generation: UInt64, startedAt: Date, completedAt: Date? = nil,
                outcome: MimoInfrastructureCheckOutcome? = nil, reason: String? = nil, isCurrent: Bool = true) {
        self.id = id; self.generation = generation; self.startedAt = startedAt
        self.completedAt = completedAt; self.outcome = outcome; self.reason = reason; self.isCurrent = isCurrent
    }
}

public struct MimoInfrastructureStatus: Codable, Equatable, Sendable {
    public var pf: MimoInfrastructureHealth
    public var launchd: MimoInfrastructureHealth
    public var checkedAt: Date?
    public var pfCheckedAt: Date?
    public var launchdCheckedAt: Date?
    public var completedAt: Date?
    public var inspection: MimoInfrastructureInspection?
    public var pfEvidenceCurrent: Bool?
    public init(pf: MimoInfrastructureHealth = .unknown, launchd: MimoInfrastructureHealth = .unknown, checkedAt: Date? = nil,
                pfCheckedAt: Date? = nil, launchdCheckedAt: Date? = nil, completedAt: Date? = nil,
                inspection: MimoInfrastructureInspection? = nil, pfEvidenceCurrent: Bool? = nil) {
        self.pf = pf; self.launchd = launchd; self.checkedAt = checkedAt
        self.pfCheckedAt = pfCheckedAt; self.launchdCheckedAt = launchdCheckedAt
        self.completedAt = completedAt; self.inspection = inspection
        self.pfEvidenceCurrent = pfEvidenceCurrent
    }
    public func current(at date: Date) -> Self {
        var result = self
        func current(_ health: MimoInfrastructureHealth, observed: Date?, owned: Bool = true) -> MimoInfrastructureHealth {
            guard let observed else { return .unknown }
            let age = date.timeIntervalSince(observed)
            guard age >= -5, age <= 35 else { return .stale }
            if !owned { return .unknown }
            return health
        }
        result.pf = current(pf, observed: pfCheckedAt ?? checkedAt, owned: pfEvidenceCurrent != false)
        result.launchd = current(launchd, observed: launchdCheckedAt ?? checkedAt)
        return result
    }

    public func healthLabel(firewall: Bool, at date: Date) -> String {
        let current = current(at: date)
        let health = firewall ? current.pf : current.launchd
        let observed = firewall ? (pfCheckedAt ?? checkedAt) : (launchdCheckedAt ?? checkedAt)
        var title = health.title
        if health != .stale && health != .failed, let inspection {
            if firewall && pfEvidenceCurrent == false { title = "Check pending" }
            else if inspection.isCurrent && (inspection.outcome == .deferred || inspection.outcome == .superseded) { title = "Check pending" }
            else if inspection.isCurrent && inspection.outcome == nil { title = "Checking" }
        }
        return MimoHealthLabel.text(title, checkedAt: observed, at: date)
    }
}

/// A verification result is useful only for exactly this configuration/network transition.
public struct MimoVerification: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let networkGeneration: UInt64
    public let startedAt: Date?
    public init(revision: Int, networkGeneration: UInt64) {
        id = UUID(); self.revision = revision; self.networkGeneration = networkGeneration; startedAt = .now
    }
}

public struct MimoRoutingState: Codable, Equatable, Sendable {
    public var networkReleaseRequested: Bool?
    public var networkReleased: Bool?
    public var configuration: MimoConfiguration
    public var phase: MimoAccessPhase = .unavailable
    public var effectiveMode: ProxyMode?
    public var reason = "The traffic supervisor is unavailable."
    public var observedIP: MimoIPObservation?
    public var ipv6Observation: MimoIPObservation?
    public var exitObservations: MimoExitObservations?
    /// Display-only history; no gate/receipt validation consumes this value.
    public var lastExitObservation: MimoSnapshot?
    public var blockingIP: MimoIPObservation?
    public var verification: MimoVerification?
    /// A check of an unchanged approved path; never grants permission by itself.
    public var observation: MimoVerification?
    public var observationFailed: Bool?
    /// Traffic is allowed after optimistic checks while the full audit runs.
    /// Optional for compatibility with earlier stored snapshots.
    public var backgroundVerification: Bool?
    public var services: [MimoServiceStatus] = []
    /// Independent PF/launchd health. Nil means no audit has been observed yet.
    public var infrastructure: MimoInfrastructureStatus?
    public var heartbeatHealth: MimoInfrastructureHealth?
    public var heartbeatCheckedAt: Date?
    /// Time the supervisor produced this state; retained through core/UI caches.
    public var supervisorCheckedAt: Date?
    public var hasProxyPassword = false
    public var mihomoVersion: String?
    public init(configuration: MimoConfiguration = MimoConfiguration()) { self.configuration = configuration }
    public var allowsTraffic: Bool { phase == .active && effectiveMode == configuration.mode }
    public var rejectedExit: MimoIPObservation? {
        guard configuration.mode.requiresVerification, phase == .blocked else { return nil }
        return blockingIP
    }
    public func observation(for family: MimoAddressFamily) -> MimoIPObservation? {
        family == .ipv4 ? observedIP : ipv6Observation
    }
    public var displayedIP: MimoIPObservation? {
        guard ![.unavailable, .closing, .restoringDirect].contains(phase) else { return nil }
        return blockingIP ?? observedIP
    }
    public var lastKnownExit: MimoSnapshot? {
        guard configuration.mode.requiresVerification, observedIP == nil,
              [.blocked, .unavailable].contains(phase) else { return nil }
        return lastExitObservation
    }
}

/// A service action's confirmed closure must not be replaced by an older core
/// snapshot that still says Allowed. Only fresh progress/proof can replace it.
public enum MimoServiceProgress {
    public static func canReplace(_ pending: MimoRoutingState, with current: MimoRoutingState,
                                  startedAt: Date, configurationAdvanced: Bool) -> Bool {
        // A failed supervisor poll has no new supervisor timestamp. It must
        // still remove any assurance that the last confirmed barrier is live.
        if current.phase == .unavailable { return true }
        if let barrier = pending.supervisorCheckedAt {
            guard let checkedAt = current.supervisorCheckedAt, checkedAt >= barrier else { return false }
        }
        if pending.networkReleaseRequested == true {
            // A fresh post-operation report may also confirm that Stop was
            // rejected before persisting intent. Do not leave stale progress up.
            return current.networkReleased == true || current.phase == .restoringDirect ||
                (current.networkReleaseRequested == false && (current.supervisorCheckedAt ?? .distantPast) > startedAt)
        }
        if current.configuration.mode != pending.configuration.mode { return configurationAdvanced }
        if [.blocked, .validating, .checking, .unavailable].contains(current.phase) { return true }
        guard current.allowsTraffic, let observation = current.observedIP else { return false }
        return observation.checkedAt > startedAt && observation.checkedAt > (pending.observedIP?.checkedAt ?? .distantPast)
    }
}

/// Pure authorization policy. The owner must close the firewall BEFORE calling begin/invalidate,
/// and open it only after approve succeeds and the effective runtime policy has been verified.
public struct MimoAccessPolicy: Sendable {
    public private(set) var state: MimoRoutingState
    public init(configuration: MimoConfiguration = MimoConfiguration()) {
        state = MimoRoutingState(configuration: configuration)
    }

    public mutating func beginObservation(revision: Int, networkGeneration: UInt64) -> MimoVerification? {
        guard state.allowsTraffic, state.configuration.mode.requiresVerification, state.observedIP != nil else { return nil }
        let check = MimoVerification(revision: revision, networkGeneration: networkGeneration)
        state.observation = check; state.observationFailed = false
        state.reason = "Checking exit IP · traffic remains allowed."
        return check
    }

    public mutating func finishObservation(_ observations: MimoExitObservations, allowlist: AllowedIPList) -> Bool {
        guard let check = state.observation, state.allowsTraffic, let since = check.startedAt,
              observations.isValid(for: check, family: state.configuration.networkFamily, since: since) else { return false }
        state.observedIP = .init(address: observations.ipv4.ipAddress, checkedAt: observations.ipv4.checkedAt)
        state.exitObservations = observations
        state.observation = nil; state.observationFailed = false
        if revokeDisallowed(allowlist) { return false }
        state.reason = "IPv4 exit IP approved."
        return true
    }

    public mutating func failObservation(_ check: MimoVerification) {
        guard state.observation == check, state.allowsTraffic else { return }
        state.observation = nil; state.observationFailed = true
        state.reason = "Check failed · using last approved result. Traffic remains allowed."
    }

    /// Owner must establish the block before publishing a revoked policy.
    @discardableResult
    public mutating func revokeDisallowed(_ allowlist: AllowedIPList) -> Bool {
        guard state.allowsTraffic, state.configuration.mode.requiresVerification,
              let current = state.observedIP, !allowlist.contains(current.address) else { return false }
        state.blockingIP = current
        block(allowlist.isEmpty ? "No exit IPs are approved. Review Allowed IPs in Settings."
              : "The observed IPv4 exit IP is not approved. Review Allowed IPs or select another proxy.")
        return true
    }

    @discardableResult
    public mutating func begin(configuration: MimoConfiguration, revision: Int, networkGeneration: UInt64) -> MimoVerification {
        state.observation = nil; state.observationFailed = nil
        state.backgroundVerification = nil
        let verification = MimoVerification(revision: revision, networkGeneration: networkGeneration)
        state.configuration = configuration
        state.phase = .validating
        state.effectiveMode = nil
        state.reason = "Validating the profile. Internet remains blocked."
        state.observedIP = nil
        state.blockingIP = nil
        state.ipv6Observation = nil; state.exitObservations = nil
        state.verification = verification
        return verification
    }

    public mutating func checking(_ verification: MimoVerification) {
        guard state.verification == verification else { return }
        state.phase = .checking
        state.reason = "Checking the exit IP. Internet remains blocked."
    }

    public mutating func waitingForReadiness(address: String, verification: MimoVerification) {
        guard state.verification == verification, state.phase == .checking else { return }
        state.observedIP = MimoIPObservation(address: address, checkedAt: .now)
        state.blockingIP = nil
        state.reason = "Exit IP approved. Checking profile, tunnel and DNS. Internet remains blocked."
    }

    @discardableResult
    public mutating func approve(observations: MimoExitObservations, allowlist: AllowedIPList,
                                 verification: MimoVerification, runtimeMatches: Bool) -> Bool {
        guard state.verification == verification, state.phase == .checking,
              state.configuration.mode.requiresVerification,
              state.configuration.proxy != nil, state.configuration.profileHostingEnabled, state.configuration.mihomoEnabled,
              let since = verification.startedAt,
              observations.isValid(for: verification, family: state.configuration.networkFamily, since: since) else { return false }
        state.observedIP = .init(address: observations.ipv4.ipAddress, checkedAt: observations.ipv4.checkedAt)
        state.ipv6Observation = nil
        state.exitObservations = observations
        for observation in [state.observedIP].compactMap({ $0 }) {
            guard allowlist.contains(observation.address) else {
                state.blockingIP = observation
                block(allowlist.isEmpty ? "No exit IPs are approved. Review Allowed IPs in Settings."
                    : "The observed IPv4 exit IP is not approved. Review Allowed IPs or select another proxy.")
                return false
            }
        }
        guard runtimeMatches else { block("The effective profile does not match the verified candidate."); return false }
        state.phase = .active; state.effectiveMode = state.configuration.mode
        state.reason = "IPv4 exit IP approved."
        state.blockingIP = nil; state.verification = nil
        return true
    }

    @discardableResult
    public mutating func approve(address: String, at date: Date, allowlist: AllowedIPList,
                                 verification: MimoVerification, runtimeMatches: Bool) -> Bool {
        guard state.configuration.mode.requiresVerification,
              state.configuration.proxy != nil, state.configuration.profileHostingEnabled, state.configuration.mihomoEnabled,
              state.verification == verification,
              state.phase == .checking,
              let address = IPAddressValidator.normalize(address) else { return false }
        let observation = MimoIPObservation(address: address, checkedAt: date)
        state.observedIP = observation
        guard !address.contains(":") else {
            state.blockingIP = observation
            block("An IPv4 exit address is required for verification in both traffic settings.")
            return false
        }
        guard !allowlist.isEmpty, allowlist.contains(address) else {
            state.blockingIP = observation
            block(allowlist.isEmpty ? "The allowed exit IP list is empty." : "Exit IP \(address) is not on the allowed list.")
            return false
        }
        guard runtimeMatches else { block("The effective runtime profile does not match the validated profile."); return false }
        state.phase = .active
        state.effectiveMode = state.configuration.mode
        state.reason = "Exit IP approved."
        state.blockingIP = nil
        state.verification = nil // A successful proof cannot be replayed.
        return true
    }

    public mutating func directRestored(configuration: MimoConfiguration, nativeIssue: String? = nil) {
        state.observation = nil; state.observationFailed = nil
        state.backgroundVerification = nil
        state.configuration = configuration
        state.configuration.mode = .direct
        state.phase = .active; state.effectiveMode = .direct
        state.reason = nativeIssue ?? "System networking without Mimo proxy routing or firewall restrictions."
        state.verification = nil; state.blockingIP = nil; state.observedIP = nil
        state.ipv6Observation = nil; state.exitObservations = nil
    }

    public mutating func restoringDirect(configuration: MimoConfiguration) {
        directRestored(configuration: configuration)
        state.phase = .restoringDirect; state.effectiveMode = nil
        state.reason = "Switching to Direct. Removing proxy routing and restoring system DNS."
    }

    public mutating func releasing(configuration: MimoConfiguration, error: String? = nil) {
        directRestored(configuration: configuration)
        state.phase = error == nil ? .restoringDirect : .unavailable
        state.effectiveMode = nil
        state.reason = error.map { "Network cleanup incomplete: \($0) Retry Stop engine." }
            ?? "Stopping engine and restoring system networking…"
    }

    public mutating func networkReleased(configuration: MimoConfiguration, reason: String = "Mimo routing is off. Other VPNs can manage networking.") {
        directRestored(configuration: configuration)
        state.reason = reason
    }

    public mutating func block(_ reason: String, confirmed: Bool = true) {
        state.observation = nil; state.observationFailed = nil
        state.backgroundVerification = nil
        state.phase = confirmed ? .blocked : .unavailable
        state.effectiveMode = nil
        state.reason = reason
        state.verification = nil
    }

    public mutating func requestingBlock(_ reason: String) {
        state.observation = nil; state.observationFailed = nil
        state.backgroundVerification = nil
        state.phase = .closing
        state.effectiveMode = nil
        state.reason = reason
        state.verification = nil
    }

    public mutating func auditing(_ pending: Bool) {
        guard state.allowsTraffic, state.configuration.mode.requiresVerification else { return }
        state.backgroundVerification = pending
        state.reason = pending ? "Exit IP approved. Internet is allowed while background verification runs." : "Exit IP approved. Background verification passed."
    }
}

/// Ordering identity for one core process. Authorization still uses the XPC peer.
public struct MimoCommandStamp: Codable, Equatable, Sendable {
    public let controller: UUID
    public let sequence: UInt64
    public init(controller: UUID, sequence: UInt64) {
        self.controller = controller; self.sequence = sequence
    }
}

public struct MimoSupervisorRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        case state, heartbeat, prepare, approve, close, direct, service, profile
        case observe, completeObservation, observationFailed, updatePolicy
    }
    public var command: Command
    /// A heartbeat receipt only; no state read, policy change, or ordering advance.
    public var livenessOnly: Bool?
    /// Read-only diagnostics, requested explicitly by the Event Log window.
    public var includeEvents: Bool?
    public var configuration: MimoConfiguration?
    public var verification: MimoVerification?
    public var allowlist: AllowedIPList?
    public var address: String?
    public var exitObservations: MimoExitObservations?
    public var revision: Int?
    public var networkGeneration: UInt64?
    public var service: MimoServiceID?
    public var operation: MimoServiceOperation?
    public var stamp: MimoCommandStamp?
    /// Diagnostic context only; neither field grants authority or changes ordering.
    public var lookupID: UUID?
    public var reason: String?
    public init(_ command: Command) { self.command = command }

    /// Deliberately excludes proxy configuration, addresses and credentials.
    public var diagnosticFields: [String: String] {
        var fields = ["command": command.rawValue]
        fields["sequence"] = stamp.map { String($0.sequence) }
        fields["controller"] = stamp?.controller.uuidString
        fields["revision"] = revision.map(String.init)
        fields["generation"] = networkGeneration.map(String.init)
        fields["lookup"] = lookupID?.uuidString
        fields["attempt"] = verification?.id.uuidString
        return fields
    }
}

public enum MimoRuntime {
    public static let version = "1.19.34-mimo-v3.2"
    public static let proxyPasswordAccount = "mimo-machine-proxy-password"
    public static let supervisorLabel = "com.mimo.supervisor"
    public static let engineLabel = "com.mimo.mihomo"
    public static let engineGroup = "_mimo"
    public static let supervisorPlist = "/Library/LaunchDaemons/\(supervisorLabel).plist"
    public static let bootGuardLabel = "com.mimo.pf-boot"
    public static let infrastructureLabel = "com.mimo.infrastructure"
    public static let guardDirectory = URL(fileURLWithPath: "/Library/Application Support/Mimo/Guard", isDirectory: true)
    public static let guardScript = guardDirectory.appendingPathComponent("pf-guard.pl")
    // Three existing launchd identities, each with its own background-item name.
    // The utility mimo-core itself is not a fourth daemon.
    public static let jobDirectory = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
    public static let helperDirectory = MimoService.support.appendingPathComponent("LaunchHelpers", isDirectory: true)
    public static let supervisorExecutable = helperDirectory.appendingPathComponent("mimo-core-supervisor")
    public static let heartbeatExecutable = helperDirectory.appendingPathComponent("mimo-core-heartbeat")
    public static let engineLauncher = helperDirectory.appendingPathComponent("mihomo")
    public static let directory = MimoService.support.appendingPathComponent("Runtime", isDirectory: true)
    public static let engine = directory.appendingPathComponent("mihomo")
    // Recovery journals stay in their established location across upgrades. Only
    // credential-free bootstrap data and the private controller live here.
    public static let profileDirectory = URL(fileURLWithPath: "/Library/Application Support/Mimo/Mihomo", isDirectory: true)
    public static let controller = profileDirectory.appendingPathComponent("controller.sock")
    public static let blockingProfile = profileDirectory.appendingPathComponent("blocking.yaml")
    public static let probePort = 17891
    public static let mixedPort = 7890
    public static let dnsPort = 1053
    public static let dnsStateKey = "State:/Network/Service/com.mimo.dns/DNS"
    public static let probeUser = "mimo-core"
    public static let lookupHosts = ["api.ipinfo.io", "v4.api.ipinfo.io", "v6.api.ipinfo.io", "ipapi.co", "ipwho.is", "api.ipapi.is", "api4.ipify.org", "api6.ipify.org"]
}
