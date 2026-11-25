import XCTest
@testable import MimoShared

final class MimoRoutingTests: XCTestCase {
    func testRevocationKeepsInboundStatesAndKillsOnlyOutboundSources() throws {
        let states = """
        en0 tcp 192.0.2.5:22 <- 192.0.2.9:54000 ESTABLISHED:ESTABLISHED
        en0 tcp 192.0.2.5:54001 -> 203.0.113.5:443 ESTABLISHED:ESTABLISHED
        en0 udp 2001:db8::5[54002] -> 2001:db8::9[443] MULTIPLE:SINGLE
        utun8 tcp 100.64.0.5:5900 <- 100.64.0.9:54003 ESTABLISHED:ESTABLISHED
        """
        XCTAssertEqual(try MimoFirewallPolicy.outboundStateSources(states), ["192.0.2.5", "2001:db8::5"])
        XCTAssertEqual(try MimoFirewallPolicy.outboundStateSources(""), [])
        XCTAssertThrowsError(try MimoFirewallPolicy.outboundStateSources("unknown state format"))
        XCTAssertThrowsError(try MimoFirewallPolicy.outboundStateSources("en0 tcp bad:123 -> 192.0.2.9:443"))
    }

    func testBlockedPolicyKeepsInboundTCPAndVerifiedVPNTransportOnly() throws {
        var native = MimoNativeEgress()
        native.datagrams.insert(.init(ipv6: false, source: nil, port: 41641))
        native.https.insert("192.0.2.8")
        let blocked = try MimoFirewallPolicy.blockedPolicy(nativeEgress: native)
        XCTAssertTrue(blocked.hasPrefix(MimoFirewallPolicy.inboundTCP))
        XCTAssertTrue(blocked.hasPrefix(MimoFirewallPolicy.inboundTCP + "\n" + MimoFirewallPolicy.inboundLoopback))
        XCTAssertFalse(blocked.contains("pass in quick"), "Mimo must not override administrator ingress rules")
        XCTAssertFalse(blocked.contains("flags any"), "An outbound SYN-ACK must not create an ingress permission")
        XCTAssertTrue(blocked.contains("keep state (if-bound)"))
        XCTAssertFalse(blocked.contains("mimo:active:engine"))
        XCTAssertFalse(blocked.contains("mimo:active:tunnel"))
        XCTAssertTrue(blocked.hasSuffix("block drop out quick all label \"mimo:transition:deny\"\n"))
    }
    func testEveryGeneratedPacketRuleHasAnIdentifiablePersistentLabel() throws {
        let policies = [MimoFirewallPolicy.startupBlocking,
            try MimoFirewallPolicy.render(group: 400),
            try MimoFirewallPolicy.render(group: 400, endpoints: ["192.0.2.10"], proxyPort: 1080)]
        for policy in policies {
            for line in policy.split(separator: "\n") where line.hasPrefix("pass ") || line.hasPrefix("block ") {
                XCTAssertTrue(line.contains("label \"mimo:"), String(line))
            }
        }
    }
    func testActiveGuardSurvivesEngineLossWithoutRootOrFloatingStatePermissions() throws {
        for mode in [ProxyMode.rule, .global] {
            let active = try MimoFirewallPolicy.render(group: 400, endpoints: ["192.0.2.10"], proxyPort: 1080, mode: mode)
            XCTAssertTrue(MimoFirewallPolicy.isActiveReadback(active, group: 400))
            XCTAssertFalse(MimoFirewallPolicy.isActiveReadback(active, group: 401))
            XCTAssertFalse(MimoFirewallPolicy.isActiveReadback(active + "pass out quick all\n", group: 400))
            XCTAssertFalse(MimoFirewallPolicy.isActiveReadback("", group: 400))
            XCTAssertTrue(active.contains("on utun239 all no state"))
            XCTAssertTrue(active.contains("group = 400 no state"))
            XCTAssertFalse(active.contains("user 0"))
            XCTAssertTrue(active.contains(MimoFirewallPolicy.inboundTCP))
            let tunnel = try XCTUnwrap(active.range(of: "mimo:active:tunnel")?.lowerBound)
            let fake = try XCTUnwrap(active.range(of: "fdfe:dcba:9876::/48")?.lowerBound)
            let native = try XCTUnwrap(active.range(of: "fc00::/7")?.lowerBound)
            XCTAssertLessThan(tunnel, fake, "Captured fake destinations must reach the engine")
            XCTAssertLessThan(fake, native, "Fake ULA addresses must never inherit the native LAN exemption")
            XCTAssertTrue(active.hasSuffix("block drop out quick all label \"mimo:active:deny-native-fallback\"\n"))
            for line in active.split(separator: "\n") {
                XCTAssertTrue(line.contains("label \"mimo:"))
                if line.hasPrefix("pass out ") { XCTAssertTrue(line.contains("no state")) }
            }
        }
        XCTAssertThrowsError(try MimoFirewallPolicy.activePolicy(group: 0))
        XCTAssertEqual(MimoFirewallPolicy.direct, "")
    }

    func testTransitionAllowsOnlyPinnedTCPProbeAndLocalControl() throws {
        let rules = try MimoFirewallPolicy.preparedPolicy(group: 400, endpoints: ["192.0.2.10"], proxyPort: 1080)
        XCTAssertTrue(rules.contains("pass out quick inet proto tcp to 192.0.2.10 port 1080 group 400 no state"))
        XCTAssertTrue(rules.hasSuffix("block drop out quick all label \"mimo:probe:deny\"\n"))
        for bypass in ["native-transport", "on utun239 all", "100.64.0.0/10", "10.0.0.0/8", "group !=", "1.1.1.1", "proto udp to 192.0.2.10"] {
            XCTAssertFalse(rules.contains(bypass), bypass)
        }
        XCTAssertTrue(MimoFirewallPolicy.permissionParent.hasSuffix(MimoFirewallPolicy.startupBlocking))
        let bootstrap = try MimoFirewallPolicy.preparedPolicy(group: 400, endpoints: [], proxyPort: nil)
        XCTAssertTrue(bootstrap.contains("pass out quick inet proto tcp to 1.1.1.1 port 443 group 400"))
        XCTAssertFalse(bootstrap.contains("port 53"))
    }

    func testNativeDNSCannotUsePhysicalFallbackOrBroadULAAllowance() throws {
        let rules = try MimoFirewallPolicy.activePolicy(group: 400, nativeInterfaces: ["utun8"])
        XCTAssertTrue(MimoFirewallPolicy.isActiveReadback(rules, group: 400, nativeInterfaces: ["utun8"]))
        XCTAssertFalse(MimoFirewallPolicy.isActiveReadback(rules, group: 400, nativeInterfaces: ["utun9"]))
        let native = try XCTUnwrap(rules.range(of: "on utun8 inet from any to 100.64.0.0/10")?.lowerBound)
        let deny = try XCTUnwrap(rules.range(of: "mimo:active:tailnet-wrong-path")?.lowerBound)
        let engine = try XCTUnwrap(rules.range(of: "mimo:active:engine")?.lowerBound)
        let ula = try XCTUnwrap(rules.range(of: "fc00::/7")?.lowerBound)
        XCTAssertLessThan(native, deny)
        XCTAssertLessThan(deny, engine, "Even engine DNS must not send Quad100 queries on a physical route")
        XCTAssertLessThan(deny, ula, "Tailnet IPv6 must not inherit generic native ULA permission")
        for invalid in ["en0", "utun239", "utun", "utun8\npass out quick all", "utun８"] {
            XCTAssertThrowsError(try MimoFirewallPolicy.activePolicy(group: 400, nativeInterfaces: [invalid]))
        }
        let absent = try MimoFirewallPolicy.activePolicy(group: 400)
        XCTAssertFalse(absent.contains("label \"mimo:active:tailnet\""))
        XCTAssertTrue(absent.contains("mimo:active:tailnet-wrong-path"))
    }

    func testPendingBlockRevokesApprovalWithoutClaimingConfirmedBlocking() {
        var policy = MimoAccessPolicy()
        policy.directRestored(configuration: MimoConfiguration())
        policy.requestingBlock("Blocking traffic.")
        XCTAssertEqual(policy.state.phase, .closing)
        XCTAssertNil(policy.state.effectiveMode)
        XCTAssertNil(policy.state.verification)
        XCTAssertFalse(policy.state.allowsTraffic)
        policy.block("Confirmed.")
        XCTAssertEqual(policy.state.phase, .blocked)
    }

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

    func testTransitionBarrierCoversBothFamiliesWithoutSteadyIPv6Rules() throws {
        XCTAssertTrue(MimoFirewallPolicy.startupBlocking.hasSuffix("block drop out quick all label \"mimo:transition:deny\"\n"))
        XCTAssertTrue(MimoFirewallPolicy.startupBlocking.contains("icmp6-type"), "Link control remains available for network recovery")
        XCTAssertFalse(MimoFirewallPolicy.startupBlocking.contains("block return out quick inet6 all"))
        XCTAssertEqual(MimoFirewallPolicy.direct, "")
        XCTAssertEqual(try MimoFirewallPolicy.render(group: 10000, mode: .rule), try MimoFirewallPolicy.activePolicy(group: 10000))
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

    func testVerificationProfileRejectsOrdinaryTrafficAndScopesAuthenticatedProbe() throws {
        let result = try MihomoProfile.render(configuration.proxy!.settings(), mode: .rule, stage: .verification, probePassword: "fixture-probe-secret")
        XCTAssertEqual(MihomoProfile.routingRules(in: result).suffix(2), ["MATCH,Proxy", "MATCH,REJECT"])
        XCTAssertTrue(result.contains("mixed-port: 0"))
        XCTAssertTrue(result.contains("enable: false"))
        XCTAssertTrue(result.contains("listen: 127.0.0.1"))
        XCTAssertTrue(result.contains("password: \"fixture-probe-secret\""))
        XCTAssertTrue(result.contains("(DST-PORT,443)"))
        XCTAssertTrue(result.hasSuffix("    - MATCH,REJECT\n"))
        XCTAssertFalse(MihomoProfile.blocking().contains("fixture-probe-secret"))
    }

    func testStartupGuardDoesNotTrustRuntimeOrNativeTransportBeforeValidation() {
        let policy = MimoFirewallPolicy.startupBlocking
        XCTAssertTrue(policy.hasPrefix(MimoFirewallPolicy.inboundTCP))
        XCTAssertTrue(policy.contains("port { \(MimoRuntime.mixedPort), \(MimoRuntime.dnsPort) }"))
        XCTAssertFalse(policy.contains("block return out quick inet6 all"))
        XCTAssertTrue(policy.hasSuffix("block drop out quick all label \"mimo:transition:deny\"\n"))
        XCTAssertFalse(policy.contains("group "))
        XCTAssertFalse(policy.contains("native-transport"))
        XCTAssertFalse(policy.contains(MimoFirewallPolicy.bootstrapResolver))
    }

}
