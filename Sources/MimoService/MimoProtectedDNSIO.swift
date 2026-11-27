import Foundation
import SystemConfiguration

/// The protected-I/O serial queue owns this entire dynamic-store session. Its
/// lifetime extends beyond each operation so temporary DNS ownership persists.
/// Only immutable serialized receipts cross back to the control actor.
final class MimoProtectedDNSIO: @unchecked Sendable {
    private var store: SCDynamicStore?
    private var installed = false

    func install(check: () throws -> Void) throws -> Data {
        try check()
        if store == nil { store = SCDynamicStoreCreate(nil, "Mimo protected DNS worker" as CFString, nil, nil) }
        guard let store else { throw DaemonFailure.unavailable }
        var values = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/DNS"] as CFArray) as? [String: [String: Any]] ?? [:]
        values.removeValue(forKey: MimoRuntime.dnsStateKey)
        var primary: [String: Any]?
        if let service = (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryService"] as? String,
           !service.isEmpty, !service.contains("/") {
            let saved = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(service)/DNS" as CFString) as? [String: Any] ?? [:]
            primary = (values["State:/Network/Service/\(service)/DNS"] ?? [:]).merging(saved) { $1 }
        }
        guard let value = MimoProtectedDNS.resolver(services: values, primary: primary) else { throw DaemonFailure.unavailable }
        let key = MimoRuntime.dnsStateKey as CFString
        let actual = SCDynamicStoreCopyValue(store, key)
        try check()
        if !installed || actual == nil || actual as? NSDictionary != value as NSDictionary {
            let success: Bool
            if !installed || actual == nil {
                if actual != nil, !SCDynamicStoreRemoveValue(store, key) { throw DaemonFailure.unavailable }
                try check()
                success = SCDynamicStoreAddTemporaryValue(store, key, value as CFDictionary)
            } else { success = SCDynamicStoreSetValue(store, key, value as CFDictionary) }
            guard success else { throw DaemonFailure.unavailable }
            installed = true
        }
        try check()
        return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    static func matches(_ receipt: Data) -> Bool {
        guard let expected = try? PropertyListSerialization.propertyList(from: receipt, format: nil) as? NSDictionary,
              let store = SCDynamicStoreCreate(nil, "Mimo protected DNS readback" as CFString, nil, nil),
              let actual = SCDynamicStoreCopyValue(store, MimoRuntime.dnsStateKey as CFString) as? NSDictionary else { return false }
        return expected == actual
    }

    func removeAndDrain(check: () throws -> Void) throws {
        try check()
        guard let source = store ?? SCDynamicStoreCreate(nil, "Mimo DNS worker cleanup" as CFString, nil, nil) else { throw DaemonFailure.unavailable }
        let key = MimoRuntime.dnsStateKey as CFString
        if SCDynamicStoreCopyValue(source, key) != nil, !SCDynamicStoreRemoveValue(source, key) { throw DaemonFailure.unavailable }
        guard SCDynamicStoreCopyValue(source, key) == nil else { throw DaemonFailure.unavailable }
        installed = false
        for (tool, arguments) in [("/usr/bin/dscacheutil", ["-flushcache"]), ("/usr/bin/killall", ["-HUP", "mDNSResponder"])] {
            try check()
            guard BoundedProcess.run(tool, arguments, timeout: 3).status == 0 else { throw DaemonFailure.unavailable }
        }
        Thread.sleep(forTimeInterval: 0.3)
        try check()
        let readback = BoundedProcess.run("/usr/sbin/scutil", ["--dns"], timeout: 3)
        guard readback.status == 0, !readback.text.contains("port     : 1053") else { throw DaemonFailure.unavailable }
        RuntimeLog.shared.info("mimo_dns_removed_and_drained")
    }
}
