import Darwin
import Foundation

enum MimoInfrastructureTests {
    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    @MainActor
    static func run() async throws {
        // This process has no engine launchd job. Its live kernel identity is
        // still unambiguous; a failed job-list query must not mean it exited.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        require(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size, "test process identity available")
        let started = "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        require(proc_pidpath(getpid(), &path, UInt32(path.count)) > 0, "test executable available")
        let executable = String(cString: path)
        func inspect(_ pid: Int32 = getpid(), start: String? = nil, file: String? = nil, uid: UInt32? = nil) -> String? {
            MimoSystemRuntime.processLivenessFailure(pid, started: start ?? started,
                executable: file ?? executable, uid: uid ?? info.pbi_uid, gid: info.pbi_gid)
        }
        require(inspect() == nil, "kernel identity confirms an existing process independently of launchctl output")
        require(inspect(0) == "process_missing", "invalid PID cannot qualify liveness")
        require(inspect(start: "obsolete") == "process_replaced", "PID reuse cannot qualify liveness")
        require(inspect(file: "/wrong/executable") == "process_executable_changed", "exec replacement cannot qualify liveness")
        require(inspect(uid: UInt32.max) == "process_credentials_changed", "changed credentials cannot qualify liveness")
        func progress(_ time: Double, _ sequence: UInt64, pid: Int32 = 42, work: Double? = nil) -> MimoPeerProgress {
            .init(boot: "test", pid: pid, sequence: sequence, uptime: time, workUptime: work ?? time)
        }
        var lease = MimoPeerLease()
        require(!lease.needsRepair(pid: 42, progress: progress(0, 1), now: 0), "responsive supervisor must not be restarted")
        require(!lease.needsRepair(pid: 42, progress: progress(0, 1), now: 44), "one delayed sample cannot restart a supervisor")
        require(lease.needsRepair(pid: 42, progress: progress(0, 1), now: 45), "a running PID with no progress must be recovered")
        require(!lease.needsRepair(pid: 42, progress: progress(46, 2), now: 46), "resumed progress cancels pending recovery")
        require(!lease.needsRepair(pid: 43, progress: progress(46, 2), now: 47), "replacement receives startup grace; prior PID is not proof of health")
        require(!lease.needsRepair(pid: 43, progress: nil, now: 166), "cold startup grace is bounded but permits migration")
        require(lease.needsRepair(pid: 43, progress: nil, now: 167), "hung startup must eventually recover")
        require(!lease.needsRepair(pid: nil, progress: nil, now: 168), "launchd gets first opportunity to restart an exited process")
        require(lease.needsRepair(pid: nil, progress: nil, now: 178), "missing registration must be repaired")
        var future = MimoPeerLease()
        require(!future.needsRepair(pid: 42, progress: progress(500, 1), now: 0), "future progress cannot qualify")
        require(future.needsRepair(pid: 42, progress: progress(500, 2), now: 120), "future timestamps cannot indefinitely extend startup grace")
        var stalled = MimoPeerLease()
        require(!stalled.needsRepair(pid: 42, progress: progress(0, 1), now: 0), "first work check qualifies")
        require(!stalled.needsRepair(pid: 42, progress: progress(89, 2, work: 0), now: 89), "bounded infrastructure check gets time to complete")
        require(stalled.needsRepair(pid: 42, progress: progress(134, 3, work: 0), now: 134), "responsive loop cannot hide stalled infrastructure work")
        require(MimoCoreRole.heartbeat.peer == .supervisor && MimoCoreRole.supervisor.peer == .heartbeat,
                "each existing role owns exactly one peer, never itself")
        var budget = MimoPeerRepairBudget(boot: "one", attempts: [10])
        require(budget.waitReason(boot: "one", now: 39) == "backoff", "first restart waits 30 seconds")
        require(budget.waitReason(boot: "one", now: 40) == nil, "backoff expires")
        budget.attempts.append(40)
        require(budget.waitReason(boot: "one", now: 99) == "backoff", "second restart waits 60 seconds")
        budget.attempts.append(100)
        let restored = try JSONDecoder().decode(MimoPeerRepairBudget.self, from: JSONEncoder().encode(budget))
        budget = restored
        require(budget.waitReason(boot: "one", now: 220) == "restart_budget_exhausted", "watchdog restart cannot reset persisted budget")
        require(budget.waitReason(boot: "one", now: 610) == nil, "sliding window permits later explicit recovery")
        require(budget.waitReason(boot: "two", now: 1) == nil && budget.attempts.isEmpty, "new boot resets monotonic budget")
        print("PASS: peer progress, sustained hangs, missing jobs, startup grace, restart identity and stalled work")
    }
}
