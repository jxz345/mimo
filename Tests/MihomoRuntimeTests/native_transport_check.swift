import Foundation
import Darwin
import SystemConfiguration

@main
enum NativeTransportCheck {
    @MainActor static func main() async throws {
        if CommandLine.arguments[1] == "serve-transport" {
            guard BoundedProcess.run("/usr/sbin/sysctl", ["-n", "hw.model"]).text.hasPrefix("VirtualMac"),
                  geteuid() == 0, let group = getgrnam("_mimo"), setgid(group.pointee.gr_gid) == 0 else {
                fatalError("Isolated VM root and private runtime group are required")
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let output = root.appendingPathComponent("native.pf")
            var previous: String?
            let observer = MimoNativeTransportObserver { transport in
                do {
                    let rules = try transport.render()
                    if CommandLine.arguments.contains("--trace") {
                        let entry: [String: Any] = ["time": Date().timeIntervalSince1970,
                            "infrastructureCount": transport.infrastructure.count,
                            "sockets": transport.sockets.filter { $0.destination != nil }.map {
                                ["source": $0.source ?? "*", "port": String($0.port), "destination": $0.destination ?? ""]
                            }, "tcpRules": rules.split(separator: "\n").filter { $0.contains("proto tcp") }.map(String.init)]
                        var data = try JSONSerialization.data(withJSONObject: entry)
                        data.append(10)
                        let trace = root.appendingPathComponent("native-observations.jsonl")
                        if !FileManager.default.fileExists(atPath: trace.path) { FileManager.default.createFile(atPath: trace.path, contents: nil) }
                        let handle = try FileHandle(forWritingTo: trace)
                        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
                    }
                    guard rules != previous else { return }
                    try rules.write(to: output, atomically: true, encoding: .utf8)
                    let result = BoundedProcess.run("/sbin/pfctl", ["-a", "com.apple/001.mimo-packet/native-transport", "-f", output.path])
                    guard result.status == 0 else { fatalError("Test transport policy could not be applied") }
                    previous = rules
                } catch { fatalError("Test transport policy could not be rendered") }
            }
            var enabled: Bool?
            while true {
                let next = !FileManager.default.fileExists(atPath: CommandLine.arguments[3])
                if enabled != next { observer.start(tailnetEnabled: next); enabled = next }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        if CommandLine.arguments[1] == "observe-load" {
            guard BoundedProcess.run("/usr/sbin/sysctl", ["-n", "hw.model"]).text.hasPrefix("VirtualMac"),
                  geteuid() == 0 else { fatalError("Isolated VM root is required") }
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let name = CommandLine.arguments[3]
            var events: [String] = [], diagnostics: [String] = []
            let observer = MimoNetworkObserver { events.append($0) }
            observer.diagnostic = { diagnostics.append($0) }
            observer.start()
            try await Task.sleep(for: .milliseconds(250))
            guard observer.isRunning else { fatalError("Network observers must be running") }
            events = []; diagnostics = []
            observer.willChangeProfile(engineProcess: Int32(CommandLine.arguments[4]))
            let body = try JSONSerialization.data(withJSONObject: ["path": root.appendingPathComponent(name + ".yaml").path])
            let request = root.appendingPathComponent("reload-request.json")
            try body.write(to: request)
            let loaded = BoundedProcess.run("/usr/bin/curl", ["--silent", "--fail", "--max-time", "5", "--unix-socket",
                root.appendingPathComponent("controller.sock").path, "-X", "PUT", "http://localhost/configs?force=true",
                "--data-binary", "@" + request.path], timeout: 6)
            observer.didChangeProfile()
            try await Task.sleep(for: .seconds(2))
            observer.stop()
            let result: [String: Any] = ["externalEvents": events, "diagnostics": diagnostics, "reloadStatus": loaded.status]
            try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: root.appendingPathComponent(name + "-observer.json"))
            guard loaded.status == 0, events.isEmpty else { exit(1) }
            return
        }
        if CommandLine.arguments[1] == "serve-provider" {
            let provider = TailscaleProviderService(persistFiles: false)
            while true {
                let stopped = CommandLine.arguments.count > 2 && FileManager.default.fileExists(atPath: CommandLine.arguments[2])
                provider.setEnabled(!stopped)
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        if CommandLine.arguments[1] == "serve-dns" {
            guard BoundedProcess.run("/usr/sbin/sysctl", ["-n", "hw.model"]).text.hasPrefix("VirtualMac"),
                  geteuid() == 0 else { fatalError("Isolated VM root is required") }
            let dns = MimoDNSConfiguration()
            let store = SCDynamicStoreCreate(nil, "DNS acceptance evidence" as CFString, nil, nil)!
            func globals() -> [String: Any] {
                SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Global/.*"] as CFArray) as? [String: Any] ?? [:]
            }
            let before = globals()
            var events: [String] = [], diagnostics: [String] = []
            let observer = MimoNetworkObserver { events.append($0) }
            observer.diagnostic = { diagnostics.append($0) }
            observer.start()
            try await Task.sleep(for: .milliseconds(250))
            observer.willChangeProfile(engineProcess: Int32(CommandLine.arguments[3]))
            try dns.install()
            observer.didChangeProfile()
            guard dns.matches else { fatalError("Protected DNS was not installed") }
            try await Task.sleep(for: .seconds(2))
            let result: [String: Any] = ["externalEvents": events, "diagnostics": diagnostics,
                "before": before, "after": globals()]
            try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
                .write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("dns-observer.json"))
            guard events.isEmpty else { exit(1) }
            observer.stop()
            while true { try await Task.sleep(for: .seconds(1)) }
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let cacheURL = output.appendingPathExtension("infrastructure.json")
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(MimoInfrastructureCache.self, from: $0) } ?? MimoInfrastructureCache()
        if cache.needsRefresh(at: .now) {
            guard let group = getgrnam("_mimo"), setgid(group.pointee.gr_gid) == 0 else { fatalError("Private group is required") }
            cache.update(MimoNativeTransportProbe.infrastructure(), at: .now)
            try JSONEncoder().encode(cache).write(to: cacheURL)
        }
        let stopped = CommandLine.arguments.count > 2 && FileManager.default.fileExists(atPath: CommandLine.arguments[2])
        let result = MimoNativeTransportProbe.check(tailnetEnabled: !stopped, infrastructure: cache.addresses(at: .now))
        try result.render().write(to: output, atomically: true, encoding: .utf8)
        let metadata: [String: Any] = ["sockets": result.sockets.count, "interface": result.interface ?? ""]
        print(String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self))
    }
}
