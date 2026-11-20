import XCTest
@testable import ExitIPShared

final class MimoRoutingTests: XCTestCase {
    func testLostSupervisorDoesNotLeaveServiceProgressClaimingConfirmedBlocking() {
        var pending = MimoRoutingState(); pending.phase = .blocked
        pending.supervisorCheckedAt = Date(timeIntervalSince1970: 101)
        var lost = pending; lost.phase = .unavailable
        lost.supervisorCheckedAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(MimoServiceProgress.canReplace(pending, with: lost, startedAt: .distantPast, configurationAdvanced: false))
    }

    func testServiceProgressRejectsOlderSupervisorStateEvenWhenBlocked() {
        var pending = MimoRoutingState(); pending.phase = .unavailable
        pending.supervisorCheckedAt = Date(timeIntervalSince1970: 101)
        var current = pending; current.phase = .blocked
        current.supervisorCheckedAt = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(MimoServiceProgress.canReplace(pending, with: current, startedAt: .distantPast, configurationAdvanced: false))
        current.supervisorCheckedAt = nil
        XCTAssertFalse(MimoServiceProgress.canReplace(pending, with: current, startedAt: .distantPast, configurationAdvanced: false))
        current.supervisorCheckedAt = Date(timeIntervalSince1970: 102)
        XCTAssertTrue(MimoServiceProgress.canReplace(pending, with: current, startedAt: .distantPast, configurationAdvanced: false))
    }

    func testServiceProgressRejectsCachedApprovalAndAcceptsFreshVerification() {
        var config = MimoConfiguration(); config.mode = .rule
        let started = Date(timeIntervalSince1970: 100)
        var pending = MimoRoutingState(configuration: config); pending.phase = .blocked
        pending.observedIP = MimoIPObservation(address: "203.0.113.1", checkedAt: started.addingTimeInterval(-1))
        var current = pending; current.phase = .active; current.effectiveMode = .rule
        XCTAssertFalse(MimoServiceProgress.canReplace(pending, with: current, startedAt: started, configurationAdvanced: false))
        current.observedIP = MimoIPObservation(address: "203.0.113.1", checkedAt: started.addingTimeInterval(1))
        XCTAssertTrue(MimoServiceProgress.canReplace(pending, with: current, startedAt: started, configurationAdvanced: false))
        current.effectiveMode = .global
        XCTAssertFalse(MimoServiceProgress.canReplace(pending, with: current, startedAt: started, configurationAdvanced: false))
    }

    func testServiceProgressKeepsConfirmedBlockingThroughUnconfirmedClosure() {
        var config = MimoConfiguration(); config.mode = .global
        var pending = MimoRoutingState(configuration: config); pending.phase = .blocked
        var current = pending; current.phase = .closing
        XCTAssertFalse(MimoServiceProgress.canReplace(pending, with: current, startedAt: .now, configurationAdvanced: false))
        for phase: MimoAccessPhase in [.blocked, .validating, .checking, .unavailable] {
            current.phase = phase
            XCTAssertTrue(MimoServiceProgress.canReplace(pending, with: current, startedAt: .now, configurationAdvanced: false))
        }
    }

    func testServiceProgressRejectsOldDirectSnapshotButAcceptsExplicitModeChange() {
        var config = MimoConfiguration(); config.mode = .rule
        let pending = MimoRoutingState(configuration: config)
        var direct = MimoRoutingState(); direct.phase = .active; direct.effectiveMode = .direct
        XCTAssertFalse(MimoServiceProgress.canReplace(pending, with: direct, startedAt: .now, configurationAdvanced: false))
        XCTAssertTrue(MimoServiceProgress.canReplace(pending, with: direct, startedAt: .now, configurationAdvanced: true))
    }

    func testInfrastructureHealthExpiresWithoutFreshChecks() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let healthy = MimoInfrastructureStatus(pf: .healthy, launchd: .healthy, checkedAt: now)
        XCTAssertEqual(healthy.current(at: now.addingTimeInterval(35)).pf, .healthy)
        XCTAssertEqual(healthy.current(at: now.addingTimeInterval(36)).pf, .stale)
        XCTAssertEqual(healthy.current(at: now.addingTimeInterval(-6)).launchd, .stale)
        XCTAssertEqual(MimoInfrastructureStatus().current(at: now).pf, .unknown)
        let failed = MimoInfrastructureStatus(pf: .healthy, launchd: .failed, checkedAt: now)
        XCTAssertEqual(failed.current(at: now).launchd, .failed)
        var state = MimoRoutingState(); state.infrastructure = healthy
        XCTAssertEqual(try JSONDecoder().decode(MimoRoutingState.self, from: JSONEncoder().encode(state)).infrastructure, healthy)
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        let oldData = try JSONSerialization.data(withJSONObject: old.filter { $0.key != "infrastructure" })
        XCTAssertNil(try JSONDecoder().decode(MimoRoutingState.self, from: oldData).infrastructure)
    }
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

    func testApprovedIPWaitsForReadinessAndLateReadinessCannotUndoDirect() {
        var policy = MimoAccessPolicy(configuration: configuration)
        let token = policy.begin(configuration: configuration, revision: 1, networkGeneration: 1)
        policy.checking(token)
        policy.waitingForReadiness(address: "203.0.113.42", verification: token)
        XCTAssertFalse(policy.state.allowsTraffic)
        XCTAssertEqual(policy.state.phase, .checking)
        XCTAssertEqual(policy.state.observedIP?.address, "203.0.113.42")
        XCTAssertTrue(policy.state.reason.contains("profile, tunnel and DNS"))
        XCTAssertFalse(policy.approve(address: "203.0.113.42", at: .now, allowlist: allowed,
                                      verification: token, runtimeMatches: false))
        policy.directRestored(configuration: MimoConfiguration())
        policy.waitingForReadiness(address: "203.0.113.42", verification: token)
        XCTAssertTrue(policy.state.allowsTraffic)
        XCTAssertEqual(policy.state.effectiveMode, .direct)
        XCTAssertNil(policy.state.observedIP)
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

    func testPowerBarrierPrecedesEveryProtectedTrafficException() throws {
        for mode: ProxyMode? in [nil, .rule, .global] {
            let rules = try MimoFirewallPolicy.render(group: 10000, mode: mode, tunnel: mode == nil ? nil : "utun239")
            let power = try XCTUnwrap(rules.range(of: "anchor \"power-guard\" out quick"))
            for exception in ["pass out quick on lo0", "anchor \"native-transport\"", "pass out quick on utun239"] {
                if let range = rules.range(of: exception) { XCTAssertLessThan(power.lowerBound, range.lowerBound) }
            }
        }
        XCTAssertFalse(MimoFirewallPolicy.directIPv4.contains("power-guard"), "Direct does not depend on protected wake verification")
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

    func testProtectedPublicDNSUsesProxyWithoutLegacyDirectResolvers() throws {
        for mode in [ProxyMode.rule, .global] {
            for stage in [MihomoProfile.Stage.verification, .active] {
                let result = try MihomoProfile.render(configuration.proxy!.settings(), mode: mode, stage: stage, probePassword: "fixture")
                XCTAssertTrue(result.contains("  nameserver:\n  - \"https://1.1.1.1/dns-query#Proxy\"\n"))
                XCTAssertTrue(result.contains("  proxy-server-nameserver:\n  - \"https://1.1.1.1/dns-query\"\n"))
                XCTAssertTrue(result.contains("\"+.ts.net\":\n      - \"tcp://100.100.100.100:53#TS-DIRECT\""))
                for legacy in ["119.29.29.29", "180.76.76.76", "120.53.53.53", "223.5.5.5", "223.6.6.6"] {
                    XCTAssertFalse(result.contains(legacy), "A protected profile must not inherit a legacy public resolver")
                }
                XCTAssertFalse(result.contains("direct-nameserver:"))
                XCTAssertFalse(result.contains("\n  fallback:"))
            }
        }
    }

    func testStartupGuardDoesNotTrustRuntimeOrNativeTransportBeforeValidation() {
        let policy = MimoFirewallPolicy.startupBlocking
        XCTAssertTrue(policy.hasPrefix("block return out quick on lo0"))
        XCTAssertTrue(policy.contains("port { \(MimoRuntime.mixedPort), \(MimoRuntime.dnsPort) }"))
        XCTAssertTrue(policy.contains("block return out quick inet6 all"))
        XCTAssertTrue(policy.hasSuffix("block drop out quick all\n"))
        XCTAssertFalse(policy.contains("group "))
        XCTAssertFalse(policy.contains("native-transport"))
        XCTAssertFalse(policy.contains(MimoFirewallPolicy.bootstrapResolver))
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
