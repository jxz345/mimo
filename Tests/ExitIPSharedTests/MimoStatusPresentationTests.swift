import XCTest
@testable import ExitIPShared

final class MimoStatusPresentationTests: XCTestCase {
    func testBlockedVerificationShowsFailureInsteadOfGenericCloseReason() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .rule
        routing.phase = .blocked
        routing.reason = "Network or configuration changed. Verification is required."
        let failure = "Protected routing is not qualified on this build. Direct remains available."
        func present(_ status: MonitoringStatus) -> MimoStatusPresentation {
            MimoStatusPresentation(routing: routing, snapshot: nil, preferences: MonitoringPreferences(),
                                   date: .now, monitoringStatus: status)
        }
        XCTAssertEqual(present(.failed(failure)).detail, failure)
        XCTAssertEqual(present(.refreshing).detail, routing.reason)
        routing.blockingIP = .init(address: "198.51.100.77", checkedAt: .now)
        XCTAssertTrue(present(.failed("Proxy unavailable")).detail.contains("198.51.100.77"))
        routing.phase = .unavailable
        XCTAssertEqual(present(.failed(failure)).detail, routing.reason)
    }

    func testRuleMismatchDisplaysRejectedIPInsteadOfOlderApprovedSnapshot() {
        var configuration = MimoConfiguration()
        configuration.mode = .rule
        configuration.proxy = MimoProxy(ClashProxySettings(name: "Fixture", type: .socks5, server: "192.0.2.20", port: 1080))
        var policy = MimoAccessPolicy()
        let check = policy.begin(configuration: configuration, revision: 1, networkGeneration: 1)
        policy.checking(check)
        XCTAssertFalse(policy.approve(address: "198.51.100.77", at: .now,
            allowlist: AllowedIPList(addresses: ["203.0.113.42"]), verification: check, runtimeMatches: true))
        let older = ExitIPSnapshot(ipAddress: "203.0.113.42", countryCode: "SG", countryName: "Singapore", provider: .ipWhois)
        let blocked = MimoStatusPresentation(routing: policy.state, snapshot: older, preferences: MonitoringPreferences(), date: .now)
        XCTAssertEqual(blocked.address, "198.51.100.77")
        XCTAssertEqual(blocked.symbol, ExitIPIndicatorSymbol.outsideAllowlist)
        XCTAssertTrue(blocked.detail.contains("198.51.100.77 is not on the allowed list"))
        _ = policy.begin(configuration: configuration, revision: 1, networkGeneration: 2)
        let retrying = MimoStatusPresentation(routing: policy.state, snapshot: older, preferences: MonitoringPreferences(), date: .now)
        XCTAssertEqual(retrying.address, blocked.address)
    }

    func testDirectLookupChangesIconWithoutClaimingTrafficIsBlocked() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .direct
        routing.phase = .active
        routing.effectiveMode = .direct
        routing.reason = "Normal networking is restored."
        routing.observedIP = .init(address: "192.0.2.10", checkedAt: .now)
        let snapshot = ExitIPSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois)
        func status(_ lookup: MonitoringStatus) -> MimoStatusPresentation {
            MimoStatusPresentation(routing: routing, snapshot: snapshot, preferences: MonitoringPreferences(),
                                   date: .now, monitoringStatus: lookup)
        }
        XCTAssertEqual(status(.ready).kind, .direct)
        for lookup in [MonitoringStatus.ready, .refreshing, .failed("Offline")] {
            XCTAssertTrue(status(lookup).isDirect)
            XCTAssertEqual(status(lookup).country, snapshot.countryFlag)
        }
        XCTAssertEqual(status(.refreshing).kind, .checking)
        let failed = status(.failed("The network is offline."))
        XCTAssertEqual(failed.kind, .directWarning)
        XCTAssertTrue(failed.detail.contains("network is offline"))
        XCTAssertTrue(failed.detail.contains("Direct remains selected"))
        XCTAssertEqual(status(.ready).kind, .direct)
    }

    func testProtectedGateTakesPrecedenceOverLookupAndCachedLocation() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .rule
        routing.phase = .blocked
        routing.blockingIP = .init(address: "192.0.2.9", checkedAt: .now)
        for lookup in [MonitoringStatus.ready, .refreshing, .failed("Offline")] {
            let status = MimoStatusPresentation(routing: routing, snapshot: nil,
                preferences: MonitoringPreferences(), date: .now, monitoringStatus: lookup)
            XCTAssertEqual(status.kind, .blocked)
            XCTAssertFalse(status.isDirect)
            XCTAssertEqual(status.address, "192.0.2.9")
        }
        routing.phase = .unavailable
        let unavailable = MimoStatusPresentation(routing: routing, snapshot: nil,
            preferences: MonitoringPreferences(), date: .now, monitoringStatus: .ready)
        XCTAssertEqual(unavailable.kind, .unavailable)
        XCTAssertNil(unavailable.address)
        XCTAssertFalse(unavailable.isDirect)
    }
}
