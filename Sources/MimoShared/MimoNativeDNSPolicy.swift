import Foundation

/// Validated private suffix knowledge. A missing resolver is an explicit local
/// negative response, never permission to use a public resolver.
public struct MimoPrivateDNSRule: Codable, Equatable, Sendable {
    public let suffix: String
    public let servers: [String]
    public let port: Int
    public init(suffix: String, servers: [String], port: Int = 53) throws {
        let name = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard ClashProxySettings.isHostName(name), name.contains("." ) || !name.isEmpty,
              (1...65535).contains(port), servers.count <= 16,
              servers.allSatisfy({ IPAddressValidator.normalize($0) != nil &&
                  !$0.hasPrefix("127.") && $0 != "::1" && !$0.hasPrefix("198.18.") }) else {
            throw DaemonFailure.invalidRequest
        }
        self.suffix = name; self.servers = servers; self.port = port
    }
    public var upstreams: [String] {
        servers.isEmpty ? ["rcode://name_error"] : servers.map {
            "udp://\($0.contains(":") ? "[\($0)]" : $0):\(port)"
        }
    }
}

public enum MimoNativeDNSPolicy {
    public static func rules(services: [String: [String: Any]], primary: [String: Any]?) throws -> [MimoPrivateDNSRule] {
        var result: [String: MimoPrivateDNSRule] = [:]
        // Saved primary-service DNS settings override its DHCP snapshot.
        for value in services.keys.sorted().compactMap({ services[$0] }) + [primary].compactMap({ $0 }) {
            let names = (value["SupplementalMatchDomains"] as? [String] ?? []) +
                (value["SearchDomains"] as? [String] ?? []) +
                (value["DomainName"] as? String).map { [$0] }.orEmpty
            let addresses = value["ServerAddresses"] as? [String] ?? []
            for suffix in names where !suffix.isEmpty {
                let rule = try MimoPrivateDNSRule(suffix: suffix, servers: addresses,
                                                port: value["ServerPort"] as? Int ?? 53)
                result[rule.suffix] = rule
            }
        }
        guard result.count <= MimoProtectedDNS.maximumDomains else { throw DaemonFailure.invalidRequest }
        return result.values.sorted { $0.suffix < $1.suffix }
    }
}

private extension Optional where Wrapped == [String] {
    var orEmpty: [String] { self ?? [] }
}
