import Foundation

/// These checks classify notifications, never grant native transport permission.
/// Unknown fields, public routes and subnet-router routes require verification.
public enum MimoTailnetChangePolicy {
    public static func addressFamily(_ address: String) -> Int? {
        guard let normalized = IPAddressValidator.normalize(address) else { return nil }
        let parts = normalized.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return 4 }
        if normalized.lowercased().hasPrefix("fd7a:115c:a1e0:") { return 6 }
        return nil
    }

    public static func isPrivateRoute(destination: String?, prefixLength: Int?) -> Bool {
        guard let destination, let prefixLength else { return false }
        switch addressFamily(destination) {
        case 4: return (10...32).contains(prefixLength)
        case 6: return (48...128).contains(prefixLength)
        default: return false
        }
    }

    public static func prefixLength(mask: String) -> Int? {
        let parts = mask.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bits = 0, sawZero = false
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            for bit in (0..<8).reversed() {
                if byte & (1 << bit) == 0 { sawZero = true }
                else if sawZero { return nil }
                else { bits += 1 }
            }
        }
        return bits
    }

    public static func isNativeDNS(_ value: [String: Any]) -> Bool {
        let keys: Set<String> = ["ServerAddresses", "InterfaceName", "ConfirmedServiceID", "SupplementalMatchDomains", "SearchDomains", "SearchOrder", "SupplementalMatchOrders", "SupplementalMatchDomainsNoSearch"]
        guard Set(value.keys).isSubset(of: keys),
              let servers = value["ServerAddresses"] as? [String], !servers.isEmpty,
              servers.allSatisfy({ ["100.100.100.100", "fd7a:115c:a1e0::53"].contains(IPAddressValidator.normalize($0) ?? "") }) else { return false }
        for key in ["SupplementalMatchDomains", "SearchDomains"] where value[key] != nil {
            guard let domains = value[key] as? [String], domains.allSatisfy({ domain in
                let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return normalized.isEmpty || normalized.hasSuffix(".ts.net") || normalized == "ts.net"
            }) else { return false }
        }
        return true
    }

    public static func isInactiveProxyConfiguration(_ value: [String: Any]) -> Bool {
        let disabled: Set<String> = ["FTPEnable", "GopherEnable", "HTTPEnable", "HTTPSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable", "RTSPEnable", "SOCKSEnable", "ExcludeSimpleHostnames"]
        return value.allSatisfy { key, value in
            if key == "FTPPassive" { return value as? Int == 1 }
            return disabled.contains(key) && value as? Int == 0
        }
    }

    public static func isPrivateIPConfiguration(_ value: [String: Any], interface: String, family: Int) -> Bool {
        let keys: Set<String> = ["Addresses", "InterfaceName", "Router", "ServerAddress", "AdditionalRoutes", "SubnetMasks", "PrefixLength"]
        guard Set(value.keys).isSubset(of: keys), value["InterfaceName"] as? String == interface,
              let addresses = value["Addresses"] as? [String], !addresses.isEmpty,
              addresses.allSatisfy({ addressFamily($0) == family }) else { return false }
        if let router = value["Router"] { guard let router = router as? String, addressFamily(router) == family else { return false } }
        if let server = value["ServerAddress"] { guard server as? String == "127.0.0.1" else { return false } }
        if let masks = value["SubnetMasks"] {
            guard let masks = masks as? [String], masks.allSatisfy({ prefixLength(mask: $0).map { $0 >= 10 } == true }) else { return false }
        }
        if let prefixes = value["PrefixLength"] {
            guard let prefixes = prefixes as? [Int], prefixes.allSatisfy({ (48...128).contains($0) }) else { return false }
        }
        if let routes = value["AdditionalRoutes"] {
            guard let routes = routes as? [[String: Any]], routes.allSatisfy({ route in
                guard Set(route.keys).isSubset(of: ["DestinationAddress", "SubnetMask", "PrefixLength", "GatewayAddress"]) else { return false }
                if let gateway = route["GatewayAddress"] {
                    guard let gateway = gateway as? String, addressFamily(gateway) == family else { return false }
                }
                let prefix = family == 4 ? (route["SubnetMask"] as? String).flatMap { prefixLength(mask: $0) } : route["PrefixLength"] as? Int
                return isPrivateRoute(destination: route["DestinationAddress"] as? String, prefixLength: prefix)
            }) else { return false }
        }
        return true
    }
}
