import Foundation

enum MimoRecoveryState {
    /// Installation explicitly restores every service, while an active upgrade
    /// retains its selected routing mode. Full deactivation resumes in Direct.
    static func commitInstallation(storage: FilePreferenceStorage, startingInDirect: Bool) throws -> MimoConfiguration {
        var configuration = try storage.data(forKey: "service.routing").map {
            try JSONDecoder().decode(MimoConfiguration.self, from: $0).validated()
        } ?? MimoConfiguration()
        if startingInDirect { configuration.mode = .direct }
        configuration.mihomoEnabled = true
        configuration.profileHostingEnabled = true
        var settings = try storage.data(forKey: "service.settings").map {
            try JSONDecoder().decode(MachineSettings.self, from: $0)
        } ?? MachineSettings()
        settings.tailscaleProviderEnabled = true
        try storage.update([
            "service.routing": try JSONEncoder().encode(configuration),
            "service.settings": try JSONEncoder().encode(settings),
            "service.revision": storage.integer(forKey: "service.revision") + 1
        ])
        return configuration
    }

    static func commitDirect(storage: FilePreferenceStorage, activateServices: Bool = false) throws -> MimoConfiguration {
        var configuration: MimoConfiguration
        if let data = storage.data(forKey: "service.routing") {
            configuration = try JSONDecoder().decode(MimoConfiguration.self, from: data).validated()
        } else {
            configuration = MimoConfiguration()
        }
        configuration.mode = .direct
        if activateServices { configuration.mihomoEnabled = true }
        var values: [String: Any] = [
            "service.routing": try JSONEncoder().encode(configuration),
            "service.revision": storage.integer(forKey: "service.revision") + 1
        ]
        if activateServices, let data = storage.data(forKey: "service.settings") {
            var settings = try JSONDecoder().decode(MachineSettings.self, from: data)
            settings.tailscaleProviderEnabled = true
            values["service.settings"] = try JSONEncoder().encode(settings)
        }
        try storage.update(values)
        return configuration
    }
}

/// Stop core before taking its storage lock. Commit the saved mode before restoring
/// access, and restart only a core that the user had enabled before recovery.
@MainActor
enum MimoDirectRecovery {
    typealias Send = @MainActor (MimoSupervisorRequest) async throws -> MimoRoutingState

    static func run(coreWasEnabled: Bool, send: Send,
                    persist: @MainActor () throws -> MimoConfiguration) async throws {
        var stop = MimoSupervisorRequest(.service)
        stop.service = .core; stop.operation = .stop
        let stopped = try await send(stop)
        guard stopped.services.first(where: { $0.id == .core })?.health == .stopped else {
            throw MimoRuntimeError.unavailable("Core did not stop; Direct recovery was not applied.")
        }
        let configuration = try persist()
        var direct = MimoSupervisorRequest(.direct)
        direct.configuration = configuration
        let restored = try await send(direct)
        guard restored.allowsTraffic, restored.effectiveMode == .direct else {
            throw MimoRuntimeError.unavailable("Direct was saved, but networking recovery could not be confirmed.")
        }
        if coreWasEnabled {
            var start = MimoSupervisorRequest(.service)
            start.service = .core; start.operation = .start
            var restarted = try await send(start)
            for _ in 0..<30 {
                if restarted.services.first(where: { $0.id == .core })?.health == .running { break }
                try await Task.sleep(for: .milliseconds(100))
                restarted = try await send(MimoSupervisorRequest(.state))
            }
            guard restarted.services.first(where: { $0.id == .core })?.health == .running else {
                throw MimoRuntimeError.unavailable("Direct was saved and networking restored, but core did not restart. Start core from Background services.")
            }
        }
    }
}
