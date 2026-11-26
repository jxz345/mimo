import XCTest
@testable import MimoShared

final class MimoStatusPresentationTests: XCTestCase {
    func testBlockedProviderFailuresOfferRecoveryWithoutHidingRejection() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .rule
        routing.phase = .blocked
        routing.reason = "Verification required"
        let until = Date().addingTimeInterval(600)
        for status in [MonitoringStatus.coolingDown(until), .providerPaused(.ipWhois, until), .waitingForIPinfoToken] {
            let display = MimoStatusPresentation(routing: routing, snapshot: nil, preferences: .init(), date: .now, monitoringStatus: status)
            XCTAssertEqual(display.kind, .blocked)
            XCTAssertTrue(display.detail.contains("use Direct"))
            XCTAssertNotEqual(display.detail, routing.reason)
        }
        let paused = MimoStatusPresentation(routing: routing, snapshot: nil, preferences: .init(), date: .now,
            monitoringStatus: .coolingDown(until), lookupError: "The proxy connection timed out.")
        XCTAssertTrue(paused.detail.contains("proxy connection timed out"))
        XCTAssertTrue(paused.detail.contains("paused until"))
        XCTAssertTrue(paused.detail.contains("use Direct"))
        routing.blockingIP = .init(address: "192.0.2.1", checkedAt: .now)
        routing.reason = "The observed IPv4 exit IP is not approved. Review Allowed IPs or select another proxy."
        let rejected = MimoStatusPresentation(routing: routing, snapshot: nil, preferences: .init(), date: .now, monitoringStatus: .coolingDown(until))
        XCTAssertTrue(rejected.detail.contains("not approved"))
    }
    func testBackgroundAuditKeepsAllowedPresentationStableAndFailureRemainsVisible() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .rule
        routing.phase = .active; routing.effectiveMode = .rule
        routing.backgroundVerification = true
        let pending = MimoStatusPresentation(routing: routing, snapshot: nil, preferences: .init(), date: .now)
        XCTAssertTrue(routing.allowsTraffic)
        XCTAssertTrue(pending.isBackgroundVerification)
        XCTAssertFalse(pending.trafficIsBlocked)
        XCTAssertEqual(pending.title, "Rule · Allowed")
        routing.backgroundVerification = false
        let finished = MimoStatusPresentation(routing: routing, snapshot: nil, preferences: .init(), date: .now)
        XCTAssertEqual(pending.visualKey, finished.visualKey)
        XCTAssertEqual(pending.symbol, finished.symbol)
        XCTAssertEqual(pending.title, finished.title)
        XCTAssertEqual(pending.detail, finished.detail)
        XCTAssertEqual(pending.verificationProgress, finished.verificationProgress)
        routing.phase = .blocked; routing.effectiveMode = nil
        routing.reason = "Background audit failed: DNS changed."
        let failed = MimoStatusPresentation(routing: routing, snapshot: nil, preferences: .init(), date: .now)
        XCTAssertTrue(failed.trafficIsBlocked)
        XCTAssertEqual(failed.kind, .blocked)
        XCTAssertTrue(failed.detail.contains("DNS changed"))
    }

    func testApprovedIPWhileReadinessIsPendingStillShowsBlockedChecking() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .rule
        routing.phase = .checking
        routing.observedIP = .init(address: "203.0.113.42", checkedAt: .now)
        routing.reason = "Exit IP approved. Checking profile, tunnel and DNS. Internet remains blocked."
        let value = MimoStatusPresentation(routing: routing, snapshot: nil,
            preferences: MonitoringPreferences(), date: .now)
        XCTAssertTrue(value.trafficIsBlocked)
        XCTAssertTrue(value.isCheckingReadiness)
        XCTAssertEqual(value.kind, .checking)
        XCTAssertTrue(value.title.contains("Checking readiness"))
        XCTAssertTrue(value.verificationProgress?.contains("Exit IP received") == true)
        XCTAssertFalse(routing.allowsTraffic)
    }

    func testDirectTransitionDoesNotClaimBlockingOrApproval() {
        var routing = MimoRoutingState()
        routing.phase = .restoringDirect
        routing.reason = "Switching to Direct. Removing proxy routing and restoring system DNS."
        routing.observedIP = .init(address: "192.0.2.9", checkedAt: .now)
        let value = MimoStatusPresentation(routing: routing, snapshot: nil,
            preferences: MonitoringPreferences(), date: .now)
        XCTAssertEqual(value.title, "Switching to Direct")
        XCTAssertTrue(value.isRestoringDirect)
        XCTAssertFalse(value.isClosing)
        XCTAssertFalse(value.trafficIsBlocked)
        XCTAssertFalse(value.isDirect)
        XCTAssertFalse(routing.allowsTraffic)
        XCTAssertNil(value.address)
        XCTAssertNil(value.verificationProgress)
    }

    func testPendingCloseIsProgressWithoutClaimingTrafficIsAlreadyBlocked() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .rule
        routing.phase = .closing
        routing.observedIP = .init(address: "192.0.2.9", checkedAt: .now)
        let value = MimoStatusPresentation(routing: routing, snapshot: nil,
            preferences: MonitoringPreferences(), date: .now)
        XCTAssertEqual(value.kind, .checking)
        XCTAssertTrue(value.isClosing)
        XCTAssertFalse(value.trafficIsBlocked)
        XCTAssertNil(value.address)
        XCTAssertNil(value.verificationProgress)
        XCTAssertTrue(value.title.contains("Closing traffic"))
    }

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
        let older = MimoSnapshot(ipAddress: "203.0.113.42", countryCode: "SG", countryName: "Singapore", provider: .ipWhois)
        let blocked = MimoStatusPresentation(routing: policy.state, snapshot: older, preferences: MonitoringPreferences(), date: .now)
        XCTAssertEqual(blocked.address, "198.51.100.77")
        XCTAssertEqual(blocked.symbol, MimoIndicatorSymbol.outsideAllowlist)
        XCTAssertTrue(blocked.detail.contains("198.51.100.77 is not on the allowed list"))
        _ = policy.begin(configuration: configuration, revision: 1, networkGeneration: 2)
        let retrying = MimoStatusPresentation(routing: policy.state, snapshot: older, preferences: MonitoringPreferences(), date: .now)
        XCTAssertNil(retrying.address, "A pending retry has no fresh result; failed retries use separately labelled history")
    }

    func testDirectLookupChangesIconWithoutClaimingTrafficIsBlocked() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .direct
        routing.phase = .active
        routing.effectiveMode = .direct
        routing.reason = "Normal networking is restored."
        routing.observedIP = .init(address: "192.0.2.10", checkedAt: .now)
        let snapshot = MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois)
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
        XCTAssertFalse(status(.refreshing).trafficIsBlocked)
        XCTAssertNil(status(.refreshing).verificationProgress)
        let failed = status(.failed("The network is offline."))
        XCTAssertEqual(failed.kind, .directWarning)
        XCTAssertTrue(failed.detail.contains("network is offline"))
        XCTAssertTrue(failed.detail.contains("Direct remains selected"))
        XCTAssertEqual(status(.ready).kind, .direct)
    }

    func testProtectedProgressRequiresConfirmedBlockingAndApproval() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .global
        func present() -> MimoStatusPresentation {
            MimoStatusPresentation(routing: routing, snapshot: nil, preferences: MonitoringPreferences(), date: .now)
        }
        // An unacknowledged firewall request must not claim confirmed blocking.
        XCTAssertFalse(present().trafficIsBlocked)
        XCTAssertNil(present().verificationProgress)
        routing.phase = .validating
        XCTAssertTrue(present().trafficIsBlocked)
        XCTAssertTrue(present().isValidating)
        XCTAssertTrue(present().title.contains("Blocked"))
        routing.phase = .checking
        XCTAssertTrue(present().trafficIsBlocked)
        XCTAssertFalse(present().isValidating)
        XCTAssertTrue(present().title.contains("Checking exit IP"))
        XCTAssertFalse(present().verificationProgress?.contains("Internet reopened") ?? true)
        routing.phase = .active
        routing.effectiveMode = .global
        XCTAssertFalse(present().trafficIsBlocked)
        XCTAssertTrue(present().verificationProgress?.contains("Internet reopened") ?? false)
        routing.effectiveMode = .rule
        XCTAssertNil(present().verificationProgress, "Mismatched effective mode cannot show a completed verification")
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
