import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Existing user defaults and daemon-owned storage share the same persistence boundary.
public protocol PreferenceStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferenceStorage {}

public extension PreferenceStorage {
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
}

/// A single daemon owns this file. Commit the complete property list by atomic replacement;
/// never expose a partially written budget or a partially applied settings transaction.
public final class FilePreferenceStorage: PreferenceStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var values: [String: Any]
    private var failure: String?

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            self.values = values
        } else {
            values = [:]
        }
    }

    public var lastError: String? { lock.withLock { failure } }
    public func object(forKey key: String) -> Any? { lock.withLock { values[key] } }

    public func set(_ value: Any?, forKey key: String) {
        do { try update([key: value]) } catch { /* Reported through lastError to the service. */ }
    }

    public func removeObject(forKey key: String) { set(nil, forKey: key) }

    public func update(_ changes: [String: Any?]) throws {
        try lock.withLock {
            var next = values
            for (key, value) in changes { next[key] = value }
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: next, format: .binary, options: 0)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try writeAtomically(data)
                values = next
                failure = nil
            } catch {
                failure = error.localizedDescription
                throw error
            }
        }
    }

    private func writeAtomically(_ data: Data) throws {
        // The system daemon must reopen state while the login session is locked.
        // User-session file protection prevents that. Protect both the temporary
        // and committed files with owner-only permissions from their creation;
        // private proxy passwords and the IPinfo token are stored only here.
        var template = Array(url.deletingLastPathComponent().appendingPathComponent(".state-XXXXXX").path.utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = String(cString: template)
        defer { unlink(temporary) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        guard rename(temporary, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
