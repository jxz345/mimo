import Foundation
import Security

@main
struct ServiceTests {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--cycle-regression") {
            try await MimoCycleTests.run()
            try MimoPowerTests.run()
            return
        }
        if CommandLine.arguments.contains("--profile-preparation") {
            MimoTailnetNetworkTests.run()
            MimoNativeObserverTests.run()
            try await MimoNativeObserverTests.preparation()
            try await MimoCoordinatorTests.run()
            return
        }
        MimoTailnetNetworkTests.run()
        MimoCommandFenceTests.run()
        try MimoPowerTests.run()
        try await MimoGateTests.run()
        MimoNativeObserverTests.run()
        try await MimoNativeObserverTests.preparation()
        try await MimoRecoveryTests.run()
        let boot = UUID().uuidString
        let reference = MimoPFReference(token: "12345", boot: boot)
        require(try reference.token(forBoot: boot) == "12345", "same-boot PF references remain usable")
        require(try reference.token(forBoot: UUID().uuidString) == nil, "PF references cannot survive kernel reboot")
        let references = "TOKENS:\nPID Process Name TOKEN TIMESTAMP\n12345 pfctl 67890 0 days\n7 pfctl 12345 0 days\n"
        require(MimoPFReference.isLive("12345", references: references), "live PF ownership is recognized")
        require(!MimoPFReference.isLive("12345", references: "TOKENS:\n12345 pfctl 67890 0 days\n"),
                "a PID or stale same-boot token cannot establish PF ownership")
        require(!MimoPFReference.isLive("12345", references: "TOKENS:\n"), "PF disable clears ownership within a boot")
        for invalid in ["", "-1", "１２", "123;anything"] {
            do {
                _ = try MimoPFReference(token: invalid, boot: boot).token(forBoot: boot)
                require(false, "malformed PF references must be rejected")
            } catch { }
        }
        try await MimoCoordinatorTests.run()
        let tokenQuery = try SystemCredentials().query(account: SecureTokenStore.ipinfoLiteAccount)
        let proxyQuery = try SystemCredentials().query(account: MimoRuntime.proxyPasswordAccount)
        require(tokenQuery[kSecAttrAccount as String] as? String == SecureTokenStore.ipinfoLiteAccount,
                "IPinfo queries must select the IPinfo account")
        require(proxyQuery[kSecAttrAccount as String] as? String == MimoRuntime.proxyPasswordAccount,
                "proxy queries must not select the IPinfo account")
        require(proxyQuery[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String,
                "machine credential queries must never prompt in a login session")
        let access = try SystemCredentials.ownerAccess()
        var owner: uid_t = 0, group: gid_t = 0, type: SecAccessOwnerType = 0
        var acl: CFArray?
        require(SecAccessCopyOwnerAndACL(access, &owner, &group, &type, &acl) == errSecSuccess,
                "credential access policy must be inspectable")
        require(owner == getuid() && type == UInt32(kSecUseOnlyUID), "credential ACL must restrict access to the daemon's UID")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try FilePreferenceStorage(url: directory.appendingPathComponent("state.plist"))
        let client = RecordingLookup()
        let credentials = MemorySystemCredentials()
        let service = try DaemonService(storage: storage, observeSystem: false, credentials: credentials, client: client,
                                        authorize: { $0 == Data("authorized".utf8) })
        require(!service.state(for: 501).initialized, "new service must await explicit initialization")
        require(await client.count == 0, "uninitialized service must not spend quota")
        var initialize = DaemonRequest(.initialize)
        initialize.expectedRevision = 0
        initialize.settings = MachineSettings(preferences: .init(provider: .ipinfoLite, providerPool: [.ipinfoLite]))
        require(await service.handle(initialize, uid: 501).failure == .unauthorized, "configuration must require authorization")
        require(await service.handle(DaemonRequest(.networkChanged), uid: 501).failure == .unauthorized,
                "only the privileged supervisor can deliver network-change invalidations")
        var migratedBudget = LookupBudget()
        for _ in 0..<20 { migratedBudget.recordCall(to: .ipinfoLite) }
        initialize.migration = MigrationState(settings: initialize.settings!, budget: migratedBudget, attempts: [:], cooldowns: [:],
            snapshot: MimoSnapshot(ipAddress: "192.0.2.9", countryCode: "SG", countryName: "Singapore", provider: .ipinfoLite))
        initialize.authorization = Data("authorized".utf8)
        require(await service.handle(initialize, uid: 501).failure == nil, "authorized initialization must succeed")
        try await Task.sleep(for: .milliseconds(350))
        require(await client.count == 1, "daemon must load its System Keychain token and look up once")
        require(service.state(for: 501).budget.callsToday(for: .ipinfoLite) == 21, "initialization must retain the migrating user’s consumed quota")
        require(credentials.reads == 1, "daemon startup must read the System Keychain once")
        require(service.state(for: 502).hasIPinfoToken, "other users receive token availability")
        let wire = try JSONEncoder().encode(service.state(for: 502))
        require(!String(decoding: wire, as: UTF8.self).contains("daemon-test-secret"), "state must never contain the saved token")
        initialize.expectedRevision = 1
        require(await service.handle(initialize, uid: 502).failure == .alreadyInitialized, "later users cannot overwrite migration")

        var presentation = DaemonRequest(.presentation)
        var personal = UserPresentationPreferences()
        personal.displayStyle = .name
        personal.highlightCountryChanges = false
        presentation.presentation = personal
        require(await service.handle(presentation, uid: 501).failure == nil, "personal appearance requires no administrator")
        require(service.state(for: 501).presentation.displayStyle == .name, "request updates caller preferences")
        require(service.state(for: 502).presentation.displayStyle == .flag, "different users retain independent preferences")

        // Exercise NSXPC encoding, kernel caller identity and asynchronous replies without launchd.
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let remote = try await DaemonRPC.call(DaemonRequest(.state), connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        require(remote.state?.instanceID == service.state(for: getuid()).instanceID, "XPC must reach this service")
        personal.displayStyle = .name
        presentation.presentation = personal
        _ = try await DaemonRPC.call(presentation, connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        require(service.state(for: getuid()).presentation.displayStyle == .name, "XPC must use the caller's kernel UID")
        var wrongVersion = DaemonRequest(.state)
        wrongVersion.protocolVersion = 99
        do {
            _ = try await DaemonRPC.call(wrongVersion, connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
            fatalError("XPC accepted an incompatible version")
        } catch DaemonFailure.incompatible {}

        var update = DaemonRequest(.configure)
        update.authorization = Data("authorized".utf8)
        update.expectedRevision = 0
        var settings = service.state(for: 501).settings
        settings.allowlist = AllowedIPList(addresses: ["192.0.2.20"])
        update.settings = settings
        require(await service.handle(update, uid: 501).failure == .conflict, "stale edits must fail")
        update.expectedRevision = 1
        require(await service.handle(update, uid: 501).failure == nil, "current revision must commit")
        require(service.state(for: 502).settings.allowlist.contains("192.0.2.20"), "configuration must be visible to all users")
        require(!service.state(for: 502).authorizationState.isNotAllowed && service.state(for: 502).allowlistEventID == nil,
                "Direct must monitor its IP without comparing it to the shared allowlist or publishing a warning")

        let count = await client.count
        async let first = service.handle(DaemonRequest(.refresh), uid: 501)
        async let second = service.handle(DaemonRequest(.refresh), uid: 502)
        _ = await (first, second)
        try await Task.sleep(for: .milliseconds(350))
        require(await client.count == count + 1, "concurrent user refreshes must produce one lookup")

        var forbidden = DaemonRequest(.removeToken)
        forbidden.expectedRevision = 2
        require(await service.handle(forbidden, uid: 502).failure == .unauthorized, "standard users cannot remove shared credentials")
        var incompatible = DaemonRequest(.state)
        incompatible.protocolVersion = 99
        require(await service.handle(incompatible, uid: 501).failure == .incompatible, "protocol mismatch must be explicit")
        try await routingCredentialChecks(service, credentials: credentials, stateFile: directory.appendingPathComponent("state.plist"))
        let committedRevision = service.state(for: 501).revision
        service.stop()
        let restored = try DaemonService(storage: FilePreferenceStorage(url: directory.appendingPathComponent("state.plist")),
                                        observeSystem: false, credentials: credentials, client: client)
        require(restored.state(for: 501).revision == committedRevision, "settings revision must survive restart")
        require(restored.state(for: 501).presentation.displayStyle == .name, "personal preferences must survive restart")
        require(restored.state(for: 502).presentation.displayStyle == .flag, "restart must retain user isolation")
        require(restored.state(for: 501).budget.callsToday(for: .ipinfoLite) >= 2, "provider budget must survive restart")
        // Fresh Direct monitoring needs no shared-settings migration or Keychain read.
        let freshStorage = try FilePreferenceStorage(url: directory.appendingPathComponent("fresh.plist"))
        let freshCredentials = MemorySystemCredentials(), freshClient = RecordingLookup()
        let fresh = try DaemonService(storage: freshStorage, observeSystem: false,
                                      credentials: freshCredentials, client: freshClient)
        await fresh.start()
        try await Task.sleep(for: .milliseconds(350))
        require(await freshClient.count == 1 && fresh.state(for: 501).snapshot != nil,
                "fresh Direct must obtain an anonymous public IP immediately")
        require(!fresh.state(for: 501).initialized && freshStorage.data(forKey: "service.settings") == nil && freshCredentials.reads == 0,
                "anonymous Direct lookup must not migrate settings or read credentials")
        require(await fresh.handle(DaemonRequest(.refresh), uid: 501).failure == nil,
                "Direct refresh must be available before shared initialization")
        try await Task.sleep(for: .milliseconds(350))
        require(await freshClient.count == 2, "manual Direct refresh must perform the lookup")
        fresh.stop()
        let eofMarker = directory.appendingPathComponent("stdin-reader-ready")
        let concurrentInput = Task.detached {
            BoundedProcess.run("/bin/sh", ["-c", ": > \"$1\"; /bin/sleep 0.4; /usr/bin/wc -c", "stdin-eof", eofMarker.path],
                               timeout: 2, input: Data(repeating: 120, count: 300_000))
        }
        let eofDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: eofMarker.path) {
            require(ContinuousClock.now < eofDeadline, "stdin fixture must start")
            try await Task.sleep(for: .milliseconds(10))
        }
        let unrelatedChild = Task.detached { BoundedProcess.run("/bin/sleep", ["3"], timeout: 4) }
        let concurrentResult = await concurrentInput.value
        _ = await unrelatedChild.value
        require(concurrentResult.status == 0 && concurrentResult.text.trimmingCharacters(in: .whitespacesAndNewlines) == "300000",
                "an unrelated child must not inherit stdin descriptors or delay EOF for a concurrent command")
        let input = Data(repeating: 120, count: 300_000)
        let streamed = await Task.detached { BoundedProcess.run("/usr/bin/wc", ["-c"], timeout: 3, input: input) }.value
        require(streamed.status == 0 && streamed.text.trimmingCharacters(in: .whitespacesAndNewlines) == "300000",
                "bounded stdin must stream a payload larger than the socket buffer and close with EOF")
        let earlyExit = await Task.detached { BoundedProcess.run("/usr/bin/true", [], input: Data(repeating: 120, count: 1_048_576)) }.value
        require(earlyExit.status == 126, "an incomplete stdin transfer must fail without SIGPIPE")
        let stalledInput = await Task.detached { BoundedProcess.run("/bin/sleep", ["30"], timeout: 0.2, input: input) }.value
        require(stalledInput.status == 124, "a subprocess that does not read stdin must still time out")
        let supervisor = MimoSupervisor()
        var profileRequest = DaemonRequest(.supervisor); profileRequest.supervisor = MimoSupervisorRequest(.profile)
        let deniedProfile = await supervisor.handle(profileRequest, uid: 501, pid: getpid())
        require(deniedProfile.failure == .unauthorized && deniedProfile.profileContents == nil,
                "runtime profile contents require explicit administrator authorization")
        let normal = await Task.detached { BoundedProcess.run("/usr/bin/printf", ["hello"]) }.value
        require(normal.status == 0 && normal.text == "hello", "probe must capture output")
        let childFile = directory.appendingPathComponent("child.pid")
        let timeout = await Task.detached {
            BoundedProcess.run("/bin/bash", ["-c", "sleep 30 & echo $! > \"$1\"; wait", "probe", childFile.path], timeout: 0.2)
        }.value
        require(timeout.status == 124, "stalled probes must time out")
        let child = Int32(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try await Task.sleep(for: .milliseconds(200))
        require(kill(child, 0) != 0 && errno == ESRCH, "timeout must terminate the child as well as the parent")
        let flood = await Task.detached { BoundedProcess.run("/usr/bin/yes", [], timeout: 2) }.value
        require(flood.status == 125, "probe output must be bounded")
        print("PASS: real XPC transport, initialization, authorization, secret isolation, per-user state, concurrent refresh, revision conflicts, restart persistence and bounded subprocesses")
    }

    @MainActor
    private static func routingCredentialChecks(_ service: DaemonService, credentials: MemorySystemCredentials,
                                        stateFile: URL) async throws {
        func request(_ command: DaemonCommand) -> DaemonRequest {
            var request = DaemonRequest(command)
            request.expectedRevision = service.state(for: 501).revision
            request.authorization = Data("authorized".utf8)
            return request
        }
        var save = request(.saveProxy)
        save.proxy = MimoProxy(ClashProxySettings(name: "Test", type: .socks5, server: "192.0.2.20",
                                                port: 1080, username: "test-user"))
        save.proxyPassword = "proxy-test-secret"
        require(await service.handle(save, uid: 501).failure == nil, "saving a machine proxy must succeed")
        require(try credentials.read(account: SecureTokenStore.ipinfoLiteAccount) == "daemon-test-secret",
                "saving a proxy must preserve the IPinfo token")
        require(try credentials.read(account: MimoRuntime.proxyPasswordAccount) == "proxy-test-secret",
                "the proxy password must use its own account")
        let encoded = String(decoding: try JSONEncoder().encode(service.state(for: 502)), as: UTF8.self)
        require(!encoded.contains("daemon-test-secret") && !encoded.contains("proxy-test-secret"),
                "public state must omit both machine secrets")

        var protected = request(.configureRouting)
        var protectedConfiguration = MimoConfiguration(); protectedConfiguration.mode = .rule
        protected.routing = protectedConfiguration
        require(await service.handle(protected, uid: 501).failure == nil, "Rule selection must enable proxy-exit approval")
        require(!service.state(for: 501).authorizationState.isNotAllowed,
                "entering Rule must not compare the cached Direct address with the proxy allowlist")
        try await Task.sleep(for: .milliseconds(350))
        require(service.state(for: 501).authorizationState.isNotAllowed && service.state(for: 501).allowlistEventID != nil,
                "a fresh protected lookup outside the allowlist must still publish its rejection")

        credentials.blockedReadAccount = MimoRuntime.proxyPasswordAccount
        var direct = request(.configureRouting)
        direct.routing = MimoConfiguration()
        require(await service.handle(direct, uid: 501).failure == nil,
                "Direct recovery must not require reading a proxy credential")
        require(service.state(for: 501).routing?.hasProxyPassword == true,
                "mode selection must preserve known credential availability")
        require(!service.state(for: 501).authorizationState.isNotAllowed && service.state(for: 501).allowlistEventID == nil,
                "selecting Direct must clear the protected rejection immediately")
        credentials.blockedReadAccount = nil

        var token = request(.setToken)
        token.token = "replacement-ipinfo-secret"
        require(await service.handle(token, uid: 501).failure == nil, "token replacement must commit")
        require(try credentials.read(account: MimoRuntime.proxyPasswordAccount) == "proxy-test-secret",
                "token replacement must preserve the proxy password")
        try await Task.sleep(for: .milliseconds(350))

        // A directory at the state-file path forces the atomic commit to fail without changing
        // permissions or relying on the UID running this suite. Only this test's temporary data moves.
        let revision = service.state(for: 501).revision
        let backup = stateFile.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: stateFile, to: backup)
        try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
        do {
            defer {
                try? FileManager.default.removeItem(at: stateFile)
                try? FileManager.default.moveItem(at: backup, to: stateFile)
            }
            var failing = request(.setToken)
            failing.token = "must-not-commit"
            require(await service.handle(failing, uid: 501).failure == .storage,
                    "a failed revision write must report failure")
            require(try credentials.read(account: SecureTokenStore.ipinfoLiteAccount) == "replacement-ipinfo-secret",
                    "a failed state commit must restore the previous Keychain token")
            require(service.engine.ipinfoToken == "replacement-ipinfo-secret" && service.state(for: 501).revision == revision,
                    "rollback must restore the cached token and preserve the committed revision")
            var failingProxy = request(.saveProxy)
            failingProxy.proxy = save.proxy
            failingProxy.proxyPassword = "must-not-change-proxy"
            require(await service.handle(failingProxy, uid: 501).failure == .storage,
                    "proxy metadata and its revision must commit together")
            require(try credentials.read(account: MimoRuntime.proxyPasswordAccount) == "proxy-test-secret",
                    "a failed proxy commit must restore its previous password")
            credentials.blockedReadAccount = MimoRuntime.proxyPasswordAccount
            var failingMode = request(.configureRouting)
            failingMode.routing = MimoConfiguration()
            require(await service.handle(failingMode, uid: 501).failure == .storage,
                    "a mode save failure must not access proxy credentials")
            credentials.blockedReadAccount = nil
            require(try credentials.read(account: MimoRuntime.proxyPasswordAccount) == "proxy-test-secret",
                    "a mode save failure must not delete an unrelated saved proxy password")
        }
        require(await service.handle(request(.removeToken), uid: 501).failure == nil, "token removal must succeed")
        require(try credentials.read(account: MimoRuntime.proxyPasswordAccount) == "proxy-test-secret",
                "removing the token must preserve the proxy password")
        require(await service.handle(request(.removeProxy), uid: 501).failure == nil, "proxy removal must succeed")
        require(try credentials.read(account: MimoRuntime.proxyPasswordAccount) == nil &&
                    credentials.read(account: SecureTokenStore.ipinfoLiteAccount) == nil,
                "removing the proxy must leave the separate removed-token state unchanged")
        print("PASS: machine credential account separation, public-state redaction, Direct recovery without secrets and token rollback")
    }
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
}

private actor RecordingLookup: PublicIPLookupClientProtocol {
    private(set) var count = 0
    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        count += 1
        try await Task.sleep(for: .milliseconds(100))
        return MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: configuration.provider)
    }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
        MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois)
    }
}

private final class MemorySystemCredentials: CredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var values = [SecureTokenStore.ipinfoLiteAccount: "daemon-test-secret"]
    private var blockedAccount: String?
    var blockedReadAccount: String? {
        get { lock.withLock { blockedAccount } }
        set { lock.withLock { blockedAccount = newValue } }
    }
    var reads: Int { lock.withLock { count } }
    func read(account: String) throws -> String? {
        try lock.withLock {
            count += 1
            if blockedAccount == account { throw DaemonFailure.credential }
            return values[account]
        }
    }
    func save(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
    func delete(account: String) throws { lock.withLock { values[account] = nil } }
}
