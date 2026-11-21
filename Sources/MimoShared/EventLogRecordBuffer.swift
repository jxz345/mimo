import Foundation

/// Bounded copies of already-redacted JSON records for diagnostic export. Unlike
/// the readable Event Log, this retains event names and every recorded field.
public struct EventLogRecordBuffer: Sendable {
    public private(set) var lines: [String] = []
    private var bytes = 0
    private let limit: Int
    private let byteLimit: Int

    public init(limit: Int = 500, byteLimit: Int = 262_144) {
        self.limit = limit
        self.byteLimit = byteLimit
    }

    public mutating func append(jsonLines: String) {
        for row in jsonLines.split(separator: "\n") {
            let line = String(row)
            let size = line.utf8.count + 1
            guard limit > 0, size <= byteLimit,
                  let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["timestamp"] is String, record["event"] is String,
                  record["fields"] is [String: String] else { continue }
            lines.append(line)
            bytes += size
            while lines.count > limit || bytes > byteLimit {
                bytes -= lines.removeFirst().utf8.count + 1
            }
        }
    }
}
