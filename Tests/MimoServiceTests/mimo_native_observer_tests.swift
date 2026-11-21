import Foundation

enum MimoNativeObserverTests {
    private final class PreparationProbe: @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var started = false
        private var applied: String?
        var isStarted: Bool { lock.withLock { started } }
        var appliedInterface: String? { lock.withLock { applied } }
        func apply(_ value: MimoNativeTransport) { lock.withLock { applied = value.interface } }
        func check() -> TailscaleProbe.Result {
            lock.withLock { started = true }
            _ = release.wait(timeout: .now() + 5)
            return .init(status: .init(served: .direct(interface: "utun8"), checkedAt: .now), user: 501, address: "100.64.1.2")
        }
    }

    @MainActor static func preparation() async throws {
        for stopDuringProbe in [false, true] {
            let fixture = PreparationProbe()
            let observer = MimoNativeTransportObserver(changed: { fixture.apply($0) }, probe: { value, _ in
                guard case .direct(let interface) = value?.status.served else { return .init() }
                return .init(interface: interface)
            }, interfaceProbe: { _ in fixture.check() })
            observer.start(tailnetEnabled: false, discoverInfrastructure: false)
            let preparation = Task { try await observer.prepareForProfile(tailnetEnabled: true) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !fixture.isStarted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            require(fixture.isStarted && fixture.appliedInterface == nil,
                    "profile preparation must request and wait for a fresh interface observation")
            if stopDuringProbe { observer.stop() }
            fixture.release.signal()
            if stopDuringProbe {
                do { _ = try await preparation.value; fatalError("stopped observation must not prepare a profile") }
                catch is CancellationError { }
                require(fixture.appliedInterface == nil, "late preparation cannot republish a stopped provider")
            } else {
                let result = try await preparation.value
                require(result.interface == "utun8" && fixture.appliedInterface == "utun8",
                        "profile preparation must return only after applying the fresh firewall/provider observation")
                observer.stop()
            }
        }
        let session = MimoNativeObservationSession()
        let now = Date()
        session.observed(.init(status: .init(served: .direct(interface: "utun8"), checkedAt: now), user: 501))
        session.observed(.init(status: .init(served: .direct(interface: "utun7"), checkedAt: now.addingTimeInterval(-1)), user: 501))
        require(session.snapshot().0?.status.served == .direct(interface: "utun8"),
                "a delayed periodic probe cannot overwrite the profile's fresher native observation")
        print("PASS: profile preparation joins fresh native firewall/provider publication and fences stopped or stale observations")
    }
    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    @MainActor static func run() {
        let progress = DispatchSemaphore(value: 0)
        let observer = MimoNativeTransportObserver(changed: { value in
            if value.interface == "utun8" { progress.signal() }
        }, probe: { _, _ in MimoNativeTransport(interface: "utun8") })
        observer.start(tailnetEnabled: false, discoverInfrastructure: false)
        // Deliberately block the main actor, as profile/controller work can.
        // The socket/PF path must continue to run and deliver fresh observations.
        require(progress.wait(timeout: .now() + 3) == .success, "native enforcement must run independently of the main actor")
        require(progress.wait(timeout: .now() + 3) == .success, "native enforcement must keep polling while the main actor waits")
        observer.stop()

        let session = MimoNativeObservationSession()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.apply(.init(interface: "utun8")) { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        require(entered.wait(timeout: .now() + 3) == .success, "probe must enter application")
        DispatchQueue.global().async { session.stop { _ in stopped.signal() } }
        require(stopped.wait(timeout: .now() + 0.1) == .timedOut, "Stop must serialize after an in-flight rule update")
        release.signal()
        require(stopped.wait(timeout: .now() + 3) == .success, "Stop must clear rules after the previous update completes")
        require(!session.apply(.init(interface: "utun8")) { _ in fatalError("a stopped session reinstalled stale rules") },
                "late observations must be rejected after Stop")

        let infrastructure = MimoNativeInfrastructureObservations()
        let previous = MimoNativeObservationSession(infrastructure: infrastructure)
        previous.infrastructure(["192.0.2.8"])
        previous.stop { _ in }
        let restarted = MimoNativeObservationSession(infrastructure: infrastructure)
        require(restarted.snapshot().1 == ["192.0.2.8"], "provider restart must retain unexpired authenticated control endpoints")
        previous.infrastructure(["192.0.2.9"])
        require(restarted.snapshot().1 == ["192.0.2.8"], "cancelled discovery must not update the new session")

        let now = Date(timeIntervalSince1970: 1000)
        var observation = TailscaleProbe.Result(status: .init(served: .direct(interface: "utun8"), checkedAt: now),
                                              user: 501, address: "100.64.1.2")
        require(MimoNativeTransportProbe.eligibleInterface(observation, at: now.addingTimeInterval(4.9))?.0 == "utun8", "fresh verified interface must be eligible for live route/address checks")
        require(MimoNativeTransportProbe.eligibleInterface(observation, at: now.addingTimeInterval(5)) == nil, "interface lease must expire without a fresh native CLI result")
        require(MimoNativeTransportProbe.eligibleInterface(observation, at: now.addingTimeInterval(-1)) == nil, "future observations must not grant an interface")
        observation.address = "203.0.113.9"
        require(MimoNativeTransportProbe.eligibleInterface(observation, at: now) == nil, "only native tailnet addresses can own the interface lease")
        print("PASS: native enforcement progresses while the main actor is blocked; Stop fences late updates and interface leases expire")
    }
}
