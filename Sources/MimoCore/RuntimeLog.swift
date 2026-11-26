#if SWIFT_PACKAGE
import MimoShared
#endif
import Foundation

/// Small JSON-lines logger for diagnosing refresh lifecycle and provider behavior.
/// The log directory can be overridden with MIMO_LOG_DIRECTORY during local testing.
final class RuntimeLog: @unchecked Sendable {
    static let shared = RuntimeLog()
    /// Posted on the main queue for every in-memory record; disk persistence is
    /// asynchronous. Fields are already redacted per Diagnostics.
    static let recordWritten = Notification.Name("MimoRuntimeLogRecordWritten")

    private let lock = NSLock()
    private var store: MimoLogStore?
    private let diskQueue = DispatchQueue(label: "com.mimo.log-storage", qos: .utility)
    private var maintenanceTimer: DispatchSourceTimer?
    private var pending: [(Data, Date)] = []
    private var pendingBytes = 0
    private var draining = false
    private var droppedRecords = 0
    private var writeFailures = 0
    private var serviceDiagnostics: DiagnosticPreferences?
    private var recent = EventLogBuffer(limit: 500)
    private var diagnosticRecords = EventLogRecordBuffer()
    private var recordSequence: UInt64 = 0
    private let processRole: String = {
        if CommandLine.arguments.contains("--supervisor") { return "supervisor" }
        if CommandLine.arguments.contains("--engine") { return "engine" }
        if ProcessInfo.processInfo.processName.contains("gui") { return "gui" }
        return "core"
    }()
    /// The folder holding bounded runtime segments (UTC time, PID and UUID).
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

        #if MIMO_DAEMON
        store = try? MimoLogStore(directory: directory, serviceOutputs: true)
        #else
        store = try? MimoLogStore(directory: directory)
        #endif
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
        let timer = DispatchSource.makeTimerSource(queue: diskQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(60), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.maintain() }
        maintenanceTimer = timer
        timer.resume()
    }

    func configure(_ preferences: DiagnosticPreferences) {
        let changed = lock.withLock {
            let changed = serviceDiagnostics != preferences
            serviceDiagnostics = preferences
            return changed
        }
        if changed {
            #if !MIMO_DAEMON
            // Cache the last shared choice for an offline/released GUI launch.
            DiagnosticPreferencesStore().save(preferences)
            #endif
            diskQueue.async { [weak self] in self?.maintain() }
        }
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
        let preferences = lock.withLock { serviceDiagnostics } ?? DiagnosticPreferencesStore().load()
        var safeFields = fields.mapValues { value in
            preferences.includeFullIPAddresses ? value : LogRedactor.redactIPAddresses(in: value)
        }
        // Serialize timestamp and sequence with the write. Milliseconds and a
        // process-local sequence preserve same-second transitions in exports.
        lock.lock()
        recordSequence &+= 1
        safeFields["processRole"] = processRole
        safeFields["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        safeFields["recordSequence"] = String(recordSequence)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date.now
        let timestamp = formatter.string(from: now)
        let record: [String: Any] = [
            "timestamp": timestamp,
            "level": level,
            "event": event,
            "fields": safeFields
        ]
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else { lock.unlock(); return }
        line.append("\n")

        _ = recent.append(timestamp: timestamp, event: event, fields: safeFields)
        diagnosticRecords.append(jsonLines: line)
        let bytes = Data(line.utf8)
        // Bound the asynchronous backlog as well as disk usage. Storage delays
        // must never stall the GUI, a traffic gate or a health-check actor.
        if pending.count < 1_024, pendingBytes + bytes.count <= 2 * 1_024 * 1_024 {
            pending.append((bytes, now)); pendingBytes += bytes.count
            if !draining {
                draining = true
                diskQueue.async { [weak self] in self?.drain() }
            }
        } else {
            droppedRecords += 1
        }
        lock.unlock()

        let userInfo: [String: any Sendable] = ["timestamp": timestamp, "event": event, "fields": safeFields]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.recordWritten, object: nil, userInfo: userInfo)
        }
    }

    /// Every retained runtime segment, oldest first.
    func logFiles() -> [URL] {
        guard lock.withLock({ store != nil }) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("runtime-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func drain(reschedule: Bool = true) {
        let batch: [(Data, Date)] = lock.withLock {
            let batch = Array(pending.prefix(64))
            pending.removeFirst(batch.count)
            pendingBytes -= batch.reduce(0) { $0 + $1.0.count }
            return batch
        }
        for (record, date) in batch {
            do {
                guard let store = lock.withLock({ store }) else { throw CocoaError(.fileWriteNoPermission) }
                try store.append(record, now: date)
            } catch { writeFailures += 1 }
        }
        lock.withLock {
            if pending.isEmpty { draining = false }
            else if reschedule { diskQueue.async { [weak self] in self?.drain() } }
        }
    }

    private func maintain() {
        var preferences = lock.withLock { serviceDiagnostics } ?? DiagnosticPreferencesStore().load()
        #if MIMO_DAEMON
        // Both long-running roles live in mimo-core. Read the shared preference
        // without RPC so retention continues if the other role/GUI is stopped.
        if let storage = try? FilePreferenceStorage(url: MimoService.storageURL),
           let data = storage.data(forKey: "service.settings"),
           let settings = try? JSONDecoder().decode(MachineSettings.self, from: data) {
            preferences = settings.diagnostics
        }
        #endif
        do {
            let store: MimoLogStore
            if let available = lock.withLock({ self.store }) { store = available }
            else {
                #if MIMO_DAEMON
                store = try MimoLogStore(directory: directory, serviceOutputs: true)
                #else
                store = try MimoLogStore(directory: directory)
                #endif
                lock.withLock { self.store = store }
            }
            let result = try store.maintain(retentionDays: preferences.retentionDays)
            let dropped = lock.withLock { let count = droppedRecords; droppedRecords = 0; return count }
            let failed = writeFailures; writeFailures = 0
            if result.changed || dropped > 0 || failed > 0 {
                info("mimo_log_maintenance", fields: [
                    "rotated": String(result.rotated), "deleted": String(result.deleted),
                    "truncated": String(result.truncated), "bytesRemoved": String(result.bytesRemoved),
                    "droppedRecords": String(dropped), "writeFailures": String(failed)
                ])
            }
        } catch {
            // Publish one bounded in-memory diagnostic per sweep; do not recurse
            // synchronously into a failed disk write or any network operation.
            self.error("mimo_log_maintenance_failed", fields: ["reason": "storage_unavailable"])
        }
    }

    /// Used only at process exit or by diagnostics tests, never by UI controls
    /// or routing actors. Runtime writes themselves remain asynchronous.
    func flush() {
        diskQueue.sync {
            while lock.withLock({ !pending.isEmpty }) { drain(reschedule: false) }
        }
    }
}
