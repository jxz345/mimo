import Foundation

/// Monotonic stage timings without addresses, credentials or profile contents.
struct MimoTransitionTiming {
    private let operation: String
    private var previous = ContinuousClock.now

    init(_ operation: String) { self.operation = operation }

    mutating func record(_ stage: String) {
        let now = ContinuousClock.now
        let elapsed = previous.duration(to: now).components
        let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        RuntimeLog.shared.info("mimo_transition_timing", fields: [
            "operation": operation, "stage": stage, "duration_ms": String(milliseconds)
        ])
        previous = now
    }
}
