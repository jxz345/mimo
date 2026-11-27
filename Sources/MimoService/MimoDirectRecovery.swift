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

            values["service.settings"] = try JSONEncoder().encode(settings)
        }
        try storage.update(values)
        return configuration
    }
}

/// Persist through the sole settings owner. Never stop the supervisor to take
/// its storage lock, and never turn a stopped IP monitor back on during recovery.
@MainActor
enum MimoDirectRecovery {
    static func run(authorization: Data,
                    call: @MainActor (DaemonRequest) async throws -> DaemonResponse) async throws {
        let response = try await call(DaemonRequest(.state))
        guard let state = response.state, var configuration = state.routing?.configuration else { throw DaemonFailure.unavailable }
        configuration.mode = .direct
        var request = DaemonRequest(.configureRouting)
        request.authorization = authorization
        request.expectedRevision = state.revision
        request.routing = configuration
        let changed = try await call(request)
        if let failure = changed.failure { throw failure }
        guard let restored = changed.state?.routing, restored.allowsTraffic, restored.effectiveMode == .direct else {
            throw MimoRuntimeError.unavailable("Direct recovery could not be confirmed. Inspect the core log or use full Stop cleanup.")
        }
    }
}
