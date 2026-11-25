import XCTest
@testable import MimoShared

final class MimoBypassTests: XCTestCase {
    private let proxy = ClashProxySettings(name: "Fixture", type: .socks5, server: "192.0.2.1", port: 1080)

    func testOldSettingsRetainDefaultsButAnExplicitEmptyListRemovesWebsiteBypasses() throws {
        let original = MachineSettings()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "bypassBlocks")
        let decoded = try JSONDecoder().decode(MachineSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.effectiveBypassBlocks, MimoBypassBlock.defaults)
        var edited = decoded; edited.bypassBlocks = []
        XCTAssertEqual(try edited.validated().effectiveBypassBlocks, [])
        XCTAssertTrue(edited.affectsVerification(comparedTo: decoded, mode: .rule))
        XCTAssertFalse(edited.affectsVerification(comparedTo: decoded, mode: .global))
        XCTAssertFalse(edited.affectsVerification(comparedTo: decoded, mode: .direct))
    }

    func testRulesKeepNativeAndLANBoundariesAndGlobalIgnoresCustomBlocks() throws {
        let blocks = [MimoBypassBlock(name: "Sites", domains: [.init("Example.COM."), .init("cdn.example.net", match: .exact)]),
                      MimoBypassBlock(name: "Off", enabled: false, domains: [.init("disabled.invalid")])]
        let rule = try MihomoProfile.render(proxy, mode: .rule, stage: .active, probePassword: "test", bypassBlocks: blocks)
        let global = try MihomoProfile.render(proxy, mode: .global, stage: .active, probePassword: "test", bypassBlocks: blocks)
        XCTAssertTrue(rule.contains("DOMAIN-SUFFIX,example.com,DIRECT"))
        XCTAssertTrue(rule.contains("DOMAIN,cdn.example.net,DIRECT"))
        XCTAssertFalse(rule.contains("disabled.invalid"))
        XCTAssertFalse(global.contains("example.com"))
        XCTAssertFalse(global.contains("cdn.example.net"))
        for profile in [rule, global] {
            XCTAssertTrue(profile.contains("100.64.0.0/10"))
            XCTAssertTrue(profile.contains("fd7a:115c:a1e0::/48"))
            XCTAssertTrue(profile.contains("MATCH,Proxy"))
        }
        let removed = try MihomoProfile.render(proxy, mode: .rule, stage: .active, probePassword: "test", bypassBlocks: [])
        XCTAssertFalse(removed.contains("DOMAIN-SUFFIX,youtube.com,DIRECT"))
        XCTAssertTrue(removed.contains("100.64.0.0/10"))
    }

    func testMalformedOrInjectableDomainsAreRejectedBeforeSaving() throws {
        for value in ["https://example.com", "*.example.com", "example.com,REJECT", "x..com", "-x.com", "127.0.0.1", "a.com\nMATCH,DIRECT", "x.com:443", "localhost"] {
            XCTAssertThrowsError(try MimoBypassDomain(value).validated(), value)
        }
        XCTAssertEqual(try MimoBypassDomain(" EXAMPLE.COM. ").validated().domain, "example.com")
        XCTAssertThrowsError(try MimoBypassBlock.validated([.init(name: "Empty")]))
        XCTAssertThrowsError(try MimoBypassBlock.validated([.init(name: "\n", domains: [.init("example.com")])]))
        let duplicate = MimoBypassBlock(name: "One", domains: [.init("example.com")])
        XCTAssertThrowsError(try MimoBypassBlock.validated([duplicate, duplicate]))
        XCTAssertEqual(try MimoBypassBlock.rules([.init(name: "One", domains: [.init("example.com"), .init("example.com")])]).count, 1)
    }

    func testReleaseIntentAndConfirmedStateRemainDistinct() throws {
        let old = try JSONDecoder().decode(MimoServicePreferences.self, from: Data(#"{"core":true,"engine":false,"profile":true}"#.utf8))
        XCTAssertFalse(old.networkReleaseRequested, "An unexpected/stored engine stop cannot silently opt out of protection")
        var flags = old; flags.releaseNetwork = true
        XCTAssertTrue(try JSONDecoder().decode(MimoServicePreferences.self, from: JSONEncoder().encode(flags)).networkReleaseRequested)
        var policy = MimoAccessPolicy()
        policy.releasing(configuration: MimoConfiguration())
        XCTAssertFalse(policy.state.allowsTraffic)
        policy.releasing(configuration: MimoConfiguration(), error: "DNS cleanup failed")
        XCTAssertEqual(policy.state.phase, .unavailable)
        XCTAssertFalse(policy.state.allowsTraffic)
        policy.networkReleased(configuration: MimoConfiguration())
        var released = policy.state; released.networkReleased = true; released.networkReleaseRequested = true
        released.services = [.init(id: .mihomo, health: .suspended, transport: "Unix socket")]
        let display = MimoStatusPresentation(routing: released, snapshot: nil, preferences: .init(), date: .now)
        XCTAssertEqual(display.title, "Direct · Engine stopped")
        XCTAssertFalse(display.trafficIsBlocked)
    }

    func testStopProgressRequiresFreshConfirmationWhenRequestWasRejected() {
        let started = Date(timeIntervalSince1970: 100)
        var pending = MimoRoutingState()
        pending.networkReleaseRequested = true
        pending.phase = .restoringDirect
        pending.supervisorCheckedAt = started
        var current = MimoRoutingState()
        current.networkReleaseRequested = false
        current.phase = .active
        current.supervisorCheckedAt = started
        XCTAssertFalse(MimoServiceProgress.canReplace(pending, with: current, startedAt: started, configurationAdvanced: false))
        current.supervisorCheckedAt = started.addingTimeInterval(1)
        XCTAssertTrue(MimoServiceProgress.canReplace(pending, with: current, startedAt: started, configurationAdvanced: false))
    }
}
