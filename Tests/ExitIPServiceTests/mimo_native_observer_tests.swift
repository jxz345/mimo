import Foundation

enum MimoNativeObserverTests {
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
