import Darwin
import Foundation

@MainActor
enum MimoInstallationTests {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        for direct in [false, true] {
            let storage = try FilePreferenceStorage(url: directory.appendingPathComponent("state-\(direct).plist"))
            var routing = MimoConfiguration()
            routing.mode = .global; routing.mihomoEnabled = false; routing.profileHostingEnabled = false
            routing.proxy = MimoProxy(ClashProxySettings(name: "Saved", type: .http, server: "127.0.0.1", port: 8080))
            let settings = MachineSettings(allowlist: AllowedIPList(addresses: ["203.0.113.1"]), tailscaleProviderEnabled: false)
            try storage.update(["service.routing": try JSONEncoder().encode(routing),
                                "service.settings": try JSONEncoder().encode(settings), "service.revision": 42, "quota": 17])
            let installed = try MimoRecoveryState.commitInstallation(storage: storage, startingInDirect: direct)
            let saved = try JSONDecoder().decode(MachineSettings.self, from: storage.data(forKey: "service.settings")!)
            require(installed.mode == (direct ? .direct : .global), "only reactivation resets routing to Direct")
            require(installed.mihomoEnabled && installed.profileHostingEnabled && saved.tailscaleProviderEnabled,
                    "installation restores engine, profile and provider despite saved stop flags")
            require(installed.proxy == routing.proxy && saved.allowlist == settings.allowlist && storage.integer(forKey: "quota") == 17,
                    "installation preserves proxy, allowlist and unrelated settings")
            require(storage.integer(forKey: "service.revision") == 43, "other GUI clients must observe a new revision")
        }
        let now = Date()
        var routing = MimoRoutingState()
        routing.phase = .blocked // Health does not approve protected traffic.
        routing.supervisorCheckedAt = now
        routing.services = [.core, .mihomo, .profileHosting].map { MimoServiceStatus(id: $0, health: .running, transport: "test", checkedAt: now) }
        routing.infrastructure = .init(pf: .healthy, launchd: .healthy, checkedAt: now)
        let provider = MimoServiceStatus(id: .tailnetProvider, health: .running, transport: "HTTP", port: 18766, bindingConfirmed: true, checkedAt: now)
        func problems(_ state: MimoRoutingState? = nil, _ flags: MimoServicePreferences = .init(), _ report: MimoServiceStatus? = provider) -> [String] {
            MimoInstallationReadiness.problems(flags: flags, supervisor: state ?? routing, provider: report, now: now)
        }
        require(problems().isEmpty, "all services may be healthy while protected verification remains blocked")
        for index in routing.services.indices {
            var failed = routing; failed.services[index].health = .stopped
            require(!problems(failed).isEmpty, "a stopped service cannot qualify an installation")
        }
        var flags = MimoServicePreferences(); flags.engine = false
        require(problems(nil, flags).contains("service_intent"), "old stopped intent cannot pass")
        flags.engine = true; flags.releaseNetwork = true
        require(problems(nil, flags).contains("service_intent"), "old release intent cannot pass")
        var stale = routing; stale.supervisorCheckedAt = now.addingTimeInterval(-30)
        require(problems(stale).contains("supervisor"), "cached GUI/core health cannot pass")
        require(problems(nil, .init(), nil).contains("tailnetProvider"), "the core must answer with a bound provider")
        stale = routing; stale.infrastructure?.checkedAt = now.addingTimeInterval(-40)
        require(problems(stale).contains("launchd_monitor"), "stale infrastructure cannot pass")

        let journal = directory.appendingPathComponent("installation.jsonl")
        let attempt = UUID().uuidString
        for stage in ["started", "conflict_detected", "conflict_approved", "services_verified", "succeeded"] {
            try MimoInstallationJournal.append(attempt: attempt, operation: "install", stage: stage, to: journal, owner: geteuid())
        }
        require(MimoInstallationJournal.records(from: journal).count == 5, "events survive writer process lifetimes")
        try MimoInstallationJournal.append(attempt: UUID().uuidString, operation: "activate", stage: "failed", item: "verifying_services", status: "1", to: journal, owner: geteuid())
        require(MimoInstallationJournal.records(from: journal).count == 6, "new events remain visible after a reader has started")
        do {
            try MimoInstallationJournal.append(attempt: attempt, operation: "install", stage: "failed", item: "secret\nvalue", to: journal, owner: geteuid())
            fatalError("arbitrary command output entered the journal")
        } catch { }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: journal)
        do {
            try MimoInstallationJournal.append(attempt: attempt, operation: "install", stage: "started", to: link, owner: geteuid())
            fatalError("journal followed a substituted file")
        } catch { }
        print("PASS: installation restores services, preserves shared settings, rejects incomplete/stale health, and retains shared events safely")
    }

    private static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}
