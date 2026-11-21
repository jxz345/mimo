import XCTest
@testable import MimoShared

final class NetworkLocationChangeFilterTests: XCTestCase {
    private let location: [String: Any] = ["CurrentSet": "/Sets/fixture", "LastUpdated": Date(timeIntervalSince1970: 1)]

    func testRepeatedPreferenceAppliesDoNotInvalidateTheSameLocation() {
        var filter = NetworkLocationChangeFilter()
        filter.seed(location)
        XCTAssertFalse(filter.evaluate(location).shouldNotify)
        for i in 2...10 {
            var applied = location
            applied["LastUpdated"] = Date(timeIntervalSince1970: Double(i))
            let decision = filter.evaluate(applied)
            XCTAssertFalse(decision.shouldNotify)
            XCTAssertEqual(decision.changedFields, ["LastUpdated"])
        }
    }

    func testLocationAndUnknownChangesRemainRelevantAlongsideTheTimestamp() {
        for (field, value) in [("CurrentSet", "/Sets/other"), ("FutureRoutingField", "changed")] {
            var filter = NetworkLocationChangeFilter()
            filter.seed(location)
            var changed = location
            changed[field] = value
            changed["LastUpdated"] = Date(timeIntervalSince1970: 2)
            let decision = filter.evaluate(changed)
            XCTAssertTrue(decision.shouldNotify)
            XCTAssertTrue(decision.changedFields.contains(field))
            XCTAssertFalse(decision.changedFields.contains(value))
        }
        var filter = NetworkLocationChangeFilter()
        var unknown = location
        unknown["FutureRoutingField"] = 1
        filter.seed(unknown)
        XCTAssertTrue(filter.evaluate(location).shouldNotify, "Removed unknown fields also count")
    }

    func testMissingMalformedAndFirstReadCannotSuppressAChange() {
        for invalid: [String: Any]? in [nil, [:], ["CurrentSet": ""], ["CurrentSet": 123]] {
            var filter = NetworkLocationChangeFilter()
            filter.seed(location)
            XCTAssertTrue(filter.evaluate(invalid).shouldNotify)
            XCTAssertTrue(filter.evaluate(location).shouldNotify, "Recovery from an unknown baseline stays conservative")
            XCTAssertFalse(filter.evaluate(location).shouldNotify)
        }
        var filter = NetworkLocationChangeFilter()
        XCTAssertTrue(filter.evaluate(location).shouldNotify)
    }
}
