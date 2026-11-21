import Foundation
import ServiceManagement
import Darwin

/// Carries the former bundle ID solely to remove its per-user SMAppService item.
/// It never starts a GUI, registers a login item, or runs with root privileges.
@main
enum LegacyLoginCleanup {
    @MainActor
    static func main() {
        guard geteuid() != 0, CommandLine.arguments.dropFirst() == ["--unregister-login-item"] else { exit(2) }
        let defaults = UserDefaults(suiteName: "group.com.example.exitipmonitor")!
        let key = "exit-ip.launch-at-login.v1"
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval || defaults.bool(forKey: key) {
                do { try service.unregister() }
                catch let error as NSError {
                    guard error.code == kSMErrorJobNotFound,
                          service.status == .notRegistered || service.status == .notFound else { throw error }
                }
            }
            guard service.status == .notRegistered || service.status == .notFound else { exit(1) }
            defaults.removeObject(forKey: key)
            guard defaults.synchronize() else { exit(1) }
            print("Legacy login registration removed.")
        } catch {
            fputs("Legacy login registration could not be removed.\n", stderr)
            exit(1)
        }
    }
}
