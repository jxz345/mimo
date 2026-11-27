import Foundation

@MainActor
enum MimoDirectReleaseTests {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-direct-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MimoDirectReleaseRequest(id: UUID(), parentPID: 123, parentIdentity: "owner-start", revision: 42)
        var tested = 0
        for scenario in ["valid", "token", "parent", "identity", "revision", "mode", "maintenance", "released", "orphan"] {
            let fixture = root.appendingPathComponent(scenario)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            let mutation = fixture.appendingPathComponent("pf-mutation.epoch")
            let closure = fixture.appendingPathComponent("pf-close.epoch")
            try Data("newer-owner".utf8).write(to: mutation)
            try Data("newer-close".utf8).write(to: closure)
            var wrote = false
            let record = scenario == "token" ? MimoDirectReleaseRequest(id: UUID(), parentPID: 123, parentIdentity: "owner-start", revision: 42) : owner
            let candidate = scenario == "orphan" ? MimoDirectReleaseRequest(id: owner.id, parentPID: 1, parentIdentity: "owner-start", revision: 42) : owner
            do {
                try MimoFirewallLock.mutate(revoking: true, directory: fixture, admitting: {
                    guard candidate.isCurrent(record: scenario == "orphan" ? candidate : record,
                        parent: scenario == "parent" ? 456 : scenario == "orphan" ? 1 : 123,
                        identity: scenario == "identity" ? "reused-pid" : "owner-start",
                        savedRevision: scenario == "revision" ? 43 : 42,
                        mode: scenario == "mode" ? .rule : .direct,
                        maintenance: scenario == "maintenance", released: scenario == "released") else { throw DaemonFailure.conflict }
                }) { wrote = true }
                require(scenario == "valid", "stale Direct child must not write: \(scenario)")
            } catch { require(scenario != "valid", "live Direct owner must be admitted") }
            require(wrote == (scenario == "valid"), "only current owner may mutate")
            if scenario != "valid" {
                require(try String(contentsOf: mutation, encoding: .utf8) == "newer-owner", "stale child must not invalidate a newer audit")
                require(try String(contentsOf: closure, encoding: .utf8) == "newer-close", "stale child must not invalidate a newer closure")
            }
            tested += 1
        }
        let helper = root.appendingPathComponent("child.py")
        try Data("""
        import pathlib,sys,time,json
        pathlib.Path(sys.argv[2]+'.started').write_text('started')
        text=pathlib.Path(sys.argv[1]).read_text()
        if sys.argv[4] not in ['old','future','malformed','oversized']:
            value=json.loads(text)
            value['completedAt']=time.time()-978307200
            text=json.dumps(value)
        print(text,flush=True)
        time.sleep(.12)
        pathlib.Path(sys.argv[2]).write_text('physically complete')
        sys.exit(int(sys.argv[3]))
        """.utf8).write(to: helper)
        let queue = MimoBlockingWorkQueue("test.direct-joined-child")
        for scenario in ["valid", "failure", "timeout", "malformed", "token", "future", "old", "oversized", "caller-cancelled"] {
            let output = root.appendingPathComponent(scenario + ".json")
            let done = root.appendingPathComponent(scenario + ".done")
            let value = MimoDirectReleaseResult(id: scenario == "token" ? UUID() : owner.id,
                completedAt: Date.now.addingTimeInterval(scenario == "future" ? 3600 : scenario == "old" ? -3600 : 0), nativeVerified: true)
            let data = scenario == "malformed" ? Data("not-json".utf8) : scenario == "oversized" ? Data(repeating: 65, count: 16384) : try JSONEncoder().encode(value)
            try data.write(to: output)
            let status = scenario == "timeout" ? 124 : scenario == "failure" ? 1 : 0
            let task = Task {
                await queue.run { () -> Result<MimoDirectReleaseResult, Error> in
                    Result {
                        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                        process.arguments = [helper.path, output.path, done.path, String(status), scenario]
                        return try MimoJoinedDirectProcess.collect(process, request: owner)
                    }
                }
            }
            if scenario == "caller-cancelled" {
                for _ in 0..<2000 {
                    if FileManager.default.fileExists(atPath: done.path + ".started") { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
                require(FileManager.default.fileExists(atPath: done.path + ".started"), "fixture child must start before cancellation")
                task.cancel()
            }
            let result = await task.value
            require(FileManager.default.fileExists(atPath: done.path), "\(scenario) must join physical child completion, including rejected output")
            if scenario == "valid" { require((try? result?.get()) != nil, "valid child receipt must be accepted") }
            else if scenario == "caller-cancelled" { require(result == nil, "cancellation is returned only after child completion") }
            else { require((try? result?.get()) == nil, "invalid child receipt must fail: \(scenario)") }
            tested += 1
        }
        print("PASS: \(tested)/18 Direct child ownership, rejection, timeout-result and physical-join controls")
    }
    private static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }

}
