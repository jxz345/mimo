#if os(macOS)
import Foundation

@objc(MimoDaemonProtocol) public protocol MimoDaemonProtocol {
    func request(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

@objc(MimoDaemonObserver) public protocol MimoDaemonObserver {
    func changed(_ data: Data)
}

/// Exactly-once completion handles the reply, timeout and XPC invalidation racing each other.
private final class RPCCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DaemonResponse, any Error>?
    init(_ continuation: CheckedContinuation<DaemonResponse, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<DaemonResponse, any Error>) {
        let continuation = lock.withLock { let result = self.continuation; self.continuation = nil; return result }
        continuation?.resume(with: result)
    }
}

private final class RPCProgressObserver: NSObject, MimoDaemonObserver, @unchecked Sendable {
    let receive: @Sendable (DaemonResponse) -> Void
    init(_ receive: @escaping @Sendable (DaemonResponse) -> Void) { self.receive = receive }
    func changed(_ data: Data) {
        guard data.count <= MimoService.maximumMessageSize,
              let response = try? JSONDecoder().decode(DaemonResponse.self, from: data) else { return }
        receive(response)
    }
}

public enum DaemonRPC {
    public static func call(_ request: DaemonRequest, timeout: TimeInterval = 8, serviceLabel: String = MimoService.label,
                            returningFailures: Bool = false,
                            progress: (@Sendable (DaemonResponse) -> Void)? = nil) async throws -> DaemonResponse {
        guard [MimoService.label, MimoRuntime.supervisorLabel,
               MimoService.controlLabel, MimoService.supervisorControlLabel].contains(serviceLabel) else { throw DaemonFailure.invalidRequest }
        let connection = NSXPCConnection(machServiceName: serviceLabel, options: .privileged)
        return try await call(request, connection: connection, timeout: timeout, returningFailures: returningFailures, progress: progress)
    }

    // An anonymous listener can exercise the real transport in tests without registering a service.
    static func call(_ request: DaemonRequest, connection: NSXPCConnection, timeout: TimeInterval = 8,
                     returningFailures: Bool = false,
                     progress: (@Sendable (DaemonResponse) -> Void)? = nil) async throws -> DaemonResponse {
        var request = request
        request.reportsProgress = progress != nil
        let data = try JSONEncoder().encode(request)
        guard data.count <= MimoService.maximumMessageSize else { throw DaemonFailure.invalidRequest }
        connection.remoteObjectInterface = NSXPCInterface(with: MimoDaemonProtocol.self)
        if let progress {
            connection.exportedInterface = NSXPCInterface(with: MimoDaemonObserver.self)
            connection.exportedObject = RPCProgressObserver(progress)
        }
        defer { connection.invalidate() }
        let response: DaemonResponse = try await withCheckedThrowingContinuation { continuation in
            let completion = RPCCompletion(continuation)
            connection.invalidationHandler = { completion.finish(.failure(DaemonFailure.unavailable)) }
            connection.interruptionHandler = { completion.finish(.failure(DaemonFailure.unavailable)) }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                completion.finish(.failure(DaemonFailure.unavailable))
            }) as? MimoDaemonProtocol else {
                completion.finish(.failure(DaemonFailure.unavailable))
                return
            }
            proxy.request(data) { data in
                guard data.count <= MimoService.maximumMessageSize else {
                    completion.finish(.failure(DaemonFailure.invalidRequest)); return
                }
                completion.finish(Result { try JSONDecoder().decode(DaemonResponse.self, from: data) })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                completion.finish(.failure(DaemonFailure.unavailable))
            }
        }
        if let failure = response.failure, !returningFailures { throw failure }
        if let state = response.state, state.protocolVersion != MimoService.protocolVersion { throw DaemonFailure.incompatible }
        return response
    }
}

/// The UI subscribes for immediate changes. Reconnection is owned by its lifecycle controller.
public enum DaemonConnectionEvent: Sendable {
    case state(DaemonState)
    case failed(DaemonFailure)
}

public final class DaemonSubscription: NSObject, MimoDaemonObserver, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let receive: @Sendable (DaemonConnectionEvent) -> Void
    public init(receive: @escaping @Sendable (DaemonConnectionEvent) -> Void) {
        self.receive = receive
        connection = NSXPCConnection(machServiceName: MimoService.label, options: .privileged)
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: MimoDaemonProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: MimoDaemonObserver.self)
        connection.exportedObject = self
        connection.invalidationHandler = { receive(.failed(.unavailable)) }
        connection.interruptionHandler = { receive(.failed(.unavailable)) }
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in receive(.failed(.unavailable)) } as? MimoDaemonProtocol
        if let data = try? JSONEncoder().encode(DaemonRequest(.subscribe)) {
            proxy?.request(data) { data in
                let response = try? JSONDecoder().decode(DaemonResponse.self, from: data)
                if let failure = response?.failure { receive(.failed(failure)) }
                else if let state = response?.state {
                    receive(state.protocolVersion == MimoService.protocolVersion ? .state(state) : .failed(.incompatible))
                }
                else { receive(.failed(.unavailable)) }
            }
        }
    }
    public func changed(_ data: Data) {
        guard data.count <= MimoService.maximumMessageSize,
              let state = try? JSONDecoder().decode(DaemonState.self, from: data) else { receive(.failed(.unavailable)); return }
        guard state.protocolVersion == MimoService.protocolVersion else { receive(.failed(.incompatible)); return }
        receive(.state(state))
    }
    public func invalidate() { connection.invalidate() }
}
#endif
