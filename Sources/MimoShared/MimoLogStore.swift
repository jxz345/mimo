import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct MimoLogLimits: Sendable {
    public var fileBytes: Int
    public var directoryBytes: Int
    public var fileCount: Int

    public init(fileBytes: Int = 5 * 1_024 * 1_024, directoryBytes: Int = 64 * 1_024 * 1_024, fileCount: Int = 128) {
        precondition(fileBytes > 0 && directoryBytes >= fileBytes && fileCount > 0)
        self.fileBytes = fileBytes
        self.directoryBytes = directoryBytes
        self.fileCount = fileCount
    }
}

public struct MimoLogCleanup: Sendable {
    public var rotated = 0
    public var deleted = 0
    public var truncated = 0
    public var bytesRemoved = 0
    public var changed: Bool { rotated + deleted + truncated > 0 }
}

/// Owns only Mimo log names in a non-writable-by-others directory. Call on a
/// utility queue: rotation, pruning and writers share a cross-process flock.
/// Runtime files reopen on every append, so another process may safely evict an
/// old segment. launchd descriptors must instead retain their original inode.
public final class MimoLogStore: @unchecked Sendable {
    public let directory: URL
    private let limits: MimoLogLimits
    private let serviceOutputs: Bool
    private let mutex = NSLock()
    private var currentName: String?
    private var currentDay: Int?
    private var pendingCleanup = MimoLogCleanup()
    private static let outputs: Set<String> = ["core.log", "supervisor.log", "engine.log", "infrastructure.log"]

    public init(directory: URL, serviceOutputs: Bool = false, limits: MimoLogLimits = .init()) throws {
        self.directory = directory.standardizedFileURL
        self.serviceOutputs = serviceOutputs
        self.limits = limits
        guard self.directory.resolvingSymlinksInPath().path == self.directory.path else { throw POSIXError(.EACCES) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try withDirectoryLock { _ in }
    }

    public func append(_ record: Data, now: Date = .now) throws {
        guard !record.isEmpty, record.last == 10, record.count <= limits.fileBytes else { throw POSIXError(.EFBIG) }
        try mutex.withLock {
            try withDirectoryLock { directoryFD in
                let day = Int(floor(now.timeIntervalSince1970 / 86_400))
                let existing = currentName.flatMap { info($0, in: directoryFD) }
                let rotates = currentDay != day || existing == nil || Int(existing!.st_size) + record.count > limits.fileBytes
                let replacesSegment = rotates && currentName != nil
                if rotates {
                    currentName = name(prefix: "runtime", suffix: "jsonl", now: now)
                    currentDay = day
                }
                let fd = try openFile(currentName!, in: directoryFD, flags: O_WRONLY | O_APPEND | O_CREAT)
                defer { close(fd) }
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: record)
                if rotates {
                    var result = MimoLogCleanup()
                    // Size/count enforcement also runs on rotation; age expiry
                    // belongs to the scheduler's current shared preference.
                    try prune(in: directoryFD, cutoff: nil, result: &result)
                    pendingCleanup.rotated += replacesSegment ? 1 : 0
                    pendingCleanup.deleted += result.deleted
                    pendingCleanup.truncated += result.truncated
                    pendingCleanup.bytesRemoved += result.bytesRemoved
                }
            }
        }
    }

    public func maintain(retentionDays: Int = 7, now: Date = .now) throws -> MimoLogCleanup {
        try mutex.withLock {
            try withDirectoryLock { directoryFD in
                let days = [1, 7, 30].contains(retentionDays) ? retentionDays : 7
                let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                var result = pendingCleanup
                if serviceOutputs {
                    for output in Self.outputs.sorted() {
                        guard let value = info(output, in: directoryFD), value.st_size > 0 else { continue }
                        if modified(value) < cutoff {
                            try truncate(output, in: directoryFD, cutoff: cutoff, result: &result)
                        } else if value.st_size > limits.fileBytes {
                            // launchd/engine do not cooperate with our lock. Copy
                            // a bounded tail, then truncate IN PLACE: no restart,
                            // orphaned open descriptor or indefinitely growing .1.
                            let fd = try openFile(output, in: directoryFD, flags: O_RDWR)
                            defer { close(fd) }
                            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                            let size = try handle.seekToEnd()
                            let offset = size > UInt64(limits.fileBytes) ? size - UInt64(limits.fileBytes) : 0
                            try handle.seek(toOffset: offset)
                            var tail = try handle.read(upToCount: limits.fileBytes) ?? Data()
                            if offset > 0 { tail = wholeLines(tail) }
                            if !tail.isEmpty {
                                let archive = name(prefix: "archive-\(output)", suffix: "log", now: now)
                                let target = try openFile(archive, in: directoryFD, flags: O_WRONLY | O_CREAT | O_EXCL)
                                defer { close(target) }
                                try FileHandle(fileDescriptor: target, closeOnDealloc: false).write(contentsOf: tail)
                            }
                            try handle.truncate(atOffset: 0)
                            result.rotated += 1
                            result.bytesRemoved += max(0, Int(size) - tail.count)
                        }
                    }
                    // The journal has its own writer lock and 256-KiB cap.
                    // Never unlink it: an installer may already hold its fd.
                    if let value = info("installation.jsonl", in: directoryFD), modified(value) < cutoff {
                        try truncate("installation.jsonl", in: directoryFD, cutoff: cutoff, result: &result)
                    }
                }
                try prune(in: directoryFD, cutoff: cutoff, result: &result)
                pendingCleanup = MimoLogCleanup()
                return result
            }
        }
    }

    private struct Entry {
        let name: String
        let size: Int
        let modified: Date
        let removable: Bool
        let heartbeat: Bool
    }

    private func prune(in directoryFD: Int32, cutoff: Date?, result: inout MimoLogCleanup) throws {
        var entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).compactMap { name -> Entry? in
            let runtime = name.hasPrefix("runtime-") && name.hasSuffix(".jsonl")
            let archive = Self.outputs.contains { name.hasPrefix("archive-\($0)-") && name.hasSuffix(".log") }
            let heartbeat = name.hasPrefix("launch-") && name.hasSuffix(".json")
            let fixed = serviceOutputs && (Self.outputs.contains(name) || name == "installation.jsonl")
            guard runtime || (serviceOutputs && archive) || heartbeat || fixed,
                  let value = info(name, in: directoryFD) else { return nil }
            return Entry(name: name, size: Int(value.st_size), modified: modified(value), removable: !fixed, heartbeat: heartbeat)
        }
        // Readiness heartbeat files are small, overwritten and removed at clean
        // GUI exit. Only expire stale ones; never evict a live readiness marker.
        if let cutoff {
            for entry in entries where entry.removable && entry.modified < cutoff {
                guard unlinkat(directoryFD, entry.name, 0) == 0 else { throw error() }
                result.deleted += 1; result.bytesRemoved += entry.size
            }
            entries.removeAll { $0.removable && $0.modified < cutoff }
        }
        entries.removeAll(where: { $0.heartbeat })
        // Upgrade an old unbounded runtime file without reading all of it into
        // memory. Retain the newest complete lines within one segment's cap.
        for index in entries.indices where entries[index].removable && entries[index].size > limits.fileBytes {
            let entry = entries[index]
            let fd = try openFile(entry.name, in: directoryFD, flags: O_RDWR)
            defer { close(fd) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.seek(toOffset: UInt64(entry.size - limits.fileBytes))
            let tail = wholeLines(try handle.read(upToCount: limits.fileBytes) ?? Data())
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tail)
            result.truncated += 1; result.bytesRemoved += entry.size - tail.count
            entries[index] = Entry(name: entry.name, size: tail.count, modified: entry.modified, removable: true, heartbeat: false)
        }
        var bytes = entries.reduce(0) { $0 + $1.size }
        var count = entries.count
        // Old complete segments go first, including logs from older versions.
        for entry in entries.filter(\.removable).sorted(by: {
            $0.modified == $1.modified ? $0.name < $1.name : $0.modified < $1.modified
        }) where bytes > limits.directoryBytes || count > limits.fileCount {
            guard unlinkat(directoryFD, entry.name, 0) == 0 else { throw error() }
            bytes -= entry.size; count -= 1
            result.deleted += 1; result.bytesRemoved += entry.size
        }
        // An old version's output alone may exceed the directory budget.
        // In-place truncation preserves every launchd/installer descriptor.
        for entry in entries.filter({ !$0.removable }).sorted(by: { $0.modified < $1.modified }) where bytes > limits.directoryBytes {
            try truncate(entry.name, in: directoryFD, result: &result)
            bytes -= entry.size
        }
    }

    private func truncate(_ name: String, in directoryFD: Int32, cutoff: Date? = nil, result: inout MimoLogCleanup) throws {
        let fd = try openFile(name, in: directoryFD, flags: O_RDWR)
        defer { close(fd) }
        // Journal writers use this same lock. Other output writers do not;
        // bytes arriving during copy/truncate may be lost (documented).
        guard flock(fd, LOCK_EX) == 0 else { throw error() }
        defer { flock(fd, LOCK_UN) }
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw error() }
        if let cutoff, modified(value) >= cutoff { return }
        guard value.st_size > 0 else { return }
        guard ftruncate(fd, 0) == 0 else { throw error() }
        result.truncated += 1; result.bytesRemoved += Int(value.st_size)
    }

    private func name(prefix: String, suffix: String, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        return "\(prefix)-\(stamp)-\(getpid())-\(UUID().uuidString).\(suffix)"
    }

    private func wholeLines(_ data: Data) -> Data {
        guard let first = data.firstIndex(of: 10), let last = data.lastIndex(of: 10), first < last else { return Data() }
        return Data(data[data.index(after: first)...last])
    }

    private func modified(_ value: stat) -> Date {
        #if canImport(Darwin)
        let time = value.st_mtimespec
        #else
        let time = value.st_mtim
        #endif
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }

    private func valid(_ value: stat, directory: Bool = false) -> Bool {
        value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) && value.st_uid == geteuid()
            && value.st_mode & 0o022 == 0 && (directory || value.st_nlink == 1)
    }

    private func info(_ name: String, in directoryFD: Int32) -> stat? {
        var value = stat()
        guard fstatat(directoryFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0, valid(value) else { return nil }
        return value
    }

    private func openFile(_ name: String, in directoryFD: Int32, flags: Int32) throws -> Int32 {
        let options = flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var fd: Int32 = -1
        // Simultaneous first launches create the SAME directory lock. Use an
        // exclusive create, then reopen the winner, instead of racing O_CREAT.
        // A bounded retry handles a just-created directory entry becoming visible.
        for _ in 0..<3 {
            if flags & O_CREAT != 0 && flags & O_EXCL == 0 {
                fd = openat(directoryFD, name, options | O_EXCL, 0o600)
                if fd < 0, errno == EEXIST { fd = openat(directoryFD, name, options & ~O_CREAT, 0o600) }
            } else {
                fd = openat(directoryFD, name, options, 0o600)
            }
            if fd >= 0 || (errno != EINTR && !(errno == ENOENT && flags & O_CREAT != 0)) { break }
        }
        guard fd >= 0 else { throw error("open log") }
        var value = stat()
        guard fstat(fd, &value) == 0, valid(value) else { close(fd); throw POSIXError(.EACCES) }
        return fd
    }

    private func withDirectoryLock<T>(_ body: (Int32) throws -> T) throws -> T {
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw POSIXError(.EACCES) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("open directory") }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, valid(value, directory: true) else { throw POSIXError(.EACCES) }
        let lock = try openFile(".mimo-log.lock", in: fd, flags: O_RDWR | O_CREAT)
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw error("lock directory") }
        defer { flock(lock, LOCK_UN) }
        return try body(fd)
    }

    private func error(_ operation: String = "log storage") -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSLocalizedFailureReasonErrorKey: operation])
    }
}
