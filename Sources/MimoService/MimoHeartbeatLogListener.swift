import Foundation

/// Read-only diagnostics; the heartbeat has no settings, credentials or network API.
final class MimoHeartbeatLogListener: NSObject, NSXPCListenerDelegate, MimoDaemonProtocol, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MimoDaemonProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func request(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard data.count <= MimoService.maximumMessageSize,
              let request = try? JSONDecoder().decode(DaemonRequest.self, from: data),
              request.protocolVersion == MimoService.protocolVersion, request.command == .events else {
            reply((try? JSONEncoder().encode(DaemonResponse(failure: .invalidRequest))) ?? Data()); return
        }
        var response = DaemonResponse(events: RuntimeLog.shared.recentLines())
        response.diagnosticEvents = RuntimeLog.shared.recentDiagnosticRecords()
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }
}
