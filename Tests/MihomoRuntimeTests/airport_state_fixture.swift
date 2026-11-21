import Darwin
import Foundation
import SystemConfiguration

/// Exercises actual configd notifications in mimo-vm, which has no Wi-Fi hardware.
/// This key belongs to no real interface and is removed after the test.
@main
enum AirPortStateFixture {
    static let key = "State:/Network/Interface/mimowifi0/AirPort" as CFString

    static func main() throws {
        let hardware = Process()
        hardware.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        hardware.arguments = ["-n", "hw.model"]
        let pipe = Pipe(); hardware.standardOutput = pipe
        try hardware.run()
        let model = pipe.fileHandleForReading.readDataToEndOfFile(); hardware.waitUntilExit()
        guard getuid() == 0, String(decoding: model, as: UTF8.self).hasPrefix("VirtualMac"),
              if_nametoindex("mimowifi0") == 0,
              let store = SCDynamicStoreCreate(nil, "Mimo AirPort notification fixture" as CFString, nil, nil),
              let operation = CommandLine.arguments.dropFirst().first else { exit(2) }
        if let existing = SCDynamicStoreCopyValue(store, key) {
            guard let value = existing as? [String: Any], value["MimoTestFixture"] as? String == "airport-status" else { exit(3) }
        }
        if operation == "remove" {
            if SCDynamicStoreCopyValue(store, key) != nil { guard SCDynamicStoreRemoveValue(store, key) else { exit(4) } }
            return
        }
        guard ["connected", "timestamp", "timestamp-busy", "telemetry", "association", "power"].contains(operation) else { exit(2) }
        let sequence = Int(CommandLine.arguments.last ?? "") ?? 0
        let ssid = operation == "association" ? "Mimo other fixture" : "Mimo fixture"
        let value: [String: Any] = [
            "MimoTestFixture": "airport-status", "SSID_STR": ssid, "SSID": Data(ssid.utf8),
            "BSSID": Data([2, 0, 0, 0, 0, 1]), "Power Status": operation == "power" ? 0 : 1,
            "Busy": ["telemetry", "timestamp-busy"].contains(operation) && sequence % 2 == 0,
            "AutoJoinTimestamp": Date(timeIntervalSince1970: 1_795_228_800 + Double(sequence * 20)),
            "RSSI": operation == "telemetry" ? -50 - sequence : -50,
            "CHANNEL": ["CHANNEL": 36, "CHANNEL_FLAGS": 0]
        ]
        guard SCDynamicStoreSetValue(store, key, value as CFDictionary) else { exit(4) }
    }
}
