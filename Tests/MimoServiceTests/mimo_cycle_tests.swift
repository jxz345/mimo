import Foundation

@MainActor
enum MimoCycleTests {
    static func run() async throws {
        let fence = MimoPowerFence()
        let epoch = try fence.arm()
        fence.beginCycle()
        var prematureCloses = 0
        for _ in 0..<5 { try fence.observeNetworkChange { prematureCloses += 1 }.resolve(true) }
        require(prematureCloses == 0 && fence.isCycleActive, "events must not interrupt an active cycle")
        var openings = 0
        do {
            try fence.completeCycle(epoch: epoch) { openings += 1 }
            require(false, "an external change must reject the stale result")
        } catch is MimoDeferredNetworkChange { }
        require(openings == 0 && fence.finishCycle() && !fence.finishCycle(), "many events must produce exactly one follow-up")
        fence.beginCycle()
        let next = try fence.arm()
        try fence.completeCycle(epoch: next) { openings += 1 }
        require(openings == 1 && !fence.isCycleActive, "a clean follow-up must open and finish")
        try fence.direct {}
        _ = try fence.observeNetworkChange { prematureCloses += 1 }
        require(prematureCloses == 0, "Direct events must not close traffic")

        let classified = MimoPowerFence()
        let classifiedEpoch = try classified.arm()
        classified.beginCycle()
        let ownEvent = try classified.observeNetworkChange { prematureCloses += 1 }
        do {
            try classified.completeCycle(epoch: classifiedEpoch) { require(false, "unclassified callbacks must prevent opening") }
            require(false, "pending classification must hold approval")
        } catch is MimoDeferredNetworkChange { }
        ownEvent.resolve(false)
        try classified.completeCycle(epoch: classifiedEpoch) { openings += 1 }
        require(!classified.finishCycle(), "an owned event must not leave a follow-up flag")
        classified.beginCycle()
        let late = try classified.observeNetworkChange {}
        require(classified.finishCycle(), "unresolved callback must conservatively request a follow-up")
        classified.beginCycle()
        let external = try classified.observeNetworkChange {}
        late.resolve(false)
        external.resolve(true)
        ownEvent.resolve(false)
        do {
            try classified.completeCycle(epoch: classifiedEpoch) { require(false, "late owned callbacks cannot erase an external change") }
            require(false, "external event must hold approval")
        } catch is MimoDeferredNetworkChange { }
        require(classified.finishCycle(), "real external event must retain its follow-up")
        print("PASS: pending classification holds approval; owned events add no follow-up; external and late callbacks remain safe")

        let queue = MimoControlQueue()
        var busy = true
        var executed: [Int] = []
        let first = Task { @MainActor in
            try await queue.wait(command: "Direct") { busy }
            executed.append(1)
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await queue.wait(command: "Rule") { busy }
            executed.append(2)
        }
        try await Task.sleep(for: .milliseconds(60))
        require(executed.isEmpty, "human commands must wait for the cycle")
        busy = false
        try await first.value
        try await second.value
        require(executed == [1, 2], "queued human commands must retain arrival order")
        print("PASS: cycle events coalesce, stale opening is rejected, Direct stays open and controls wait in order")
    }

    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
