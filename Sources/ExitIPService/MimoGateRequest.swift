import Foundation

/// Cancellation is checked while holding firewall.lock. A later Direct/service
/// transition either follows a running close under that lock or cancels a close
/// which has not acquired it yet. No late worker can overwrite Direct.
final class MimoGateRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
