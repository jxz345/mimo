import Darwin
import Foundation

/// Isolated VM test host for the production resolver owner. It never changes PF
/// or saved network preferences. The installed-app campaign tests full ordering.
@main
enum V3DNSOwner {
    @MainActor static func main() throws {
        guard geteuid() == 0, ProcessInfo.processInfo.hostName.hasPrefix("mimo-vm"),
              CommandLine.arguments.count == 4,
              let parent = Int32(CommandLine.arguments[1]), let engine = Int32(CommandLine.arguments[2]) else { exit(2) }
        let path = URL(fileURLWithPath: CommandLine.arguments[3])
        let owner = MimoDNSConfiguration()
        defer { try? owner.removeAndDrain() }
        while kill(parent, 0) == 0, kill(engine, 0) == 0,
              !FileManager.default.fileExists(atPath: path.appendingPathComponent("dns-owner-stop").path) {
            try owner.install()
            if !FileManager.default.fileExists(atPath: path.appendingPathComponent("dns-owner-ready").path) {
                try Data().write(to: path.appendingPathComponent("dns-owner-ready"))
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
