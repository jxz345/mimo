import Foundation

/// Follows the native app's connection intent, including Starting while its
/// transport still needs bootstrap access. Failed observations never mean Off.
@MainActor
final class MimoTailnetLifecycle {
    private enum Observation: Sendable { case on, off, unknown }
    private let changed: @MainActor (Bool) async -> Bool
    private let queue = MimoBlockingWorkQueue("com.mimo.tailnet-lifecycle")
    private var task: Task<Void, Never>?

    init(changed: @escaping @MainActor (Bool) async -> Bool) { self.changed = changed }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var previous: Bool?
            while !Task.isCancelled {
                guard let self, let result = await self.queue.run({ Self.observe() }), !Task.isCancelled else { return }
                let enabled: Bool?
                switch result {
                case .on: enabled = true
                case .off: enabled = false
                case .unknown: enabled = nil
                }
                if let enabled, enabled != previous, await self.changed(enabled) { previous = enabled }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    nonisolated private static func observe() -> Observation {
        guard FileManager.default.isExecutableFile(atPath: TailscaleProbe.cli) else { return .off }
        let users = TailscaleProbe.candidateUsers(previousUser: nil)
        guard !users.isEmpty else { return .off }
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        var sawOff = false
        var unknown = false
        for user in users {
            guard ContinuousClock.now < deadline else { return .unknown }
            let result = TailscaleProbe.runAsUser(user, arguments: ["status", "--json"])
            guard result.status == 0, let data = result.text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = value["BackendState"] as? String else { unknown = true; continue }
            switch state {
            case "Starting", "Running": return .on
            case "Stopped", "NeedsLogin", "NeedsMachineAuth", "NoState": sawOff = true
            default: unknown = true
            }
        }
        return sawOff && !unknown ? .off : .unknown
    }
}
