import Darwin
import Foundation
import SystemConfiguration

/// Legacy IPv6 preference journal compatibility. Current routing never disables
/// macOS IPv6; upgrade, Direct and uninstall restore flags saved by older builds.
enum MimoIPv4Configuration {
    static let backup = MimoRuntime.directory.appendingPathComponent("ipv6-original.plist")
    private static let pending = MimoRuntime.directory.appendingPathComponent("ipv6-apply-pending")

    static func apply(restoring: Bool = false) throws {
        // Current builds only restore the legacy journal. Avoid acquiring the
        // global preferences lock when Mimo never changed these settings.
        if restoring, !FileManager.default.fileExists(atPath: backup.path) {
            guard !FileManager.default.fileExists(atPath: pending.path) else {
                throw MimoRuntimeError.unavailable("The older IPv6 restoration journal is missing. Network cleanup is incomplete.")
            }
            return
        }
        guard geteuid() == 0,
              let preferences = SCPreferencesCreate(nil, "Mimo IPv4 policy" as CFString, nil),
              SCPreferencesLock(preferences, false) else {
            throw MimoRuntimeError.unavailable("Could not lock network settings for Mimo's IPv4-only policy.")
        }
        defer { SCPreferencesUnlock(preferences) }
        var saved: [String: Bool] = [:]
        if FileManager.default.fileExists(atPath: backup.path) {
            var info = stat()
            guard lstat(backup.path, &info) == 0, info.st_uid == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
                  let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), format: nil) as? [String: Bool],
                  value.count <= 512 else {
                throw MimoRuntimeError.unavailable("The saved IPv6 settings are unsafe. Repair installation.")
            }
            saved = value
        } else if restoring { return }
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            throw MimoRuntimeError.unavailable("Could not inspect network services for the IPv4-only policy.")
        }
        var changed = false
        for service in services {
            guard let identifier = SCNetworkServiceGetServiceID(service) as String?,
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv6) else { continue }
            let enabled = SCNetworkProtocolGetEnabled(proto)
            // Mimo only wrote false. Preserve a later owner's explicit enable.
            if restoring, enabled { continue }
            if !restoring, saved[identifier] == nil { saved[identifier] = enabled }
            guard let target = restoring ? saved[identifier] : false, enabled != target else { continue }
            guard SCNetworkProtocolSetEnabled(proto, target) else {
                throw MimoRuntimeError.unavailable("Could not update a network service's IPv6 setting.")
            }
            changed = true
        }
        if !restoring {
            guard saved.count <= 512 else { throw MimoRuntimeError.unavailable("Too many network services to manage safely.") }
            let data = try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
            if (try? Data(contentsOf: backup)) != data {
                try data.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600, .ownerAccountID: 0], ofItemAtPath: backup.path)
            }
        }
        if changed {
            try Data().write(to: pending, options: .atomic)
            guard SCPreferencesCommitChanges(preferences) else {
                throw MimoRuntimeError.unavailable("Could not save Mimo's IPv4-only network settings.")
            }
        }
        if changed || FileManager.default.fileExists(atPath: pending.path) {
            guard SCPreferencesApplyChanges(preferences) else {
                throw MimoRuntimeError.unavailable("Could not apply Mimo's IPv4-only network settings.")
            }
            try FileManager.default.removeItem(at: pending)
        }
        if restoring { try FileManager.default.removeItem(at: backup) }
    }
}
