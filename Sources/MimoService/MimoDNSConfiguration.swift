import Foundation
import SystemConfiguration

/// A temporary supplemental resolver owned by the supervisor's dynamic-store session.
/// Never edits saved network-service preferences. Removal, Direct, and process exit
/// restore the pre-existing resolver configuration, including Tailscale's own DNS.
@MainActor
final class MimoDNSConfiguration {
    private var store: SCDynamicStore?
    private(set) var installed = false
    private var expected: NSDictionary?

    var matches: Bool {
        guard installed, let store, let expected,
              let actual = SCDynamicStoreCopyValue(store, MimoRuntime.dnsStateKey as CFString) as? NSDictionary else { return false }
        return actual == expected
    }

    func install(willChange: (() -> Void)? = nil, didChange: (() -> Void)? = nil) throws {
        if store == nil { store = SCDynamicStoreCreate(nil, "Mimo protected DNS" as CFString, nil, nil) }
        guard let store else { throw MimoRuntimeError.unavailable("Could not configure the protected DNS resolver.") }
        var values = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/DNS"] as CFArray) as? [String: [String: Any]] ?? [:]
        values.removeValue(forKey: MimoRuntime.dnsStateKey)
        // Saved search domains override DHCP values, as they do for configd.
        var primary: [String: Any]?
        if let service = (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryService"] as? String,
           !service.isEmpty, !service.contains("/") {
            let saved = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(service)/DNS" as CFString) as? [String: Any] ?? [:]
            primary = (values["State:/Network/Service/\(service)/DNS"] ?? [:]).merging(saved) { $1 }
        }
        guard let value = MimoProtectedDNS.resolver(services: values, primary: primary) else {
            throw MimoRuntimeError.unavailable("Too many supplemental DNS domains to safely override.")
        }
        let key = MimoRuntime.dnsStateKey as CFString
        let actual = SCDynamicStoreCopyValue(store, key)
        // Re-publishing an identical resolver can cause configd to issue new
        // global-DNS notifications and restart a just-completed verification.
        // Read the actual live value; a missing/changed value must be repaired.
        if installed, actual as? NSDictionary == value as NSDictionary {
            expected = value as NSDictionary
            return
        }
        willChange?()
        defer { didChange?() }
        let success: Bool
        if !installed || actual == nil {
            // SetValue on a removed key creates a persistent entry. Always use
            // AddTemporaryValue when acquiring/reacquiring this session's key.
            // A previous version may have left this Mimo-owned key persistent.
            if actual != nil, !SCDynamicStoreRemoveValue(store, key) {
                throw MimoRuntimeError.unavailable("Could not reclaim the protected DNS resolver.")
            }
            success = SCDynamicStoreAddTemporaryValue(store, key, value as CFDictionary)
        } else {
            success = SCDynamicStoreSetValue(store, key, value as CFDictionary)
        }
        guard success else { throw MimoRuntimeError.unavailable("Could not install the protected DNS resolver.") }
        installed = true
        expected = value as NSDictionary
    }

    func remove() throws {
        guard let store else { return }
        let key = MimoRuntime.dnsStateKey as CFString
        if SCDynamicStoreCopyValue(store, key) != nil, !SCDynamicStoreRemoveValue(store, key) {
            throw MimoRuntimeError.unavailable("Could not restore the original DNS configuration.")
        }
        installed = false
        expected = nil
    }
}
