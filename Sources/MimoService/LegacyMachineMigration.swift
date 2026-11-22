import Foundation

/// The old manager must stop its jobs and restore networking before this runs.
enum LegacyMachineMigration {
    private static let oldRoot = URL(fileURLWithPath: "/Library/Application Support/ExitIPMonitor")
    private static let marker = MimoService.support.appendingPathComponent("names-migrated.v1")

    static func prepare() throws {
        let files = FileManager.default
        if files.fileExists(atPath: oldRoot.path) { try requireRootDirectory(oldRoot) }
        try copyPreferences(from: oldRoot.appendingPathComponent("Service/state.plist"), to: MimoService.storageURL)
        let oldFlags = oldRoot.appendingPathComponent("Mihomo/services.json")
        let newFlags = MimoRuntime.directory.appendingPathComponent("services.json")
        if files.fileExists(atPath: oldFlags.path), !files.fileExists(atPath: newFlags.path) {
            try requireRootFile(oldFlags)
            try files.createDirectory(at: newFlags.deletingLastPathComponent(), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            try Data(contentsOf: oldFlags).write(to: newFlags, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: newFlags.path)
        }
        try Data("copied\n".utf8).write(to: marker, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    static func finish() throws {
        let files = FileManager.default
        guard files.fileExists(atPath: marker.path) else { return }
        try requireRootFile(marker)
        try ServiceAuthorization.removeRight(LegacyNaming.appID + ".configure")
        if files.fileExists(atPath: oldRoot.path) {
            try requireRootDirectory(oldRoot)
            // These directories contain only the old product's machine state or generated runtime.
            // State/service preferences have already been copied and the new service verified.
            for name in ["Service", "Mihomo", "Uninstaller", "LaunchDaemons", "TailscaleVerge"] {
                let path = oldRoot.appendingPathComponent(name)
                if files.fileExists(atPath: path.path) { try files.removeItem(at: path) }
            }
            for name in ["installed-app", "command-support.sh", "cleanup-installation.sh", "tailscale-verge.sh", "legacy-provider-enabled", "needs-removal-bridge"] {
                let path = oldRoot.appendingPathComponent(name)
                if files.fileExists(atPath: path.path) { try files.removeItem(at: path) }
            }
            // Unexpected user-added files are preserved, never swept away.
            try LegacyNaming.moveContents(from: oldRoot, to: MimoService.support.appendingPathComponent("Migrated"))
        }
        let oldLogs = URL(fileURLWithPath: "/Library/Logs/ExitIPMonitor")
        if files.fileExists(atPath: oldLogs.path) { try requireRootDirectory(oldLogs) }
        try LegacyNaming.moveContents(from: oldLogs, to: MimoService.logDirectory)
    }

    private static func copyPreferences(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else { return }
        try requireRootFile(source)
        guard let original = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let values = LegacyNaming.migratedPreferences(original)
        if files.fileExists(atPath: destination.path) {
            try requireRootFile(destination)
            // An interrupted migration resumes without overwriting newer settings.
            if files.fileExists(atPath: marker.path) { try requireRootFile(marker); return }
            let existing = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination), format: nil)
            guard (existing as? NSDictionary)?.isEqual(to: values) == true else { throw DaemonFailure.conflict }
            return
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try data.write(to: destination, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func requireRootDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else { throw DaemonFailure.unavailable }
    }

    private static func requireRootFile(_ url: URL) throws {
        try requireRootDirectory(url.deletingLastPathComponent())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw DaemonFailure.unavailable }
    }
}
