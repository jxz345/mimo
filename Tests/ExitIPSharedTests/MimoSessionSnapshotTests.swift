import XCTest
@testable import ExitIPShared

final class MimoSessionSnapshotTests: XCTestCase {
    private func user(_ uid: Int = 501, audit: Int = 10, active: Bool = true) -> [String: Any] {
        ["kCGSSessionUserIDKey": uid, "kCGSSessionAuditIDKey": audit, "kCGSSessionIDKey": 2,
         "kCGSSessionOnConsoleKey": active, "kCGSessionLoginDoneKey": true]
    }

    private func snapshot(locked: Bool = false, users: [[String: Any]]? = nil, asleep: Bool? = false) -> MimoSessionSnapshot {
        MimoSessionSnapshot(registry: ["IOConsoleLocked": locked, "IOConsoleUsers": users ?? [user()]], displaysAsleep: asleep)!
    }

    func testLockAndUnlockEachRequireNewVerificationWithoutChangingSession() {
        let unlocked = snapshot()
        let locked = snapshot(locked: true)
        XCTAssertEqual(locked.changes(from: unlocked), ["screen_locked"])
        XCTAssertEqual(unlocked.changes(from: locked), ["screen_unlocked"])
        XCTAssertEqual(unlocked.changes(from: unlocked), [])
    }

    func testLoginLogoutAndFastUserSwitchAreSeparateFromApplicationActivation() {
        let first = snapshot()
        let second = snapshot(users: [user(active: false), user(502, audit: 20)])
        XCTAssertEqual(second.changes(from: first), ["user_login", "console_session_changed"])
        let switched = snapshot(users: [user(), user(502, audit: 20, active: false)])
        XCTAssertEqual(switched.changes(from: second), ["console_session_changed"])
        XCTAssertEqual(first.changes(from: switched), ["user_logout"])
    }

    func testRegistryOrderAndNonsecurityMetadataDoNotTriggerChecks() {
        var named = user()
        named["kCGSSessionUserNameKey"] = "ignored"
        let first = snapshot(users: [user(), user(502, audit: 20, active: false)])
        let reordered = snapshot(users: [user(502, audit: 20, active: false), named])
        XCTAssertEqual(reordered.changes(from: first), [])
    }

    func testReusedUserIDWithNewLoginSessionStillTriggersVerification() {
        XCTAssertEqual(snapshot(users: [user(audit: 11)]).changes(from: snapshot()),
                       ["user_login", "user_logout", "console_session_changed"])
    }

    func testDisplaySleepAndWakeAndHeadlessOperation() {
        XCTAssertEqual(snapshot(asleep: true).changes(from: snapshot()), ["display_sleep"])
        XCTAssertEqual(snapshot().changes(from: snapshot(asleep: true)), ["display_wake"])
        XCTAssertEqual(snapshot(asleep: nil).changes(from: snapshot()), [])
        XCTAssertEqual(snapshot().changes(from: snapshot(asleep: nil)), [])
    }

    func testMissingOrMalformedRegistryIsNotTreatedAsAnUnchangedDesktop() {
        XCTAssertNil(MimoSessionSnapshot(registry: [:], displaysAsleep: false))
        XCTAssertNil(MimoSessionSnapshot(registry: ["IOConsoleLocked": false, "IOConsoleUsers": [["unexpected": true]]], displaysAsleep: false))
        XCTAssertNil(MimoSessionSnapshot(registry: ["IOConsoleLocked": false, "IOConsoleUsers": "unknown"], displaysAsleep: false))
        XCTAssertNotNil(MimoSessionSnapshot(registry: ["IOConsoleLocked": true, "IOConsoleUsers": []], displaysAsleep: nil))
    }
}
