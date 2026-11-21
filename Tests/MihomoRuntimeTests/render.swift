import Foundation
import Darwin

@main
enum RuntimeFixtures {
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "closed-runtime-policy" {
            guard let group = getgrnam(MimoRuntime.engineGroup) else { fatalError("Private runtime group is required") }
            try MimoFirewallPolicy.render(group: group.pointee.gr_gid).write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "packet-profiles" {
            try packetProfiles(configuration: URL(fileURLWithPath: CommandLine.arguments[2]),
                               root: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "probe-success" {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let config = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let password = config["probePassword"] as! String
            let session = try MimoLookupSession.make(probePassword: password)
            defer { session.invalidateAndCancel() }
            let snapshot = try await PublicIPLookupClient(session: session).lookup(configuration: LookupConfiguration(provider: .ipWhois, ipinfoToken: nil))
            print(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))
            return
        }
        if (4...5).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "inspect" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2]), mode = CommandLine.arguments[3]
            let active = CommandLine.arguments.last == "active"
            func object(_ name: String) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name))) as! [String: Any]
            }
            let config = try object("\(mode)-configs.json")
            let rules = try object("\(mode)-rules.json")["rules"] as! [[String: Any]]
            let proxies = try object("\(mode)-proxies.json")["proxies"] as! [String: Any]
            let profile = try String(contentsOf: root.appendingPathComponent("\(mode)-\(active ? "active" : "verification").yaml"), encoding: .utf8)
            let proxy = try JSONDecoder().decode(MimoProxy.self, from: Data(contentsOf: root.appendingPathComponent("metadata.json")))
            guard MihomoRuntimeInspection.matches(profile: profile, active: active, proxy: proxy,
                                                  config: config, rules: rules, proxies: proxies) else { exit(1) }
            print("Effective runtime inspection passed")
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "closed-policy" {
            // The isolated PF smoke test uses the existing daemon GID only for its
            // synthetic bootstrap client; no user/group or service is installed.
            try MimoFirewallPolicy.render(group: 1).write(toFile: CommandLine.arguments[2],
                                                        atomically: true, encoding: .utf8)
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "lookup",
           let port = Int(CommandLine.arguments[2]) {
            let session = try MimoLookupSession.make(probePassword: CommandLine.arguments[3], probePort: port)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await session.data(from: URL(string: "https://ipwho.is/")!)
                fatalError("A broken proxy must not complete an HTTPS request through Direct fallback")
            } catch {
                print("Expected protected lookup failure: \((error as NSError).domain) \((error as NSError).code)")
            }
            return
        }
        guard CommandLine.arguments.count == 4,
              let upstreamPort = Int(CommandLine.arguments[2]),
              let probePort = Int(CommandLine.arguments[3]) else {
            fatalError("Usage: render-profiles DIRECTORY UPSTREAM_PORT PROBE_PORT")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let controller = root.appendingPathComponent("controller.sock").path
        let settings = ClashProxySettings(name: "RuntimeFixture", type: .http, server: "127.0.0.1",
                                          port: upstreamPort)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(MimoProxy(settings)).write(to: root.appendingPathComponent("metadata.json"))
        try MihomoProfile.blocking(controllerPath: controller).write(
            to: root.appendingPathComponent("blocking.yaml"), atomically: true, encoding: .utf8)
        for mode in [ProxyMode?.none, .rule, .global] {
            let policy = try MimoFirewallPolicy.render(group: getgid(), endpoints: ["198.51.100.10", "2001:db8::10"],
                                                       proxyPort: 443, mode: mode,
                                                       tunnel: mode == nil ? nil : MihomoProfile.tunnelDevice)
            try policy.write(to: root.appendingPathComponent("\(mode?.rawValue ?? "closed").pf"),
                             atomically: true, encoding: .utf8)
        }
        for mode in [ProxyMode.rule, .global] {
            for (name, stage) in [("verification", MihomoProfile.Stage.verification), ("active", .active)] {
                let profile = try MihomoProfile.render(settings, mode: mode, stage: stage,
                                                       probePassword: String(repeating: "ab", count: 32), controllerPath: controller,
                                                       probePort: probePort)
                try profile.write(to: root.appendingPathComponent("\(mode.rawValue)-\(name).yaml"),
                                  atomically: true, encoding: .utf8)
            }
        }
    }

    private static func packetProfiles(configuration: URL, root: URL) throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as! [String: Any]
        let settings = ClashProxySettings(name: "PacketFixture", type: .socks5, server: config["bind"] as! String,
                                          port: config["port"] as! Int, username: config["username"] as! String,
                                          password: config["password"] as! String)
        guard let group = getgrnam(MimoRuntime.engineGroup) else { fatalError("Install the private runtime group first") }
        let controller = root.appendingPathComponent("controller.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(MimoProxy(settings)).write(to: root.appendingPathComponent("metadata.json"))
        try MihomoProfile.blocking(controllerPath: controller).write(to: root.appendingPathComponent("blocking.yaml"), atomically: true, encoding: .utf8)
        for mode in [ProxyMode.rule, .global] {
            for (label, stage) in [("verification", MihomoProfile.Stage.verification), ("active", .active)] {
                let profile = try MihomoProfile.render(settings, mode: mode, stage: stage,
                    probePassword: config["probePassword"] as! String, controllerPath: controller)
                try profile.write(to: root.appendingPathComponent("\(mode.rawValue)-\(label).yaml"), atomically: true, encoding: .utf8)
            }
        }
        var broken = settings; broken.password = "deliberately-invalid-fixture-password"
        try MihomoProfile.render(broken, mode: .global, stage: .verification, probePassword: config["probePassword"] as! String,
                                 controllerPath: controller).write(to: root.appendingPathComponent("wrong-password.yaml"), atomically: true, encoding: .utf8)
        for mode in [ProxyMode?.none, .rule, .global] {
            let rules = try MimoFirewallPolicy.render(group: group.pointee.gr_gid, endpoints: [settings.server], proxyPort: settings.port,
                mode: mode, tunnel: mode == nil ? nil : MihomoProfile.tunnelDevice)
            try rules.write(to: root.appendingPathComponent("\(mode?.rawValue ?? "closed").pf"), atomically: true, encoding: .utf8)
        }
    }
}
