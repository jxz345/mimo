import Foundation

/// One inspection owner, with coalesced wakeups after physical transitions.
/// A deferred scan is neither new health evidence nor a recovery event.
@MainActor
final class MimoInfrastructureScheduler {
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private var timer: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var timerID = UUID()
    private var deadline: TimeInterval?
    private var requested = false
    private var stopped = false
    private var deferredCount = 0

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.now = now
        self.sleep = sleep
    }

    func request(reason: String) {
        guard !stopped else { return }
        if !requested {
            RuntimeLog.shared.info("mimo_infrastructure_reconcile_requested", fields: ["reason": reason])
        }
        requested = true
        // Repeated events can shorten a normal wait, never postpone a pending
        // scan or create concurrent checkers. One second bounds the wake rate.
        if waiter != nil, let deadline, now() + 1 < deadline { arm(after: 1) }
    }

    func wait(after outcome: MimoInfrastructureCheckOutcome) async {
        guard !stopped, !Task.isCancelled else { return }
        let delay: TimeInterval
        if outcome == .deferred {
            deferredCount = min(deferredCount + 1, 3)
            delay = [1.0, 2.0, 4.0][deferredCount - 1]
            RuntimeLog.shared.info("mimo_infrastructure_retry_scheduled", fields: [
                "outcome": outcome.rawValue, "delay_seconds": String(requested ? 1 : delay),
                "retry_level": String(deferredCount)
            ])
        } else {
            deferredCount = 0
            delay = 10
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !stopped, !Task.isCancelled else { continuation.resume(); return }
                precondition(waiter == nil)
                waiter = continuation
                arm(after: requested ? 1 : delay)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishWait() }
        }
    }

    func stop() {
        stopped = true
        finishWait()
    }

    private func arm(after delay: TimeInterval) {
        timer?.cancel()
        let id = UUID(); timerID = id
        deadline = now() + delay
        timer = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.timerID == id else { return }
            self.finishWait()
        }
    }

    private func finishWait() {
        timerID = UUID()
        timer?.cancel(); timer = nil
        deadline = nil; requested = false
        let continuation = waiter; waiter = nil
        continuation?.resume()
    }
}
