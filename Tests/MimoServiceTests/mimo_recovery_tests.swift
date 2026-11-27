import Foundation

@MainActor
enum MimoRecoveryTests {
    static func run() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let service = try DaemonService(storage: FilePreferenceStorage(url: fixtureRoot.appendingPathComponent("fixture.plist")), observeSystem: false)
        var initial = service.state(for: 0)
        initial.revision = 12
        initial.routing = MimoRoutingState()
        initial.routing?.configuration.mode = .global
        initial.routing?.configuration.profileHostingEnabled = false
        var commands: [DaemonCommand] = []
        let authorization = Data("test-authorization".utf8)
        try await MimoDirectRecovery.run(authorization: authorization) { request in
            commands.append(request.command)
            if request.command == .state { return DaemonResponse(state: initial) }
            require(request.command == .configureRouting && request.expectedRevision == 12 && request.authorization == authorization,
                    "recovery must use the sole owner's authorization and revision fencing")
            require(request.routing?.mode == .direct && request.routing?.profileHostingEnabled == false,
                    "recovery must preserve unrelated configuration")
            var changed = initial
            var policy = MimoAccessPolicy()
            policy.directRestored(configuration: request.routing!)
            changed.routing = policy.state
            return DaemonResponse(state: changed)
        }
        require(commands == [.state, .configureRouting], "recovery must never stop either peer or toggle IP monitoring")
        for failure in [DaemonFailure.conflict, .unauthorized] {
            do {
                try await MimoDirectRecovery.run(authorization: authorization) { request in
                    request.command == .state ? DaemonResponse(state: initial) : DaemonResponse(failure: failure)
                }
                require(false, "rejected settings writes must not claim restored networking")
            } catch { }
        }
        do {
            try await MimoDirectRecovery.run(authorization: authorization) { _ in DaemonResponse(state: initial) }
            require(false, "unconfirmed Direct cannot be reported as success")
        } catch { }
        var writes = 0
        do {
            try await MimoDirectRecovery.run(authorization: authorization) { request in
                if request.command == .configureRouting { writes += 1 }
                return DaemonResponse(failure: .unavailable)
            }
            require(false, "missing owner must fail without competing persistence")
        } catch { }
        require(writes == 0, "unavailable state must not issue a settings mutation")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try verifyFirewallContention(at: root)
        try verifyConditionalFirewallMutation(at: root)
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
        print("PASS: Direct recovery uses sole settings owner, preserves service intent and rejects unconfirmed recovery")
    }

    private static func verifyConditionalFirewallMutation(at root: URL) throws {
        let epoch = root.appendingPathComponent("pf-mutation.epoch")
        try Data("stable-audit-snapshot".utf8).write(to: epoch)
        var writes = 0
        for _ in 0..<20 {
            try MimoFirewallLock.mutateIfNeeded(directory: root, when: {
                require(try SingleInstanceLock(url: root.appendingPathComponent("pf-mutation.lock")) == nil,
                        "conditional inspection must hold the mutation lock")
                return false
            }) { writes += 1 }
        }
        require(try String(contentsOf: epoch, encoding: .utf8) == "stable-audit-snapshot" && writes == 0,
                "unchanged blocked transport checks must not invalidate a concurrent health snapshot")
        enum FailedWrite: Error { case injected }
        do {
            try MimoFirewallLock.mutateIfNeeded(directory: root, when: { true }) {
                require(try String(contentsOf: epoch, encoding: .utf8) != "stable-audit-snapshot",
                        "real writes must invalidate the audit snapshot before touching PF")
                require(try SingleInstanceLock(url: root.appendingPathComponent("pf-mutation.lock")) == nil,
                        "commit must retain the same mutation lock")
                throw FailedWrite.injected
            }
            require(false, "the injected write must fail")
        } catch FailedWrite.injected { }
        require(try String(contentsOf: epoch, encoding: .utf8) != "stable-audit-snapshot",
                "a partial/failed write must never restore the old audit identity")
        require(try SingleInstanceLock(url: root.appendingPathComponent("pf-mutation.lock")) != nil,
                "failure must release the mutation lock for recovery")
        print("PASS: unchanged firewall inspections preserve audit identity; writes invalidate before commit and failures release exclusion")
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
