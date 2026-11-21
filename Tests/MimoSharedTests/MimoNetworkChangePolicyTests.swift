import XCTest
@testable import MimoShared

final class MimoNetworkChangePolicyTests: XCTestCase {
    func testOnlyOwnedUnchangedTunnelEventsCanBeClassifiedAsSelfChanges() {
        XCTAssertTrue(MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: true,
            recordedTunnelMatches: true, eventProcess: 123, engineProcess: 123))
        XCTAssertTrue(MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: true,
            recordedTunnelMatches: true, eventProcess: nil, engineProcess: 123, insideProfileChangeWindow: true))
        XCTAssertTrue(MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: false,
            recordedTunnelMatches: true, eventProcess: 123, engineProcess: 123, unresolvedInterface: true))
        XCTAssertTrue(MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: false,
            recordedTunnelMatches: true, eventProcess: 0, engineProcess: 123, ownedAddress: true,
            insideProfileChangeWindow: true))
        XCTAssertFalse(MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: true,
            recordedTunnelMatches: true, eventProcess: nil, engineProcess: 123))
        XCTAssertFalse(MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: false,
            recordedTunnelMatches: true, eventProcess: 456, engineProcess: 123, unresolvedInterface: true,
            ownedAddress: true, insideProfileChangeWindow: true))
        for (owned, matches, process, engine): (Bool, Bool, Int32?, Int32?) in [
            (false, true, 123, 123), (true, false, 123, 123), (true, true, 124, 123),
            (true, true, 0, 123), (true, true, nil, nil), (true, true, nil, 0)
        ] {
            XCTAssertFalse(MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: owned,
                recordedTunnelMatches: matches, eventProcess: process, engineProcess: engine))
        }
    }
}
