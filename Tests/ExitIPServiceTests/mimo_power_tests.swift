import Foundation

enum MimoPowerTests {
    private static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }

    static func run() throws {
        let fence = MimoPowerFence()
        var closes = 0
        try fence.sleep { closes += 1 }
        require(closes == 0, "Direct must not acquire an allowlist or sleep firewall restriction")
        do { _ = try fence.arm(); require(false, "verification cannot start while sleeping") } catch {}
        fence.wake()
        let beforeSleep = try fence.arm()
        try fence.activate(epoch: beforeSleep) {}
        try fence.sleep { closes += 1 }
        require(closes == 1, "protected traffic must close before sleep returns for acknowledgement")
        do {
            try fence.activate(epoch: beforeSleep) { require(false, "late approval must not open during sleep") }
            require(false, "sleep must reject approval")
        } catch {}
        fence.wake()
        do {
            try fence.activate(epoch: beforeSleep) { require(false, "pre-sleep approval must not open on wake") }
            require(false, "wake must invalidate all old approvals")
        } catch {}
        let afterWake = try fence.arm()
        try fence.activate(epoch: afterWake) {}
        do { try fence.sleep { throw DaemonFailure.unavailable }; require(false, "guard failure must propagate") } catch {}
        do { _ = try fence.arm(); require(false, "failed sleep guard must still inhibit opening") } catch {}
        fence.wake()
        try fence.direct {}
        try fence.sleep { closes += 1 }
        require(closes == 1, "explicit Direct must release protected sleep behavior")
        try concurrentActivation()
        print("PASS: power fence closes before acknowledgement, rejects late approvals and requires fresh verification after wake")
    }

    private static func concurrentActivation() throws {
        let fence = MimoPowerFence()
        let epoch = try fence.arm()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try fence.activate(epoch: epoch) {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 3)
                }
            } catch { fatalError("activation unexpectedly failed") }
        }
        require(entered.wait(timeout: .now() + 3) == .success, "activation must enter its critical section")
        DispatchQueue.global().async {
            do { try fence.sleep { closed.signal() } }
            catch { fatalError("sleep unexpectedly failed") }
        }
        require(closed.wait(timeout: .now() + 0.1) == .timedOut, "sleep must not close before an in-flight activation can finish reopening")
        release.signal()
        require(closed.wait(timeout: .now() + 3) == .success, "sleep must close after an overlapping activation and before acknowledging")
        do {
            try fence.activate(epoch: epoch) { fatalError("old approval reopened after concurrent sleep") }
            require(false, "overlapping sleep must revoke the approval")
        } catch {}
    }
}
