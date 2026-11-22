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
    /// Selected metadata, retained for runtime consumers and legacy-state migration.
    public var proxy: MimoProxy?
    /// nil identifies the pre-2.1 single-proxy format. An empty list is intentional.
    public var proxies: [MimoSavedProxy]?
    public var activeProxyID: UUID?
    public var profileHostingEnabled = true
    public var mihomoEnabled = true
    public init() {}
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
    case core, mihomo, profileHosting, tailnetProvider
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .core: "mimo-core"
        case .mihomo: "mihomo"
        case .profileHosting: "Profile hosting"
        case .tailnetProvider: "Tailnet provider"
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
            return age <= 35 ? "Healthy" : "Stale"
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

/// Last independent inspection, never inferred from the selected routing mode.
public struct MimoInfrastructureStatus: Codable, Equatable, Sendable {
    public var pf: MimoInfrastructureHealth
    public var launchd: MimoInfrastructureHealth
    public var checkedAt: Date?
    public init(pf: MimoInfrastructureHealth = .unknown, launchd: MimoInfrastructureHealth = .unknown, checkedAt: Date? = nil) {
        self.pf = pf; self.launchd = launchd; self.checkedAt = checkedAt
    }
    public func current(at date: Date) -> Self {
        guard let checkedAt else { return Self() }
        let age = date.timeIntervalSince(checkedAt)
        guard age >= -5, age <= 35 else { return Self(pf: .stale, launchd: .stale, checkedAt: checkedAt) }
        return self
    }
}

/// A verification result is useful only for exactly this configuration/network transition.
public struct MimoVerification: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let networkGeneration: UInt64
    public init(revision: Int, networkGeneration: UInt64) {
        id = UUID(); self.revision = revision; self.networkGeneration = networkGeneration
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
    public var blockingIP: MimoIPObservation?
    public var verification: MimoVerification?
    /// Traffic is allowed after optimistic checks while the full audit runs.
    /// Optional for compatibility with earlier stored snapshots.
    public var backgroundVerification: Bool?
    public var services: [MimoServiceStatus] = []
    /// Native Tailscale is starting/running. Nil means it has not been observed yet.
    public var tailnetExpected: Bool?
    public var infrastructure: MimoInfrastructureStatus?
    /// Time the supervisor produced this state; retained through core/UI caches.
    public var supervisorCheckedAt: Date?
    public var hasProxyPassword = false
    public var mihomoVersion: String?
    public init(configuration: MimoConfiguration = MimoConfiguration()) { self.configuration = configuration }
    public var allowsTraffic: Bool { phase == .active && effectiveMode == configuration.mode }
    public var displayedIP: MimoIPObservation? {
        guard ![.unavailable, .closing, .restoringDirect].contains(phase) else { return nil }
        return blockingIP ?? observedIP
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

    @discardableResult
    public mutating func begin(configuration: MimoConfiguration, revision: Int, networkGeneration: UInt64) -> MimoVerification {
        state.backgroundVerification = nil
        let verification = MimoVerification(revision: revision, networkGeneration: networkGeneration)
        state.configuration = configuration
        state.phase = .validating
        state.effectiveMode = nil
        state.reason = "Validating the profile. Internet remains blocked."
        state.observedIP = nil
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
            block("The profile rejects IPv6. An IPv4 exit address is required for verification.")
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

    public mutating func directRestored(configuration: MimoConfiguration) {
        state.backgroundVerification = nil
        state.configuration = configuration
        state.configuration.mode = .direct
        state.phase = .active; state.effectiveMode = .direct
        state.reason = "System networking without Mimo proxy routing or firewall restrictions."
        state.verification = nil; state.blockingIP = nil; state.observedIP = nil
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
        state.backgroundVerification = nil
        state.phase = confirmed ? .blocked : .unavailable
        state.effectiveMode = nil
        state.reason = reason
        state.verification = nil
    }

    public mutating func requestingBlock(_ reason: String) {
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
    public enum Command: String, Codable, Sendable { case state, heartbeat, prepare, approve, close, direct, service, profile }
    public var command: Command
    /// A heartbeat receipt only; no state read, policy change, or ordering advance.
    public var livenessOnly: Bool?
    /// Read-only diagnostics, requested explicitly by the Event Log window.
    public var includeEvents: Bool?
    public var configuration: MimoConfiguration?
    public var verification: MimoVerification?
    public var allowlist: AllowedIPList?
    public var address: String?
    public var revision: Int?
    public var networkGeneration: UInt64?
    public var service: MimoServiceID?
    public var operation: MimoServiceOperation?
    public var stamp: MimoCommandStamp?
    public init(_ command: Command) { self.command = command }
}

public enum MimoRuntime {
    public static let version = "1.19.34"
    public static let proxyPasswordAccount = "mimo-machine-proxy-password"
    public static let supervisorLabel = "com.mimo.supervisor"
    public static let engineLabel = "com.mimo.mihomo"
    public static let engineGroup = "_mimo"
    public static let supervisorPlist = "/Library/LaunchDaemons/\(supervisorLabel).plist"
    public static let bootGuardLabel = "com.mimo.pf-boot"
    public static let infrastructureLabel = "com.mimo.infrastructure"
    public static let guardDirectory = URL(fileURLWithPath: "/Library/Application Support/Mimo/Guard", isDirectory: true)
    public static let guardScript = guardDirectory.appendingPathComponent("pf-guard.pl")
    // The supervisor and independent PF/health jobs start at boot. Core and
    // engine registration is repaired according to the saved service intent.
    public static let jobDirectory = MimoService.support.appendingPathComponent("LaunchDaemons", isDirectory: true)
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
    public static let lookupHosts = ["api.ipinfo.io", "ipapi.co", "ipwho.is", "api.ipapi.is"]
}
