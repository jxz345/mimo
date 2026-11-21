import Foundation

/// Read-only event retrieval, also exercised as the ordinary GUI account.
@main
enum SupervisorEvents {
    static func main() async throws {
        var request = DaemonRequest(.supervisor)
        var message = MimoSupervisorRequest(.state)
        message.includeEvents = true
        request.supervisor = message
        let result = try await DaemonRPC.call(request, serviceLabel: MimoRuntime.supervisorLabel)
        guard let events = result.events else { throw DaemonFailure.unavailable }
        print(String(decoding: try JSONEncoder().encode(events), as: UTF8.self))
    }
}
