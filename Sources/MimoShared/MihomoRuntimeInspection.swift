import Foundation

/// Checks the effective fields exposed by the pinned controller API. DNS, passwords and
/// sub-rules are not returned by that API; the privileged loader separately binds their
/// exact private profile bytes to the successful reload and the running engine process.
public enum MihomoRuntimeInspection {
    public static func matches(profile: String, active: Bool, proxy: MimoProxy?,
                               config: [String: Any], rules: [[String: Any]], proxies: [String: Any]) -> Bool {
        let expectedMode = profile.split(separator: "\n").first(where: { $0.hasPrefix("mode:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let expectedFamily = profile.split(separator: "\n").first(where: { $0.hasPrefix("mimo-destination-family:") })?.dropFirst(24).trimmingCharacters(in: .whitespaces)
        guard config["mode"] as? String == expectedMode, config["ipv6"] as? Bool == (proxy != nil),
              config["allow-lan"] as? Bool == false, config["bind-address"] as? String == "127.0.0.1",
              config["mixed-port"] as? Int == (active ? MimoRuntime.mixedPort : 0),
              ["port", "socks-port", "redir-port", "tproxy-port"].allSatisfy({ config[$0] as? Int == 0 }),
              ["ss-config", "vmess-config", "interface-name"].allSatisfy({ config[$0] as? String == "" }),
              config["routing-mark"] as? Int == 0,
              (config["tuic-server"] as? [String: Any])?["enable"] as? Bool == false,
              let tun = config["tun"] as? [String: Any], tun["enable"] as? Bool == active else { return false }
        if proxy != nil {
            guard tun["device"] as? String == MihomoProfile.tunnelDevice,
                  tun["stack"] as? String == "gvisor-no-ping", tun["auto-route"] as? Bool == true,
                  tun["auto-detect-interface"] as? Bool == true,
                  tun["strict-route"] as? Bool != true,
                  tun["dns-hijack"] as? [String] == ["any:53", "tcp://any:53"],
                  tun["inet6-address"] as? [String] == [MihomoProfile.tunnelIPv6],
                  tun["route-exclude-address"] as? [String] == ["100.64.0.0/10", "fd7a:115c:a1e0::/48"],
                  config["mimo-destination-family"] as? String == expectedFamily else { return false }
        } else if active { return false }

        let expected = MihomoProfile.routingRules(in: profile)
        guard rules.count == expected.count else { return false }
        let types = ["MATCH": "Match", "DOMAIN": "Domain", "DOMAIN-SUFFIX": "DomainSuffix",
                     "PROCESS-NAME": "ProcessName", "IP-CIDR": "IPCIDR", "IP-CIDR6": "IPCIDR"]
        for (index, pair) in zip(rules, expected).enumerated() {
            let (rule, expected) = pair
            let fields = expected.split(separator: ",").map(String.init)
            guard let kind = fields.first, let type = types[kind], fields.count >= (kind == "MATCH" ? 2 : 3),
                  rule["index"] as? Int == index, rule["type"] as? String == type,
                  (rule["extra"] as? [String: Any])?["disabled"] as? Bool != true,
                  rule["proxy"] as? String == fields[kind == "MATCH" ? 1 : 2],
                  rule["payload"] as? String == (kind == "MATCH" ? "" : fields[1]) else { return false }
        }
        if let proxy {
            guard let group = proxies["Proxy"] as? [String: Any], group["type"] as? String == "Selector",
                  group["all"] as? [String] == [proxy.name], group["now"] as? String == proxy.name,
                  let selected = proxies[proxy.name] as? [String: Any],
                  selected["type"] as? String == (proxy.type == .http ? "Http" : "Socks5"),
                  selected["interface"] as? String == "", selected["dialer-proxy"] as? String == "",
                  selected["routing-mark"] as? Int == 0,
                  let global = proxies["GLOBAL"] as? [String: Any],
                  global["all"] as? [String] == ["Proxy"], global["now"] as? String == "Proxy" else { return false }
        }
        return true
    }
}
