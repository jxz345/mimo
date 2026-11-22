#if SWIFT_PACKAGE
import MimoShared
#endif
import Foundation

/// Small JSON-lines logger for diagnosing refresh lifecycle and provider behavior.
/// The log directory can be overridden with MIMO_LOG_DIRECTORY during local testing.
final class RuntimeLog: @unchecked Sendable {
    static let shared = RuntimeLog()
    /// Posted on the main queue for every record written; `userInfo` holds `timestamp`, `event`, and
    /// `fields` exactly as written (IP addresses redacted per Diagnostics). The Event Log window shows them.
    static let recordWritten = Notification.Name("MimoRuntimeLogRecordWritten")

    private let lock = NSLock()
    private let fileURL: URL?
    private var serviceDiagnostics: DiagnosticPreferences?
    private var recent = EventLogBuffer(limit: 500)
    private var diagnosticRecords = EventLogRecordBuffer()
    /// The folder holding every launch's `runtime-*.jsonl` (time plus PID avoids launch collisions).
    let directory: URL

    private init() {
        let fileManager = FileManager.default
        let directory: URL
        #if MIMO_DAEMON
        directory = MimoService.logDirectory
        #else
        if let override = ProcessInfo.processInfo.environment["MIMO_LOG_DIRECTORY"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Mimo/Logs", isDirectory: true)
        }
        #endif
        self.directory = directory

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: .now)
                .replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("runtime-\(stamp)-\(ProcessInfo.processInfo.processIdentifier).jsonl")
            fileManager.createFile(atPath: url.path, contents: nil)
            fileURL = url
        } catch {
            fileURL = nil
        }
        // Bound startup I/O while retaining useful history after a daemon restart.
        for file in logFiles().suffix(4) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 262144 ? size - 262144 : 0)
            if let data = try? handle.read(upToCount: 262144), let text = String(data: data, encoding: .utf8) {
                recent.append(jsonLines: text)
                diagnosticRecords.append(jsonLines: text)
            }
        }
    }

    func configure(_ preferences: DiagnosticPreferences) {
        let changed = lock.withLock {
            let changed = serviceDiagnostics != preferences
            serviceDiagnostics = preferences
            return changed
        }
        if changed { Self.cleanupOldLogs(in: directory, retentionDays: preferences.retentionDays) }
    }

    func recentLines() -> [String] {
        var lines = lock.withLock { recent.lines }
        #if MIMO_DAEMON
        var installation = EventLogBuffer(limit: 500)
        installation.append(jsonLines: MimoInstallationJournal.records().joined(separator: "\n"))
        lines = Array(Set(lines + installation.lines).sorted().suffix(500))
        #endif
        return lines
    }
    func recentDiagnosticRecords() -> [String] {
        var lines = lock.withLock { diagnosticRecords.lines }
        #if MIMO_DAEMON
        let dated = Set(lines + MimoInstallationJournal.records()).map { line -> (String, String) in
            let data = Data(line.utf8)
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (value?["timestamp"] as? String ?? "", line)
        }
        lines = Array(dated.sorted { $0 < $1 }.suffix(500).map(\.1))
        #endif
        return lines
    }

    func info(_ event: String, fields: [String: String] = [:]) {
        write(level: "info", event: event, fields: fields)
    }

    func error(_ event: String, fields: [String: String] = [:]) {
        write(level: "error", event: event, fields: fields)
    }

    private func write(level: String, event: String, fields: [String: String]) {
        guard let fileURL else { return }
        let preferences = lock.withLock { serviceDiagnostics } ?? DiagnosticPreferencesStore().load()
        let safeFields = fields.mapValues { value in
            preferences.includeFullIPAddresses ? value : LogRedactor.redactIPAddresses(in: value)
        }
        let timestamp = ISO8601DateFormatter().string(from: .now)
        let record: [String: Any] = [
            "timestamp": timestamp,
            "level": level,
            "event": event,
            "fields": safeFields
        ]
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")

        lock.lock()
        _ = recent.append(timestamp: timestamp, event: event, fields: safeFields)
        diagnosticRecords.append(jsonLines: line)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
        lock.unlock()

        let userInfo: [String: any Sendable] = ["timestamp": timestamp, "event": event, "fields": safeFields]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.recordWritten, object: nil, userInfo: userInfo)
        }
    }

    /// Every launch's log file, oldest first (the names start with the launch time).
    func logFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("runtime-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func cleanupOldLogs(in directory: URL, retentionDays: Int) {
        let cutoff = Date.now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where
            (file.lastPathComponent.hasPrefix("runtime-") && file.pathExtension == "jsonl") ||
            (file.lastPathComponent.hasPrefix("launch-") && file.pathExtension == "json") {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
