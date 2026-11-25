import Foundation

/// The profile owns routing and DNS; PF also prevents native application fallback
/// when a protected engine disappears or a more-specific route bypasses its TUN.
/// Only validated literal endpoints and the installed runtime group enter PF syntax.
public enum MimoFirewallPolicy {
    public static let anchor = "com.apple/000.mimo"
    public static let permissionParent = startupBlocking
    public static let direct = ""
    public static let bootstrapResolver = "1.1.1.1"

    // Only a peer's initial SYN creates this permission. Interface binding
    // prevents an ingress state from authorizing an application on another path.
    // Do not use quick: later administrator ingress rules retain their veto.
    public static let inboundTCP = "pass in on ! utun239 proto tcp all flags S/SA keep state (if-bound) label \"mimo:inbound:tcp\""
    // Last-match override: local clients of Mimo's public proxy/DNS listeners
    // must not keep an ingress state that bypasses closure of those listeners.
    public static let inboundLoopback = "pass in on lo0 all no state label \"mimo:inbound:loopback\""

    /// Apple pfctl -k selects the originating host. Preserve inbound server
    /// states; revoke only sources of original outbound connections. This is
    /// also used by the staged installer before a new guard script is installed.
    public static func outboundStateSources(_ text: String) throws -> [String] {
        var sources = Set<String>()
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.contains(" <- ") { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5, fields.contains("->") else { throw DaemonFailure.invalidRequest }
            var source = String(fields[2])
            if let bracket = source.lastIndex(of: "["), source.hasSuffix("]") {
                guard Int(source[source.index(after: bracket)..<source.index(before: source.endIndex)]) != nil else { throw DaemonFailure.invalidRequest }
                source = String(source[..<bracket])
            } else if source.contains("."), let colon = source.lastIndex(of: ":"),
                      source.filter({ $0 == ":" }).count == 1 {
                guard Int(source[source.index(after: colon)...]) != nil else { throw DaemonFailure.invalidRequest }
                source = String(source[..<colon])
            }
            if let zone = source.firstIndex(of: "%") { source = String(source[..<zone]) }
            guard let address = IPAddressValidator.normalize(source) else { throw DaemonFailure.invalidRequest }
            sources.insert(address)
        }
        guard sources.count <= 256 else { throw DaemonFailure.invalidRequest }
        return sources.sorted()
    }

    /// No floating PF states: a permission on the TUN must never authorize the
    /// same application flow on a physical interface after tunnel destruction.
    /// Native destinations are intentional exceptions, not public transport grants.
    public static func activePolicy(group: UInt32, nativeInterfaces: [String] = [], nativeEgress: MimoNativeEgress = .init()) throws -> String {
        guard group != 0, group != UInt32.max, nativeInterfaces.count <= 32,
              nativeInterfaces.allSatisfy({ name in
                  name != MihomoProfile.tunnelDevice && name.hasPrefix("utun") &&
                  !name.dropFirst(4).isEmpty && name.dropFirst(4).allSatisfy({ $0.isASCII && $0.isNumber })
              }) else { throw DaemonFailure.invalidRequest }
        var lines = [inboundTCP, inboundLoopback,
            "pass out quick on lo0 all no state label \"mimo:active:loopback\"",
            "pass out quick on \(MihomoProfile.tunnelDevice) all no state label \"mimo:active:tunnel\"",
            "block drop out quick inet from any to 198.18.0.0/16 label \"mimo:active:fake-address\"",
            "block drop out quick inet6 from any to fdfe:dcba:9876::/48 label \"mimo:active:fake-address\""
        ]
        for interface in Set(nativeInterfaces).sorted() {
            lines.append("pass out quick on \(interface) inet from any to 100.64.0.0/10 no state label \"mimo:active:tailnet\"")
            lines.append("pass out quick on \(interface) inet6 from any to fd7a:115c:a1e0::/48 no state label \"mimo:active:tailnet\"")
        }
        // An absent native tunnel must not expose private DNS on the physical
        // default route, including queries originating from the engine itself.
        lines.append("block drop out quick inet from any to 100.64.0.0/10 label \"mimo:active:tailnet-wrong-path\"")
        lines.append("block drop out quick inet6 from any to fd7a:115c:a1e0::/48 label \"mimo:active:tailnet-wrong-path\"")
        lines += try nativeEgress.rules()
        for transport in ["tcp", "udp"] {
            lines.append("pass out quick proto \(transport) all group = \(group) no state label \"mimo:active:engine\"")
        }
        for network in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"] {
            lines.append("pass out quick inet from any to \(network) no state label \"mimo:active:native-v4\"")
        }
        for network in ["fc00::/7", "fe80::/10"] {
            lines.append("pass out quick inet6 from any to \(network) no state label \"mimo:active:native-v6\"")
        }
        lines.append("pass out quick inet proto udp from any port = 68 to 255.255.255.255 port = 67 no state label \"mimo:active:dhcp\"")
        lines.append("pass out quick inet proto udp from any to 224.0.0.251 port = 5353 no state label \"mimo:active:mdns\"")
        lines.append("pass out quick inet6 proto udp from any to ff02::fb port = 5353 no state label \"mimo:active:mdns\"")
        for type in ["neighbrsol", "neighbradv", "routersol", "routeradv"] {
            lines.append("pass out quick inet6 proto ipv6-icmp from any to ff02::/16 icmp6-type \(type) no state label \"mimo:active:ipv6-link-control\"")
        }
        lines.append("block drop out quick all label \"mimo:active:deny-native-fallback\"")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func isActiveReadback(_ value: String, group: UInt32, nativeInterfaces: [String] = [], nativeEgress: MimoNativeEgress = .init()) -> Bool {
        guard let expected = try? activePolicy(group: group, nativeInterfaces: nativeInterfaces, nativeEgress: nativeEgress) else { return false }
        return value == expected
    }

    private static let localControl = """
    \(inboundTCP)
    \(inboundLoopback)
    block return out quick on lo0 proto { tcp, udp } to { 127.0.0.1, ::1 } port { \(MimoRuntime.mixedPort), \(MimoRuntime.dnsPort) } label "mimo:transition:public-listeners"
    pass out quick on lo0 all no state label "mimo:transition:local-control"
    pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67 no state label "mimo:transition:dhcp"
    pass out quick inet6 proto icmp6 to { fe80::/10, ff02::/16 } icmp6-type { neighbrsol, neighbradv, routersol, routeradv } no state label "mimo:transition:ipv6-link-control"

    """
    /// Deny new outbound application flows, retaining replies to inbound TCP.
    public static let startupBlocking = localControl + "block drop out quick all label \"mimo:transition:deny\"\n"

    /// Independently verified native VPN transport keeps inbound Tailnet services
    /// reachable while the public exit is rejected. It never grants engine egress.
    public static func blockedPolicy(nativeEgress: MimoNativeEgress) throws -> String {
        localControl + (try nativeEgress.rules()).map { $0 + "\n" }.joined()
            + "block drop out quick all label \"mimo:transition:deny\"\n"
    }

    // pfctl expands lists. Compare every expanded control rule, not just labels:
    // a malicious extra pass carrying a copied label must never qualify a close.
    private static var controlReadback: [String] {
        var lines: [String] = [inboundTCP, inboundLoopback]
        for transport in ["tcp", "udp"] {
            for (family, address) in [("inet", "127.0.0.1"), ("inet6", "::1")] {
                for port in [MimoRuntime.mixedPort, MimoRuntime.dnsPort] {
                    lines.append("block return out quick on lo0 \(family) proto \(transport) from any to \(address) port = \(port) label \"mimo:transition:public-listeners\"")
                }
            }
        }
        lines += ["pass out quick on lo0 all no state label \"mimo:transition:local-control\"",
                  "pass out quick inet proto udp from any port = 68 to 255.255.255.255 port = 67 no state label \"mimo:transition:dhcp\""]
        for type in ["neighbrsol", "neighbradv", "routersol", "routeradv"] {
            for destination in ["fe80::/10", "ff02::/16"] {
                lines.append("pass out quick inet6 proto ipv6-icmp from any to \(destination) icmp6-type \(type) no state label \"mimo:transition:ipv6-link-control\"")
            }
        }
        return lines
    }

    public static func isClosedReadback(_ value: String) -> Bool {
        value.split(separator: "\n").map(String.init) == controlReadback + ["block drop out quick all label \"mimo:transition:deny\""]
    }

    public static func isBlockedReadback(_ value: String, nativeEgress: MimoNativeEgress) -> Bool {
        guard let native = try? nativeEgress.rules() else { return false }
        return value.split(separator: "\n").map(String.init) == controlReadback + native
            + ["block drop out quick all label \"mimo:transition:deny\""]
    }

    public static func isVerificationReadback(_ value: String) -> Bool {
        let lines = value.split(separator: "\n").map(String.init)
        guard Array(lines.prefix(controlReadback.count)) == controlReadback,
              lines.last == "block drop out quick all label \"mimo:probe:deny\"" else { return false }
        let grants = lines.dropFirst(controlReadback.count).dropLast()
        guard !grants.isEmpty, grants.count <= 32 else { return false }
        return grants.allSatisfy { line in
            line.range(of: #"^pass out quick inet proto tcp from any to [0-9.]+ port = [0-9]+ group =? ?[0-9]+ no state label "mimo:probe:(proxy|bootstrap-doh)"$"#, options: .regularExpression) != nil
        }
    }

    public static func preparedPolicy(group: UInt32, endpoints: [String], proxyPort: Int?, mode: ProxyMode? = nil) throws -> String {
        try render(group: group, endpoints: endpoints, proxyPort: proxyPort, mode: mode)
    }

    public static func render(group: UInt32, endpoints: [String] = [], proxyPort: Int? = nil,
                              mode: ProxyMode? = nil, tunnel: String? = nil) throws -> String {
        guard group != UInt32.max, endpoints.allSatisfy({ IPAddressValidator.normalize($0) == $0 && !$0.contains(":") }),
              proxyPort.map({ (1...65535).contains($0) }) ?? endpoints.isEmpty,
              tunnel == nil || tunnel == MihomoProfile.tunnelDevice,
              mode != .direct else { throw DaemonFailure.invalidRequest }
        if mode != nil { return try activePolicy(group: group) }
        var rules = localControl
        // The authenticated private listener can only check exit-IP HTTPS hosts.
        // The public listeners and TUN remain blocked. No UDP relay exception is
        // needed for this TCP-only probe; ordinary routing belongs to the profile.
        if endpoints.isEmpty {
            rules += "pass out quick inet proto tcp to \(bootstrapResolver) port 443 group \(group) no state label \"mimo:probe:bootstrap-doh\"\n"
        } else if let proxyPort {
            for address in endpoints {
                rules += "pass out quick inet proto tcp to \(address) port \(proxyPort) group \(group) no state label \"mimo:probe:proxy\"\n"
            }
        }
        return rules + "block drop out quick all label \"mimo:probe:deny\"\n"
    }
}
