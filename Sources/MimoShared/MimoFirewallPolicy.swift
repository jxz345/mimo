import Foundation

/// PF is only a transition barrier. The active profile owns routing and DNS.
/// Only validated literal endpoints and the installed runtime group enter PF syntax.
public enum MimoFirewallPolicy {
    public static let anchor = "com.apple/000.mimo"
    public static let permissionAnchor = anchor + "/permission"
    public static let permissionParent = "# mimo:transition — emergency barrier, private probe, then deny\nanchor \"power-guard\" out quick\nanchor \"permission\" out quick\n" + startupBlocking
    /// No pass/block rules: other firewall owners retain their normal decisions.
    /// The empty child can be filled immediately on a network/power/failure event.
    public static let activeParent = "# mimo:active — profile owns routing; emergency anchor is empty\nanchor \"power-guard\" out quick\n"
    public static let direct = ""
    public static let privateProbePermission = "# mimo:probe — authenticated verification only\nanchor \"/com.apple/000.mimo/probe-policy\" out quick\n"
    public static let bootstrapResolver = "1.1.1.1"

    private static let localControl = """
    block return out quick on lo0 proto { tcp, udp } to { 127.0.0.1, ::1 } port { \(MimoRuntime.mixedPort), \(MimoRuntime.dnsPort) } label "mimo:transition:public-listeners"
    pass out quick on lo0 all no state label "mimo:transition:local-control"
    pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67 no state label "mimo:transition:dhcp"
    pass out quick inet6 proto icmp6 to { fe80::/10, ff02::/16 } icmp6-type { neighbrsol, neighbradv, routersol, routeradv } no state label "mimo:transition:ipv6-link-control"

    """
    /// No application/TUN/LAN/native-VPN exception while a transition is closed.
    public static let startupBlocking = localControl + "block drop out quick all label \"mimo:transition:deny\"\n"

    public static func preparedPolicy(group: UInt32, endpoints: [String], proxyPort: Int?, mode: ProxyMode? = nil) throws -> String {
        try render(group: group, endpoints: endpoints, proxyPort: proxyPort, mode: mode)
            .replacingOccurrences(of: activeParent, with: "")
    }

    public static func render(group: UInt32, endpoints: [String] = [], proxyPort: Int? = nil,
                              mode: ProxyMode? = nil, tunnel: String? = nil) throws -> String {
        guard endpoints.allSatisfy({ IPAddressValidator.normalize($0) == $0 }),
              proxyPort.map({ (1...65535).contains($0) }) ?? endpoints.isEmpty,
              tunnel == nil || tunnel == MihomoProfile.tunnelDevice,
              mode != .direct else { throw DaemonFailure.invalidRequest }
        if mode != nil { return activeParent }
        var rules = activeParent + localControl
        // The authenticated private listener can only check exit-IP HTTPS hosts.
        // The public listeners and TUN remain blocked. No UDP relay exception is
        // needed for this TCP-only probe; ordinary routing belongs to the profile.
        if endpoints.isEmpty {
            rules += "pass out quick proto tcp to \(bootstrapResolver) port 443 group \(group) no state label \"mimo:probe:bootstrap-doh\"\n"
        } else if let proxyPort {
            for address in endpoints {
                rules += "pass out quick proto tcp to \(address) port \(proxyPort) group \(group) no state label \"mimo:probe:proxy\"\n"
            }
        }
        return rules + "block drop out quick all label \"mimo:probe:deny\"\n"
    }
}
