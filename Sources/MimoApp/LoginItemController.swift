import Combine
import Foundation
import ServiceManagement

protocol LoginItemBackend: Sendable {
    func status() -> LoginItemStatus
    func setEnabled(_ enabled: Bool) throws
}

struct SystemLoginItemBackend: LoginItemBackend {
    func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

/// Background Task Management can wait on other system services during login.
/// Keep every GUI status/registration call on one dedicated queue, never in a
/// SwiftUI initializer, view body, activation callback or the main actor.
@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()
    @Published private(set) var status: LoginItemStatus?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    private let backend: any LoginItemBackend
    private let queue = DispatchQueue(label: "app.mimo.login-item", qos: .utility)
    private let store: @MainActor (Bool) -> Void
    private var checkedAt: Date?
    private var pendingSynchronization: Bool??

    init(backend: any LoginItemBackend = SystemLoginItemBackend(), store: @escaping @MainActor (Bool) -> Void = LoginItemSync.store) {
        self.backend = backend
        self.store = store
    }

    func refresh() {
        guard !isBusy, checkedAt.map({ Date.now.timeIntervalSince($0) < 2 }) != true else { return }
        perform(.read)
    }

    func synchronize(stored: Bool?) {
        if isBusy { pendingSynchronization = .some(stored); return }
        perform(.synchronize(stored))
    }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        store(enabled)
        perform(.set(enabled))
    }

    private enum Operation: Sendable { case read, synchronize(Bool?), set(Bool) }
    private struct Result: Sendable {
        var status: LoginItemStatus
        var action: LoginItemAction = .none
        var error: String?
        var before: LoginItemStatus
    }

    private func perform(_ operation: Operation) {
        isBusy = true; errorMessage = nil
        let backend = backend
        let started = Date.now
        queue.async { [weak self] in
            let before = backend.status()
            var result = Result(status: before, before: before)
            do {
                switch operation {
                case .read: break
                case .set(let enabled):
                    result.action = enabled ? .register : .unregister
                    try backend.setEnabled(enabled)
                    result.status = backend.status()
                case .synchronize(let stored):
                    result.action = LoginItemPolicy.action(stored: stored, status: before)
                    if result.action == .register || result.action == .unregister {
                        try backend.setEnabled(result.action == .register)
                        result.status = backend.status()
                    }
                }
            } catch { result.error = error.localizedDescription }
            let finished = result
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.status = finished.status; self.errorMessage = finished.error
                self.checkedAt = .now; self.isBusy = false
                if finished.action == .adopt { self.store(true) }
                if case .synchronize = operation {
                    var fields = ["action": finished.action.rawValue, "status": finished.before.rawValue,
                        "status_after": finished.status.rawValue, "result": finished.error == nil ? "ok" : "failed",
                        "duration_ms": String(Int(max(0, Date.now.timeIntervalSince(started)) * 1_000))]
                    if let error = finished.error { fields["error"] = error }
                    RuntimeLog.shared.info("login_item_synced", fields: fields)
                }
                if let pending = self.pendingSynchronization {
                    self.pendingSynchronization = nil
                    self.synchronize(stored: pending)
                }
            }
        }
    }
}
