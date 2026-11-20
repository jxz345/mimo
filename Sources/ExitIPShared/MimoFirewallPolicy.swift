import Foundation

/// Only literal addresses and a fixed interface/group enter PF syntax. Never interpolate hostnames,
/// user-provided interface names, shell fragments, or arbitrary configuration text.
public enum MimoFirewallPolicy {
    public static let anchor = "com.apple/000.mimo"
    public static let permissionAnchor = anchor + "/permission"
    /// No permission child means no public access. The independent power guard
    /// can also revoke grants without depending on supervisor actor scheduling.
    public static let permissionParent = "anchor \"power-guard\" out quick\nanchor \"permission\" out quick\n" + startupBlocking
    public static func permission(open: Bool) -> String {
        "anchor \"/\(anchor)/\(open ? "open-policy" : "probe-policy")\" out quick\n"
    }

    public static func preparedPolicy(group: UInt32, endpoints: [String], proxyPort: Int?, mode: ProxyMode? = nil) throws -> String {
        var rules = try render(group: group, endpoints: endpoints, proxyPort: proxyPort,
                               mode: mode, tunnel: mode == nil ? nil : MihomoProfile.tunnelDevice)
        rules = rules.replacingOccurrences(of: "anchor \"power-guard\" out quick\n", with: "")
            .replacingOccurrences(of: "anchor \"native-transport\"", with: "anchor \"/\(anchor)/native-transport\"")
        // Literal endpoints never need an unrestricted bootstrap exception.
        if !endpoints.isEmpty {
            rules = rules.replacingOccurrences(of: "pass out quick proto tcp to \(bootstrapResolver) port 443 group \(group) no state\n", with: "")
        }
        return rules
    }
    public static let bootstrapResolver = "1.1.1.1"
    public static let directIPv4 = "pass out quick on lo0 all no state\nblock return out quick inet6 all\n"
    /// Applied before dependency/group validation. No unverified runtime group
    /// or native transport receives public access during startup inspection.
    public static let startupBlocking = """
    block return out quick on lo0 proto { tcp, udp } to { 127.0.0.1, ::1 } port { \(MimoRuntime.mixedPort), \(MimoRuntime.dnsPort) }
    pass out quick on lo0 all no state
    block return out quick inet6 all
    block return out quick proto { tcp, udp } to any port { 53, 853 }
    pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67 no state
    pass out quick to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } no state
    block drop out quick all

    """

    public static func render(group: UInt32, endpoints: [String] = [], proxyPort: Int? = nil,
                              mode: ProxyMode? = nil, tunnel: String? = nil) throws -> String {
        guard endpoints.allSatisfy({ IPAddressValidator.normalize($0) == $0 }),
              proxyPort.map({ (1...65535).contains($0) }) ?? endpoints.isEmpty,
              tunnel == nil || tunnel == MihomoProfile.tunnelDevice,
              mode != .direct else { throw DaemonFailure.invalidRequest }
        var rules = [
            "# Mimo: independently enforced application gate",
            "anchor \"power-guard\" out quick"
        ]
        if mode == nil {
            // An established localhost CONNECT session must not keep forwarding via the
            // engine's endpoint exception while ordinary application traffic is closed.
            rules.append("block return out quick on lo0 proto { tcp, udp } to { 127.0.0.1, ::1 } port { \(MimoRuntime.mixedPort), \(MimoRuntime.dnsPort) }")
        }
        rules.append("pass out quick on lo0 all no state")
        rules.append("block return out quick inet6 all")
        if let mode, mode.requiresVerification, let tunnel {
            rules.append("pass out quick on \(tunnel) all no state")
        }
        // Application DNS must not leak through a LAN resolver or a competing VPN.
        rules += [
            "block return out quick proto { tcp, udp } to any port { 53, 853 } group != \(group)",
            "anchor \"native-transport\" out quick",
            "pass out quick inet6 proto icmp6 to { fe80::/10, ff02::/16 } icmp6-type { neighbrsol, neighbradv, routersol } no state",
            "pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67 no state",
            "pass out quick proto tcp to \(bootstrapResolver) port 443 group \(group) no state"
        ]
        if let proxyPort {
            for address in endpoints {
                rules.append("pass out quick proto tcp to \(address) port \(proxyPort) group \(group) no state")
                // SOCKS5 UDP ASSOCIATE may select a different relay port. Keep the
                // address pinned to the verified endpoint and the engine group.
                rules.append("pass out quick proto udp to \(address) group \(group) no state")
            }
        }
        // A stopped provider must reject tailnet traffic even from Rule's engine.
        // The earlier native sub-anchor permits only a freshly verified interface.
        rules.append("block return out quick to { 100.64.0.0/10, fd7a:115c:a1e0::/48 }")
        if mode == .rule {
            // Only the dedicated runtime group can execute the profile's intentional direct rules.
            rules.append("pass out quick proto { tcp, udp } all group \(group) no state")
        }
        // LAN access remains local. Tailnet ranges are deliberately not included here: the verified
        // provider and native transport require their own enforcement qualification.
        rules += [
            "pass out quick to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, fe80::/10 } no state",
            // Drop an unclassified SYN so the native socket observer can inspect
            // SYN_SENT and grant only an authenticated infrastructure tuple.
            // Returning an error immediately destroys the socket before inspection.
            "block drop out quick all"
        ]
        return rules.joined(separator: "\n") + "\n"
    }
}
