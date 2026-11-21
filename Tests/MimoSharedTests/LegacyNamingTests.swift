import Foundation
import XCTest
@testable import MimoShared

final class LegacyNamingTests: XCTestCase {
    func testPreferenceMigrationPreservesValuesAndResetsOldLoginChoice() {
        let payload = Data([0, 1, 2, 255])
        let values: [String: Any] = ["exit-ip.snapshot.v1": payload, "service.revision": 42,
                                     LegacyNaming.loginKey: true, "mimo.refresh-interval.v1": 300]
        let result = LegacyNaming.migratedPreferences(values, excludingLogin: true)
        XCTAssertEqual(result["mimo.snapshot.v1"] as? Data, payload)
        XCTAssertEqual(result["service.revision"] as? Int, 42)
        XCTAssertEqual(result["mimo.refresh-interval.v1"] as? Int, 300)
        XCTAssertNil(result[MimoPreferenceKey.launchAtLogin])
        XCTAssertNil(result[LegacyNaming.loginKey])
    }

    func testExistingMimoKeyWinsOverLegacyAlias() {
        let result = LegacyNaming.migratedPreferences(["exit-ip.provider.v1": "old", "mimo.provider.v1": "current"])
        XCTAssertEqual(result["mimo.provider.v1"] as? String, "current")
    }

    func testStatusItemPositionKeyMigrates() {
        let key = "NSStatusItem Preferred Position " + LegacyNaming.supportName + "StatusItem"
        XCTAssertEqual(LegacyNaming.migratedKey(key), "NSStatusItem Preferred Position MimoStatusItem")
    }

    func testCollidingFilesArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        for directory in [old, new] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("old profile".utf8).write(to: old.appendingPathComponent("profile.yaml"))
        try Data("current profile".utf8).write(to: new.appendingPathComponent("profile.yaml"))
        try LegacyNaming.moveContents(from: old, to: new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("profile.yaml"), encoding: .utf8), "current profile")
        let archived = try FileManager.default.contentsOfDirectory(at: new.appendingPathComponent("Migrated"), includingPropertiesForKeys: nil)
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(try String(contentsOf: archived[0], encoding: .utf8), "old profile")
    }
}
