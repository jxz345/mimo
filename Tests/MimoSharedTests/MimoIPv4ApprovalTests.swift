import XCTest
@testable import MimoShared

final class MimoIPv4ApprovalTests: XCTestCase {
    func testLegacyAllowlistMigrationPreservesIPv4SecretsAndPersistsOnce() throws {
        for addresses in [["203.0.113.10", "2001:db8::10"], ["2001:db8::10"]] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("state.plist")
            let storage = try FilePreferenceStorage(url: url)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(MachineSettings())) as? [String: Any])
            json["allowlist"] = ["addresses": addresses]
            try storage.update(["service.settings": JSONSerialization.data(withJSONObject: json),
                MimoPreferenceKey.allowedIPs: JSONSerialization.data(withJSONObject: ["addresses": addresses]),
                "service.revision": 4, MimoLocalSettings.tokenKey: "synthetic-local-only"])
            XCTAssertEqual(try MimoLocalSettings.migrateIPv4Allowlist(storage), 1)
            let reopened = try FilePreferenceStorage(url: url)
            let settings = try JSONDecoder().decode(MachineSettings.self, from: XCTUnwrap(reopened.data(forKey: "service.settings"))).validated()
            XCTAssertEqual(settings.allowlist.addresses, addresses.filter { !$0.contains(":") })
            XCTAssertEqual(AllowedIPStore(defaults: reopened).load(), settings.allowlist)
            XCTAssertEqual(reopened.string(forKey: MimoLocalSettings.tokenKey), "synthetic-local-only")
            XCTAssertEqual(reopened.integer(forKey: "service.revision"), 5)
            XCTAssertEqual(try MimoLocalSettings.migrateIPv4Allowlist(reopened), 0)
            XCTAssertEqual(reopened.integer(forKey: "service.revision"), 5)
        }
    }

    func testIPv6AdditionsCannotReachMachineSettings() throws {
        var list = AllowedIPList()
        XCTAssertFalse(list.insert("2001:db8::10"))
        XCTAssertFalse(list.insert("::ffff:203.0.113.10"))
        XCTAssertTrue(list.insert("203.0.113.10"))
        var settings = MachineSettings()
        settings.allowlist = try JSONDecoder().decode(AllowedIPList.self, from: Data(#"{"addresses":["2001:db8::10"]}"#.utf8))
        XCTAssertThrowsError(try settings.validated(), "Raw XPC input must not bypass UI validation")
    }

    func testFailedLookupShowsLastKnownWithoutSupplyingApproval() throws {
        var routing = MimoRoutingState()
        routing.configuration.mode = .global; routing.configuration.networkFamily = .dual
        routing.phase = .blocked
        routing.reason = "The IPv4 exit-IP check failed."
        let old = MimoSnapshot(ipAddress: "203.0.113.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois,
                               checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        routing.lastExitObservation = old
        let presentation = MimoStatusPresentation(routing: routing, snapshot: nil, preferences: .init(), date: .now,
            monitoringStatus: .failed("Proxy connection refused"), lookupError: "Proxy connection refused")
        XCTAssertEqual(presentation.address, old.ipAddress)
        XCTAssertTrue(presentation.detail.contains("Last known IPv4"))
        XCTAssertTrue(presentation.detail.contains("Current check failed"))
        XCTAssertTrue(presentation.detail.contains("Proxy connection refused"))
        XCTAssertNotNil(presentation.country)
        XCTAssertFalse(routing.allowsTraffic)
        XCTAssertNil(routing.observedIP)
        XCTAssertNil(routing.verification)
        XCTAssertNil(routing.rejectedExit)
        routing.configuration.mode = .direct
        XCTAssertNil(routing.lastKnownExit)
    }

    func testReceivedAddressDoesNotClaimApprovalBeforeReadinessCompletes() {
        var routing = MimoRoutingState()
        routing.configuration.mode = .global
        routing.phase = .checking
        routing.observedIP = .init(address: "203.0.113.10", checkedAt: .now)
        let presentation = MimoStatusPresentation(routing: routing, snapshot: nil, preferences: .init(), date: .now)
        XCTAssertTrue(presentation.verificationProgress?.contains("received") == true)
        XCTAssertFalse(presentation.verificationProgress?.contains("approved") == true)
        XCTAssertFalse(routing.allowsTraffic)
    }
}
