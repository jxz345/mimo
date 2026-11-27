import Foundation

struct Preferences: Sendable { var engine = true }
enum ServiceID: Sendable { case mihomo }
enum MimoServiceHealth: String, Sendable { case running, unavailable, stopped }
struct MimoServiceStatus: Sendable {
    var id: ServiceID; var health: MimoServiceHealth; var transport: String
    var address: String; var port: Int; var checkedAt: Date
}
enum DaemonFailure: Error { case unavailable }
enum MimoRuntimeError: Error { case unavailable(String) }
struct TestPolicy { struct State { var phase = Phase.active }; enum Phase { case active, blocked }; var state = State() }
@MainActor final class TestPeer { func workProgressed() {} }
final class RuntimeLog: Sendable {
    static let shared = RuntimeLog()
    func info(_ name: String, fields: [String:String] = [:]) { TestClock.shared.note(name) }
    func error(_ name: String, fields: [String:String] = [:]) { TestClock.shared.note(name) }
}
enum MimoRuntime {
    static var guardDirectory: URL { TestClock.shared.directory.appendingPathComponent("Guard") }
    static var guardScript: URL { TestClock.shared.script }
    static let engineLabel = "isolated-engine"
    static let mixedPort = 0
}
struct Check: Codable, Sendable { let started: Double; let finished: Double; let status: Int32; let checkedAt: Double? }
struct Sample: Codable, Sendable { let elapsed: Double; let age: Double?; let pf: String; let launchd: String }
struct GuardRecord: Codable, Sendable {
    let boot: String; let checkedAt: Double; let pf: String; let launchd: String
    var pfCheckedAt: Double?; var launchdCheckedAt: Double?; var completedAt: Double?
}
final class TestClock: @unchecked Sendable {
    static let shared = TestClock()
    let base = 1_700_000_000.0
    private let lock = NSLock()
    private var time = 0.0
    var directory = URL(fileURLWithPath: "/unconfigured-test")
    var script = URL(fileURLWithPath: "/unconfigured-guard")
    var scenario = ""
    var generation: UInt64 = 0
    var horizon = 50.0
    var checks: [Check] = []
    var samples: [Sample] = []
    var events: [String] = []
    var elapsed: Double { lock.withLock {time} }
    var date: Date { Date(timeIntervalSince1970: base + elapsed) }
    func note(_ event: String) { lock.withLock {events.append(event)} }
    func record() -> GuardRecord? {
        try? JSONDecoder().decode(GuardRecord.self, from: Data(contentsOf: directory.appendingPathComponent("Guard/health.json")))
    }
    func projected(_ record: GuardRecord?, at time: Double) -> MimoInfrastructureStatus {
        guard let record else {return .init()}
        return MimoInfrastructureStatus(pf: record.pf == "enabled" ? .healthy : .failed,
            launchd: record.launchd == "healthy" ? .healthy : .failed,
            checkedAt: Date(timeIntervalSince1970: record.checkedAt),
            pfCheckedAt:record.pfCheckedAt.map(Date.init(timeIntervalSince1970:)),
            launchdCheckedAt:record.launchdCheckedAt.map(Date.init(timeIntervalSince1970:)),
            completedAt:record.completedAt.map(Date.init(timeIntervalSince1970:))).current(at: Date(timeIntervalSince1970: base+time))
    }
    func advance(by delta: Double, record: GuardRecord?) {
        lock.withLock {
            let end = time + delta
            var instant = time
            while instant < end {
                let status = projected(record, at: instant)
                samples.append(Sample(elapsed: instant, age: record.map {base + instant - $0.checkedAt},
                    pf: status.pf.rawValue, launchd: status.launchd.rawValue))
                instant += 0.25
            }
            time = end
        }
    }
    func reset(_ name: String, root: URL, script: URL, start: Double, checkedAt: Double, until: Double) throws {
        self.directory = root; self.script = script; self.scenario = name; self.horizon = until
        time = start; checks = []; samples = []; events = []; generation = 0
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Runtime"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Guard"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("Guard/boot.id"))
        try Data("fixture-epoch".utf8).write(to: root.appendingPathComponent("Runtime/pf-mutation.epoch"))
        try Data("active".utf8).write(to: root.appendingPathComponent("Runtime/gate.state"))
        try Data("fixture policy".utf8).write(to: root.appendingPathComponent("Runtime/guard.expected"))
        let record = GuardRecord(boot: "fixture",checkedAt:base+checkedAt,pf:"enabled",launchd:"healthy")
        try JSONEncoder().encode(record).write(to:root.appendingPathComponent("Guard/health.json"))
    }
    func facts(at start: Double) -> (String,Double) {
        if scenario == "two-discrete-deferrals" && ((start >= 10 && start < 12) || (start >= 21 && start < 23)) {return ("defer",1)}
        if scenario == "sustained-deferrals" {return ("defer",1)}
        if scenario == "genuine-check-failure" || scenario == "persistent-failure-episode" {return ("failure",1)}
        if scenario == "slow-scan-start-time" {return ("success",24)}
        if scenario == "two-discrete-deferrals" || scenario == "stale-record-recovery" {return ("success",4)}
        return ("success",1)
    }
}
enum BoundedProcess {
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval, captureError: Bool) -> (text:String,status:Int32) {
        precondition(executable == "/usr/bin/perl" && args.count == 2 && args[1] == "--check")
        let c = TestClock.shared; let start = c.elapsed; let before = c.record();let fact = c.facts(at:start)
        let p = Process();p.executableURL=URL(fileURLWithPath:executable);p.arguments=args
        p.environment=ProcessInfo.processInfo.environment.merging([
            "HEALTH_TEST_ROOT":c.directory.path,"HEALTH_TEST_START":String(c.base+start),
            "HEALTH_TEST_DURATION":String(fact.1),"HEALTH_TEST_OUTCOME":fact.0]) {_,v in v}
        let pipe=Pipe();p.standardOutput=pipe;p.standardError=pipe
        do {try p.run();p.waitUntilExit()} catch {fatalError("Isolated Perl helper could not run")}
        let text=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
        let end=(try! JSONSerialization.jsonObject(with:Data(contentsOf:c.directory.appendingPathComponent("clock.json"))) as! [String:Double])["finished"]! - c.base
        c.advance(by:end-start,record:before)
        if c.scenario == "superseded-receipt" {c.generation = 1}
        c.checks.append(Check(started:start,finished:end,status:p.terminationStatus,checkedAt:c.record().map{$0.checkedAt-c.base}))
        return (text,p.terminationStatus)
    }
}
