import XCTest
@testable import MimoShared

/// The full Clash Verge profile the app maintains. Only RFC 5737 addresses and dummy credentials appear
/// here; real proxy details live in the Keychain and the generated 0600 file, never in the repository.
final class ClashVergeProfileTests: XCTestCase {
    private let sample = ClashProxySettings(name: "MP-SG", type: .socks5, server: "192.0.2.10", port: 1080,
                                            username: "user", password: "pa\"ss\\#: x")

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    func testHTTPProxyWithoutAuthOmitsCredentials() throws {
        let settings = ClashProxySettings(name: "Office", type: .http, server: "proxy.example.com", port: 8080)
        let text = try ClashVergeProfile.render(settings)
        let upstream = String(text.components(separatedBy: "proxies:\n")[1].components(separatedBy: "proxy-groups:")[0])
        XCTAssertTrue(upstream.contains("type: http"))
        XCTAssertTrue(upstream.contains("udp: false"))
        XCTAssertFalse(upstream.contains("username:"))
        XCTAssertFalse(upstream.contains("password:"))
    }

    func testValidationRejectsBadInput() {
        func error(_ change: (inout ClashProxySettings) -> Void) -> ClashProxySettings.ValidationError? {
            var settings = sample
            change(&settings)
            do { _ = try settings.validated(); return nil } catch { return error as? ClashProxySettings.ValidationError }
        }
        XCTAssertNil(error { _ in })
        XCTAssertEqual(error { $0.server = "" }, .invalidServer)
        XCTAssertEqual(error { $0.server = "bad host" }, .invalidServer)
        XCTAssertEqual(error { $0.server = "-bad.example.com" }, .invalidServer)
        XCTAssertNil(error { $0.server = "2001:db8::1" })
        XCTAssertNil(error { $0.server = "proxy.example.com" })
        XCTAssertEqual(error { $0.port = 0 }, .invalidPort)
        XCTAssertEqual(error { $0.port = 70000 }, .invalidPort)
        XCTAssertEqual(error { $0.name = "" }, .invalidName)
        XCTAssertEqual(error { $0.name = "a\nb" }, .invalidName)
        XCTAssertEqual(error { $0.name = "Proxy" }, .reservedName("Proxy"))
        XCTAssertEqual(error { $0.name = "TS-DIRECT" }, .reservedName("TS-DIRECT"))
        XCTAssertEqual(error { $0.password = "a\nb" }, .invalidCharacters(field: "Password"))
        XCTAssertEqual(error { $0.username = "a\tb" }, .invalidCharacters(field: "Username"))
        XCTAssertEqual(error { $0.username = "" }, .passwordWithoutUsername)
        XCTAssertThrowsError(try ClashVergeProfile.render(ClashProxySettings(name: "X", type: .socks5, server: "", port: 1)))
    }

    func testValidationTrimsNameAndServer() throws {
        var settings = sample
        settings.name = "  MP-SG "
        settings.server = " 192.0.2.10 "
        XCTAssertEqual(try settings.validated().server, "192.0.2.10")
        XCTAssertTrue(try ClashVergeProfile.render(settings).contains("- name: \"MP-SG\"\n"))
    }

    func testSettingsRoundTripThroughTheKeychainEncoding() throws {
        XCTAssertEqual(ClashVergeProfile.decode(try ClashVergeProfile.encode(sample)), sample)
        XCTAssertNil(ClashVergeProfile.decode("not json"))
    }

    private func temporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clash-profile-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("nested/clash-verge-profile.yaml")
    }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testWriteCreatesAPrivateFileAndRewritesOnlyOnChange() throws {
        let url = temporaryFile()
        XCTAssertEqual(try ClashVergeProfile.write("a: 1\n", to: url), .written)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a: 1\n")
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        XCTAssertEqual(try ClashVergeProfile.write("a: 1\n", to: url), .unchanged)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, inode)
        XCTAssertEqual(try ClashVergeProfile.write("a: 2\n", to: url), .written)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a: 2\n")
        XCTAssertEqual(try mode(url), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["clash-verge-profile.yaml"])
    }

    func testWriteTightensALooseFileThatAlreadyMatches() throws {
        let url = temporaryFile()
        try ClashVergeProfile.write("a: 1\n", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try ClashVergeProfile.write("a: 1\n", to: url), .unchanged)
        XCTAssertEqual(try mode(url), 0o600)
    }

    // MARK: Copy for Clash Verge

    private func copyDate(_ iso: String = "2026-10-24T20:00:00Z") throws -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
        return (try XCTUnwrap(ISO8601DateFormatter().date(from: iso)), calendar)
    }

    private func files(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testCopyIsNamedForClashVergeAndPrivate() throws {
        let source = temporaryFile()
        let text = try ClashVergeProfile.render(sample)
        try ClashVergeProfile.write(text, to: source)
        let (date, calendar) = try copyDate()

        let copy = try ClashVergeProfile.writeCopy(of: source, existingNames: [], date: date, calendar: calendar)
        XCTAssertEqual(copy.lastPathComponent, "Mimo 2026-10-25 (1).yaml")
        XCTAssertEqual(copy.deletingLastPathComponent(), source.deletingLastPathComponent())
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), text)
        XCTAssertEqual(try mode(copy), 0o600)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), text, "The profile file itself is untouched")

        let again = try ClashVergeProfile.writeCopy(of: source, existingNames: ["clash-verge 5.yaml"], date: date, calendar: calendar)
        XCTAssertEqual(again, copy, "Until Clash Verge has the name, Finder shows the same copy")
        XCTAssertEqual(try files(source.deletingLastPathComponent()), ["Mimo 2026-10-25 (1).yaml", "clash-verge-profile.yaml"])
    }

    func testANewCopyMovesPastNamesClashVergeHasAndReplacesTheOldCopy() throws {
        let source = temporaryFile()
        try ClashVergeProfile.write("a: 1\n", to: source)
        let (date, calendar) = try copyDate()
        try ClashVergeProfile.writeCopy(of: source, existingNames: [], date: date, calendar: calendar)

        let dropped = try ClashVergeProfile.writeCopy(of: source, existingNames: ["Mimo 2026-10-25 (1).yaml"],
                                                      date: date, calendar: calendar)
        XCTAssertEqual(dropped.lastPathComponent, "Mimo 2026-10-25 (2).yaml")
        XCTAssertEqual(try files(source.deletingLastPathComponent()), ["Mimo 2026-10-25 (2).yaml", "clash-verge-profile.yaml"],
                       "Only one copy of the credentials is kept")

        let remote = try ClashVergeProfile.writeCopy(of: source, existingNames: ["Mimo 2026-10-25 (1)", "Mimo 2026-10-25 (2).yaml"],
                                                     date: date, calendar: calendar)
        XCTAssertEqual(remote.lastPathComponent, "Mimo 2026-10-25 (3).yaml", "Names without .yaml count too")

        let (tomorrow, _) = try copyDate("2026-10-25T20:00:00Z")
        let next = try ClashVergeProfile.writeCopy(of: source, existingNames: ["Mimo 2026-10-25 (3).yaml"],
                                                   date: tomorrow, calendar: calendar)
        XCTAssertEqual(next.lastPathComponent, "Mimo 2026-10-26 (1).yaml")
        XCTAssertEqual(try files(source.deletingLastPathComponent()), ["Mimo 2026-10-26 (1).yaml", "clash-verge-profile.yaml"])
    }

    func testRemoveCopiesDeletesOnlyCopies() throws {
        let source = temporaryFile()
        try ClashVergeProfile.write("a: 1\n", to: source)
        let directory = source.deletingLastPathComponent()
        let (date, calendar) = try copyDate()
        try ClashVergeProfile.writeCopy(of: source, existingNames: [], date: date, calendar: calendar)
        let unrelated = directory.appendingPathComponent("Mimo notes.yaml")
        try Data().write(to: unrelated)

        try ClashVergeProfile.removeCopies(in: directory)
        XCTAssertEqual(try files(directory), ["Mimo notes.yaml", "clash-verge-profile.yaml"])
        XCTAssertThrowsError(try ClashVergeProfile.writeCopy(of: directory.appendingPathComponent("missing.yaml"),
                                                             existingNames: [], date: date, calendar: calendar))
    }

    func testCopyFileNames() {
        XCTAssertTrue(ClashVergeProfile.isCopyFileName("Mimo 2026-10-25 (1).yaml"))
        XCTAssertTrue(ClashVergeProfile.isCopyFileName("Mimo 2026-10-25 (12).yaml"))
        for name in ["clash-verge-profile.yaml", "Mimo 2026-10-25 (1).yml", "Mimo 2026-10-25.yaml",
                     "Mimo 2026-10-25 (1).yaml.bak", "x Mimo 2026-10-25 (1).yaml", "Mimo notes.yaml"] {
            XCTAssertFalse(ClashVergeProfile.isCopyFileName(name), name)
        }
    }

    func testFileLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClashVergeProfile.fileURL.path, home + "/Library/Application Support/Mimo/clash-verge-profile.yaml")
        XCTAssertEqual(ClashVergeProfile.legacyPartialFileURL.path, home + "/Library/Application Support/Mimo/verge-profile.yaml")
    }
}
