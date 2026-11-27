    let runtime = MimoSystemRuntime()
    var infrastructureMonitor: Task<Void,Never>?
    lazy var infrastructureScheduler = MimoInfrastructureScheduler(now: {TestClock.shared.elapsed}, sleep: { delay in
        TestClock.shared.advance(by: delay, record: TestClock.shared.record())
        if TestClock.shared.elapsed >= TestClock.shared.horizon { await MainActor.run {self.infrastructureMonitor?.cancel()} }
        await Task.yield()
    })
    var directRestorationTask: Task<Void,Never>?
    var generation: UInt64 {TestClock.shared.generation}
    var infrastructureRecoveryPending = false
    var infrastructureFailureGeneration:UInt64?
    var verificationRecoveryPending = false
    var policy = TestPolicy()
    var peerWatchdog: TestPeer? = TestPeer()
    var failureCount = 0
    var networkChecks = 0
    var stopping = false
    func networkChanged(_ source: String) { networkChecks += 1 }
    @discardableResult func close(_ reason: String) -> Bool {
        failureCount += 1
        requestInfrastructureReconciliation("close_finished")
        return true
    }
    func testSleep(seconds: Double) async {
        TestClock.shared.advance(by: seconds, record: TestClock.shared.record())
        if TestClock.shared.elapsed >= TestClock.shared.horizon { infrastructureMonitor?.cancel() }
        await Task.yield()
    }
