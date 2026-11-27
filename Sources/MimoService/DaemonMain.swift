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
        defer { RuntimeLog.shared.flush() }
        do {
#if MIMO_VM_ACCEPTANCE
            try MimoSystemRuntime.requireAcceptanceVM()
            if CommandLine.arguments.dropFirst() == ["--vm-acceptance-status"] {
                print("VM-only acceptance runtime; no release qualification granted.")
                return
            }
#endif
            let runtime = MimoSystemRuntime()
            // Independently registered at boot, but saved Stop intent still wins.
            if CommandLine.arguments.dropFirst() == ["--engine"], !(try runtime.servicePreferences().engine) { return }
            if !runtime.networkReleaseRequested, CommandLine.arguments.dropFirst() == ["--supervisor"] || CommandLine.arguments.dropFirst() == ["--engine"] {
                // Establish boot protection in the existing roles before either process
                // can restore Direct or approve traffic in this boot.
                try runtime.ensureBootGuard()
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
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--record-installation-event", arguments.count == 6 {
                try MimoInstallationJournal.append(attempt: arguments[1], operation: arguments[2],
                    stage: arguments[3], item: arguments[4], status: arguments[5])
                return
            }
            if let command = arguments.first, ["--restore-direct-online", "--close-direct-failure"].contains(command), arguments.count == 2 {
                guard let id = UUID(uuidString: arguments[1]) else { throw DaemonFailure.invalidRequest }
                let owner = try runtime.directReleaseRequest(id: id)
                let fields = ["operation": id.uuidString, "parentPID": String(owner.parentPID), "action": command == "--restore-direct-online" ? "release" : "close"]
                RuntimeLog.shared.info("mimo_direct_worker_child_started", fields: fields)
                do {
                    // Live operation: never inherit offline maintenance privileges.
                    if command == "--restore-direct-online" { try runtime.restoreDirect(owner: owner) }
                    else { try runtime.closeDirectFailure(owner: owner) }
                    let result = MimoDirectReleaseResult(id: id, completedAt: .now,
                                                        nativeVerified: runtime.nativeReleaseIssue == nil,
                                                        pfHealth: command == "--restore-direct-online" ? runtime.latestPFHealthReceipt : nil)
                    RuntimeLog.shared.info("mimo_direct_worker_child_finished", fields: fields)
                    print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
                    return
                } catch {
                    RuntimeLog.shared.error("mimo_direct_worker_child_failed", fields: fields)
                    throw error
                }
            }
            let installationAttempt = arguments.first == "--check-installation" && arguments.count == 2 ? arguments[1] : nil
            if let installationAttempt, UUID(uuidString: installationAttempt) == nil { throw DaemonFailure.invalidRequest }
            switch installationAttempt == nil ? arguments : ["--check-installation"] {
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
                try runtime.prepareInstallation(startingInDirect: true)
                return
            case ["--prepare-installation"]:
                try runtime.prepareInstallation(startingInDirect: runtime.networkReleaseRequested)
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
                // Wait for any peer repair before publishing removal intent.
                // Later repairs read this marker while holding the same lock.
                let peerLock = try MimoFirewallLock.acquire(at: MimoRuntime.directory.appendingPathComponent("peer-repair.lock"), timeout: .seconds(20))
                try withExtendedLifetime(peerLock) {
                    try MimoFirewallLock.mutate {
                        _ = try runtime.writePrivate(Data(), name: "maintenance")
                    }
                }
                // Revoke promptly through the short PF lock. The lifecycle
                // owner may still be draining DNS or inspecting native access.
                try runtime.holdApplicationGate()
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
                RuntimeLog.shared.flush()
                execv(MimoRuntime.engine.path, &argv)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            case ["--check-installation"]:
                try runtime.checkInstallation()
                Task { @MainActor in
                    // Startup retires legacy network controls before servicing
                    // requests. Allow that bounded work to finish on a busy Mac.
                    let deadline = Date.now.addingTimeInterval(120)
                    var problems = ["supervisor"]
                    while Date.now < deadline {
                        var request = DaemonRequest(.supervisor)
                        request.supervisor = MimoSupervisorRequest(.state)
                        async let supervisor = try? DaemonRPC.call(request, timeout: 10, serviceLabel: MimoRuntime.supervisorLabel)
                        async let core = try? DaemonRPC.call(DaemonRequest(.state), timeout: 10)
                        let (response, coreResponse) = await (supervisor, core)
                        guard let flags = try? runtime.servicePreferences() else { break }
                        problems = MimoInstallationReadiness.problems(flags: flags, supervisor: response?.routing)
                        if coreResponse?.state == nil { problems.append("core_communication") }
                        if problems.isEmpty, (try? runtime.checkInstalledController()) != nil {
                            print("All Mimo services, engine controller and infrastructure monitors are healthy.")
                            exit(0)
                        }
                        if problems.isEmpty { problems = ["engine_controller"] }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if let installationAttempt {
                        for problem in problems {
                            try? MimoInstallationJournal.append(attempt: installationAttempt, operation: "install", stage: "health_failed", item: problem)
                        }
                    }
                    fputs("Service verification failed: \(problems.joined(separator: ", "))\n", stderr)
                    exit(1)
                }
                RunLoop.main.run()
                return
            default: break
            }
            if CommandLine.arguments.dropFirst() == ["--supervisor"] {
                let supervisor = MimoSupervisor()
                let directory = MimoService.storageURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard let lock = try SingleInstanceLock(url: directory.appendingPathComponent("instance.lock")) else { exit(0) }
                let service = try DaemonService(storage: FilePreferenceStorage(url: MimoService.storageURL), supervisor: supervisor)
                supervisor.monitoringOperation = { [weak service] in service?.changeMonitoring($0) }
                supervisor.coreNetworkChanged = { [weak service] in
                    guard let service else { throw DaemonFailure.unavailable }
                    let response = await service.handle(DaemonRequest(.networkChanged), uid: 0)
                    if let failure = response.failure { throw failure }
                }
                let peer = try MimoPeerWatchdog(role: .supervisor)
                supervisor.peerWatchdog = peer
                let listener = NSXPCListener(machServiceName: MimoRuntime.supervisorLabel)
                listener.delegate = supervisor
                listener.resume()
                let coreListener = NSXPCListener(machServiceName: MimoService.label)
                coreListener.delegate = service
                coreListener.resume()
                let coreControls = try InstalledAppControlListener(label: MimoService.controlLabel) { service.accept($0, installedApp: true) }
                let controls = try? InstalledAppControlListener(label: MimoService.supervisorControlLabel) {
                    supervisor.accept($0, installedApp: true)
                }
                if controls == nil { RuntimeLog.shared.error("mimo_installed_app_control_unavailable") }
                peer.start()
                supervisor.start()
                Task { await service.start() }
                signal(SIGTERM, SIG_IGN)
                let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
                termination.setEventHandler {
                    peer.stop(); service.stop(); supervisor.stop()
                    listener.invalidate(); controls?.invalidate(); coreListener.invalidate(); coreControls.invalidate()
                    Task { @MainActor in
                        await supervisor.drainInfrastructure()
                        await peer.drain()
                        RuntimeLog.shared.flush(); exit(0)
                    }
                }
                termination.resume()
                RuntimeLog.shared.info("daemon_started", fields: ["pid": String(getpid()), "role": "supervisor"])
                withExtendedLifetime((lock, service, supervisor, peer, listener, coreListener, controls, coreControls, termination)) { RunLoop.main.run() }
                return
            }
            if CommandLine.arguments.dropFirst() == ["--heartbeat"] {
                let peer = try MimoPeerWatchdog(role: .heartbeat)
                let logs = MimoHeartbeatLogListener()
                let listener = NSXPCListener(machServiceName: MimoService.heartbeatLogLabel)
                listener.delegate = logs; listener.resume()
                peer.start()
                signal(SIGTERM, SIG_IGN)
                let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
                termination.setEventHandler {
                    peer.stop(); listener.invalidate()
                    Task { @MainActor in await peer.drain(); RuntimeLog.shared.flush(); exit(0) }
                }
                termination.resume()
                withExtendedLifetime((peer, logs, listener, termination)) { RunLoop.main.run() }
                return
            }
            if CommandLine.arguments.dropFirst() == ["--recover-direct"] {
                Task { @MainActor in
                    do {
                        var authorization: AuthorizationRef?
                        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else { throw DaemonFailure.unauthorized }
                        defer { AuthorizationFree(authorization, []) }
                        let status = MimoService.settingsRight.withCString { name in
                            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                            return withUnsafeMutablePointer(to: &item) { pointer in
                                var rights = AuthorizationRights(count: 1, items: pointer)
                                return AuthorizationCopyRights(authorization, &rights, nil, [.extendRights], nil)
                            }
                        }
                        var external = AuthorizationExternalForm()
                        guard status == errAuthorizationSuccess, AuthorizationMakeExternalForm(authorization, &external) == errAuthorizationSuccess else { throw DaemonFailure.unauthorized }
                        let data = withUnsafeBytes(of: external) { Data($0) }
                        try await MimoDirectRecovery.run(authorization: data) { try await DaemonRPC.call($0, timeout: 75) }
                        RuntimeLog.shared.info("mimo_direct_recovery_saved")
                        print("Direct mode saved and networking restored. IP-monitor Start/Stop intent was retained.")
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
                           response.state?.build == "3.1" {
                            print("Background service 3.1 responds to XPC.")
                            exit(0)
                        }
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    exit(1)
                }
                RunLoop.main.run()
                return
            }
            // An old no-argument monitoring job must not duplicate the new owner.
            fputs("Install the current launchd jobs; expected --supervisor or --heartbeat.\n", stderr)
            exit(2)
        } catch {
            RuntimeLog.shared.error("daemon_start_failed", fields: ["error": error.localizedDescription])
            fputs("Mimo service operation failed: \(error.localizedDescription)\n", stderr)
            RuntimeLog.shared.flush()
            exit(1)
        }
    }
}
#endif
