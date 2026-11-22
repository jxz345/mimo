import Darwin
import Foundation
import Security

/// Bounded VM-only driver for release/coexistence acceptance, without secrets.
@main
enum ReleaseControls {
    static func main() async throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "hw.model"]; process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard geteuid() == 0, String(decoding: data, as: UTF8.self).hasPrefix("VirtualMac") else { throw DaemonFailure.unauthorized }
        let args = Array(CommandLine.arguments.dropFirst())
        var request = DaemonRequest(.supervisor), label = MimoRuntime.supervisorLabel
        var message = MimoSupervisorRequest(.state)
        var authorization: AuthorizationRef?
        defer { if let authorization { AuthorizationFree(authorization, []) } }
        if args.count == 2, let service = MimoServiceID(rawValue: args[0]), let operation = MimoServiceOperation(rawValue: args[1]) {
            message = MimoSupervisorRequest(.service); message.service = service; message.operation = operation
        } else if args.first == "core" {
            request = DaemonRequest(.state); label = MimoService.label
        } else if args.first == "mode" || args.first == "bypass" {
            let current = try await DaemonRPC.call(DaemonRequest(.state))
            guard let state = current.state else { throw DaemonFailure.unavailable }
            request = DaemonRequest(args[0] == "mode" ? .configureRouting : .configure)
            request.expectedRevision = state.revision; label = MimoService.label
            if args[0] == "mode" {
                guard args.count == 2, let mode = ProxyMode(rawValue: args[1]) else { throw DaemonFailure.invalidRequest }
                var routing = state.routing!.configuration; routing.mode = mode; request.routing = routing
            } else if args.count == 2 {
                var settings = state.settings
                settings.bypassBlocks = try JSONDecoder().decode([MimoBypassBlock].self,
                    from: Data(contentsOf: URL(fileURLWithPath: args[1])))
                request.settings = settings
            } else {
                var settings = state.settings
                settings.bypassBlocks = [.init(name: "Acceptance domains", domains: [.init("v2-fixture.invalid"), .init("www.v2-fixture.invalid", match: .exact)])]
                request.settings = settings
            }
            guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else { throw DaemonFailure.unauthorized }
            let status = MimoService.settingsRight.withCString { name in
                var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                return withUnsafeMutablePointer(to: &item) { pointer in
                    var rights = AuthorizationRights(count: 1, items: pointer)
                    return AuthorizationCopyRights(authorization, &rights, nil, [.extendRights], nil)
                }
            }
            var external = AuthorizationExternalForm()
            guard status == errAuthorizationSuccess, AuthorizationMakeExternalForm(authorization, &external) == errAuthorizationSuccess else { throw DaemonFailure.unauthorized }
            request.authorization = withUnsafeBytes(of: external) { Data($0) }
        } else if !args.isEmpty { throw DaemonFailure.invalidRequest }
        if request.command == .supervisor { request.supervisor = message }
        let response = try await DaemonRPC.call(request, timeout: 75, serviceLabel: label, returningFailures: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(response), as: UTF8.self))
    }
}
