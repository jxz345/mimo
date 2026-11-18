import XCTest
@testable import ExitIPShared

final class MimoRoutingTests: XCTestCase {
    func testStoppedServiceIntentSurvivesPersistence() throws {
        var preferences = MimoServicePreferences()
        preferences.core = false
        preferences.engine = false
        preferences.profile = false
        let restored = try JSONDecoder().decode(MimoServicePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        XCTAssertFalse(restored.core)
        XCTAssertFalse(restored.engine)
        XCTAssertFalse(restored.profile)
        XCTAssertThrowsError(try JSONDecoder().decode(MimoServicePreferences.self, from: Data("{}".utf8)))
    }
    private let allowed = AllowedIPList(addresses: ["203.0.113.42"])
    private var configuration: MimoConfiguration {
        var value = MimoConfiguration(); value.mode = .rule
        value.proxy = MimoProxy(ClashProxySettings(name: "Example", type: .socks5, server: "192.0.2.1", port: 1080))
        return value
    }

    func testStartupNeverTrustsPersistedModeWithoutConfirmation() {
        let policy = MimoAccessPolicy(configuration: configuration)
        XCTAssertFalse(policy.state.allowsTraffic)
        XCTAssertEqual(policy.state.phase, .unavailable)
    }

    func testProtectedAccessRequiresAllowlistAndMatchingEffectiveRuntime() {
        for mode in [ProxyMode.rule, .global] {
            for (list, matches) in [(AllowedIPList(), true), (allowed, false), (allowed, true)] {
                var configuration = configuration; configuration.mode = mode
                var policy = MimoAccessPolicy()
                let check = policy.begin(configuration: configuration, revision: 1, networkGeneration: 1)
                XCTAssertFalse(policy.state.allowsTraffic)
                policy.checking(check)
                XCTAssertEqual(policy.approve(address: "203.0.113.42", at: .now, allowlist: list,
                                              verification: check, runtimeMatches: matches), !list.isEmpty && matches)
            }
        }
    }

    func testSupersededAndReplayedChecksNeverOpenTraffic() {
        var policy = MimoAccessPolicy()
        let old = policy.begin(configuration: configuration, revision: 1, networkGeneration: 1)
        policy.checking(old)
        let current = policy.begin(configuration: configuration, revision: 1, networkGeneration: 2)
        policy.checking(current)
        XCTAssertFalse(policy.approve(address: "203.0.113.42", at: .now, allowlist: allowed, verification: old, runtimeMatches: true))
        XCTAssertTrue(policy.approve(address: "203.0.113.42", at: .now, allowlist: allowed, verification: current, runtimeMatches: true))
        policy.block("Engine stopped")
        XCTAssertFalse(policy.approve(address: "203.0.113.42", at: .now, allowlist: allowed, verification: current, runtimeMatches: true))
    }

    func testIPv6ExitCannotApproveTrafficEvenWhenAllowlisted() {
        var policy = MimoAccessPolicy()
        let check = policy.begin(configuration: configuration, revision: 1, networkGeneration: 1)
        policy.checking(check)
        XCTAssertFalse(policy.approve(address: "2001:db8::42", at: .now,
            allowlist: AllowedIPList(addresses: ["2001:db8::42"]), verification: check, runtimeMatches: true))
        XCTAssertEqual(policy.state.phase, .blocked)
        XCTAssertEqual(policy.state.blockingIP?.address, "2001:db8::42")
    }

    func testIPv6FirewallBlockPrecedesTunnelAndNativeExceptions() throws {
        for mode: ProxyMode? in [nil, .rule, .global] {
            let rules = try MimoFirewallPolicy.render(group: 10000, mode: mode, tunnel: mode == nil ? nil : "utun239")
            let deny = try XCTUnwrap(rules.range(of: "block return out quick inet6 all"))
            let native = try XCTUnwrap(rules.range(of: "anchor \"native-transport\""))
            XCTAssertLessThan(deny.lowerBound, native.lowerBound)
            if let tunnel = rules.range(of: "pass out quick on utun239") { XCTAssertLessThan(deny.lowerBound, tunnel.lowerBound) }
        }
        XCTAssertTrue(MimoFirewallPolicy.directIPv4.contains("block return out quick inet6 all"))
        XCTAssertFalse(MimoFirewallPolicy.directIPv4.contains("block return out quick all"))
    }

    func testBlockingAddressSurvivesRetryAndClearsOnlyAfterApprovalOrDirect() {
        var policy = MimoAccessPolicy()
        let check = policy.begin(configuration: configuration, revision: 1, networkGeneration: 1)
        policy.checking(check)
        XCTAssertFalse(policy.approve(address: "198.51.100.77", at: .now, allowlist: allowed, verification: check, runtimeMatches: true))
        let retry = policy.begin(configuration: configuration, revision: 1, networkGeneration: 1)
        XCTAssertEqual(policy.state.displayedIP?.address, "198.51.100.77")
        policy.checking(retry)
        XCTAssertTrue(policy.approve(address: "203.0.113.42", at: .now, allowlist: allowed, verification: retry, runtimeMatches: true))
        XCTAssertNil(policy.state.blockingIP)
        policy.directRestored(configuration: configuration)
        XCTAssertTrue(policy.state.allowsTraffic)
        XCTAssertEqual(policy.state.effectiveMode, .direct)
        XCTAssertNil(policy.state.displayedIP)
    }

    func testPublicConfigurationCannotExposeProxyPassword() throws {
        let proxy = ClashProxySettings(name: "Example", type: .http, server: "192.0.2.1", port: 443, username: "test", password: "fixture-secret")
        let wire = String(decoding: try JSONEncoder().encode(MimoProxy(proxy)), as: UTF8.self)
        XCTAssertFalse(wire.contains("fixture-secret"))
        XCTAssertFalse(wire.contains("password"))
    }

    func testRuleProfilePreservesOriginalIPv4RulesAndDisablesIPv6() throws {
        let settings = try configuration.proxy!.settings()
        let original = try ClashVergeProfile.render(settings)
        let result = try MihomoProfile.render(settings, mode: .rule, stage: .active, probePassword: "fixture-probe-secret")
        XCTAssertEqual(MihomoProfile.routingRules(in: original).count, 38)
        XCTAssertEqual(MihomoProfile.routingRules(in: result), ["IP-CIDR6,::/0,REJECT,no-resolve"] + MihomoProfile.routingRules(in: original).filter { !$0.hasPrefix("IP-CIDR6,") })
        XCTAssertEqual(MihomoProfile.routingRules(in: result).count, 36)
        XCTAssertFalse(result.contains("/tmp/verge"))
        XCTAssertFalse(result.contains("external-controller-cors"))
        XCTAssertFalse(result.contains("fake-ip-range6:"))
        XCTAssertFalse(result.contains("ipv6: true"))
        XCTAssertFalse(result.contains("fd7a:"))
        XCTAssertTrue(result.contains("ipv6: false"))
        XCTAssertTrue(result.contains("udp: true"))
    }

    func testVerificationProfileRejectsOrdinaryTrafficAndScopesAuthenticatedProbe() throws {
        let result = try MihomoProfile.render(configuration.proxy!.settings(), mode: .rule, stage: .verification, probePassword: "fixture-probe-secret")
        XCTAssertEqual(MihomoProfile.routingRules(in: result), ["MATCH,REJECT"])
        XCTAssertTrue(result.contains("mixed-port: 0"))
        XCTAssertTrue(result.contains("enable: false"))
        XCTAssertTrue(result.contains("listen: 127.0.0.1"))
        XCTAssertTrue(result.contains("password: \"fixture-probe-secret\""))
        XCTAssertTrue(result.contains("(DST-PORT,443)"))
        XCTAssertTrue(result.hasSuffix("    - MATCH,REJECT\n"))
        XCTAssertFalse(MihomoProfile.blocking().contains("fixture-probe-secret"))
    }

    func testGlobalRetainsLocalExceptionsButRemovesPublicDirectRules() throws {
        let result = try MihomoProfile.render(configuration.proxy!.settings(), mode: .global, stage: .active, probePassword: "fixture")
        let rules = MihomoProfile.routingRules(in: result)
        XCTAssertFalse(rules.contains { $0.contains("youtube.com") || $0.contains("github.com") })
        XCTAssertFalse(rules.contains("DOMAIN-SUFFIX,tailscale.com,DIRECT"))
        XCTAssertFalse(rules.contains("DOMAIN-SUFFIX,tailscale.io,DIRECT"))
        XCTAssertTrue(rules.contains("PROCESS-NAME,io.tailscale.ipn.macsys.network-extension,DIRECT"))
        XCTAssertTrue(rules.contains("DOMAIN-SUFFIX,ts.net,TS-DIRECT"))
        XCTAssertTrue(rules.contains("IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"))
        XCTAssertEqual(rules.last, "MATCH,Proxy")
        XCTAssertTrue(result.contains("https://1.1.1.1/dns-query#Proxy"))
    }
}
