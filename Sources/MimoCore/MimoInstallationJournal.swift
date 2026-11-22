import Darwin
import Foundation

/// Installer events belong to the machine, not to the GUI/account that requested
/// setup. Only mimo-core writes this fixed, bounded journal; daemon event replies
/// merge it on demand so success/failure records written after startup are visible.
enum MimoInstallationJournal {
    static let url = URL(fileURLWithPath: "/Library/Logs/Mimo/installation.jsonl")
    static let maximumBytes = 262_144

    static func append(attempt: String, operation: String, stage: String, item: String = "", status: String = "",
                       to url: URL = url, owner: uid_t = 0) throws {
        guard geteuid() == owner, UUID(uuidString: attempt) != nil,
              ["install", "activate"].contains(operation),
              !stage.isEmpty, stage.utf8.count <= 64,
              [stage, item, status].allSatisfy({ value in
                  value.utf8.count <= 200 && value.utf8.allSatisfy {
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0)
                  }
              }) else { throw CocoaError(.fileWriteNoPermission) }
        // Never write through a substituted directory/file or expose arbitrary
        // command output. Fields contain stage codes, labels and numeric statuses.
        let directory = url.deletingLastPathComponent()
        var info = stat()
        guard directory.resolvingSymlinksInPath().path == directory.path,
              lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == owner, info.st_mode & 0o022 == 0 else { throw CocoaError(.fileWriteNoPermission) }
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == owner, info.st_nlink == 1, info.st_mode & 0o022 == 0,
              flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { flock(fd, LOCK_UN) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record: [String: Any] = [
            "timestamp": formatter.string(from: .now),
            "level": ["failed", "rollback_failed"].contains(stage) ? "error" : "info",
            "event": "mimo_installation",
            "fields": ["attempt": attempt, "operation": operation, "stage": stage, "item": item, "status": status]
        ]
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        line.append(10)
        let size = try handle.seekToEnd()
        if size + UInt64(line.count) > maximumBytes {
            try handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
            let tail = try handle.read(upToCount: 131_072) ?? Data()
            // Discard the first potentially partial record after a bounded seek.
            let retained = tail.firstIndex(of: 10).map { Data(tail.suffix(from: tail.index(after: $0))) } ?? Data()
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: retained)
        }
        try handle.write(contentsOf: line)
        guard fchmod(fd, 0o644) == 0 else { throw POSIXError(.EACCES) }
    }

    static func records(from url: URL = url) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0)
        guard let data = try? handle.read(upToCount: maximumBytes), let text = String(data: data, encoding: .utf8) else { return [] }
        var buffer = EventLogRecordBuffer()
        buffer.append(jsonLines: text)
        return buffer.lines
    }
}
