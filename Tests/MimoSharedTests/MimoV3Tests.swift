import XCTest
@testable import MimoShared

final class MimoV3Tests: XCTestCase {
    private let proxy = ClashProxySettings(name: "Fixture", type: .socks5, server: "192.0.2.10", port: 1080,
        username: "fixture", password: "quoted\"#credential")

    func testPackagedEnginePinMatchesRuntimeInstallationCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Configuration/MihomoDependency.plist"))
        let pin = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(pin["version"] as? String, MimoRuntime.version,
            "An engine update must also update the runtime check or installation rolls back.")
    }

    func testLegacyConfigurationMigratesToStrictIPv4WithoutProviderState() throws {
        let data = Data(#"{"mode":"global","profileHostingEnabled":true,"mihomoEnabled":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MimoConfiguration.self, from: data).networkFamily, .ipv4)
        var settings = MachineSettings()
        let previous = settings
        settings.refreshInterval = .never
        XCTAssertFalse(settings.affectsVerification(comparedTo: previous), "timer changes must not interrupt protected routing")
        XCTAssertEqual(MimoServiceID.allCases, [.core, .mihomo, .profileHosting])
    }

    func testRendererEnforcesFamilyInBothRealEngineModesWithoutProviderMachinery() throws {
        for mode in [ProxyMode.rule, .global] {
            for family in MimoNetworkFamily.allCases {
                let profile = try MihomoProfile.render(proxy, mode: mode, stage: .active, probePassword: "private-probe",
                    bypassBlocks: [], family: family)
                XCTAssertTrue(profile.contains("\nmode: \(mode.rawValue)\n"))
                XCTAssertTrue(profile.contains("mimo-destination-family: \(family.rawValue)"))
                XCTAssertTrue(profile.contains("stack: gvisor-no-ping"))
                XCTAssertTrue(profile.contains("route-address: ['::/1', '8000::/1']"), "NAT64 must enter the tunnel too")
                XCTAssertTrue(profile.contains("dns-mode: disabled"), "core is the only system DNS owner")
                XCTAssertFalse(profile.contains("inet6-address:"), "use the pinned engine default")
                for obsolete in ["TS-NATIVE", "TS-DIRECT", "tailscale-live", "18766", "proxy-providers:", "interface-name:"] {
                    XCTAssertFalse(profile.contains(obsolete), obsolete)
                }
                XCTAssertEqual(MihomoProfile.routingRules(in: profile),
                    (family == .ipv4 ? ["IP-CIDR6,::/0,REJECT,no-resolve"] : []) + ["MATCH,Proxy", "MATCH,REJECT"])
                XCTAssertTrue(profile.contains("password: \"quoted\\\"#credential\""))
                XCTAssertEqual(profile.contains("fake-ip-range6:"), family == .dual)
            }
        }
    }

    func testPrivateNamesHaveBothFakeIPExclusionAndNonPublicPolicy() throws {
        let native = try MimoPrivateDNSRule(suffix: "corp.example", servers: ["10.0.0.53"])
        let absent = try MimoPrivateDNSRule(suffix: "offline.example", servers: [])
        let profile = try MihomoProfile.render(proxy, mode: .global, stage: .active, probePassword: "probe",
            privateDNS: [native, absent])
        XCTAssertTrue(profile.contains("'https://1.1.1.1/dns-query#Proxy'"))
        XCTAssertTrue(profile.contains("respect-rules: false"))
        XCTAssertTrue(profile.contains("fallback: []"))
        XCTAssertTrue(profile.contains("'*': ['rcode://name_error']"))
        XCTAssertTrue(profile.contains("\"+.corp.example\": [\"udp://10.0.0.53:53\"]"))
        XCTAssertTrue(profile.contains("\"+.offline.example\": [\"rcode://name_error\"]"))
        for domain in ["corp.example", "offline.example", "ts.net"] {
            XCTAssertTrue(profile.contains("    - \"+.\(domain)\""))
        }
        for invalid in ["a,b", "corp.example\nMATCH,DIRECT", "*"] {
            XCTAssertThrowsError(try MimoPrivateDNSRule(suffix: invalid, servers: ["10.0.0.53"]))
        }
        XCTAssertThrowsError(try MimoPrivateDNSRule(suffix: "corp.example", servers: ["127.0.0.1"]))
    }

    func testPairedApprovalCannotMixFamiliesAttemptsOrCachedResults() throws {
        var configuration = MimoConfiguration(); configuration.mode = .global; configuration.networkFamily = .dual; configuration.proxy = MimoProxy(proxy)
        var policy = MimoAccessPolicy()
        let check = policy.begin(configuration: configuration, revision: 2, networkGeneration: 3)
        policy.checking(check)
        let now = Date()
        let v4 = MimoSnapshot(ipAddress: "203.0.113.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois, checkedAt: now)
        let v6 = MimoSnapshot(ipAddress: "2001:db8::10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois, checkedAt: now)
        let both = MimoExitObservations(verification: check, ipv4: v4, ipv6: v6)
        XCTAssertFalse(MimoExitObservations(verification: check, ipv4: v4).isValid(for: check, family: .dual, since: check.startedAt!))
        XCTAssertFalse(both.isValid(for: MimoVerification(revision: 2, networkGeneration: 3), family: .dual, since: check.startedAt!))
        XCTAssertFalse(both.isValid(for: check, family: .dual, since: now.addingTimeInterval(1)))
        XCTAssertFalse(both.isValid(for: check, family: .ipv4, since: check.startedAt!))
        XCTAssertFalse(policy.approve(observations: both, allowlist: AllowedIPList(addresses: [v4.ipAddress]), verification: check, runtimeMatches: true))
        XCTAssertFalse(policy.state.allowsTraffic)
        let retry = policy.begin(configuration: configuration, revision: 2, networkGeneration: 3)
        policy.checking(retry)
        let fresh4 = MimoSnapshot(ipAddress: v4.ipAddress, countryCode: "SG", countryName: "Singapore", provider: .ipWhois, checkedAt: .now)
        let fresh6 = MimoSnapshot(ipAddress: v6.ipAddress, countryCode: "SG", countryName: "Singapore", provider: .ipWhois, checkedAt: .now)
        XCTAssertTrue(policy.approve(observations: .init(verification: retry, ipv4: fresh4, ipv6: fresh6),
            allowlist: AllowedIPList(addresses: [v4.ipAddress, v6.ipAddress]), verification: retry, runtimeMatches: true))
        XCTAssertTrue(policy.state.allowsTraffic)
    }
}
