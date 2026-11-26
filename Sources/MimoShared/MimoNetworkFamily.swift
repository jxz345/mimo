import Foundation

public enum MimoNetworkFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case ipv4, dual
    public var id: String { rawValue }
    public var title: String { self == .ipv4 ? "IPv4" : "Dual-stack" }
    public var requiresIPv6: Bool { self == .dual }
}

public enum MimoAddressFamily: String, Codable, Sendable {
    case ipv4, ipv6
    public func accepts(_ address: String) -> Bool {
        guard let key = IPAddressValidator.canonicalKey(address) else { return false }
        return key.count == (self == .ipv4 ? 8 : 32)
    }
}

/// Fresh IPv4 approval is independent of the traffic-family setting. The legacy
/// IPv6 member is decoded only to reject obsolete paired receipts, never required.
public struct MimoExitObservations: Codable, Equatable, Sendable {
    public let verification: MimoVerification
    public let ipv4: MimoSnapshot
    public let ipv6: MimoSnapshot?
    public init(verification: MimoVerification, ipv4: MimoSnapshot, ipv6: MimoSnapshot? = nil) {
        self.verification = verification; self.ipv4 = ipv4; self.ipv6 = ipv6
    }
    public func isValid(for check: MimoVerification, family _: MimoNetworkFamily,
                        since: Date, now: Date = .now) -> Bool {
        guard verification == check, MimoAddressFamily.ipv4.accepts(ipv4.ipAddress),
              ipv4.checkedAt >= since, ipv4.checkedAt <= now.addingTimeInterval(5) else { return false }
        return ipv6 == nil
    }
}
