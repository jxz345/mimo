import Foundation

/// Legacy process, Security and OperationQueue calls can wait for other dispatch
/// work. They must not occupy Swift's bounded cooperative executor. A persistent
/// serial queue also prevents cancelled provider generations from overlapping.
final class MimoBlockingWorkQueue: @unchecked Sendable {
    private let queue: DispatchQueue

    init(_ label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func run<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value? {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else { continuation.resume(returning: nil); return }
                    let value = operation()
                    continuation.resume(returning: cancellation.isCancelled ? nil : value)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
