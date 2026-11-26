import XCTest
@testable import MimoShared

final class MimoV3Tests: XCTestCase {
    func testRejectedIPv4IsVisibleInBothTrafficSettings() throws {
        for family in MimoNetworkFamily.allCases {
            for allowed in [AllowedIPList(), AllowedIPList(addresses: ["203.0.113.99"])] {
                var configuration = MimoConfiguration(); configuration.mode = .rule; configuration.networkFamily = family
                configuration.proxy = MimoProxy(proxy)
                var policy = MimoAccessPolicy()
                let check = policy.begin(configuration: configuration, revision: 1, networkGeneration: 1)
                policy.checking(check)
                let v4 = MimoSnapshot(ipAddress: "203.0.113.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois)
                XCTAssertFalse(policy.approve(observations: .init(verification: check, ipv4: v4), allowlist: allowed, verification: check, runtimeMatches: true))
                XCTAssertEqual(policy.state.displayedIP?.address, v4.ipAddress)
                XCTAssertEqual(policy.state.rejectedExit?.address, v4.ipAddress)
                XCTAssertNil(policy.state.observation(for: .ipv6))
                XCTAssertTrue(policy.state.reason.contains("Review Allowed IPs"))
                _ = policy.begin(configuration: configuration, revision: 2, networkGeneration: 2)
                XCTAssertNil(policy.state.rejectedExit, "New attempt cannot reuse the old rejection as a fresh result")
                policy.directRestored(configuration: .init())
                XCTAssertNil(policy.state.displayedIP)
            }
        }
    }

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

    func testIPv4ApprovalRequiresCurrentFreshReceiptInBothTrafficSettings() throws {
        for family in MimoNetworkFamily.allCases {
            var configuration = MimoConfiguration(); configuration.mode = .global; configuration.networkFamily = family; configuration.proxy = MimoProxy(proxy)
            var policy = MimoAccessPolicy()
            let check = policy.begin(configuration: configuration, revision: 2, networkGeneration: 3)
            policy.checking(check)
            let now = Date()
            let v4 = MimoSnapshot(ipAddress: "203.0.113.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois, checkedAt: now)
            let v6 = MimoSnapshot(ipAddress: "2001:db8::10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois, checkedAt: now)
            let receipt = MimoExitObservations(verification: check, ipv4: v4)
            XCTAssertTrue(receipt.isValid(for: check, family: family, since: check.startedAt!))
            XCTAssertFalse(receipt.isValid(for: MimoVerification(revision: 2, networkGeneration: 3), family: family, since: check.startedAt!))
            XCTAssertFalse(receipt.isValid(for: check, family: family, since: now.addingTimeInterval(1)))
            XCTAssertFalse(MimoExitObservations(verification: check, ipv4: v6).isValid(for: check, family: family, since: check.startedAt!))
            XCTAssertFalse(MimoExitObservations(verification: check, ipv4: v4, ipv6: v6).isValid(for: check, family: family, since: check.startedAt!), "Old paired receipts are not accepted")
            XCTAssertTrue(policy.approve(observations: receipt, allowlist: AllowedIPList(addresses: [v4.ipAddress]), verification: check, runtimeMatches: true))
            XCTAssertTrue(policy.state.allowsTraffic)
            XCTAssertFalse(policy.approve(observations: receipt, allowlist: AllowedIPList(addresses: [v4.ipAddress]), verification: check, runtimeMatches: true), "Cannot replay a completed receipt")
        }
    }
}
