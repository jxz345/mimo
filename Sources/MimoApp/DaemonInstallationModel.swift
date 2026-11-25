import AppKit
import Darwin
import SwiftUI

/// One model per dashboard, shared by both responsive layouts. Authentication and launchctl
/// run off the main thread so the dashboard and launch heartbeat remain responsive.
@MainActor
final class DaemonInstallationModel: ObservableObject {
    @Published private(set) var monitorInstalled = false
    @Published private(set) var responderInstalled = false
    @Published private(set) var isInstalling = false
    @Published private(set) var message: String?
    @Published private(set) var hasError = false

    var serviceInstalled: Bool { monitorInstalled }
    var isInstalled: Bool { serviceInstalled }

    init() { reload() }

    func reload() {
        monitorInstalled = FileManager.default.fileExists(atPath: MimoRuntime.supervisorPlist)
        responderInstalled = monitorInstalled

    }

    func install(activating: Bool = false) {
        guard !isInstalling else { return }
        // An already installed service is recovered through its fixed supervisor
        // operation. Never fall back to a password dialog during normal use.
        if !activating && !MimoDeactivation.isConfirmed() && (serviceInstalled || FileManager.default.fileExists(atPath: MimoService.executable)) {
            isInstalling = true
            hasError = false
            message = "Restoring the installed background service…"
            Task {
                defer { isInstalling = false; reload() }
                do {
                    var message = MimoSupervisorRequest(.service)
                    message.service = .core; message.operation = .start
                    var request = DaemonRequest(.supervisor); request.supervisor = message
                    _ = try await DaemonRPC.call(request, timeout: 30, serviceLabel: MimoService.supervisorControlLabel)
                    MimoAppDelegate.monitor.applicationDidBecomeActive()
                    self.message = "Background service restored."
                } catch {
                    hasError = true
                    self.message = "The installed supervisor is unavailable. Automatic recovery will retry. If installation files were removed or replaced, reinstall Mimo."
                }
            }
            return
        }
        guard Bundle.main.url(forResource: "mihomo-v3", withExtension: "bin") != nil else {
            hasError = true
            message = "The bundled engine is missing. Reinstall the complete Mimo app."
            return
        }
        guard let script = Bundle.main.url(forResource: "daemon", withExtension: "sh") else {
            hasError = true
            message = "The installer is missing from this app. Reinstall the current release."
            RuntimeLog.shared.error("daemon_install_failed", fields: ["reason": "missing_bundled_script"])
            return
        }
        isInstalling = true
        hasError = false
        message = "Complete macOS administrator authentication to install the background service."
        // The setup output is saved here: the outcome check reads it, and the runtime log points to it.
        let logURL = RuntimeLog.shared.directory.appendingPathComponent("daemon-setup-\(UUID().uuidString).log")
        let operation: DaemonInstallation.Operation = activating || MimoDeactivation.isConfirmed() ? .activate : .install
        let appleScript = DaemonInstallation.appleScript(scriptPath: script.path, userName: NSUserName(), operation: operation)
        RuntimeLog.shared.info("daemon_install_started", fields: ["log": logURL.path])
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.runInstaller(appleScript: appleScript, logURL: logURL)
            }.value
            var outcome = result.outcome
            if outcome == .succeeded {
                outcome = .failed
                for _ in 0..<5 {
                    if let response = try? await DaemonRPC.call(DaemonRequest(.state), timeout: 2), let state = response.state,
                       state.build == "3.0" {
                        MimoAppDelegate.monitor.receive(state)
                        outcome = .succeeded
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            reload()
            isInstalling = false
            switch outcome {
            case .succeeded:
                MimoAppDelegate.monitor.refreshInstallationState()
                message = operation == .activate ? "Mimo activated. All background services enabled in Direct mode." : "Background service installed. Complete shared monitoring setup below."
                RuntimeLog.shared.info("daemon_install_succeeded", fields: ["log": logURL.path])
            case .cancelled:
                message = "Installation cancelled. Click Install Service to try again."
                RuntimeLog.shared.info("daemon_install_cancelled", fields: ["log": logURL.path])
            case .failed:
                hasError = true
                message = "Service installation did not complete. Click Retry Installation to try again."
                RuntimeLog.shared.error("daemon_install_failed", fields: ["log": logURL.path])
            }
        }
    }

    func deactivate() {
        guard !isInstalling, let script = Bundle.main.url(forResource: "daemon", withExtension: "sh") else { return }
        isInstalling = true
        hasError = false
        message = "Removing Mimo services and restoring system networking…"
        let logURL = RuntimeLog.shared.directory.appendingPathComponent("daemon-deactivate-\(UUID().uuidString).log")
        let appleScript = DaemonInstallation.appleScript(scriptPath: script.path, userName: NSUserName(), operation: .deactivate)
        RuntimeLog.shared.info("mimo_deactivation_started", fields: ["log": logURL.path])
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.runInstaller(appleScript: appleScript, logURL: logURL, deactivating: true)
            }.value
            isInstalling = false
            reload()
            MimoAppDelegate.monitor.refreshInstallationState()
            LoginItemController.shared.refresh()
            for (index, stage) in MimoCleanupEvent.stages(in: result.output).enumerated() {
                RuntimeLog.shared.info("mimo_cleanup_step", fields: ["stage": stage, "step": String(format: "%02d", index + 1)])
            }
            switch result.outcome {
            case .succeeded:
                message = "Network controls released. Exit IP monitoring continues while this app is open. Safe to delete Mimo.app."
                RuntimeLog.shared.info("mimo_deactivation_succeeded", fields: ["log": logURL.path])
            case .cancelled:
                message = "Cleanup cancelled. Mimo has not confirmed removal."
                RuntimeLog.shared.info("mimo_deactivation_cancelled", fields: ["log": logURL.path])
            case .failed:
                hasError = true
                message = "Cleanup did not finish. Retry cleanup before deleting Mimo.app."
                RuntimeLog.shared.error("mimo_deactivation_failed", fields: ["log": logURL.path])
            }
        }
    }

    private struct Result: Sendable {
        let outcome: DaemonInstallation.Outcome
        let output: String
    }

    nonisolated private static func runInstaller(appleScript: String, logURL: URL, deactivating: Bool = false) -> Result {
        do {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            // A file avoids pipe-buffer deadlocks, even with verbose daemon diagnostics.
            process.standardOutput = log
            process.standardError = log
            try process.run()
            process.waitUntilExit()
            if deactivating && process.terminationStatus == 0 {
                let removed = MimoDeactivation.isConfirmed() &&
                    ![MimoService.label, MimoRuntime.supervisorLabel, MimoRuntime.engineLabel,
                      "com.mimo.pf-boot", "com.mimo.infrastructure"].contains(where: jobLoaded)
                let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                let completed = MimoCleanupEvent.stages(in: output).contains("uninstall_completed")
                return Result(outcome: removed && completed ? .succeeded : .failed, output: output)
            }
            let monitorLoaded = process.terminationStatus == 0 && jobLoaded(MimoService.label)
            let responderLoaded = process.terminationStatus == 0 && jobLoaded(MimoRuntime.supervisorLabel)
            if process.terminationStatus == 0 && (!monitorLoaded || !responderLoaded) {
                try log.write(contentsOf: Data("\nVerification failed: the background service must be loaded.\n".utf8))
            }
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "No installer output was available."
            return Result(outcome: DaemonInstallation.outcome(exitStatus: process.terminationStatus,
                          output: output, monitorLoaded: monitorLoaded, responderLoaded: responderLoaded),
                          output: String(output.suffix(16_000)))
        } catch {
            return Result(outcome: .failed, output: error.localizedDescription)
        }
    }

    nonisolated private static func jobLoaded(_ label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Do not leave post-install verification waiting indefinitely on launchd.
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            guard !process.isRunning else {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return false
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
