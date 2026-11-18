import XCTest
@testable import ExitIPShared

final class MimoStatusPresentationTests: XCTestCase {
    func testDirectLookupChangesIconWithoutClaimingTrafficIsBlocked() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .direct
        routing.phase = .active
        routing.effectiveMode = .direct
        routing.reason = "Normal networking is restored."
        func status(_ lookup: MonitoringStatus) -> MimoStatusPresentation {
            MimoStatusPresentation(routing: routing, snapshot: nil, preferences: MonitoringPreferences(),
                                   date: .now, monitoringStatus: lookup)
        }
        XCTAssertEqual(status(.ready).kind, .direct)
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
            XCTAssertEqual(status.address, "192.0.2.9")
        }
        routing.phase = .unavailable
        let unavailable = MimoStatusPresentation(routing: routing, snapshot: nil,
            preferences: MonitoringPreferences(), date: .now, monitoringStatus: .ready)
        XCTAssertEqual(unavailable.kind, .unavailable)
        XCTAssertNil(unavailable.address)
    }
}
