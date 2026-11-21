import Foundation
import ServiceManagement

/// Applies the remembered Launch at login choice to `SMAppService.mainApp` once per launch, so a
/// registration macOS dropped (for example when a reinstall replaced the bundle) comes back.
@MainActor
enum LoginItemSync {
    static let changed = Notification.Name("MimoLoginItemChanged")

    static func setEnabled(_ enabled: Bool) throws {
        store(enabled)
        defer { NotificationCenter.default.post(name: changed, object: nil) }
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

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
        let before = status
        let action = LoginItemPolicy.action(stored: storedChoice, status: before)
        var fields = ["action": action.rawValue, "status": before.rawValue]
        do {
            switch action {
            case .register: try SMAppService.mainApp.register()
            case .unregister: try SMAppService.mainApp.unregister()
            case .adopt: store(true)
            case .none: break
            }
            fields["result"] = "ok"
            fields["status_after"] = status.rawValue
            RuntimeLog.shared.info("login_item_synced", fields: fields)
        } catch {
            fields["result"] = "failed"
            fields["error"] = error.localizedDescription
            RuntimeLog.shared.error("login_item_synced", fields: fields)
        }
    }
}
