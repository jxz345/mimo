import Foundation

/// Cancellation is checked under the mutation's lock: the short PF mutation lock for revocation,
/// controllerLock for connection cleanup. Direct/service transitions either
/// follow already-running work or cancel work which has not acquired its lock.
/// A delayed waiter never creates another operation after cancellation.
final class MimoGateRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Event queues can start revocation without scheduling the supervisor actor.
/// The actor later joins this same request; Direct cancels it before replacing PF.
final class MimoApplicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = MimoBlockingWorkQueue("com.mimo.close-gate", qos: .userInitiated)
    private var pending: (token: MimoGateRequest, task: Task<Bool, Error>)?

    func request(replacing: Bool = false,
                 operation: @escaping @Sendable (MimoGateRequest) throws -> Bool) -> MimoGateRequest {
        lock.withLock {
            if let pending {
                if !replacing { return pending.token }
                pending.token.cancel()
                pending.task.cancel()
            }
            let token = MimoGateRequest()
            let queue = self.queue
            let task = Task.detached(priority: .userInitiated) {
                guard let result = await queue.run({ Result { try operation(token) } }) else { throw CancellationError() }
                return try result.get()
            }
            pending = (token, task)
            return token
        }
    }

    func confirm(_ token: MimoGateRequest) async throws -> Bool {
        let task = lock.withLock { pending?.token === token ? pending?.task : nil }
        guard let task else { throw CancellationError() }
        let result = try await task.value
        guard lock.withLock({ pending?.token === token && !token.isCancelled }) else { throw CancellationError() }
        return result
    }

    func cancel() {
        lock.withLock {
            pending?.token.cancel()
            pending?.task.cancel()
            pending = nil
        }
    }
}
