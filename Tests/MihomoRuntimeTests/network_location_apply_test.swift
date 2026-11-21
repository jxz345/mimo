import Darwin
import Foundation
import SystemConfiguration

/// Run only as root in mimo-vm. Reapply the existing SCPreferences without
/// editing values, then exercise the production observer against configd.
@main
struct NetworkLocationApplyTest {
    @MainActor
    static func main() async throws {
        var model = [CChar](repeating: 0, count: 256)
        var size = model.count
        precondition(sysctlbyname("hw.model", &model, &size, nil, 0) == 0)
        precondition(String(cString: model).hasPrefix("VirtualMac") && getuid() == 0)
        guard let store = SCDynamicStoreCreate(nil, "Mimo location regression" as CFString, nil, nil),
              let preferences = SCPreferencesCreate(nil, "Mimo location regression" as CFString, nil) else {
            fatalError("SystemConfiguration is unavailable")
        }
        let locationKey = SCDynamicStoreKeyCreateLocation(nil)
        let before = SCDynamicStoreCopyValue(store, locationKey) as? NSDictionary
        let previousRecords = Set(RuntimeLog.shared.recentDiagnosticRecords())
        var delivered: [String] = []
        let observer = NetworkConfigurationObserver(onChangedKeys: { delivered.append(contentsOf: $0) })
        observer.start()
        defer { observer.stop() }
        precondition(observer.isRunning)
        precondition(SCPreferencesLock(preferences, true))
        let saved = preferenceValues(preferences)
        let applied = SCPreferencesApplyChanges(preferences)
        precondition(SCPreferencesUnlock(preferences))
        precondition(applied, "Could not reapply the existing preferences")
        for _ in 0..<50 {
            if ignoredApplyWasObserved(after: previousRecords) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let after = SCDynamicStoreCopyValue(store, locationKey) as? NSDictionary
        precondition((before?["CurrentSet"] as? String) == (after?["CurrentSet"] as? String))
        precondition(saved == preferenceValues(preferences), "The test must not edit preferences")
        precondition(ignoredApplyWasObserved(after: previousRecords), "configd did not deliver a timestamp-only Setup: update")
        precondition(!delivered.contains(locationKey as String), "Apply metadata reached early blocking")
        print("PASS: a real SCPreferences apply delivers Setup: metadata without requesting verification; location and preferences unchanged")
    }

    private static func preferenceValues(_ preferences: SCPreferences) -> NSDictionary {
        let keys = SCPreferencesCopyKeyList(preferences) as? [String] ?? []
        return NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            SCPreferencesGetValue(preferences, key as CFString).map { (key, $0) }
        }))
    }

    private static func ignoredApplyWasObserved(after previousRecords: Set<String>) -> Bool {
        RuntimeLog.shared.recentDiagnosticRecords().contains {
            guard !previousRecords.contains($0) else { return false }
            guard let row = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
                  row["event"] as? String == "network_location_metadata_ignored",
                  let fields = row["fields"] as? [String: String] else { return false }
            return fields["fields"] == "LastUpdated" || fields["fields"] == "unchanged"
        }
    }
}
