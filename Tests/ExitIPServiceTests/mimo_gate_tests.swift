import Foundation

enum MimoGateTests {
    @MainActor
    static func run() async throws {
        let runtime = MimoSystemRuntime()
        let request = runtime.requestApplicationGate()
        guard runtime.requestApplicationGate() === request else {
            fatalError("event and preparation must share the pending close")
        }
        // Reproduce a delayed event waiter after a newer Direct/service action
        // cancelled its request. Confirmation must not create another request.
        runtime.cancelApplicationGate()
        for _ in 0..<2 {
            do {
                try await runtime.confirmApplicationGate(request)
                fatalError("cancelled closure cannot confirm or restart itself")
            } catch is CancellationError { }
        }
        let cleanup = runtime.requestConnectionCleanup()
        runtime.cancelConnectionCleanup()
        for _ in 0..<2 {
            do {
                try await runtime.confirmConnectionCleanup(cleanup)
                fatalError("cancelled cleanup cannot restart itself after Direct/service changes")
            } catch is CancellationError { }
        }
        guard !runtime.closed else { fatalError("cancellation is not confirmed blocking") }
        print("PASS: shared closure identity rejects delayed confirmation after cancellation without restarting PF or controller work")
    }
}
