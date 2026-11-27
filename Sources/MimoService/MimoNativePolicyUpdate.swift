import Foundation

/// Logical revocation is immediate; the serial worker still joins physical PF
/// work before a replacement path can finish. No mutable actor state crosses it.
final class MimoNativePolicyOwner: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

struct MimoNativePolicyScope: Equatable, Sendable {
    let state: String
    let mutationEpoch: String
    let closeEpoch: String
    let expectedRules: String
}

struct MimoNativePolicyPreparation: Sendable {
    let scope: MimoNativePolicyScope
    let native: MimoNativeEgress
    let rules: String
    let interfaces: [String]
}

struct MimoNativePolicyCommit: Sendable {
    let health: MimoPFHealthReceipt
    let readback: String
}
