import Foundation

enum MimoSessionDisplayTests {
    static func run() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let observer = MimoSessionDisplayObserver {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            completed.signal()
            return false
        }
        func snapshot(user: Int, locked: Bool = false) -> MimoSessionSnapshot {
            MimoSessionSnapshot(registry: ["IOConsoleLocked": locked, "IOConsoleUsers": [[
                "kCGSessionLoginDoneKey": true, "kCGSSessionUserIDKey": user,
                "kCGSSessionAuditIDKey": user, "kCGSSessionIDKey": user, "kCGSSessionOnConsoleKey": true
            ]]], displaysAsleep: nil)!
        }
        let now = Date.now
        ServiceTests.require(observer.value(for: snapshot(user: 501), at: now) == nil, "New session must settle before display inspection")
        _ = observer.value(for: snapshot(user: 501), at: now.addingTimeInterval(3))
        ServiceTests.require(entered.wait(timeout: .now() + 2) == .success, "Display inspection must run independently")
        let start = ContinuousClock.now
        for _ in 0..<100 {
            _ = observer.value(for: snapshot(user: 501, locked: true))
            _ = observer.value(for: snapshot(user: 502))
        }
        observer.invalidate()
        ServiceTests.require(ContinuousClock.now - start < .seconds(1), "A blocked display query must not delay session sampling or shutdown")
        release.signal()
        ServiceTests.require(completed.wait(timeout: .now() + 2) == .success, "Test display query must complete")
        ServiceTests.require(observer.value(for: snapshot(user: 502)) == nil, "A late previous-account display reply must not become current")
        // Real IORegistry-only read, with no WindowServer calls and no service mutation.
        let readStart = ContinuousClock.now
        _ = MimoSessionObserver.read()
        ServiceTests.require(ContinuousClock.now - readStart < .seconds(2), "Session identity read must be independent of display query")
        print("PASS: blocked WindowServer query cannot hold session detection; account changes and stop reject old display replies")
    }
}
