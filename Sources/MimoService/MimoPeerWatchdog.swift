import Darwin
import Foundation

enum MimoCoreRole: String, Codable, Sendable {
    case supervisor, heartbeat
    var peer: Self { self == .supervisor ? .heartbeat : .supervisor }
    // Retain the old job identity for upgrade/removal. It now runs only --heartbeat;
    // com.mimo.core Mach services belong to the supervisor, not this job.
    var label: String { self == .supervisor ? MimoRuntime.supervisorLabel : MimoService.label }
    var argument: String { "--" + rawValue }
    var executable: URL { self == .supervisor ? MimoRuntime.supervisorExecutable : MimoRuntime.heartbeatExecutable }
    var plist: URL {
        self == .supervisor ? URL(fileURLWithPath: MimoRuntime.supervisorPlist) :
            MimoRuntime.jobDirectory.appendingPathComponent(label + ".plist")
    }
}

struct MimoPeerProgress: Codable, Sendable {
    var boot: String
    var pid: Int32
    var sequence: UInt64
    var uptime: TimeInterval
    var workUptime: TimeInterval
}

/// Uses monotonic time. A new process gets startup grace; a known responsive
/// process must stop progressing for 45 seconds before a forced restart.
struct MimoPeerLease {
    private var pid: Int32?
    private var began: TimeInterval?
    private var lastProgress: TimeInterval?
    private var sequence: UInt64?

    mutating func needsRepair(pid next: Int32?, progress: MimoPeerProgress?, now: TimeInterval) -> Bool {
        if began == nil || pid != next {
            pid = next; began = now; lastProgress = nil; sequence = nil
        }
        if let progress, progress.pid == next, progress.sequence != sequence,
           now - progress.uptime >= 0, now - progress.uptime < 15,
           now - progress.workUptime >= 0, now - progress.workUptime < 90 {
            sequence = progress.sequence; lastProgress = now
        }
        return now - (lastProgress ?? began ?? now) >= (next == nil ? 10 : lastProgress == nil ? 120 : 45)
    }
}

struct MimoPeerRepairBudget: Codable {
    var boot: String
    var attempts: [TimeInterval]

    mutating func waitReason(boot currentBoot: String, now: TimeInterval) -> String? {
        if boot != currentBoot { boot = currentBoot; attempts = [] }
        attempts = attempts.filter { $0 <= now && now - $0 < 600 }
        if attempts.count >= 3 { return "restart_budget_exhausted" }
        if let last = attempts.last, now - last < 30 * pow(2, Double(attempts.count - 1)) { return "backoff" }
        return nil
    }
}

/// No network/PF/DNS/profile operations here. Both peers use the same narrow
/// repair lock; persistent per-target budgets survive a watchdog restart.
private struct MimoPeerRuntime: Sendable {
    let role: MimoCoreRole
    let boot: String
    private var directory: URL { MimoRuntime.directory }
    private func path(_ role: MimoCoreRole) -> URL { directory.appendingPathComponent(role.rawValue + ".progress.json") }

    static func secure(_ url: URL, directory: Bool = false) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw DaemonFailure.unavailable }
    }

    func publish(sequence: UInt64, work: TimeInterval) throws {
        try Self.secure(directory, directory: true)
        let value = MimoPeerProgress(boot: boot, pid: getpid(), sequence: sequence,
                                    uptime: ProcessInfo.processInfo.systemUptime, workUptime: work)
        try JSONEncoder().encode(value).write(to: path(role), options: .atomic)
        guard chmod(path(role).path, 0o600) == 0 else { throw DaemonFailure.unavailable }
    }

    func inspect() throws -> (pid: Int32?, progress: MimoPeerProgress?) {
        let file = path(role.peer)
        let progress: MimoPeerProgress?
        if (try? Self.secure(file)) != nil, let data = try? Data(contentsOf: file), data.count <= 4096,
           let record = try? JSONDecoder().decode(MimoPeerProgress.self, from: data), record.boot == boot {
            progress = record
        } else { progress = nil }
        // Healthy observation is a local progress read, not a launchctl subprocess
        // every two seconds. Confirm the live executable before trusting the PID.
        if let progress, progress.pid > 0 {
            let now = ProcessInfo.processInfo.systemUptime
            var executable = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            if now - progress.uptime >= 0, now - progress.uptime < 15,
               now - progress.workUptime >= 0, now - progress.workUptime < 90,
               proc_pidpath(progress.pid, &executable, UInt32(executable.count)) > 0,
               String(cString: executable) == role.peer.executable.path {
                return (progress.pid, progress)
            }
        }
        let job = BoundedProcess.run("/bin/launchctl", ["print", "system/" + role.peer.label], timeout: 3, captureError: true)
        if job.status == 113, job.text.contains("Could not find service") { return (nil, nil) }
        guard job.status == 0 else { throw MimoRuntimeError.unavailable("Peer inspection failed (launchctl status \(job.status)).") }
        guard job.text.contains("program = " + role.peer.executable.path), job.text.contains(role.peer.argument) else {
            throw MimoRuntimeError.unavailable("Unexpected peer registration. Repair installation.")
        }
        let pid = job.text.split(separator: "\n").compactMap { line -> Int32? in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("pid = ") ? Int32(value.dropFirst(6)) : nil
        }.first
        return (pid, progress)
    }

    func repair(expectedPID: Int32?) throws -> String {
        try Self.secure(directory, directory: true)
        guard let lock = try SingleInstanceLock(url: directory.appendingPathComponent("peer-repair.lock")) else { return "peer_repair_in_progress" }
        return try withExtendedLifetime(lock) {
            // Installer/uninstaller writes maintenance before stopping either peer.
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("maintenance").path),
                  !FileManager.default.fileExists(atPath: MimoService.support.appendingPathComponent("deactivated").path) else { return "maintenance" }
            let current = try inspect()
            guard current.pid == expectedPID else { return "process_changed" }
            let now = ProcessInfo.processInfo.systemUptime
            if let p = current.progress, p.pid == current.pid, now - p.uptime < 15, now - p.workUptime < 90 { return "progress_resumed" }
            let budgetPath = directory.appendingPathComponent(role.peer.rawValue + ".repair-budget.json")
            var budget = MimoPeerRepairBudget(boot: boot, attempts: [])
            if FileManager.default.fileExists(atPath: budgetPath.path) {
                try Self.secure(budgetPath)
                budget = try JSONDecoder().decode(MimoPeerRepairBudget.self, from: Data(contentsOf: budgetPath))
            }
            if let reason = budget.waitReason(boot: boot, now: now) { return reason }
            try Self.secure(role.peer.executable)
            // Restore only the peer's root-owned installation copy, never any
            // network helper or arbitrary caller-supplied command.
            let backup = MimoRuntime.guardDirectory.appendingPathComponent(role.peer.label + ".plist")
            try Self.secure(MimoRuntime.guardDirectory, directory: true)
            try Self.secure(role.peer.plist.deletingLastPathComponent(), directory: true)
            try Self.secure(backup)
            let data = try Data(contentsOf: backup)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard plist?["Label"] as? String == role.peer.label,
                  plist?["ProgramArguments"] as? [String] == [role.peer.executable.path, role.peer.argument] else { throw DaemonFailure.invalidRequest }
            try data.write(to: role.peer.plist, options: .atomic)
            guard chmod(role.peer.plist.path, 0o644) == 0 else { throw DaemonFailure.unavailable }
            budget.attempts.append(now)
            try JSONEncoder().encode(budget).write(to: budgetPath, options: .atomic)
            RuntimeLog.shared.info("mimo_peer_repair_started", fields: ["owner": role.rawValue, "target": role.peer.rawValue,
                "reason": expectedPID == nil ? "not_running" : "progress_expired", "attempt": String(budget.attempts.count)])
            func command(_ args: [String]) throws {
                let result = BoundedProcess.run("/bin/launchctl", args, timeout: 5, captureError: true)
                guard result.status == 0 else { throw MimoRuntimeError.unavailable("Peer launchctl \(args[0]) failed (\(result.status)).") }
            }
            try command(["enable", "system/" + role.peer.label])
            if expectedPID != nil {
                // SIGKILL handles SIGSTOP/deadlock; launchd KeepAlive performs restart.
                try command(["kill", "SIGKILL", "system/" + role.peer.label])
            } else {
                let job = BoundedProcess.run("/bin/launchctl", ["print", "system/" + role.peer.label], timeout: 3, captureError: true)
                if job.status == 113 { try command(["bootstrap", "system", role.peer.plist.path]) }
                else if job.status == 0 { try command(["kickstart", "system/" + role.peer.label]) }
                else { throw DaemonFailure.unavailable }
            }
            return "restarting"
        }
    }
}

@MainActor
final class MimoPeerWatchdog {
    private let role: MimoCoreRole
    private let runtime: MimoPeerRuntime
    private let queue = MimoBlockingWorkQueue("com.mimo.peer-watchdog")
    private var task: Task<Void, Never>?
    private var lease = MimoPeerLease()
    private var sequence: UInt64 = 0
    private var issue: String?
    private var work = ProcessInfo.processInfo.systemUptime
    private(set) var health = MimoInfrastructureHealth.unknown
    private(set) var checkedAt: Date?

    init(role: MimoCoreRole) throws {
        self.role = role
        let boot = BoundedProcess.run("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"], timeout: 3)
        let value = boot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard boot.status == 0, UUID(uuidString: value) != nil else { throw DaemonFailure.unavailable }
        runtime = MimoPeerRuntime(role: role, boot: value)
    }

    func workProgressed() { work = ProcessInfo.processInfo.systemUptime }
    func start() {
        guard task == nil else { return }
        RuntimeLog.shared.info("mimo_peer_watch_started", fields: ["owner": role.rawValue, "target": role.peer.rawValue])
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    self.sequence &+= 1
                    if self.role == .heartbeat { self.workProgressed() }
                    // Main-actor publication proves the GUI/control executor can run.
                    try self.runtime.publish(sequence: self.sequence, work: self.work)
                    guard let observation = await self.queue.run({ [runtime = self.runtime] in Result { try runtime.inspect() } }) else { break }
                    let peer = try observation.get()
                    let now = ProcessInfo.processInfo.systemUptime
                    let expired = self.lease.needsRepair(pid: peer.pid, progress: peer.progress, now: now)
                    let responsive = peer.progress.map { $0.pid == peer.pid && now - $0.uptime >= 0 && now - $0.uptime < 15 && now - $0.workUptime >= 0 && now - $0.workUptime < 90 } ?? false
                    self.checkedAt = .now
                    self.health = responsive ? .healthy : expired ? .failed : .unknown
                    if responsive, self.issue != nil {
                        RuntimeLog.shared.info("mimo_peer_recovered", fields: ["owner": self.role.rawValue, "target": self.role.peer.rawValue])
                        self.issue = nil
                    }
                    if expired {
                        guard let result = await self.queue.run({ [runtime = self.runtime] in Result { try runtime.repair(expectedPID: peer.pid) } }) else { break }
                        self.report(try result.get())
                    }
                } catch { self.health = .failed; self.checkedAt = .now; self.report(error.localizedDescription) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func report(_ reason: String) {
        guard issue != reason else { return }
        issue = reason
        RuntimeLog.shared.info("mimo_peer_recovery_wait", fields: ["owner": role.rawValue, "target": role.peer.rawValue, "reason": reason])
    }
    func stop() { task?.cancel() }
    func drain() async { await task?.value }
}
