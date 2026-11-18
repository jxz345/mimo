import Darwin
import CryptoKit
import Foundation
import Security

/// VM-only driver for the public core XPC API. Credentials are input-only and
/// admin changes use the installed Authorization Services right, like the GUI.
@main
enum AcceptanceClient {
    static func printState(_ state: DaemonState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(state), as: UTF8.self))
    }

    static func authorization() throws -> (AuthorizationRef, Data) {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess,
              let reference else { throw DaemonFailure.unauthorized }
        let status = ExitIPService.settingsRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(reference, &rights, nil, [.extendRights], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(reference, [])
            throw DaemonFailure.unauthorized
        }
        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(reference, &external) == errAuthorizationSuccess else {
            AuthorizationFree(reference, [])
            throw DaemonFailure.unauthorized
        }
        return (reference, withUnsafeBytes(of: external) { Data($0) })
    }

    static func main() async throws {
        guard geteuid() == 0 else { throw DaemonFailure.unauthorized }
        let hardware = Process()
        let pipe = Pipe()
        hardware.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        hardware.arguments = ["-n", "hw.model"]
        hardware.standardOutput = pipe
        try hardware.run()
        let model = pipe.fileHandleForReading.readDataToEndOfFile()
        hardware.waitUntilExit()
        guard hardware.terminationStatus == 0, String(decoding: model, as: UTF8.self).hasPrefix("VirtualMac") else {
            throw DaemonFailure.invalidRequest
        }
        SecKeychainSetUserInteractionAllowed(false)
        let args = Array(CommandLine.arguments.dropFirst())
        guard let operation = args.first else { throw DaemonFailure.invalidRequest }
        let credentials = SystemCredentials()
        if operation == "credential-digest" {
            // The saved-configuration driver captures this only in root-owned
            // memory/evidence. It never exports a password or changes Keychain.
            let value = try credentials.read(account: MimoRuntime.proxyPasswordAccount) ?? ""
            print(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined())
            return
        }
        if operation == "require-empty-credential" {
            guard try credentials.read(account: MimoRuntime.proxyPasswordAccount) == nil else { throw DaemonFailure.conflict }
            print("Proxy credential is absent.")
            return
        }
        if operation == "clear-fixture-credential" {
            guard args.count == 2 else { throw DaemonFailure.invalidRequest }
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
            let existing = try credentials.read(account: MimoRuntime.proxyPasswordAccount)
            guard existing == nil || existing == fixture["password"] as? String || existing == "invalid-fixture-password" else {
                throw DaemonFailure.conflict
            }
            try credentials.delete(account: MimoRuntime.proxyPasswordAccount)
            print("Removed only the test proxy credential.")
            return
        }
        let current = try await DaemonRPC.call(DaemonRequest(.state), timeout: 10)
        guard let state = current.state, current.failure == nil else { throw current.failure ?? DaemonFailure.unavailable }
        if operation == "state" { try printState(state); return }
        if operation == "check-private-profile" || operation == "check-blocking-profile" {
            var request = DaemonRequest(.supervisor)
            request.supervisor = MimoSupervisorRequest(.profile)
            let (reference, external) = try authorization()
            defer { AuthorizationFree(reference, [.destroyRights]) }
            request.authorization = external
            let response = try await DaemonRPC.call(request, timeout: 15, serviceLabel: MimoRuntime.supervisorLabel)
            guard response.failure == nil, let profile = response.profileContents,
                  let proxy = state.routing?.configuration.proxy else { throw DaemonFailure.unavailable }
            if operation == "check-blocking-profile" {
                guard profile == MihomoProfile.blocking() else { throw DaemonFailure.conflict }
                print("{\"openedProfileMatchesBlockingRuntime\":true}")
                return
            }
            let secret = try credentials.read(account: MimoRuntime.proxyPasswordAccount) ?? ""
            guard profile.contains(ClashVergeProfile.quoted(proxy.username)),
                  secret.isEmpty || profile.contains(ClashVergeProfile.quoted(secret)),
                  profile.contains("ipv6: false") else { throw DaemonFailure.conflict }
            for directory in [MimoRuntime.directory, MimoRuntime.profileDirectory] {
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
                    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    if secret.utf8.count >= 8 {
                        guard try Data(contentsOf: file).range(of: Data(secret.utf8)) == nil else { throw DaemonFailure.credential }
                    }
                }
            }
            guard try Data(contentsOf: MimoRuntime.blockingProfile) == Data(MihomoProfile.blocking().utf8) else {
                throw DaemonFailure.conflict
            }
            print("{\"privateProfileMatchesSavedCredential\":true,\"startupRemainsCredentialFree\":true}")
            return
        }
        var request = DaemonRequest(.state)
        switch operation {
        case "proxy-metadata":
            guard args.count == 2 else { throw DaemonFailure.invalidRequest }
            request.command = .saveProxy
            request.proxy = try JSONDecoder().decode(MimoProxy.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            // Deliberately omit proxyPassword. Faults use a bad username or
            // endpoint, so the user's saved secret is never overwritten.
        case "initialize":
            request.command = .initialize
            let preferences = MonitoringPreferences(provider: .ipWhois, providerPool: [.ipWhois], refreshInterval: .fifteenMinutes)
            request.settings = MachineSettings(preferences: preferences, tailscaleProviderEnabled: true)
        case "proxy", "wrong-password":
            guard args.count == 2 else { throw DaemonFailure.invalidRequest }
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
            request.command = .saveProxy
            request.proxy = MimoProxy(ClashProxySettings(name: "Installed acceptance fixture", type: .socks5,
                server: fixture["bind"] as! String, port: fixture["port"] as! Int, username: fixture["username"] as! String))
            request.proxyPassword = operation == "proxy" ? fixture["password"] as? String : "invalid-fixture-password"
        case "mode":
            guard args.count == 2, let mode = ProxyMode(rawValue: args[1]) else { throw DaemonFailure.invalidRequest }
            request.command = .configureRouting
            var configuration = MimoConfiguration()
            configuration.mode = mode
            request.routing = configuration
        case "allow":
            request.command = .configure
            var settings = state.settings
            settings.allowlist = AllowedIPList(addresses: Array(args.dropFirst()))
            request.settings = settings
        case "tailnet":
            guard args.count == 2, ["start", "stop"].contains(args[1]) else { throw DaemonFailure.invalidRequest }
            request.command = .configure
            var settings = state.settings
            settings.tailscaleProviderEnabled = args[1] == "start"
            request.settings = settings
        case "refresh": request.command = .refresh
        default: throw DaemonFailure.invalidRequest
        }
        request.expectedRevision = state.revision
        let (reference, external) = try authorization()
        defer { AuthorizationFree(reference, [.destroyRights]) }
        request.authorization = external
        let response = try await DaemonRPC.call(request, timeout: 40)
        guard response.failure == nil, let result = response.state else { throw response.failure ?? DaemonFailure.unavailable }
        try printState(result)
    }
}
