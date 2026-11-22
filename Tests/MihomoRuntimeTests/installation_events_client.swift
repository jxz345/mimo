import Foundation

/// Read-only installed-core client used by install_reactivation_test.py under
/// two OS accounts. Compile with the MimoShared sources.
@main enum InstallationEventsClient {
    static func main() async throws {
        let response = try await DaemonRPC.call(DaemonRequest(.events), timeout: 5)
        let events = (response.diagnosticEvents ?? []).compactMap { row -> [String: Any]? in
            guard let data = row.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["event"] as? String == "mimo_installation" else { return nil }
            return value
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]), as: UTF8.self))
    }
}
