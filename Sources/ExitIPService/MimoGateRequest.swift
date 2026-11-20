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
