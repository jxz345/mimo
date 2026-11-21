import Foundation

/// A protected optimistic grant has a real off-actor deadline. It revokes PF
/// permissions before asking the main actor to publish failure/recover. It is
/// cancelled before Direct, so a stale timeout cannot re-block Direct.
final class MimoAuditDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.mimo.audit-deadline", qos: .userInitiated)
    private var pending = true
    private var expired = false

    func grant(_ operation: () throws -> Void, onTimeout: @escaping @Sendable () -> Void) throws {
        try lock.withLock {
            guard pending else { throw CancellationError() }
            try operation()
            queue.asyncAfter(deadline: .now() + 3) { [self] in
                lock.withLock {
                    guard pending else { return }
                    pending = false
                    expired = true
                    onTimeout()
                }
            }
        }
    }

    /// False means the timeout already owns revocation; a late audit cannot
    /// turn that failure into a verified result.
    @discardableResult
    func finish() -> Bool {
        lock.withLock {
            pending = false
            return !expired
        }
    }
}
