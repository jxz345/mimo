import Foundation

/// Written by the administrator-approved cleanup only after all owned jobs and
/// network controls have been removed. A missing service alone is never proof.
enum MimoDeactivation {
    static let receipt = "/Library/Application Support/Mimo/deactivated"

    static func isConfirmed() -> Bool {
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: receipt),
              attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? Int == 0,
              let mode = attributes[.posixPermissions] as? Int, mode & 0o022 == 0,
              (try? String(contentsOfFile: receipt, encoding: .utf8)) == "mimo-inactive-v1\n" else { return false }
        return !files.fileExists(atPath: MimoService.executable) &&
            !files.fileExists(atPath: MimoRuntime.supervisorPlist)
    }
}
