import Foundation

/// AirPort status is republished for scans and radio telemetry as well as connection
/// changes. Keep unknown fields conservative; only known non-routing fields are ignored.
/// Callers serialize access and pass the dynamic-store value, not a Wi-Fi scan result.
public struct AirPortChangeFilter {
    public enum Reading {
        case value([String: Any])
        case absent
        case unavailable
    }

    public struct Decision {
        public let shouldNotify: Bool
        /// Field names only. Never includes SSIDs, BSSIDs or other values.
        public let changedFields: [String]
    }

    private static let telemetryFields: Set<String> = [
        "Busy", "BusyUI", "RSSI", "Noise", "CHANNEL", "CHANNEL_FLAGS",
        "CachedScanRecord", "ScanResults", "LastScanTime", "AutoJoinTimestamp",
        "BluetoothAudioInUse", "BluetoothPagingInProgress", "AirPlay"
    ]
    private var previous: [String: Reading] = [:]

    public init() {}

    public static func matches(_ key: String) -> Bool {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 5 && parts[0] == "State:" && parts[1] == "Network" &&
            parts[2] == "Interface" && !parts[3].isEmpty && parts[4] == "AirPort"
    }

    public mutating func seed(_ key: String, reading: Reading) {
        if case .unavailable = reading { return }
        previous[key] = reading
    }

    public mutating func evaluate(_ key: String, reading: Reading) -> Decision {
        if case .unavailable = reading {
            return Decision(shouldNotify: true, changedFields: ["unreadable"])
        }
        let old = previous[key]
        previous[key] = reading
        guard let old else { return Decision(shouldNotify: true, changedFields: ["first observation"]) }
        switch (old, reading) {
        case (.absent, .absent):
            return Decision(shouldNotify: false, changedFields: [])
        case (.value(let old), .value(let new)):
            let before = old as NSDictionary, after = new as NSDictionary
            let fields = Set(old.keys).union(new.keys).filter { field in
                let a = before[field] as? NSObject, b = after[field] as? NSObject
                return a != b
            }.sorted()
            return Decision(shouldNotify: fields.contains { !Self.telemetryFields.contains($0) }, changedFields: fields)
        case (_, .absent):
            return Decision(shouldNotify: true, changedFields: ["removed"])
        default:
            return Decision(shouldNotify: true, changedFields: ["appeared"])
        }
    }
}
