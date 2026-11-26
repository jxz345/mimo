import Darwin
import Foundation

@main
enum LogTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !value() { fatalError(message) }
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--unavailable" {
            let directory = URL(fileURLWithPath: args[2])
            let target = directory.appendingPathComponent("untouched.txt")
            try Data("untouched".utf8).write(to: target)
            let link = directory.appendingPathComponent(".mimo-log.lock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            setenv("MIMO_LOG_DIRECTORY", directory.path, 1)
            RuntimeLog.shared.info("storage_unavailable_test")
            RuntimeLog.shared.flush()
            require(!RuntimeLog.shared.recentDiagnosticRecords().isEmpty, "unavailable disk lost in-memory diagnostics")
            try FileManager.default.removeItem(at: link)
            RuntimeLog.shared.configure(DiagnosticPreferences(retentionDays: 30))
            RuntimeLog.shared.flush()
            RuntimeLog.shared.info("storage_recovered_test")
            RuntimeLog.shared.flush()
            let contents = try RuntimeLog.shared.logFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined()
            require(contents.contains("storage_recovered_test"), "logger did not recover after storage was repaired")
            try require(String(contentsOf: target, encoding: .utf8) == "untouched", "unsafe lock target was modified")
            return
        }
        if args.count == 4, args[1] == "--writer" {
            let store: MimoLogStore
            do {
                store = try MimoLogStore(directory: URL(fileURLWithPath: args[2]),
                    limits: .init(fileBytes: 2_048, directoryBytes: 2_000_000, fileCount: 512))
            } catch {
                print("Writer \(args[3]) initialization failed; directory exists=\(FileManager.default.fileExists(atPath: args[2])): \(error)")
                exit(2)
            }
            for index in 0..<400 {
                do {
                    try store.append(Data("{\"writer\":\"\(args[3])\",\"index\":\(index)}\n".utf8))
                    if index % 17 == 0 { _ = try store.maintain() }
                } catch {
                    print("Writer \(args[3]) failed at record \(index): \(error)")
                    exit(2)
                }
            }
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-log-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var writers: [Process] = []
        for index in 0..<4 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: args[0])
            child.arguments = ["--writer", directory.path, String(index)]
            try child.run(); writers.append(child)
        }
        for child in writers { child.waitUntilExit() }
        require(writers.allSatisfy { $0.terminationStatus == 0 }, "writer failed")
        var records = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
            let data = try Data(contentsOf: file)
            require(data.count <= 2_048, "concurrent segment exceeded cap")
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
                records.insert(String(line))
            }
        }
        require(records.count == 1_600, "concurrent rotation/cleanup lost or interleaved a record")
        print("PASS: four independent writer processes, 1,600 intact records, simultaneous cleanup")

        let failureDirectory = directory.appendingPathComponent("unavailable")
        try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        let failure = Process()
        failure.executableURL = URL(fileURLWithPath: args[0])
        failure.arguments = ["--unavailable", failureDirectory.path]
        try failure.run(); failure.waitUntilExit()
        require(failure.terminationStatus == 0, "storage recovery failed")
        print("PASS: unavailable storage retains in-memory diagnostics and recovers after repair")

        let runtimeDirectory = directory.appendingPathComponent("runtime")
        setenv("MIMO_LOG_DIRECTORY", runtimeDirectory.path, 1)
        RuntimeLog.shared.configure(DiagnosticPreferences())
        for index in 0..<450 {
            RuntimeLog.shared.info("rotation_regression", fields: ["index": String(index), "detail": String(repeating: "x", count: 16_384)])
            if index % 16 == 0 { RuntimeLog.shared.flush() }
        }
        RuntimeLog.shared.flush()
        let files = RuntimeLog.shared.logFiles()
        require(files.count >= 2, "active logger did not rotate")
        var count = 0
        for file in files {
            let data = try Data(contentsOf: file)
            require(data.count <= 5 * 1_024 * 1_024, "active runtime exceeds 5 MiB")
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                if record["event"] as? String == "rotation_regression" { count += 1 }
            }
        }
        require(count == 450, "asynchronous persistence lost records")
        print("PASS: original 7.45-MB regression now rotates, all 450 records retained")

        let lockPath = runtimeDirectory.appendingPathComponent(".mimo-log.lock").path
        let fd = open(lockPath, O_RDWR)
        require(fd >= 0 && flock(fd, LOCK_EX) == 0, "could not simulate slow log storage")
        // A blocked disk writer must not block event producers or grow an
        // unbounded dispatch queue. The explicit drop count must survive.
        for index in 0..<2_000 {
            RuntimeLog.shared.info("bounded_backlog", fields: ["index": String(index), "detail": String(repeating: "x", count: 4_096)])
        }
        flock(fd, LOCK_UN); close(fd)
        RuntimeLog.shared.flush()
        RuntimeLog.shared.configure(DiagnosticPreferences(retentionDays: 1))
        RuntimeLog.shared.flush()
        let reports = RuntimeLog.shared.recentDiagnosticRecords().compactMap { line -> [String: String]? in
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  value["event"] as? String == "mimo_log_maintenance" else { return nil }
            return value["fields"] as? [String: String]
        }
        require(reports.contains { Int($0["droppedRecords"] ?? "0") ?? 0 > 0 }, "backlog overflow was not reported")
        print("PASS: blocked storage does not block producers; bounded backlog reports discarded records")

        // This exercises the production 60-second timer, without another log
        // write, preference change, GUI restart or main-thread run loop.
        let expired = runtimeDirectory.appendingPathComponent("runtime-expired.jsonl")
        try Data("old\n".utf8).write(to: expired)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-8 * 86_400),
                                              .posixPermissions: 0o600], ofItemAtPath: expired.path)
        print("Waiting for the production scheduled retention sweep…")
        fflush(stdout)
        let deadline = Date.now.addingTimeInterval(70)
        while FileManager.default.fileExists(atPath: expired.path), Date.now < deadline { usleep(100_000) }
        require(!FileManager.default.fileExists(atPath: expired.path), "periodic expiry did not run")
        RuntimeLog.shared.flush()
        require(RuntimeLog.shared.recentDiagnosticRecords().contains { $0.contains("mimo_log_maintenance") }, "cleanup counters were not recorded")
        print("PASS: scheduled expiry runs without restarts or settings changes; cleanup recorded")
    }
}
