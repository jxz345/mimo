import Foundation
import Security

/// Installation pins the exact GUI code directory in a root-owned file. The
/// kernel checks every message on this separate endpoint before it is decoded.
/// Public state readers and root/core traffic-control requests keep their own
/// endpoints and authorization policy.
final class InstalledAppControlListener: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let requirement: String
    private let accept: @Sendable (NSXPCConnection) -> Bool

    init(label: String, accept: @escaping @Sendable (NSXPCConnection) -> Bool) throws {
        let url = MimoService.installedAppIdentity
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else { throw DaemonFailure.unauthorized }
        let hash = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard hash.utf8.count == 40, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DaemonFailure.unauthorized
        }
        requirement = "cdhash H\"\(hash)\""
        listener = NSXPCListener(machServiceName: label)
        self.accept = accept
        super.init()
        listener.delegate = self
        listener.resume()
        RuntimeLog.shared.info("mimo_installed_app_control_ready", fields: ["endpoint": label])
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        return accept(connection)
    }

    func invalidate() { listener.invalidate() }
}

/// The daemon runs in the system context. Never consult a user's login keychain, never show UI,
/// and never send the saved value back to a client. Every query targets the System file keychain.
struct SystemCredentials: CredentialBackend {
    func migrateLegacy(removeOriginals: Bool) throws {
        for account in [SecureTokenStore.ipinfoLiteAccount, MimoRuntime.proxyPasswordAccount] {
            var legacy = try query(account: account)
            legacy[kSecAttrService as String] = LegacyNaming.serviceID
            var lookup = legacy
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else { throw KeychainError.unexpectedStatus(status) }
            if try read(account: account) == nil {
                guard !removeOriginals else { throw DaemonFailure.credential }
                try save(value, account: account)
            }
            guard try read(account: account) == value else { throw DaemonFailure.conflict }
            if removeOriginals {
                let deletion = SecItemDelete(legacy as CFDictionary)
                guard deletion == errSecSuccess || deletion == errSecItemNotFound else { throw KeychainError.unexpectedStatus(deletion) }
            }
        }
    }

    func query(account: String) throws -> [String: Any] {
        guard [SecureTokenStore.ipinfoLiteAccount, MimoRuntime.proxyPasswordAccount].contains(account) else {
            throw DaemonFailure.invalidRequest
        }
        var keychain: SecKeychain?
        let status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
        guard status == errSecSuccess, let keychain else { throw KeychainError.unexpectedStatus(status) }
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: MimoService.label,
         kSecAttrAccount as String: account,
         kSecMatchSearchList as String: [keychain],
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    func read(account: String) throws -> String? {
        var query = try query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedStatus(status)
        }
        return token
    }

    func save(_ value: String, account: String) throws {
        let query = try query(account: account)
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            // A root-only ACL survives an ad-hoc executable's code hash changing at upgrade.
            var add = query
            add[kSecUseKeychain as String] = (add.removeValue(forKey: kSecMatchSearchList as String) as? [SecKeychain])?.first
            add[kSecValueData as String] = data
            add[kSecAttrAccess as String] = try Self.ownerAccess()
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError.unexpectedStatus(result) }
        } else if status != errSecSuccess { throw KeychainError.unexpectedStatus(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(try query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }

    static func ownerAccess() throws -> SecAccess {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessCreateWithOwnerAndACL(getuid(), getgid(), UInt32(kSecUseOnlyUID), [kSecACLAuthorizationAny] as CFArray, &error) else {
            if let error { throw error.takeRetainedValue() }
            throw DaemonFailure.credential
        }
        return access
    }
}

enum ServiceAuthorization {
    static func removeRight(_ name: String = MimoService.settingsRight) throws {
        var description: CFDictionary?
        let existing = AuthorizationRightGet(name, &description)
        if existing == errAuthorizationDenied { return } // The right is already absent.
        guard existing == errAuthorizationSuccess else { throw DaemonFailure.unauthorized }
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else {
            throw DaemonFailure.unauthorized
        }
        defer { AuthorizationFree(authorization, []) }
        guard AuthorizationRightRemove(authorization, name) == errAuthorizationSuccess else {
            throw DaemonFailure.unauthorized
        }
    }

    static func installRight() throws {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else {
            throw DaemonFailure.unauthorized
        }
        defer { AuthorizationFree(authorization, []) }
        // Retain the explicit administrator recovery interface for legacy tools.
        // The GUI uses its installer-pinned XPC connection and never obtains this
        // right. Do not grant an ambient right to unrelated local processes.
        let rule: [String: Any] = ["class": "user", "group": "admin", "authenticate-user": true,
                                   "shared": false, "allow-root": true]
        guard AuthorizationRightSet(authorization, MimoService.settingsRight, rule as CFDictionary,
                                    "Change shared Mimo settings" as CFString, nil, nil) == errAuthorizationSuccess else {
            throw DaemonFailure.unauthorized
        }
    }

    static func validate(_ data: Data?) -> Bool {
        guard let data, data.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var external = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &external) { _ = data.copyBytes(to: $0) }
        var authorization: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&external, &authorization) == errAuthorizationSuccess,
              let authorization else { return false }
        defer { AuthorizationFree(authorization, []) }
        return MimoService.settingsRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                // The UI obtained the right; the daemon must recheck it without prompting.
                return AuthorizationCopyRights(authorization, &rights, nil, [], nil) == errAuthorizationSuccess
            }
        }
    }
}
