#if !MIMO_SERVICE_TEST
import Darwin
import Foundation
import Security

@main
enum DaemonMain {
    @MainActor
    static func main() {
        guard geteuid() == 0 else { fputs("Run the installed service through launchd.\n", stderr); exit(1) }
        umask(0o077)
        do {
#if MIMO_VM_ACCEPTANCE
            try MimoSystemRuntime.requireAcceptanceVM()
            if CommandLine.arguments.dropFirst() == ["--vm-acceptance-status"] {
                print("VM-only acceptance runtime; no release qualification granted.")
                return
            }
#endif
            let runtime = MimoSystemRuntime()
            if !runtime.networkReleaseRequested, CommandLine.arguments.dropFirst() == ["--supervisor"] || CommandLine.arguments.dropFirst() == ["--engine"] {
                // Synchronize with the separate boot loader before any process
                // can restore Direct or approve traffic in this boot.
                try runtime.ensureIndependentBootGuard()
                // Establish the public-traffic boundary before touching services
                // such as Keychain or directory lookups during a cold boot.
                try runtime.closeStartupGate()
                let closedAt = Date().timeIntervalSince1970
                RuntimeLog.shared.info("mimo_startup_guard_closed", fields: [
                    "confirmed": "true", "closedAt": String(closedAt),
                    "role": CommandLine.arguments[1]
                ])
            }
            SecKeychainSetUserInteractionAllowed(false)
            switch Array(CommandLine.arguments.dropFirst()) {
            case ["--migrate-legacy-names"]:
                try LegacyMachineMigration.prepare()
                return
            case ["--finish-name-migration"]:
                try LegacyMachineMigration.finish()
                return
            case ["--prepare-runtime"]:
                try runtime.checkInstallation()
                _ = try runtime.savedConfiguration()
                let flags = try runtime.servicePreferences()
                _ = try runtime.writePrivate(JSONEncoder().encode(flags), name: "services.json")
                try runtime.writeBlockingProfile()
                return
            case ["--prepare-activation"]:
                // Installer owns maintenance and has stopped every writer.
                _ = try runtime.persistDirectRecovery(activateServices: true)
                try runtime.saveServicePreferences(MimoServicePreferences())
                return
            case ["--network-release-requested"]:
                print(runtime.networkReleaseRequested ? "released" : "managed")
                return
            case ["--installation-mode"]:
                print(try runtime.savedConfiguration().mode.rawValue)
                return
            case ["--print-startup-firewall"]:
                print(MimoFirewallPolicy.startupBlocking, terminator: "")
                return
            case ["--close-gate"]:
                try runtime.closeGate()
                return
            case ["--begin-maintenance"]:
                try MimoFirewallLock.mutate {
                    _ = try runtime.writePrivate(Data(), name: "maintenance")
                }
                try runtime.closeGate()
                return
            case ["--restore-direct-offline"]:
                try runtime.restoreDirect(maintenanceRecovery: true)
                return
            case ["--uninstall-runtime"]:
                try runtime.restoreDirect(maintenanceRecovery: true, uninstalling: true)
                return
            case ["--restore-ipv6-preferences"]:
                try MimoIPv4Configuration.apply(restoring: true)
                return
            case ["--engine"]:
                guard !runtime.networkReleaseRequested else { return }
                try runtime.closeStartupGate()
                try runtime.checkInstallation()
                guard let group = getgrnam(MimoRuntime.engineGroup), getegid() == group.pointee.gr_gid else {
                    throw MimoRuntimeError.unavailable("Mihomo must run in its dedicated runtime group.")
                }
                try runtime.closeGate()
                try runtime.writeBlockingProfile()
                // IPv6 must enter the profile's REJECT rule even on a network
                // without native IPv6 at engine startup (it may appear later).
                setenv("SKIP_SYSTEM_IPV6_CHECK", "1", 1)
                let arguments = [MimoRuntime.engine.path, "-d", MimoRuntime.profileDirectory.path, "-f", MimoRuntime.blockingProfile.path]
                var argv = arguments.map { strdup($0) } + [nil]
                defer { argv.forEach { free($0) } }
                execv(MimoRuntime.engine.path, &argv)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            case ["--check-installation"]:
                try runtime.checkInstallation()
                let flags = try runtime.servicePreferences()
                Task { @MainActor in
                    for _ in 0..<20 {
                        var request = DaemonRequest(.supervisor)
                        request.supervisor = MimoSupervisorRequest(.state)
                        if let response = try? await DaemonRPC.call(request, timeout: 2, serviceLabel: MimoRuntime.supervisorLabel),
                           let state = response.routing, state.phase != .unavailable,
                           state.services.first(where: { $0.id == .core })?.health == (flags.core ? .running : .stopped),
                           state.services.first(where: { $0.id == .mihomo })?.health == (flags.engine ? .running : .stopped) {
                            print("Mimo supervisor and saved service lifecycle state are ready.")
                            exit(0)
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    exit(1)
                }
                RunLoop.main.run()
                return
            default: break
            }
            if CommandLine.arguments.dropFirst() == ["--supervisor"] {
                let supervisor = MimoSupervisor()
                let listener = NSXPCListener(machServiceName: MimoRuntime.supervisorLabel)
                listener.delegate = supervisor
                listener.resume()
                let controls = try? InstalledAppControlListener(label: MimoService.supervisorControlLabel) {
                    supervisor.accept($0, installedApp: true)
                }
                if controls == nil { RuntimeLog.shared.error("mimo_installed_app_control_unavailable") }
                supervisor.start()
                signal(SIGTERM, SIG_IGN)
                let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
                termination.setEventHandler { supervisor.stop(); listener.invalidate(); controls?.invalidate(); exit(0) }
                termination.resume()
                withExtendedLifetime((supervisor, listener, controls, termination)) { RunLoop.main.run() }
                return
            }
            if CommandLine.arguments.dropFirst() == ["--recover-direct"] {
                Task { @MainActor in
                    do {
                        let flags = try runtime.servicePreferences()
                        try await MimoDirectRecovery.run(coreWasEnabled: flags.core, send: { message in
                            var request = DaemonRequest(.supervisor); request.supervisor = message
                            let response = try await DaemonRPC.call(request, timeout: 20, serviceLabel: MimoRuntime.supervisorLabel)
                            if let failure = response.failure { throw failure }
                            guard let routing = response.routing else { throw DaemonFailure.unavailable }
                            return routing
                        }, persist: { try runtime.persistDirectRecovery() })
                        RuntimeLog.shared.info("mimo_direct_recovery_saved", fields: ["coreEnabled": String(flags.core)])
                        print("Direct mode saved and networking restored. The prior core Start/Stop preference was retained.")
                        exit(0)
                    } catch { fputs("Direct recovery did not complete: \(error.localizedDescription)\n", stderr); exit(1) }
                }
                RunLoop.main.run()
                return
            }
            if CommandLine.arguments.dropFirst() == ["--install-right"] {
                try ServiceAuthorization.installRight()
                return
            }
            if CommandLine.arguments.dropFirst() == ["--remove-right"] {
                try ServiceAuthorization.removeRight()
                return
            }
            if CommandLine.arguments.dropFirst() == ["--check-service"] {
                Task { @MainActor in
                    for _ in 0..<5 {
                        if let response = try? await DaemonRPC.call(DaemonRequest(.state), timeout: 2),
                           response.state?.build == "3.0" {
                            print("Background service 3.0 responds to XPC.")
                            exit(0)
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    exit(1)
                }
                RunLoop.main.run()
                return
            }
            guard CommandLine.arguments.count == 1 else { exit(2) }
            let directory = MimoService.storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let lock = try SingleInstanceLock(url: directory.appendingPathComponent("instance.lock")) else { exit(0) }
            let storage = try FilePreferenceStorage(url: MimoService.storageURL)
            let service = try DaemonService(storage: storage)
            let listener = NSXPCListener(machServiceName: MimoService.label)
            listener.delegate = service
            listener.resume()
            let controls = try? InstalledAppControlListener(label: MimoService.controlLabel) {
                service.accept($0, installedApp: true)
            }
            if controls == nil { RuntimeLog.shared.error("mimo_installed_app_control_unavailable") }
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termination.setEventHandler { service.stop(); listener.invalidate(); controls?.invalidate(); exit(0) }
            termination.resume()
            Task { await service.start() }
            RuntimeLog.shared.info("daemon_started", fields: ["pid": String(getpid())])
            withExtendedLifetime((lock, service, listener, controls, termination)) { RunLoop.main.run() }
        } catch {
            RuntimeLog.shared.error("daemon_start_failed", fields: ["error": error.localizedDescription])
            fputs("Mimo service operation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
