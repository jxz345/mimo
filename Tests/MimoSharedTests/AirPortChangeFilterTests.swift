import XCTest
@testable import MimoShared

final class AirPortChangeFilterTests: XCTestCase {
    private let key = "State:/Network/Interface/en1/AirPort"
    private var connected: [String: Any] {
        ["SSID_STR": "Fixture network", "SSID": Data("Fixture network".utf8),
         "BSSID": Data([0, 1, 2, 3, 4, 5]), "Power Status": 1, "Busy": false,
         "CHANNEL": ["CHANNEL": 36, "CHANNEL_FLAGS": 0], "RSSI": -50]
    }

    func testOnlyAirPortEntityIsFiltered() {
        XCTAssertTrue(AirPortChangeFilter.matches(key))
        for key in ["State:/Network/Interface/en1/Link", "State:/Network/Interface/en1/IPv4",
                    "State:/Network/Service/example/DNS", "Setup:/Network/Interface/en1/AirPort",
                    "State:/Network/Interface/en1/AirPort/Other", "State:/Network/Interface//AirPort"] {
            XCTAssertFalse(AirPortChangeFilter.matches(key))
        }
    }

    func testScanAndRadioUpdatesDoNotInvalidateAnUnchangedConnection() {
        var filter = AirPortChangeFilter()
        filter.seed(key, reading: .value(connected))
        XCTAssertFalse(filter.evaluate(key, reading: .value(connected)).shouldNotify)
        for i in 0..<20 {
            var value = connected
            value["Busy"] = i % 2 == 0
            value["RSSI"] = -50 - i
            value["CHANNEL"] = ["CHANNEL": 40 + i, "CHANNEL_FLAGS": 0]
            value["CachedScanRecord"] = ["time": i]
            XCTAssertFalse(filter.evaluate(key, reading: .value(value)).shouldNotify)
        }
    }

    func testPowerAssociationSecurityAndUnknownFieldsStillInvalidate() {
        for (field, replacement) in [("Power Status", 0 as Any), ("SSID_STR", "Other network"),
                                     ("SSID", Data("Other network".utf8)), ("BSSID", Data([9, 8, 7, 6, 5, 4])),
                                     ("Authenticated", false), ("UnknownFutureConnectionField", 1)] {
            var filter = AirPortChangeFilter()
            filter.seed(key, reading: .value(connected))
            var changed = connected; changed[field] = replacement; changed["Busy"] = true
            changed["AutoJoinTimestamp"] = Date(timeIntervalSince1970: 1_795_228_800)
            let decision = filter.evaluate(key, reading: .value(changed))
            XCTAssertTrue(decision.shouldNotify, field)
            XCTAssertTrue(decision.changedFields.contains(field))
            XCTAssertFalse(decision.changedFields.contains("Other network"))
            XCTAssertFalse(filter.evaluate(key, reading: .value(changed)).shouldNotify)
        }
    }

    func testAutoJoinTimestampOnlyAndBusyUpdatesDoNotInvalidate() {
        var filter = AirPortChangeFilter()
        filter.seed(key, reading: .value(connected))
        for i in 0..<20 {
            var value = connected
            value["AutoJoinTimestamp"] = Date(timeIntervalSince1970: 1_795_228_800 + Double(i * 20))
            let timestampOnly = filter.evaluate(key, reading: .value(value))
            XCTAssertFalse(timestampOnly.shouldNotify)
            XCTAssertEqual(timestampOnly.changedFields, ["AutoJoinTimestamp"])
            value["Busy"] = true
            value["AutoJoinTimestamp"] = Date(timeIntervalSince1970: 1_795_228_801 + Double(i * 20))
            let mixed = filter.evaluate(key, reading: .value(value))
            XCTAssertFalse(mixed.shouldNotify)
            XCTAssertEqual(mixed.changedFields, ["AutoJoinTimestamp", "Busy"])
            value["Busy"] = false
            XCTAssertFalse(filter.evaluate(key, reading: .value(value)).shouldNotify)
        }
        let removed = filter.evaluate(key, reading: .value(connected))
        XCTAssertFalse(removed.shouldNotify)
        XCTAssertEqual(removed.changedFields, ["AutoJoinTimestamp"])
    }

    func testMissingUnreadableAndIndependentInterfacesAreConservative() {
        var filter = AirPortChangeFilter()
        filter.seed(key, reading: .value(connected))
        XCTAssertTrue(filter.evaluate(key, reading: .unavailable).shouldNotify)
        XCTAssertFalse(filter.evaluate(key, reading: .value(connected)).shouldNotify, "A failed read must not erase the baseline")
        XCTAssertTrue(filter.evaluate("State:/Network/Interface/en2/AirPort", reading: .value(connected)).shouldNotify)
        XCTAssertTrue(filter.evaluate(key, reading: .absent).shouldNotify)
        XCTAssertFalse(filter.evaluate(key, reading: .absent).shouldNotify)
        XCTAssertTrue(filter.evaluate(key, reading: .value(connected)).shouldNotify)
    }
}
