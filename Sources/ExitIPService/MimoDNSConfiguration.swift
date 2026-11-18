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

    func install() throws {
        if store == nil { store = SCDynamicStoreCreate(nil, "Mimo protected DNS" as CFString, nil, nil) }
        guard let store else { throw MimoRuntimeError.unavailable("Could not configure the protected DNS resolver.") }
        // Match each existing supplemental domain at a higher priority, so a native
        // VPN's default or MagicDNS resolver cannot bypass Mimo's DNS policy.
        var domains = Set([""])
        let values = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/DNS"] as CFArray) as? [String: [String: Any]] ?? [:]
        for (key, value) in values where key != MimoRuntime.dnsStateKey {
            for domain in value["SupplementalMatchDomains"] as? [String] ?? [] {
                guard domain.utf8.count <= 253, domain.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }) else { continue }
                domains.insert(domain)
            }
        }
        guard domains.count <= 128 else { throw MimoRuntimeError.unavailable("Too many supplemental DNS domains to safely override.") }
        let value: [String: Any] = [
            "ServerAddresses": ["127.0.0.1"], "ServerPort": MimoRuntime.dnsPort,
            "SupplementalMatchDomains": domains.sorted(), "SupplementalMatchOrders": domains.map { _ in 1 },
            "SupplementalMatchDomainsNoSearch": 1, "SearchOrder": 1
        ]
        let key = MimoRuntime.dnsStateKey as CFString
        let success = installed ? SCDynamicStoreSetValue(store, key, value as CFDictionary) :
            SCDynamicStoreAddTemporaryValue(store, key, value as CFDictionary)
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
