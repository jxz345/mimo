import Foundation

/// Only fixed release stages enter the readable log, never arbitrary installer
/// output (which can include filesystem paths or command diagnostics).
public enum MimoCleanupEvent {
    public static let messages: [String: String] = [
        "services_stopped": "All Mimo background services stopped",
        "firewall_removed": "Mimo firewall rules removed, including previous-version child anchors",
        "resolver_removed": "Mimo DNS override removed",
        "ipv6_restored": "Saved IPv6 settings restored",
        "ipv6_no_backup": "No saved IPv6 settings; current network settings retained",
        "dns_refreshed": "System DNS caches refreshed",
        "tailnet_verified": "Native Tailnet route and MagicDNS verified",
        "tailnet_not_connected": "Tailnet not connected; access could not be verified",
        "tailnet_failed": "Native Tailnet DNS check failed; retry cleanup after checking Tailscale",
        "network_released": "Network controls released and checked",
        "uninstall_completed": "Full Mimo service uninstall completed"
    ]

    public static func stages(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let prefix = "MIMO_CLEANUP "
            guard line.hasPrefix(prefix) else { return nil }
            let stage = String(line.dropFirst(prefix.count))
            return messages[stage] == nil ? nil : stage
        }
    }
}
