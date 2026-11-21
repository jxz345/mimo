import XCTest
@testable import MimoShared

final class EventLogRecordBufferTests: XCTestCase {
    private func record(_ event: String, detail: String = "") -> String {
        let value = ["timestamp": "2026-11-21T01:14:00Z", "event": event,
                     "fields": ["detail": detail]] as [String: Any]
        return String(data: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), encoding: .utf8)!
    }

    func testRetainsFullFieldsAndUnknownEventsInOrder() {
        var buffer = EventLogRecordBuffer(limit: 2)
        let first = record("mimo_network_changed", detail: String(repeating: "route detail ", count: 50))
        let second = record("a_new_event", detail: "already <redacted-ip>")
        buffer.append(jsonLines: "truncated record\n" + first + "\n" + second)
        XCTAssertEqual(buffer.lines, [first, second])
        buffer.append(jsonLines: record("third"))
        XCTAssertEqual(buffer.lines, [second, record("third")])
    }

    func testByteLimitBoundsUnicodeAndOversizedRecords() {
        let first = record("first", detail: "🌐🌐🌐")
        let second = record("second")
        var buffer = EventLogRecordBuffer(byteLimit: max(first.utf8.count, second.utf8.count) + 1)
        buffer.append(jsonLines: first + "\n" + second)
        XCTAssertEqual(buffer.lines, [second])
        buffer.append(jsonLines: record("oversized", detail: String(repeating: "x", count: 1000)))
        XCTAssertEqual(buffer.lines, [second])
    }

    func testDiagnosticResponseIsBackwardCompatibleAndPreservesTriggers() throws {
        let old = try JSONDecoder().decode(DaemonResponse.self, from: Data("{\"events\":[\"readable\"]}".utf8))
        XCTAssertNil(old.diagnosticEvents)
        var response = DaemonResponse(events: ["readable"])
        response.diagnosticEvents = [record("mimo_verification_audit_failed", detail: "DNS changed")]
        let decoded = try JSONDecoder().decode(DaemonResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded.diagnosticEvents, response.diagnosticEvents)
    }
}
