import Foundation

/// Private machine data. Never embed these values in DaemonState or runtime diagnostics.
public enum MimoLocalSettings {
    public static let ipinfoAccount = "ipinfo-lite-token"
    public static let tokenKey = "service.local-ipinfo-token"
    public static let passwordsKey = "service.local-proxy-passwords"
    private static let migratedKey = "service.local-credentials.v2.1"
    private static let cleanupKey = "service.keychain-cleanup.v2.1"

    /// Core runs this before validating saved settings. Decode the old shape,
    /// remove IPv6 entries only, and atomically update both shared representations.
    /// Invalid non-IP data remains an error instead of silently granting access.
    @discardableResult
    public static func migrateIPv4Allowlist(_ storage: FilePreferenceStorage) throws -> Int {
        var changes: [String: Any?] = [:]
        var removed = 0
        if let data = storage.data(forKey: "service.settings") {
            var settings = try JSONDecoder().decode(MachineSettings.self, from: data)
            let previous = settings.allowlist.addresses
            guard previous.allSatisfy({ IPAddressValidator.normalize($0) == $0 }) else { throw DaemonFailure.invalidRequest }
            let count = previous.filter { MimoAddressFamily.ipv6.accepts($0) }.count
            if count > 0 {
                settings.allowlist = AllowedIPList(addresses: previous)
                changes["service.settings"] = try JSONEncoder().encode(settings.validated())
                changes[MimoPreferenceKey.allowedIPs] = try JSONEncoder().encode(settings.allowlist)
                changes["service.revision"] = storage.integer(forKey: "service.revision") + 1
                removed = count
            }
        }
        if changes[MimoPreferenceKey.allowedIPs] == nil, let data = storage.data(forKey: MimoPreferenceKey.allowedIPs) {
            let old = try JSONDecoder().decode(AllowedIPList.self, from: data)
            let count = old.addresses.filter { MimoAddressFamily.ipv6.accepts($0) }.count
            if count > 0 {
                changes[MimoPreferenceKey.allowedIPs] = try JSONEncoder().encode(AllowedIPList(addresses: old.addresses))
                removed = count
            }
        }
        if !changes.isEmpty { try storage.update(changes) }
        return removed
    }

    public static func passwords(in storage: any PreferenceStorage) throws -> [UUID: String] {
        guard let data = storage.data(forKey: passwordsKey) else { return [:] }
        return try JSONDecoder().decode([UUID: String].self, from: data)
    }

    /// Commits data before deleting legacy credentials. Interrupted cleanup resumes without
    /// reimporting an old value over a newer local edit.
    @discardableResult
    public static func migrate(_ storage: FilePreferenceStorage, legacy: any CredentialBackend) throws -> Bool {
        if !storage.bool(forKey: migratedKey) {
            var configuration = try storage.data(forKey: "service.routing").map {
                try JSONDecoder().decode(MimoConfiguration.self, from: $0).validated()
            } ?? MimoConfiguration()
            let upgrading = storage.data(forKey: "service.routing") != nil || storage.data(forKey: "service.settings") != nil
            let token = upgrading ? try legacy.read(account: MimoLocalSettings.ipinfoAccount) : nil
            let password = upgrading ? try legacy.read(account: MimoRuntime.proxyPasswordAccount) : nil
            var passwords = try passwords(in: storage)
            if configuration.proxies == nil {
                if let proxy = configuration.proxy {
                    let entry = MimoSavedProxy(proxy: proxy, hasPassword: password?.isEmpty == false)
                    configuration.proxies = [entry]; configuration.activeProxyID = entry.id
                    if let password, !password.isEmpty { passwords[entry.id] = password }
                } else { configuration.proxies = []; configuration.mode = .direct }
            }
            var cleanup: [String] = []
            if token != nil { cleanup.append(MimoLocalSettings.ipinfoAccount) }
            if password != nil { cleanup.append(MimoRuntime.proxyPasswordAccount) }
            try storage.update([
                "service.routing": try JSONEncoder().encode(configuration.validated()),
                passwordsKey: try JSONEncoder().encode(passwords),
                tokenKey: storage.string(forKey: tokenKey) ?? token,
                "service.revision": storage.integer(forKey: "service.revision") + 1,
                migratedKey: true, cleanupKey: cleanup
            ])
        }
        var remaining: [String] = []
        for account in storage.object(forKey: cleanupKey) as? [String] ?? [] {
            do { try legacy.delete(account: account) } catch { remaining.append(account) }
        }
        try storage.update([cleanupKey: remaining])
        return remaining.isEmpty
    }

    /// One-time upgrades apply equally to machine and released-monitor preferences.
    public static func migrateMonitoring(_ storage: any PreferenceStorage) throws {
        let marker = "monitoring.migrated.v2.1"
        guard !storage.bool(forKey: marker) else { return }
        var changes: [String: Any?] = [marker: true]
        let interval = storage.integer(forKey: MimoPreferenceKey.refreshInterval)
        if interval == 0 || interval == RefreshInterval.fifteenMinutes.rawValue {
            changes[MimoPreferenceKey.refreshInterval] = RefreshInterval.sixtyMinutes.rawValue
        }
        if let data = storage.data(forKey: "service.settings") {
            var settings = try JSONDecoder().decode(MachineSettings.self, from: data)
            if settings.refreshInterval == .fifteenMinutes { settings.refreshInterval = .sixtyMinutes }
            changes["service.settings"] = try JSONEncoder().encode(settings)
            changes[MimoPreferenceKey.refreshInterval] = settings.refreshInterval.rawValue
            changes["service.revision"] = storage.integer(forKey: "service.revision") + 1
        }
        let health = ProviderHealthStore(defaults: storage)
        let cooldowns = ProviderCooldownStore(defaults: storage)
        for provider in ProviderID.allCases {
            let record = health.load(for: provider)
            // Old HTTP failures may contain a server Retry-After that was not stored separately.
            guard let reason = record.lastError, !reason.hasPrefix("http_"), reason != "rate_limited",
                  let failed = record.lastFailure, let deadline = cooldowns.retryNotBefore(for: provider) else { continue }
            changes[MimoPreferenceKey.providerCooldownPrefix + provider.rawValue] = min(deadline, failed.addingTimeInterval(600))
        }
        if let file = storage as? FilePreferenceStorage { try file.update(changes) }
        else {
            for (key, value) in changes where key != marker { storage.set(value, forKey: key) }
            storage.set(true, forKey: marker)
        }
    }
}

/// Used only by core. GUI clients see credential availability, never stored values.
public struct MimoLocalCredentials: CredentialBackend {
    public let storage: FilePreferenceStorage
    public init(storage: FilePreferenceStorage) { self.storage = storage }
    public func read(account: String) throws -> String? {
        guard account == MimoLocalSettings.ipinfoAccount else { throw DaemonFailure.invalidRequest }
        return storage.string(forKey: MimoLocalSettings.tokenKey)
    }
    public func save(_ value: String, account: String) throws {
        guard account == MimoLocalSettings.ipinfoAccount else { throw DaemonFailure.invalidRequest }
        try storage.update([MimoLocalSettings.tokenKey: value])
    }
    public func delete(account: String) throws {
        guard account == MimoLocalSettings.ipinfoAccount else { throw DaemonFailure.invalidRequest }
        try storage.update([MimoLocalSettings.tokenKey: nil])
    }
}
