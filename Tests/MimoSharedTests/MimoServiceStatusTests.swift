import XCTest
@testable import MimoShared

final class MimoServiceStatusTests: XCTestCase {
    func testCachedServiceRetainsInspectionAgeInsteadOfBecomingFresh() throws {
        let checked = Date(timeIntervalSince1970: 1_000)
        let original = MimoServiceStatus(id: .mihomo, health: .running, transport: "Unix", checkedAt: checked)
        let cached = try JSONDecoder().decode(MimoServiceStatus.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(cached.checkedAt, checked)
        XCTAssertEqual(cached.healthTitle(at: checked.addingTimeInterval(3)), "Healthy")
        XCTAssertEqual(MimoHealthLabel.text(cached.healthTitle(at: checked.addingTimeInterval(3)),
            checkedAt: cached.checkedAt, at: checked.addingTimeInterval(3)), "Healthy(3 secs)")
        XCTAssertEqual(cached.healthTitle(at: checked.addingTimeInterval(36)), "Stale")
        XCTAssertEqual(cached.checkedAt, checked, "Presentation must not refresh an inspection timestamp")
    }

    func testOlderServicePayloadHasUnknownAgeAndDoesNotClaimFreshHealth() throws {
        let data = Data(#"{"id":"mihomo","health":"running","transport":"Unix","bindingConfirmed":false}"#.utf8)
        let status = try JSONDecoder().decode(MimoServiceStatus.self, from: data)
        XCTAssertNil(status.checkedAt)
        XCTAssertEqual(status.healthTitle(at: .now), "Unavailable")
        XCTAssertEqual(MimoHealthLabel.text(status.healthTitle(at: .now), checkedAt: nil, at: .now), "Unavailable(—)")
    }

    func testIntentionalStopAndFailuresAreNotRelabeledHealthy() {
        let checked = Date(timeIntervalSince1970: 1_000)
        for (health, title) in [(MimoServiceHealth.stopped, "Stopped"), (.unavailable, "Unavailable"), (.notInstalled, "Not installed")] {
            let status = MimoServiceStatus(id: .core, health: health, transport: "XPC", checkedAt: checked)
            XCTAssertEqual(status.healthTitle(at: checked.addingTimeInterval(60)), title)
        }
    }

    func testFutureOrInvalidInspectionTimeDoesNotAppearHealthy() {
        let now = Date(timeIntervalSince1970: 1_000)
        for date in [now.addingTimeInterval(6), Date(timeIntervalSince1970: .infinity)] {
            let status = MimoServiceStatus(id: .mihomo, health: .running, transport: "Unix", checkedAt: date)
            XCTAssertEqual(status.healthTitle(at: now), "Unavailable")
            XCTAssertNil(MimoHealthLabel.age(checkedAt: date, at: now))
        }
        XCTAssertEqual(MimoHealthLabel.age(checkedAt: now.addingTimeInterval(2), at: now), 0,
                       "Small clock skew should not print a negative age")
    }
}
