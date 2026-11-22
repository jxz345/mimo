import AppKit

/// A main-thread heartbeat lets an external installer distinguish a usable app from a process
/// suspended by macOS before main(), or an app blocked during startup. It contains no user data.
@MainActor
enum LaunchDiagnostics {
    private static let launchID = UUID().uuidString
    private static let started = Date()
    private static var ready = false
    private static var timer: Timer?
    private static var stage = "process_entered"
    private static let stateURL = RuntimeLog.shared.directory
        .appendingPathComponent("launch-\(ProcessInfo.processInfo.processIdentifier).json")

    static func record(_ event: String) {
        stage = event
        RuntimeLog.shared.info(event, fields: [
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "launch_id": launchID,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        ])
        writeHeartbeat()
    }

    static func markReady() {
        guard !ready else { return }
        ready = true
        record("app_ready")
        let heartbeat = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in writeHeartbeat() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
    }

    static func stop() {
        ready = false
        timer?.invalidate()
        timer = nil
        record("app_terminating")
        try? FileManager.default.removeItem(at: stateURL)
    }

    private static func writeHeartbeat() {
        let activeSession = MimoAppDelegate.monitor.isSessionActive
        let record: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "launch_id": launchID,
            "started": Int(started.timeIntervalSince1970),
            "updated": Int(Date().timeIntervalSince1970),
            "ready": ready,
            "stage": stage,
            "bundle_path": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "dashboard_open": DashboardWindowController.shared.isOpen,
            "session_active": activeSession,
            "dashboard_visible": activeSession && DashboardWindowController.shared.window?.isVisible == true,
            "dashboard_minimized": activeSession && DashboardWindowController.shared.window?.isMiniaturized == true,
            "dashboard_key": activeSession && DashboardWindowController.shared.window?.isKeyWindow == true,
            "dashboard_on_active_space": activeSession && DashboardWindowController.shared.window?.isOnActiveSpace == true,
            "app_active": activeSession && NSApp?.isActive == true,
            "dock_visible": NSApp?.activationPolicy() == .regular,
            "status_item_visible": (NSApp?.delegate as? MimoAppDelegate)?.statusItemIsVisible == true
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: stateURL, options: .atomic)
        } catch {
            // Do not report success if the readiness file cannot be written; the external
            // checker will time out and collect this error from the runtime log.
            RuntimeLog.shared.error("launch_heartbeat_failed", fields: ["error": error.localizedDescription])
        }
    }
}

#if !MIMO_TEST_HOST
@main
enum MimoEntryPoint {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--migrate-user-names"] {
            guard geteuid() != 0 else { exit(1) }
            do { try LegacyNaming.migrateUser(); print("Mimo preferences migrated."); exit(0) }
            catch { fputs("Mimo preference migration failed; original data was retained.\n", stderr); exit(1) }
        }
        if CommandLine.arguments.dropFirst() == ["--unregister-login-item"] {
            guard geteuid() != 0 else {
                fputs("Run login-item cleanup as the account that owns it, not root.\n", stderr)
                exit(1)
            }
            do {
                try LoginItemSync.removeForUninstall()
                print("Mimo login item and saved login preference removed.")
                exit(0)
            } catch {
                fputs("Mimo login-item cleanup failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if CommandLine.arguments.dropFirst() == ["--login-item-status"] {
            print("\(LoginItemSync.status.rawValue); saved=\(LoginItemSync.storedChoice.map(String.init) ?? "unset")")
            return
        }
        if CommandLine.arguments.dropFirst() == ["--check-service-access"] {
            // A read-only diagnostic uses this exact installed executable, even
            // from a standard account. Never accepts commands or prints state,
            // profiles, credentials, or an authorization credential.
            Task { @MainActor in
                var stage = "core state"
                do {
                    let core = try await DaemonRPC.call(DaemonRequest(.state), serviceLabel: MimoService.controlLabel)
                    guard core.state != nil else { throw DaemonFailure.unavailable }
                    // Stale revisions reach each mutation's authorization check
                    // but cannot change settings, credentials, or routing.
                    for command: DaemonCommand in [.configure, .initialize, .setToken, .removeToken,
                                                   .configureRouting, .saveProxy, .removeProxy, .selectProxy] {
                        stage = "core \(command.rawValue) authorization"
                        var stale = DaemonRequest(command)
                        stale.expectedRevision = -1
                        do {
                            _ = try await DaemonRPC.call(stale, serviceLabel: MimoService.controlLabel)
                            throw DaemonFailure.invalidRequest
                        } catch DaemonFailure.conflict {}
                    }
                    var request = DaemonRequest(.supervisor)
                    stage = "supervisor state"
                    request.supervisor = MimoSupervisorRequest(.state)
                    let supervisor = try await DaemonRPC.call(request, serviceLabel: MimoService.supervisorControlLabel)
                    guard supervisor.routing != nil else { throw DaemonFailure.unavailable }
                    request.supervisor = MimoSupervisorRequest(.profile)
                    stage = "profile read"
                    let profile = try await DaemonRPC.call(request, serviceLabel: MimoService.supervisorControlLabel)
                    guard profile.profileContents != nil else { throw DaemonFailure.unavailable }
                    // Missing service/operation fields are rejected before a
                    // lifecycle operation can run, after checking app identity.
                    request.supervisor = MimoSupervisorRequest(.service)
                    stage = "service authorization"
                    do {
                        _ = try await DaemonRPC.call(request, timeout: 75, serviceLabel: MimoService.supervisorControlLabel)
                        throw DaemonFailure.invalidRequest
                    } catch DaemonFailure.conflict {}
                    if geteuid() != 0 {
                        stage = "root-only operation restriction"
                        request.supervisor = MimoSupervisorRequest(.approve)
                        do {
                            _ = try await DaemonRPC.call(request, serviceLabel: MimoService.supervisorControlLabel)
                            throw DaemonFailure.invalidRequest
                        } catch DaemonFailure.unauthorized {}
                        do {
                            _ = try await DaemonRPC.call(DaemonRequest(.networkChanged), serviceLabel: MimoService.controlLabel)
                            throw DaemonFailure.invalidRequest
                        } catch DaemonFailure.unauthorized {}
                    }
                    print("PASS: installed-app controls and private profile access; root-only operations remain restricted")
                    exit(0)
                } catch {
                    let reason = (error as? DaemonFailure)?.rawValue ?? "request failed"
                    fputs("Service access check failed at \(stage): \(reason).\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }
        do { try LegacyNaming.migrateUser() }
        catch { fputs("Mimo could not migrate older presentation preferences.\n", stderr) }
        guard SingleInstanceController.acquire() else { return }
        LaunchDiagnostics.record("process_entered")
        let application = NSApplication.shared
        let delegate = MimoAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        LaunchDiagnostics.record("app_initialized")
        withExtendedLifetime(delegate) { application.run() }
    }
}
#endif
