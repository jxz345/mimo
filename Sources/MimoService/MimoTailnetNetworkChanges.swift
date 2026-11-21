import Darwin
import Foundation
import SystemConfiguration

/// Callback-side classification of private Tailnet changes. It never modifies PF.
/// Both snapshots must leave the verified proxy's public interface untouched.
final class MimoTailnetNetworkChanges: @unchecked Sendable {
    typealias Snapshot = [String: NSDictionary]
    private let lock = NSLock()
    private var previous: Snapshot = [:]
    private var knownServices: [String: String] = [:]
    private var publicInterface: String?
    private var inheritedDNS: Set<[String]> = []
    private let read: @Sendable () -> Snapshot?
    private let interfaceIndex: @Sendable (String) -> UInt32

    init(read: @escaping @Sendable () -> Snapshot? = MimoTailnetNetworkChanges.snapshot,
         interfaceIndex: @escaping @Sendable (String) -> UInt32 = { if_nametoindex($0) }) {
        self.read = read
        self.interfaceIndex = interfaceIndex
    }

    func start() { lock.withLock { previous = read() ?? [:]; rememberServices(previous) } }

    func setProxyEndpoint(_ address: String?, interface: String?) {
        lock.withLock {
            // A proxy inside Tailnet, or with an unknown route, still needs a
            // full verification when the native connection changes.
            guard let address, IPAddressValidator.normalize(address) != nil,
                  !address.contains(":"), MimoTailnetChangePolicy.addressFamily(address) == nil,
                  let interface, !interface.hasPrefix("utun"), interface != "lo0" else {
                publicInterface = nil
                return
            }
            publicInterface = interface
        }
    }

    func classify(_ keys: [String]) -> Set<String> {
        lock.withLock {
            guard let current = read() else { return [] }
            defer {
                for key in keys { previous[key] = current[key] }
            }
            inheritedDNS = underlayServers(previous).intersection(underlayServers(current))
            rememberServices(current)
            guard publicInterface != nil else { return [] }
            let interfaces = Set(knownServices.values)
            let result = keys.filter { key -> Bool in
                if key == "State:/Network/Interface" {
                    guard previous[key] != current[key] else { return false }
                    guard let before = previous[key]?["Interfaces"] as? [String], let after = current[key]?["Interfaces"] as? [String] else { return false }
                    return Set(before).subtracting(interfaces) == Set(after).subtracting(interfaces)
                }
                if key == "State:/Network/Global/Proxies" {
                    guard previous[key] != current[key] else { return false }
                    return normalizedGlobalProxies(previous[key], interfaces: interfaces) == normalizedGlobalProxies(current[key], interfaces: interfaces)
                        && previous[key] != nil && current[key] != nil
                }
                for (service, interface) in knownServices {
                    let prefix = "State:/Network/Service/\(service)/"
                    if key.hasPrefix(prefix) {
                        let entity = String(key.dropFirst(prefix.count))
                        return valid(previous[key], entity: entity, interface: interface) && valid(current[key], entity: entity, interface: interface)
                    }
                    let interfacePrefix = "State:/Network/Interface/\(interface)/"
                    if key.hasPrefix(interfacePrefix) {
                        let entity = String(key.dropFirst(interfacePrefix.count))
                        return validInterface(previous[key], entity: entity) && validInterface(current[key], entity: entity)
                    }
                }
                return false
            }
            return Set(result)
        }
    }

    func nonTailnetDNS(_ values: [String: NSDictionary]) -> [String: NSDictionary] {
        lock.withLock {
            guard publicInterface != nil else { return values }
            return values.filter { key, value in
                guard knownServices.keys.contains(where: { key == "State:/Network/Service/\($0)/DNS" }) else { return true }
                return !safeDNS(value as? [String: Any] ?? [:])
            }
        }
    }

    func isNativeDNSSelection(_ value: NSDictionary?) -> Bool {
        lock.withLock {
            guard publicInterface != nil, var fields = value as? [String: Any],
                  let identifier = fields["__CONFIGURATION_ID__"] as? String else { return false }
            let parts = identifier.split(separator: " ")
            guard parts.count == 3, parts[0] == "Supplemental:", let interface = knownServices[String(parts[1])],
                  Int(parts[2]) != nil else { return false }
            // configd may publish a scoped native selection during reconnect.
            // Accept its bookkeeping only when it names the current native
            // interface; an unknown, stale or different index remains external.
            if let value = fields.removeValue(forKey: "__IF_INDEX__") {
                guard let index = value as? Int, index > 0,
                      index == Int(interfaceIndex(interface)) else { return false }
            }
            for key in ["__CONFIGURATION_ID__", "__FLAGS__", "__ORDER__"] { fields.removeValue(forKey: key) }
            return MimoTailnetChangePolicy.isNativeDNS(fields)
        }
    }

    func isPrivateRouteChange(_ change: RouteChangeObserver.Change) -> Bool {
        lock.withLock {
            guard publicInterface != nil, let name = change.interfaceName,
                  name.hasPrefix("utun"), name != MihomoProfile.tunnelDevice else { return false }
            switch change.type {
            case RTM_ADD, RTM_DELETE, RTM_CHANGE:
                // Interface-scoped native defaults/multicast routes apply only
                // to sockets bound to that interface, never the public proxy.
                if change.routeFlags & RTF_IFSCOPE != 0, knownServices.values.contains(name) { return true }
                return MimoTailnetChangePolicy.isPrivateRoute(destination: change.destination, prefixLength: change.prefixLength)
            case RTM_NEWADDR, RTM_DELADDR:
                return !change.addresses.isEmpty && change.addresses.allSatisfy {
                    MimoTailnetChangePolicy.addressFamily($0) != nil ||
                        (knownServices.values.contains(name) && $0.lowercased().hasPrefix("fe80:"))
                }
            default: return false
            }
        }
    }

    private func rememberServices(_ values: Snapshot) {
        for (key, value) in values where key.hasPrefix("Setup:/Network/Service/") && key.hasSuffix("/Interface") {
            guard value["Type"] as? String == "VPN", value["SubType"] as? String == "io.tailscale.ipn.macsys" else { continue }
            let service = String(key.dropFirst("Setup:/Network/Service/".count).dropLast("/Interface".count))
            let prefix = "State:/Network/Service/\(service)/"
            let interface = ["IPv4", "IPv6", "DNS"].compactMap { values[prefix + $0]?["InterfaceName"] as? String }
                .first { TailscaleVergeStatus.isUtun($0) && $0 != MihomoProfile.tunnelDevice }
            knownServices[service] = interface ?? knownServices[service] ?? ""
        }
        for (key, value) in values where key.hasPrefix("State:/Network/Service/") && key.hasSuffix("/DNS") {
            guard let dns = value as? [String: Any], MimoTailnetChangePolicy.isNativeDNS(dns),
                  let interface = dns["InterfaceName"] as? String, interface.hasPrefix("utun"), interface != MihomoProfile.tunnelDevice else { continue }
            let prefix = String(key.dropLast(3))
            guard let ipv4 = values[prefix + "IPv4"] as? [String: Any],
                  MimoTailnetChangePolicy.isPrivateIPConfiguration(ipv4, interface: interface, family: 4),
                  valid(values[prefix + "IPv6"], entity: "IPv6", interface: interface) else { continue }
            let service = String(prefix.dropFirst("State:/Network/Service/".count).dropLast())
            // Keep the last interface while disconnected, to classify removal
            // notifications. Reuse with other addresses/routes fails validation.
            knownServices[service] = interface
        }
    }

    private func valid(_ value: NSDictionary?, entity: String, interface: String) -> Bool {
        guard ["IPv4", "IPv6", "DNS", "VPN", "Proxies"].contains(entity) else { return false }
        guard let value else { return true }
        guard let fields = value as? [String: Any] else { return false }
        switch entity {
        case "IPv4", "IPv6": return MimoTailnetChangePolicy.isPrivateIPConfiguration(fields, interface: interface, family: entity == "IPv4" ? 4 : 6)
        case "DNS": return fields["InterfaceName"] as? String == interface && safeDNS(fields)
        case "Proxies": return MimoTailnetChangePolicy.isInactiveProxyConfiguration(fields)
        case "VPN": return Set(fields.keys) == ["Status"] && fields["Status"] is Int
        default: return false
        }
    }

    private func underlayServers(_ values: Snapshot) -> Set<[String]> {
        Set(values.compactMap { key, value in
            guard key.hasPrefix("State:/Network/Service/"), key.hasSuffix("/DNS"), key != MimoRuntime.dnsStateKey,
                  !knownServices.keys.contains(where: { key == "State:/Network/Service/\($0)/DNS" }),
                  let servers = value["ServerAddresses"] as? [String], !servers.isEmpty else { return nil }
            return servers.sorted()
        })
    }

    private func safeDNS(_ fields: [String: Any]) -> Bool {
        if MimoTailnetChangePolicy.isNativeDNS(fields) { return true }
        // Native Disconnect republishes the unchanged underlay DNS under the
        // native service before removing it. Mimo's protected resolver remains
        // selected. A new/custom DNS server is deliberately not covered here.
        guard Set(fields.keys) == ["InterfaceName", "ServerAddresses"],
              let servers = fields["ServerAddresses"] as? [String] else { return false }
        return inheritedDNS.contains(servers.sorted())
    }

    private func validInterface(_ value: NSDictionary?, entity: String) -> Bool {
        guard entity == "IPv4" || entity == "IPv6" else { return false }
        guard let value else { return true }
        guard let fields = value as? [String: Any], Set(fields.keys).isSubset(of: ["Addresses", "DestAddresses", "SubnetMasks", "PrefixLength", "Flags"]),
              let addresses = fields["Addresses"] as? [String], !addresses.isEmpty else { return false }
        return addresses.allSatisfy {
            MimoTailnetChangePolicy.addressFamily($0) == (entity == "IPv4" ? 4 : 6) ||
                (entity == "IPv6" && $0.lowercased().hasPrefix("fe80:"))
        }
    }

    private func normalizedGlobalProxies(_ value: NSDictionary?, interfaces: Set<String>) -> NSDictionary? {
        guard var fields = value as? [String: Any] else { return nil }
        if var scoped = fields["__SCOPED__"] as? [String: [String: Any]] {
            for interface in interfaces {
                if let configuration = scoped[interface], MimoTailnetChangePolicy.isInactiveProxyConfiguration(configuration) { scoped.removeValue(forKey: interface) }
            }
            if scoped.isEmpty { fields.removeValue(forKey: "__SCOPED__") }
            else { fields["__SCOPED__"] = scoped }
        }
        return fields as NSDictionary
    }

    private static func snapshot() -> Snapshot? {
        guard let store = SCDynamicStoreCreate(nil, "Mimo Tailnet change classification" as CFString, nil, nil) else { return nil }
        return SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/.*", "State:/Network/Interface.*", "State:/Network/Global/Proxies", "Setup:/Network/Service/.*/Interface"] as CFArray) as? Snapshot
    }
}
