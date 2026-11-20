import Foundation

/// Mimo-owned profiles. The legacy renderer remains the compatibility fixture and migration source.
public enum MihomoProfile {
    public enum Stage: Sendable { case verification, active }
    public static let tunnelDevice = "utun239"

    public static func blocking(controllerPath: String = MimoRuntime.controller.path) -> String {
        """
        # Mimo startup profile: credentials and public listeners are absent.
        mode: rule
        mixed-port: 0
        allow-lan: false
        bind-address: 127.0.0.1
        ipv6: false
        external-controller: ''
        external-controller-unix: \(ClashVergeProfile.quoted(controllerPath))
        log-level: silent
        tun:
          enable: false
        dns:
          enable: false
        rules:
          - MATCH,REJECT

        """
    }

    public static func render(_ settings: ClashProxySettings, mode: ProxyMode, stage: Stage,
                              probePassword: String, controllerPath: String = MimoRuntime.controller.path,
                              probePort: Int = MimoRuntime.probePort) throws -> String {
        guard mode.requiresVerification, !settings.server.contains(":"), (1...65535).contains(probePort),
              !probePassword.isEmpty, probePassword.count <= 256,
              !probePassword.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              controllerPath.hasPrefix("/"), !controllerPath.contains("\n") else { throw DaemonFailure.invalidRequest }
        let legacy = try ClashVergeProfile.render(settings)
        // Keep the trusted DNS/TUN/proxy/provider template together. User data is rendered only
        // through validated quoted scalars; it can never add configuration keys or commands.
        let body = String(legacy[legacy.range(of: "mode: rule")!.lowerBound...])
        let corsStart = body.range(of: "external-controller-cors:")!.lowerBound
        let dnsStart = body.range(of: "\ndns:", range: corsStart..<body.endIndex)!.lowerBound
        var profile = String(body[..<corsStart]) + String(body[dnsStart...])
        profile = profile.replacingOccurrences(of: "\"/tmp/verge/verge-mihomo.sock\"", with: ClashVergeProfile.quoted(controllerPath))
            .replacingOccurrences(of: "ipv6: true", with: "ipv6: false")
            .replacingOccurrences(of: "  - fd7a:115c:a1e0::/48\n", with: "")
            .replacingOccurrences(of: "allow-lan: false", with: "allow-lan: false\nbind-address: 127.0.0.1")
            .replacingOccurrences(of: "log-level: info", with: "log-level: silent")
            .replacingOccurrences(of: "mixed-port: 7890", with: "mixed-port: \(stage == .active ? MimoRuntime.mixedPort : 0)")
            .replacingOccurrences(of: "dns:\n  enable: true", with: "dns:\n  enable: true\n  listen: \(stage == .active ? "127.0.0.1:\(MimoRuntime.dnsPort)" : "''")")
            .replacingOccurrences(of: "tun:\n  enable: true", with: "tun:\n  device: \(tunnelDevice)\n  enable: \(stage == .active)")
        let rulesStart = profile.range(of: "\nrules:")!.lowerBound
        let originalRules = routingRules(in: profile)
        profile = String(profile[..<rulesStart])
        // Public DNS uses the proxy in both protected modes, even when Rule
        // intentionally sends a website directly. Keep the earlier MagicDNS
        // policy and a separate encrypted resolver for the proxy endpoint;
        // resolving the proxy through itself would introduce a bootstrap loop.
        let dnsUpstreamStart = profile.range(of: "  nameserver:\n")!.lowerBound
        let dnsUpstreamEnd = profile.range(of: "proxies:\n", range: dnsUpstreamStart..<profile.endIndex)!.lowerBound
        profile.replaceSubrange(dnsUpstreamStart..<dnsUpstreamEnd, with:
            "  nameserver:\n  - \"https://1.1.1.1/dns-query#Proxy\"\n" +
            "  proxy-server-nameserver:\n  - \"https://1.1.1.1/dns-query\"\n")
        // Global keeps inner-tailnet and native-process exceptions, but ordinary
        // visits to Tailscale's public websites must use the proxy like any website.
        let activeRules = (mode == .rule ? originalRules : Array(originalRules.prefix(7)) + Array(originalRules.suffix(8)))
            .filter { !$0.hasPrefix("IP-CIDR6,") }
        let ordinaryRules = stage == .active ? ["IP-CIDR6,::/0,REJECT,no-resolve"] + activeRules : ["MATCH,REJECT"]
        profile += "\nrules:\n" + ordinaryRules.map { "  - \($0)" }.joined(separator: "\n") + "\n"
        profile += """

        listeners:
          - name: mimo-private-probe
            type: mixed
            listen: 127.0.0.1
            port: \(probePort)
            udp: false
            users:
              - username: \(MimoRuntime.probeUser)
                password: \(ClashVergeProfile.quoted(probePassword))
            rule: mimo-verification
        sub-rules:
          mimo-verification:
        """
        // Even valid probe credentials cannot turn this listener into a general proxy.
        for host in MimoRuntime.lookupHosts {
            profile += "\n    - AND,((DOMAIN,\(host)),(DST-PORT,443)),Proxy"
        }
        profile += "\n    - MATCH,REJECT\n"
        return "# Mimo private runtime profile. Do not publish or log.\n" + profile
    }

    public static func routingRules(in profile: String) -> [String] {
        guard let start = profile.range(of: "\nrules:\n")?.upperBound else { return [] }
        return profile[start...].split(separator: "\n").prefix(while: { $0.hasPrefix(" ") || $0.hasPrefix("#") }).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : nil
        }
    }
}
