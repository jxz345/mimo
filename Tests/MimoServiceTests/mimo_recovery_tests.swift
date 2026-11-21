import Foundation

@MainActor
enum MimoRecoveryTests {
    static func run() async throws {
        for enabled in [true, false] {
            var events: [String] = []
            var persisted = false
            try await MimoDirectRecovery.run(coreWasEnabled: enabled, send: { message in
                if message.command == .service {
                    events.append(message.operation!.rawValue)
                    var state = MimoRoutingState()
                    state.services = [.init(id: .core, health: message.operation == .stop ? .stopped : .running, transport: "XPC")]
                    return state
                }
                require(persisted, "Direct must be committed before opening access")
                events.append("direct")
                var policy = MimoAccessPolicy()
                policy.directRestored(configuration: message.configuration!)
                return policy.state
            }, persist: {
                events.append("persist"); persisted = true
                return MimoConfiguration()
            })
            require(events == (enabled ? ["stop", "persist", "direct", "start"] : ["stop", "persist", "direct"]),
                    "recovery must preserve prior stopped-core intent")
        }

        var sentDirect = false
        do {
            try await MimoDirectRecovery.run(coreWasEnabled: true, send: { message in
                sentDirect = message.command == .direct
                var state = MimoRoutingState()
                state.services = [.init(id: .core, health: .stopped, transport: "XPC")]
                return state
            }, persist: { throw CocoaError(.fileWriteNoPermission) })
            require(false, "failed persistence must abort recovery")
        } catch { }
        require(!sentDirect, "failed persistence must not open traffic or restart core")

        var attemptedPersistence = false
        do {
            try await MimoDirectRecovery.run(coreWasEnabled: true, send: { _ in
                var state = MimoRoutingState()
                state.services = [.init(id: .core, health: .running, transport: "XPC")]
                return state
            }, persist: { attemptedPersistence = true; return MimoConfiguration() })
            require(false, "recovery must fail when core has not stopped")
        } catch { }
        require(!attemptedPersistence, "recovery must not write settings while core still owns them")

        var attemptedRestart = false
        do {
            try await MimoDirectRecovery.run(coreWasEnabled: true, send: { message in
                if message.operation == .start { attemptedRestart = true }
                var state = MimoRoutingState()
                state.services = [.init(id: .core, health: .stopped, transport: "XPC")]
                return state
            }, persist: { MimoConfiguration() })
            require(false, "recovery must fail if the gate cannot confirm Direct")
        } catch { }
        require(!attemptedRestart, "an unconfirmed Direct transition must not restart core")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try verifyFirewallContention(at: root)
        let url = root.appendingPathComponent("state.plist")
        let storage = try FilePreferenceStorage(url: url)
        var original = MimoConfiguration()
        original.mode = .global
        original.proxy = MimoProxy(ClashProxySettings(name: "Retained", type: .http, server: "127.0.0.1", port: 8080))
        try storage.update(["service.routing": try JSONEncoder().encode(original), "service.revision": 12, "quota-fixture": 42])
        let direct = try MimoRecoveryState.commitDirect(storage: storage)
        require(direct.mode == .direct && direct.proxy == original.proxy, "recovery must preserve proxy metadata")
        let restored = try FilePreferenceStorage(url: url)
        let saved = try JSONDecoder().decode(MimoConfiguration.self, from: restored.data(forKey: "service.routing")!)
        require(saved.mode == .direct && restored.integer(forKey: "service.revision") == 13,
                "Direct and its new revision must survive storage reload")
        require(restored.integer(forKey: "quota-fixture") == 42, "recovery must retain unrelated settings and quota data")
        print("PASS: emergency Direct recovery persists mode/revision before opening access and preserves stopped-core intent")
    }

    private static func verifyFirewallContention(at root: URL) throws {
        let firewallURL = root.appendingPathComponent("firewall.lock")
        let held = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let lock = try! SingleInstanceLock(url: firewallURL)!
            held.signal()
            Thread.sleep(forTimeInterval: 0.2)
            withExtendedLifetime(lock) {}
            released.signal()
        }
        require(held.wait(timeout: .now() + 2) == .success, "contention fixture must hold the lock")
        let start = ContinuousClock.now
        let acquired = try MimoFirewallLock.acquire(at: firewallURL, timeout: .seconds(2))
        require(start.duration(to: .now) >= .milliseconds(100), "maintenance must wait for the existing firewall operation")
        withExtendedLifetime(acquired) {
            do {
                _ = try MimoFirewallLock.acquire(at: firewallURL, timeout: .milliseconds(100))
                require(false, "a sustained lock must time out without bypassing exclusion")
            } catch { }
        }
        require(released.wait(timeout: .now() + 2) == .success, "contention fixture must release its lock")
        print("PASS: firewall maintenance waits for contention and times out without bypassing the lock")
    }

    private static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
}
