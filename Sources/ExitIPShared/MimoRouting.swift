import Foundation

public enum ProxyMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case direct, rule, global
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var requiresVerification: Bool { self != .direct }
}

public enum MimoAccessPhase: String, Codable, Sendable {
    case blocked, validating, checking, active, unavailable
}

/// Public metadata only. The password lives in a distinct System Keychain account.
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

public struct MimoConfiguration: Codable, Equatable, Sendable {
    public var mode: ProxyMode = .direct
    public var proxy: MimoProxy?
    public var profileHostingEnabled = true
    public var mihomoEnabled = true
    public init() {}
    public func validated() throws -> Self {
        var result = self
        if let proxy { result.proxy = MimoProxy(try proxy.settings()) }
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
    public init() {}
}
public enum MimoServiceHealth: String, Codable, Sendable { case running, stopped, restarting, unavailable, notInstalled }
public struct MimoServiceStatus: Codable, Equatable, Sendable, Identifiable {
    public var id: MimoServiceID
    public var health: MimoServiceHealth
    public var transport: String
    public var address: String?
    public var port: Int?
    public var bindingConfirmed: Bool
    public init(id: MimoServiceID, health: MimoServiceHealth, transport: String,
                address: String? = nil, port: Int? = nil, bindingConfirmed: Bool = false) {
        self.id = id; self.health = health; self.transport = transport
        self.address = address; self.port = port; self.bindingConfirmed = bindingConfirmed
    }
}

public struct MimoIPObservation: Codable, Equatable, Sendable {
    public var address: String
    public var checkedAt: Date
    public init(address: String, checkedAt: Date) { self.address = address; self.checkedAt = checkedAt }
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
    public var configuration: MimoConfiguration
    public var phase: MimoAccessPhase = .unavailable
    public var effectiveMode: ProxyMode?
    public var reason = "The traffic supervisor is unavailable."
    public var observedIP: MimoIPObservation?
    public var blockingIP: MimoIPObservation?
    public var verification: MimoVerification?
    public var services: [MimoServiceStatus] = []
    public var hasProxyPassword = false
    public var mihomoVersion: String?
    public init(configuration: MimoConfiguration = MimoConfiguration()) { self.configuration = configuration }
    public var allowsTraffic: Bool { phase == .active && effectiveMode == configuration.mode }
    public var displayedIP: MimoIPObservation? {
        guard phase != .unavailable else { return nil }
        return blockingIP ?? observedIP
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
            block("Mimo is IPv4-only. An IPv6 exit address cannot approve traffic.")
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
        state.configuration = configuration
        state.configuration.mode = .direct
        state.phase = .active; state.effectiveMode = .direct
        state.reason = "IPv4 networking without a proxy. IPv6 remains disabled."
        state.verification = nil; state.blockingIP = nil; state.observedIP = nil
    }

    public mutating func block(_ reason: String, confirmed: Bool = true) {
        state.phase = confirmed ? .blocked : .unavailable
        state.effectiveMode = nil
        state.reason = reason
        state.verification = nil
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
    public enum Command: String, Codable, Sendable { case state, heartbeat, prepare, approve, close, direct, service }
    public var command: Command
    /// A heartbeat receipt only; no state read, policy change, or ordering advance.
    public var livenessOnly: Bool?
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
    public static let supervisorLabel = "com.example.exitipmonitor.supervisor"
    public static let engineLabel = "com.example.exitipmonitor.mihomo"
    public static let engineGroup = "_mimo"
    public static let supervisorPlist = "/Library/LaunchDaemons/\(supervisorLabel).plist"
    // Only the supervisor is automatically bootstrapped by macOS. It registers these
    // independent launchd jobs after establishing the guard and reading stop intent.
    public static let jobDirectory = ExitIPService.support.appendingPathComponent("LaunchDaemons", isDirectory: true)
    public static let directory = ExitIPService.support.appendingPathComponent("Mihomo", isDirectory: true)
    public static let engine = directory.appendingPathComponent("mihomo")
    public static let controller = directory.appendingPathComponent("controller.sock")
    public static let profile = directory.appendingPathComponent("config.yaml")
    public static let blockingProfile = directory.appendingPathComponent("blocking.yaml")
    public static let probePort = 17891
    public static let mixedPort = 7890
    public static let dnsPort = 1053
    public static let dnsStateKey = "State:/Network/Service/com.example.exitipmonitor.dns/DNS"
    public static let probeUser = "mimo-core"
    public static let lookupHosts = ["api.ipinfo.io", "ipapi.co", "ipwho.is", "api.ipapi.is"]
}
