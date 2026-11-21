import Foundation

@MainActor
enum LoginItemControllerTests {
    static func run() async throws {
        let backend = SlowBackend()
        var saved: [Bool] = []
        let controller = LoginItemController(backend: backend, store: { saved.append($0) })
        controller.refresh()
        for _ in 0..<100 where !backend.entered { try await Task.sleep(for: .milliseconds(10)) }
        CredentialAppTests.require(backend.entered && controller.isBusy, "A blocked system call must leave the main actor responsive")
        for _ in 0..<10 { controller.refresh() }
        controller.synchronize(stored: true)
        CredentialAppTests.require(backend.reads == 1, "Redraw/focus callbacks must not create concurrent system requests")
        backend.release.signal()
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        CredentialAppTests.require(controller.status == .enabled && !controller.isBusy, "Startup synchronization must run after a pending read")
        CredentialAppTests.require(backend.changes == [true], "Startup restores only the remembered per-account login choice")
        controller.setEnabled(false)
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        CredentialAppTests.require(controller.status == .notRegistered && saved == [false], "Explicit changes must be stored and read back")
        CredentialAppTests.require(!backend.calledOnMainThread, "No login-item service call may run on the GUI thread")
        print("PASS: blocked login-item service leaves GUI responsive; refresh coalesces; startup and explicit choices serialize and read back off-main")
    }

    private final class SlowBackend: LoginItemBackend, @unchecked Sendable {
        private let lock = NSLock()
        let release = DispatchSemaphore(value: 0)
        private var readCount = 0
        private var mutations: [Bool] = []
        private var main = false
        var reads: Int { lock.withLock { readCount } }
        var entered: Bool { reads > 0 }
        var changes: [Bool] { lock.withLock { mutations } }
        var calledOnMainThread: Bool { lock.withLock { main } }
        func status() -> LoginItemStatus {
            let first = lock.withLock {
                readCount += 1; main = main || Thread.isMainThread
                return readCount == 1
            }
            if first { _ = release.wait(timeout: .now() + 5) }
            return lock.withLock { mutations.last == true ? .enabled : .notRegistered }
        }
        func setEnabled(_ enabled: Bool) throws {
            lock.withLock { mutations.append(enabled); main = main || Thread.isMainThread }
        }
    }
}
