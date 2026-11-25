import Foundation

@main struct RenderV3Profiles {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let proxy = ClashProxySettings(name: "Upstream", type: .socks5, server: "192.0.2.10", port: 1080)
        for family in MimoNetworkFamily.allCases {
            let name = family == .ipv4 ? "mimo-v3-ipv4-template.yaml" : "mimo-v3-dualstack-template.yaml"
            let contents = try MihomoProfile.render(proxy, mode: .rule, stage: .active,
                probePassword: "REPLACE_WITH_RANDOM_LOCAL_PROBE_PASSWORD", bypassBlocks: [], family: family)
            try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
}
