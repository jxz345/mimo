import Foundation
import XCTest
@testable import MimoShared
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class MimoLogStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func put(_ name: String, _ text: String, ageDays: Double = 0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600,
            .modificationDate: Date.now.addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: url.path)
        return url
    }
    private func files(_ prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
    private func size(_ url: URL) throws -> Int { try Data(contentsOf: url).count }

    func testRuntimeRotatesBySizeWithoutLosingWholeRecords() throws {
        let store = try MimoLogStore(directory: directory, limits: .init(fileBytes: 100, directoryBytes: 10_000))
        for i in 0..<80 { try store.append(Data("{\"i\":\(i)}\n".utf8)) }
        let segments = try files("runtime-")
        XCTAssertGreaterThan(segments.count, 1)
        var ids = Set<Int>()
        for file in segments {
            XCTAssertLessThanOrEqual(try size(file), 100)
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                ids.insert((try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Int])["i"]!)
            }
        }
        XCTAssertEqual(ids, Set(0..<80))
    }

    func testRuntimeRotatesAtUTCDayBoundaryAndAfterAnotherWriterEvictsIt() throws {
        let store = try MimoLogStore(directory: directory)
        let day = Date(timeIntervalSince1970: 2_000_000_000 / 86_400 * 86_400)
        try store.append(Data("first\n".utf8), now: day)
        try store.append(Data("second\n".utf8), now: day.addingTimeInterval(86_400))
        XCTAssertEqual(try files("runtime-").count, 2)
        for file in try files("runtime-") { try FileManager.default.removeItem(at: file) }
        try store.append(Data("third\n".utf8), now: day.addingTimeInterval(86_400))
        XCTAssertEqual(try files("runtime-").count, 1)
        XCTAssertEqual(try String(contentsOf: files("runtime-")[0], encoding: .utf8), "third\n")
    }

    func testRetentionExpiresOnlyManagedOldFilesAndHonorsThirtyDays() throws {
        let old = try put("runtime-old.jsonl", "old\n", ageDays: 8)
        let launch = try put("launch-123.json", "{}", ageDays: 8)
        let unrelated = try put("notes.txt", "keep", ageDays: 40)
        let current = try put("runtime-recent.jsonl", "recent\n")
        let store = try MimoLogStore(directory: directory)
        XCTAssertFalse(try store.maintain(retentionDays: 30).changed)
        XCTAssertEqual(try store.maintain(retentionDays: 7).deleted, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testDiskBudgetEvictsOldestSegmentsAndLeavesLiveHeartbeat() throws {
        let old = try put("runtime-old.jsonl", String(repeating: "o", count: 90), ageDays: 2)
        _ = try put("runtime-middle.jsonl", String(repeating: "m", count: 90), ageDays: 1)
        _ = try put("runtime-new.jsonl", String(repeating: "n", count: 90))
        let marker = try put("launch-1.json", "{}")
        let store = try MimoLogStore(directory: directory, limits: .init(fileBytes: 100, directoryBytes: 200))
        XCTAssertEqual(try store.maintain().deleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertLessThanOrEqual(try files("runtime-").reduce(0) { try $0 + size($1) }, 200)
    }

    func testManySmallFilesAlsoHaveACountLimit() throws {
        for i in 0..<20 { _ = try put("runtime-\(i).jsonl", "a\n") }
        let store = try MimoLogStore(directory: directory, limits: .init(fileBytes: 100, directoryBytes: 10_000, fileCount: 4))
        XCTAssertEqual(try store.maintain().deleted, 16)
        XCTAssertEqual(try files("runtime-").count, 4)
    }

    func testExistingOversizedRuntimeKeepsNewestCompleteRecords() throws {
        let file = try put("runtime-legacy.jsonl", (0..<100).map { "{\"i\":\($0)}\n" }.joined() + "{\"partial\":")
        let store = try MimoLogStore(directory: directory, limits: .init(fileBytes: 100, directoryBytes: 1_000))
        XCTAssertEqual(try store.maintain().truncated, 1)
        XCTAssertLessThanOrEqual(try size(file), 100)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.last, "{\"i\":99}")
        for line in lines { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8))) }
    }

    func testServiceRotationKeepsOpenDescriptorAndContinuesWriting() throws {
        let file = try put("engine.log", String(repeating: "engine record\n", count: 40))
        let fd = open(file.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var before = stat(); XCTAssertEqual(fstat(fd, &before), 0)
        let store = try MimoLogStore(directory: directory, serviceOutputs: true,
                                     limits: .init(fileBytes: 100, directoryBytes: 1_000))
        XCTAssertEqual(try store.maintain().rotated, 1)
        var after = stat(); XCTAssertEqual(lstat(file.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data("after rotation\n".utf8))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after rotation\n")
        let archives = try files("archive-engine.log-")
        XCTAssertEqual(archives.count, 1)
        XCTAssertLessThanOrEqual(try size(archives[0]), 100)
    }

    func testExpiredServiceAndJournalContentsClearWithoutUnlinking() throws {
        let output = try put("core.log", "old output\n", ageDays: 8)
        let journal = try put("installation.jsonl", "old installation\n", ageDays: 8)
        let store = try MimoLogStore(directory: directory, serviceOutputs: true)
        XCTAssertEqual(try store.maintain().truncated, 2)
        XCTAssertEqual(try size(output), 0); XCTAssertEqual(try size(journal), 0)
    }

    func testUserStoreDoesNotManageMachineOutputNames() throws {
        let output = try put("core.log", "old output\n", ageDays: 8)
        let store = try MimoLogStore(directory: directory)
        XCTAssertFalse(try store.maintain().changed)
        XCTAssertGreaterThan(try size(output), 0)
    }

    func testRejectsUnsafeDirectoryAndIgnoresSymlinkAndHardlinkFiles() throws {
        let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("untouched\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("runtime-link.jsonl"), withDestinationURL: outside)
        try FileManager.default.linkItem(at: outside, to: directory.appendingPathComponent("runtime-hardlink.jsonl"))
        let store = try MimoLogStore(directory: directory)
        _ = try store.maintain(now: Date.now.addingTimeInterval(40 * 86_400))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched\n")
        let directoryLink = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
        XCTAssertThrowsError(try MimoLogStore(directory: directoryLink))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try MimoLogStore(directory: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func testRefusesSubstitutedLockAndOversizedRecord() throws {
        let target = try put("outside.txt", "keep")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(".mimo-log.lock"), withDestinationURL: target)
        XCTAssertThrowsError(try MimoLogStore(directory: directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".mimo-log.lock"))
        let store = try MimoLogStore(directory: directory, limits: .init(fileBytes: 10, directoryBytes: 100))
        XCTAssertThrowsError(try store.append(Data("too long record\n".utf8)))
        XCTAssertEqual(try files("runtime-").count, 0)
    }
}
