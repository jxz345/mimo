import Foundation
import ServiceManagement

/// Applies the remembered Launch at login choice to `SMAppService.mainApp` once per launch, so a
/// registration macOS dropped (for example when a reinstall replaced the bundle) comes back.
@MainActor
enum LoginItemSync {
    static var storedChoice: Bool? {
        MimoAppGroup.defaults.object(forKey: MimoPreferenceKey.launchAtLogin) as? Bool
    }

    static func store(_ enabled: Bool) {
        MimoAppGroup.defaults.set(enabled, forKey: MimoPreferenceKey.launchAtLogin)
    }

    /// Called in each account by the uninstaller, before the bundle is removed.
    /// Removing the preference prevents a later reinstall from registering again.
    static func removeForUninstall() throws {
        // .notFound may mean the public bundle was deleted. A saved enabled
        // choice still requires explicit removal. Accounts with no registration
        // or enabled choice need only preference cleanup: macOS can reject an
        // unnecessary unregister request in their logged-out bootstrap session.
        if status == .enabled || status == .requiresApproval || storedChoice == true {
            do {
                try SMAppService.mainApp.unregister()
            } catch let error as NSError {
                // The public error-domain constant requires macOS 15; retain macOS
                // 14 support by checking this API's job-not-found result and state.
                guard error.code == kSMErrorJobNotFound,
                      status == .notRegistered || status == .notFound else { throw error }
            }
        }
        guard status == .notRegistered || status == .notFound else {
            throw CocoaError(.executableRuntimeMismatch)
        }
        MimoAppGroup.defaults.removeObject(forKey: MimoPreferenceKey.launchAtLogin)
        guard MimoAppGroup.defaults.synchronize() else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Synchronous access is reserved for the non-GUI cleanup/status commands.
    /// Views and app startup use LoginItemController's background worker.
    static var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    static func syncAtLaunch() {
        LoginItemController.shared.synchronize(stored: storedChoice)
    }
}
