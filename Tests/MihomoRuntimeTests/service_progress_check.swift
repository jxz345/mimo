import Foundation

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String] = []
    func receive(_ response: DaemonResponse) {
        guard let routing = response.routing else { return }
        lock.withLock { phases.append(routing.phase.rawValue) }
    }
    var observed: [String] { lock.withLock { phases } }
}

@main
enum ServiceProgressCheck {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, let service = MimoServiceID(rawValue: args[0]),
              let operation = MimoServiceOperation(rawValue: args[1]) else { throw DaemonFailure.invalidRequest }
        var message = MimoSupervisorRequest(.service); message.service = service; message.operation = operation
        var request = DaemonRequest(.supervisor); request.supervisor = message
        let progress = Progress()
        var phase: String?, failure: String?
        do {
            let response = try await DaemonRPC.call(request, timeout: 40, serviceLabel: MimoRuntime.supervisorLabel,
                                                    progress: progress.receive)
            phase = response.routing?.phase.rawValue
        } catch let error as DaemonFailure { failure = error.rawValue }
        let result: [String: Any] = ["progressBeforeReply": progress.observed, "finalPhase": phase ?? "",
                                    "failure": failure ?? ""]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }
}
