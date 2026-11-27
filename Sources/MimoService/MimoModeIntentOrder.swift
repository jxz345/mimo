import Foundation

/// Bounded for the core process lifetime. Never evict a live stream: delayed
/// packets must remain obsolete even after the GUI's 75-second RPC deadline.
@MainActor
final class MimoModeIntentOrder {
    enum Admission { case admitted, superseded, capacity }
    private struct Key: Hashable { let uid: UInt32; let stream: UUID }
    private var sequences: [Key: UInt64] = [:]

    /// Call only after authenticating the caller and validating the narrow mode intent.
    func admit(_ intent: MimoModeIntent, uid: UInt32) -> Admission {
        let key = Key(uid: uid, stream: intent.stream)
        if let previous = sequences[key] {
            guard intent.sequence > previous else { return .superseded }
        } else if sequences.count >= 128 { return .capacity }
        sequences[key] = intent.sequence
        return .admitted
    }
}
