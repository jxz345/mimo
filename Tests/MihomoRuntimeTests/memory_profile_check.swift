import Darwin
import Foundation

/// Runs only against the isolated VM's installed, unconfigured Direct engine.
/// Never enables TUN, changes PF, or loads an upstream proxy.
@main
enum MemoryProfileCheck {
    struct Failure: Error { let message: String }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
    }

    @MainActor
    static func main() async throws {
        let model = BoundedProcess.run("/usr/sbin/sysctl", ["-n", "hw.model"])
        try require(geteuid() == 0 && model.text.hasPrefix("VirtualMac"), "Isolated VM administrator required")
        let runtime = MimoSystemRuntime()
        let configuration = try runtime.savedConfiguration()
        try require(configuration.mode == .direct && configuration.proxy == nil && runtime.gateState == "direct",
                    "Unconfigured Direct installation required")
        try runtime.checkInstallation()
        let startup = MihomoProfile.blocking()
        try runtime.loadProfile(startup)
        defer { try? runtime.loadProfile(startup) }
        try require(try runtime.matches(startup, active: false), "Startup profile must match the installed engine")
        print("PASS: installed-engine-accepts-stdin-validation-and-socket-payload")

        let marker = UUID().uuidString
        let candidate = startup + "\nauthentication:\n  - \"mimo-memory:\(marker)\"\n"
        try runtime.loadProfile(candidate)
        let contents = try runtime.profileContents()
        try require(contents == candidate, "Viewer must return exact delivered bytes")
        try require(try runtime.matches(candidate, active: false), "Receipt must bind the exact profile to the engine")
        try require(try !runtime.matches(candidate + "\n# altered\n", active: false), "Different bytes must not match receipt")
        print("PASS: exact-profile-view-and-digest-binding")

        let processList = BoundedProcess.run("/bin/ps", ["-axo", "command="])
        try require(processList.status == 0 && !processList.text.contains(marker), "Payload must not appear in process arguments")
        for directory in [MimoRuntime.profileDirectory, MimoRuntime.directory] {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    let data = try Data(contentsOf: file)
                    try require(data.range(of: Data(marker.utf8)) == nil, "Payload must not appear in runtime files")
                }
            }
        }
        try require(try Data(contentsOf: MimoRuntime.blockingProfile) == Data(startup.utf8), "Startup file remains credential-free")
        for name in ["candidate.yaml", "config.yaml", "reload.json", "blocking.yaml", "controller.sock"] {
            try require(!FileManager.default.fileExists(atPath: MimoRuntime.directory.appendingPathComponent(name).path),
                        "Obsolete generated profile must be removed after upgrade")
        }
        var socketInfo = stat()
        try require(lstat(MimoRuntime.controller.path, &socketInfo) == 0 && socketInfo.st_mode & 0o777 == 0o600,
                    "Controller must be owner-only")
        print("PASS: payload-absent-from-disk-and-argv-and-controller-private")

        do {
            try runtime.loadProfile("rules: [unterminated")
            throw Failure(message: "Malformed YAML was accepted")
        } catch is MimoRuntimeError { }
        try runtime.loadProfile(startup)
        try require(try runtime.matches(startup, active: false), "Blocking profile remains available after invalid reload")
        print("PASS: invalid-profile-rejected-and-blocking-profile-restored")

        var open = DaemonRequest(.supervisor)
        open.supervisor = MimoSupervisorRequest(.profile)
        let response = try await DaemonRPC.call(open, timeout: 15, serviceLabel: MimoRuntime.supervisorLabel)
        try require(response.failure == nil && response.profileContents == startup && response.state == nil,
                    "Authorized profile command returns only the private snapshot")
        var state = DaemonRequest(.supervisor)
        state.supervisor = MimoSupervisorRequest(.state)
        let publicResponse = try await DaemonRPC.call(state, timeout: 15, serviceLabel: MimoRuntime.supervisorLabel)
        try require(publicResponse.profileContents == nil && publicResponse.routing?.effectiveMode == .direct,
                    "Public state excludes profile contents and Direct remains active")
        print("PASS: authorized-viewer-and-public-state-redaction")

        var reload = DaemonRequest(.supervisor)
        var action = MimoSupervisorRequest(.service)
        action.service = .profileHosting; action.operation = .restart
        reload.supervisor = action
        let reloaded = try await DaemonRPC.call(reload, timeout: 15, serviceLabel: MimoRuntime.supervisorLabel)
        try require(reloaded.failure == nil && reloaded.routing?.effectiveMode == .direct && runtime.gateState == "direct",
                    "Reload must preserve Direct")
        print("PASS: manual-profile-reload-preserves-Direct")
    }
}
