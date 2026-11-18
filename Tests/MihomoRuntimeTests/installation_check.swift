import Foundation

@main
enum InstallationCheck {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["core-state"] {
            let response = try await DaemonRPC.call(DaemonRequest(.state), timeout: 10)
            guard let state = response.state else { throw response.failure ?? DaemonFailure.unavailable }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(state), as: UTF8.self))
            return
        }
        var message = MimoSupervisorRequest(.state)
        if arguments.count == 2, let service = MimoServiceID(rawValue: arguments[0]),
           let operation = MimoServiceOperation(rawValue: arguments[1]) {
            message = MimoSupervisorRequest(.service)
            message.service = service
            message.operation = operation
        } else if arguments == ["direct"] {
            message = MimoSupervisorRequest(.direct)
        } else if arguments == ["unqualified-rule"] {
            message = MimoSupervisorRequest(.prepare)
            var configuration = MimoConfiguration()
            configuration.mode = .rule
            configuration.proxy = MimoProxy(ClashProxySettings(name: "Installation fixture", type: .http,
                                                               server: "127.0.0.1", port: 9))
            message.configuration = configuration
            message.allowlist = AllowedIPList(addresses: ["203.0.113.1"])
            message.revision = 0
            message.networkGeneration = 0
        } else if !arguments.isEmpty {
            fatalError("Usage: installation-check [core-state | SERVICE start|stop|restart | direct | unqualified-rule]")
        }
        var request = DaemonRequest(.supervisor)
        request.supervisor = message
        let response = try await DaemonRPC.call(request, timeout: 20, serviceLabel: MimoRuntime.supervisorLabel)
        guard response.failure == nil, let state = response.routing else { throw response.failure ?? DaemonFailure.unavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(state), as: UTF8.self))
    }
}
