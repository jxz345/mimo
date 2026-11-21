import Foundation

/// The supervisor's temporary Rule/Global resolver. Claiming every domain makes it
/// the system default, and configd then drops other supplemental services' own
/// search lists. Carry the list the native default would have supplied, so short
/// tailnet names still expand. Every query still reaches only Mimo's listener.
public enum MimoProtectedDNS {
    public static let maximumDomains = 128

    /// `services` are other services' `State:/Network/Service/<id>/DNS` values.
    /// `primary` is the primary service's DNS with saved settings applied. Returns
    /// nil when there are too many domains to override safely.
    public static func resolver(services: [String: [String: Any]], primary: [String: Any]?) -> [String: Any]? {
        // Match each existing supplemental domain at a higher priority, so a native
        // VPN's default or MagicDNS resolver cannot bypass Mimo's DNS policy.
        var domains = Set([""])
        for value in services.values {
            for domain in value["SupplementalMatchDomains"] as? [String] ?? [] where isValid(domain) {
                domains.insert(domain)
            }
        }
        // configd keeps only the default resolver's own SearchDomains (or DomainName).
        // Resolvers claiming every domain, such as MagicDNS, compete for that role
        // with the primary service; keep their lists first.
        let defaults = services.keys.sorted().compactMap { key -> [String: Any]? in
            let value = services[key]!
            return (value["SupplementalMatchDomains"] as? [String])?.contains("") == true ? value : nil
        }
        var search: [String] = [], seen = Set<String>()
        for value in defaults + [primary].compactMap({ $0 }) {
            let names = value["SearchDomains"] as? [String] ?? (value["DomainName"] as? String).map { [$0] } ?? []
            for name in names {
                let domain = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard !domain.isEmpty, isValid(domain), seen.insert(domain.lowercased()).inserted else { continue }
                search.append(domain)
            }
        }
        guard domains.count <= maximumDomains, search.count <= maximumDomains else { return nil }
        var value: [String: Any] = [
            "ServerAddresses": ["127.0.0.1"], "ServerPort": MimoRuntime.dnsPort,
            "SupplementalMatchDomains": domains.sorted(), "SupplementalMatchOrders": domains.map { _ in 1 },
            "SupplementalMatchDomainsNoSearch": 1, "SearchOrder": 1
        ]
        if !search.isEmpty { value["SearchDomains"] = search }
        return value
    }

    static func isValid(_ domain: String) -> Bool {
        domain.utf8.count <= 253 && domain.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }
    }
}
