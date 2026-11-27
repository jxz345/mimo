import CryptoKit
import Foundation

/// Narrow policy evidence from an actual PF readback, separate from progress.
/// It does not renew the older full-guard observation of PF/root attachment.
/// The scope prevents a later inspection start from blessing an older policy.
struct MimoPFHealthReceipt: Codable, Equatable, Sendable {
    let mutationEpoch: String
    let state: String
    let policyDigest: String
    let observedAt: Date
    let completedAt: Date

    static func digest(_ policy: Data) -> String {
        SHA256.hash(data: policy).map { String(format: "%02x", $0) }.joined()
    }

    func matches(epoch: String, state: String, policy: Data, at date: Date) -> Bool {
        !mutationEpoch.isEmpty && mutationEpoch == epoch && self.state == state &&
            policyDigest == Self.digest(policy) && observedAt.timeIntervalSince1970.isFinite &&
            completedAt.timeIntervalSince1970.isFinite && observedAt <= completedAt && completedAt <= date
    }
}
