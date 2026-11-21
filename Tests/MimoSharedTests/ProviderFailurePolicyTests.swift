import XCTest
@testable import MimoShared

final class ProviderFailurePolicyTests: XCTestCase {
    func testFailuresWaitEightHoursAndRespectLongerProviderPause() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for error in [LookupError.transport("timeout"), .invalidResponse, .providerMessage("unavailable"),
                      .httpStatus(503, retryAfter: nil), .rateLimited(retryAfter: now.addingTimeInterval(60))] {
            XCTAssertEqual(ProviderFailurePolicy.resumeAt(after: error, now: now), now.addingTimeInterval(8 * 3600))
        }
        let longer = now.addingTimeInterval(12 * 3600)
        XCTAssertEqual(ProviderFailurePolicy.resumeAt(after: .rateLimited(retryAfter: longer), now: now), longer)
    }
}
