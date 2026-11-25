import Foundation
import XCTest
@testable import MimoShared

final class DaemonContractTests: XCTestCase {
    func testAtomicStoragePersistsBudgetAndCooldownAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.plist")
        let store = try FilePreferenceStorage(url: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budget = LookupBudget(now: now)
        budget.recordCall(to: .ipWhois)
        LookupBudgetStore(defaults: store).save(budget)
        ProviderCooldownStore(defaults: store).save(retryNotBefore: now.addingTimeInterval(300), for: .ipWhois)
        let restored = try FilePreferenceStorage(url: url)
        XCTAssertEqual(LookupBudgetStore(defaults: restored).load(now: now).callsToday(for: .ipWhois), 1)
        XCTAssertEqual(ProviderCooldownStore(defaults: restored).retryNotBefore(for: .ipWhois), now.addingTimeInterval(300))
        XCTAssertNil(restored.lastError)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testCorruptMachineStateDoesNotResetBudgetsSilently() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a property list".utf8).write(to: url)
        XCTAssertThrowsError(try FilePreferenceStorage(url: url))
    }

    func testAtomicStorageReplacesPermissiveFileAndLeavesNoTemporaryState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["revision": 1], format: .binary, options: 0)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let store = try FilePreferenceStorage(url: url)
        for revision in 2...4 {
            try store.update(["revision": revision])
            XCTAssertEqual(try FilePreferenceStorage(url: url).integer(forKey: "revision"), revision)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["state.plist"])
        }
    }

    func testFailedTransactionDoesNotPublishPartialSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.plist")
        let store = try FilePreferenceStorage(url: url)
        try store.update(["revision": 1, "provider": "old"])
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.update(["revision": 2, "provider": "new"]))
        XCTAssertEqual(store.integer(forKey: "revision"), 1)
        XCTAssertEqual(store.string(forKey: "provider"), "old")
        XCTAssertNotNil(store.lastError)
    }

    func testSettingsRejectEmptyDuplicateAndInconsistentProviderPools() throws {
        var settings = MachineSettings()
        settings.providerPool = []
        XCTAssertThrowsError(try settings.validated())
        settings.providerPool = [.ipapiCo, .ipapiCo]
        XCTAssertThrowsError(try settings.validated())
        settings.providerPool = [.ipWhois]
        XCTAssertThrowsError(try settings.validated())
        settings.provider = .ipWhois
        XCTAssertNoThrow(try settings.validated())
    }

    func testRequestRoundTripDoesNotProvideCallerIdentity() throws {
        var request = DaemonRequest(.configure)
        request.expectedRevision = 5
        request.settings = MachineSettings()
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(DaemonRequest.self, from: data)
        XCTAssertEqual(decoded.expectedRevision, 5)
        XCTAssertEqual(decoded.settings, request.settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["uid"])
        XCTAssertNil(object["user"])
    }

}
