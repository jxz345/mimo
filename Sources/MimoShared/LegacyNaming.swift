import Foundation

/// Old names are only migration inputs. New writes use the Mimo namespace.
public enum LegacyNaming {
    public static let appID = "com.example.exitipmonitor"
    public static let groupID = "group.com.example.exitipmonitor"
    public static let serviceID = "com.example.exitipmonitor.daemon"
    public static let loginKey = "exit-ip.launch-at-login.v1"
    public static let supportName = "ExitIPMonitor"

    public static func migratedKey(_ key: String) -> String {
        let renamed = key.hasPrefix("exit-ip.") ? "mimo." + key.dropFirst("exit-ip.".count) : key
        return renamed.replacingOccurrences(of: supportName, with: "Mimo")
            .replacingOccurrences(of: appID, with: "com.mimo")
    }

    public static func migratedPreferences(_ values: [String: Any], excludingLogin: Bool = false) -> [String: Any] {
        var migrated: [String: Any] = [:]
        for (key, value) in values {
            if excludingLogin && key == loginKey { continue }
            migrated[migratedKey(key)] = value
        }
        for (key, value) in values where key.hasPrefix("mimo.") { migrated[key] = value }
        return migrated
    }

    /// Run as the account being migrated, before normal GUI startup creates logs.
    public static func migrateUser() throws {
        let domains = [(appID, "com.mimo"), (groupID, MimoAppGroup.identifier)]
        let preferences = UserDefaults.standard
        for (old, new) in domains {
            guard let original = preferences.persistentDomain(forName: old) else { continue }
            var destination = preferences.persistentDomain(forName: new) ?? [:]
            for (key, value) in migratedPreferences(original, excludingLogin: true) where destination[key] == nil {
                destination[key] = value
            }
            preferences.setPersistentDomain(destination, forName: new)
            guard preferences.synchronize() else { throw CocoaError(.fileWriteUnknown) }
            // The installer unregisters the old login identity before this step.
            preferences.removePersistentDomain(forName: old)
            guard preferences.synchronize() else { throw CocoaError(.fileWriteUnknown) }
        }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let old = support.appendingPathComponent(supportName)
        let new = support.appendingPathComponent("Mimo")
        try moveContents(from: old, to: new)
    }

    /// Preserve colliding files under a migration subdirectory instead of overwriting user data.
    public static func moveContents(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else { return }
        let attributes = try files.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileReadInvalidFileName) }
        if !files.fileExists(atPath: destination.path) {
            try files.moveItem(at: source, to: destination)
            return
        }
        guard try files.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        for item in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            var target = destination.appendingPathComponent(item.lastPathComponent)
            if files.fileExists(atPath: target.path) {
                let archive = destination.appendingPathComponent("Migrated", isDirectory: true)
                try files.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                target = archive.appendingPathComponent(UUID().uuidString + "-" + item.lastPathComponent)
            }
            try files.moveItem(at: item, to: target)
        }
        try files.removeItem(at: source)
    }
}
