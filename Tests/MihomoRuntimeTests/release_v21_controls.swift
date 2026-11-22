import Darwin
import Foundation
import Security

/// VM-only release driver. Requests live in owner-only files; no secrets are CLI arguments.
@main
enum V21Controls {
    static func main() async throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "hw.model"]; process.standardOutput = pipe
        try process.run(); let model = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard String(decoding: model, as: UTF8.self).hasPrefix("VirtualMac") else { throw DaemonFailure.unauthorized }
        let args = Array(CommandLine.arguments.dropFirst())
        var request = DaemonRequest(args.first == "events" ? .events : .state)
        var authorization: AuthorizationRef?
        defer { if let authorization { AuthorizationFree(authorization, []) } }
        if args.first == "request", args.count == 2 {
            guard geteuid() == 0 else { throw DaemonFailure.unauthorized }
            request = try JSONDecoder().decode(DaemonRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            if request.expectedRevision == nil { request.expectedRevision = try await DaemonRPC.call(DaemonRequest(.state)).state?.revision }
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
        }
        let response = try await DaemonRPC.call(request, timeout: 75, returningFailures: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(response), as: UTF8.self))
    }
}
