import XCTest
@testable import MimoShared

final class ProviderFailurePolicyTests: XCTestCase {
    func testExplicitRecoveryDistinguishesLocalBackoffFromProviderRestrictions() {
        for error in [LookupError.transport("timeout"), .invalidResponse,
                      .httpStatus(503, retryAfter: nil), .httpStatus(407, retryAfter: nil)] {
            XCTAssertTrue(ProviderFailurePolicy.allowsExplicitRetry(after: error))
        }
        for error in [LookupError.rateLimited(retryAfter: nil), .httpStatus(401, retryAfter: nil),
                      .providerMessage("quota exceeded"), .missingToken(.ipinfoLite),
                      .httpStatus(503, retryAfter: Date().addingTimeInterval(900))] {
            XCTAssertFalse(ProviderFailurePolicy.allowsExplicitRetry(after: error))
        }
    }

    func testRetryPermissionSurvivesReloadAndCannotShortenProviderOrUnknownPause() {
        let name = "MimoCooldownTest." + UUID().uuidString
        let storage = UserDefaults(suiteName: name)!
        defer { storage.removePersistentDomain(forName: name) }
        let now = Date(), deadline = now.addingTimeInterval(600)
        ProviderCooldownStore(defaults: storage).save(retryNotBefore: deadline, for: .ipWhois, allowsExplicitRetry: true)
        let reloaded = ProviderCooldownStore(defaults: storage)
        XCTAssertTrue(reloaded.allowsExplicitRetry(for: .ipWhois, health: nil, now: now))
        XCTAssertFalse(reloaded.allowsExplicitRetry(for: .ipWhois, health: nil, now: deadline))
        reloaded.save(retryNotBefore: deadline, for: .ipWhois)
        let transport = ProviderHealthRecord(lastFailure: now, lastError: "transport")
        XCTAssertFalse(reloaded.allowsExplicitRetry(for: .ipWhois, health: transport, now: now))
        reloaded.clear(for: .ipWhois)
        XCTAssertNil(reloaded.retryNotBefore(for: .ipWhois))
        // Actual build-10 storage has no explicitRetry metadata.
        storage.set(deadline, forKey: MimoPreferenceKey.providerCooldownPrefix + ProviderID.ipWhois.rawValue)
        XCTAssertTrue(reloaded.allowsExplicitRetry(for: .ipWhois, health: transport, now: now))
        XCTAssertFalse(reloaded.allowsExplicitRetry(for: .ipWhois, health: .init(lastFailure: now, lastError: "rate_limited"), now: now))
        XCTAssertFalse(reloaded.allowsExplicitRetry(for: .ipWhois, health: nil, now: now))
    }
    func testFailuresWaitTenMinutesAndRespectLongerProviderPause() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for error in [LookupError.transport("timeout"), .invalidResponse, .providerMessage("unavailable"),
                      .httpStatus(503, retryAfter: nil), .rateLimited(retryAfter: now.addingTimeInterval(60))] {
            XCTAssertEqual(ProviderFailurePolicy.resumeAt(after: error, now: now), now.addingTimeInterval(10 * 60))
        }
        let longer = now.addingTimeInterval(12 * 3600)
        XCTAssertEqual(ProviderFailurePolicy.resumeAt(after: .rateLimited(retryAfter: longer), now: now), longer)
    }
}
