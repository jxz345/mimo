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
    private var loadedPrivateNames = false
    private var knownPrivateRules: [String: MimoPrivateDNSRule] = [:]

    func nativeRules() throws -> [MimoPrivateDNSRule] {
        let journal = MimoRuntime.directory.appendingPathComponent("private-dns-suffixes.json")
        if !loadedPrivateNames {
            if FileManager.default.fileExists(atPath: journal.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65536 else { throw DaemonFailure.unavailable }
                let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: journal))
                guard names.count <= MimoProtectedDNS.maximumDomains else { throw DaemonFailure.invalidRequest }
                for name in names { knownPrivateRules[name] = try MimoPrivateDNSRule(suffix: name, servers: []) }
            }
            loadedPrivateNames = true
        }
        guard let snapshot = nativeSnapshot() else { throw DaemonFailure.unavailable }
        let current = try MimoNativeDNSPolicy.rules(services: snapshot.services, primary: snapshot.primary)
        let names = Set(current.map(\.suffix))
        // A disconnected private resolver does not authorize public forwarding.
        for name in Array(knownPrivateRules.keys) where !names.contains(name) {
            knownPrivateRules[name] = try MimoPrivateDNSRule(suffix: name, servers: [])
        }
        for rule in current { knownPrivateRules[rule.suffix] = rule }
        guard knownPrivateRules.count <= MimoProtectedDNS.maximumDomains else { throw DaemonFailure.invalidRequest }
        try JSONEncoder().encode(knownPrivateRules.keys.sorted()).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        return knownPrivateRules.values.sorted { $0.suffix < $1.suffix }
    }

    private func nativeSnapshot() -> (services: [String: [String: Any]], primary: [String: Any]?)? {
        guard let source = store ?? SCDynamicStoreCreate(nil, "Mimo native DNS snapshot" as CFString, nil, nil) else { return nil }
        var values = SCDynamicStoreCopyMultiple(source, nil, ["State:/Network/Service/.*/DNS"] as CFArray) as? [String: [String: Any]] ?? [:]
        values.removeValue(forKey: MimoRuntime.dnsStateKey)
        var primary: [String: Any]?
        if let service = (SCDynamicStoreCopyValue(source, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["PrimaryService"] as? String,
           !service.isEmpty, !service.contains("/") {
            let saved = SCDynamicStoreCopyValue(source, "Setup:/Network/Service/\(service)/DNS" as CFString) as? [String: Any] ?? [:]
            primary = (values["State:/Network/Service/\(service)/DNS"] ?? [:]).merging(saved) { $1 }
        }
        return (values, primary)
    }

    var matches: Bool {
        guard installed, let store, let expected,
              let actual = SCDynamicStoreCopyValue(store, MimoRuntime.dnsStateKey as CFString) as? NSDictionary else { return false }
        return actual == expected
    }

    func install(willChange: (() -> Void)? = nil, didChange: (() -> Void)? = nil) throws {
        if store == nil { store = SCDynamicStoreCreate(nil, "Mimo protected DNS" as CFString, nil, nil) }
        guard let store else { throw MimoRuntimeError.unavailable("Could not configure the protected DNS resolver.") }
        guard let snapshot = nativeSnapshot(),
              let value = MimoProtectedDNS.resolver(services: snapshot.services, primary: snapshot.primary) else {
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

    /// Unregister and drain queued resolver work before destroying the TUN.
    /// The caller keeps the transition barrier closed throughout this operation.
    func removeAndDrain() throws {
        try remove()
        for (tool, arguments) in [("/usr/bin/dscacheutil", ["-flushcache"]),
                                  ("/usr/bin/killall", ["-HUP", "mDNSResponder"])] {
            guard BoundedProcess.run(tool, arguments, timeout: 3).status == 0 else {
                throw MimoRuntimeError.unavailable("System DNS could not be drained before tunnel removal.")
            }
        }
        // A bounded settling interval runs off GUI processes. PF still denies
        // newly queued application lookups until the native state is restored.
        Thread.sleep(forTimeInterval: 0.3)
        let check = BoundedProcess.run("/usr/sbin/scutil", ["--dns"], timeout: 3)
        guard check.status == 0, !check.text.contains("port     : 1053") else {
            throw MimoRuntimeError.unavailable("The system still advertises Mimo's DNS listener.")
        }
        RuntimeLog.shared.info("mimo_dns_removed_and_drained")
    }

    func remove() throws {
        // Also remove a persistent key left by an earlier process or build.
        guard let store = store ?? SCDynamicStoreCreate(nil, "Mimo DNS cleanup" as CFString, nil, nil) else {
            throw MimoRuntimeError.unavailable("Could not inspect the system DNS resolver.")
        }
        let key = MimoRuntime.dnsStateKey as CFString
        if SCDynamicStoreCopyValue(store, key) != nil, !SCDynamicStoreRemoveValue(store, key) {
            throw MimoRuntimeError.unavailable("Could not restore the original DNS configuration.")
        }
        guard SCDynamicStoreCopyValue(store, key) == nil else {
            throw MimoRuntimeError.unavailable("Mimo's DNS resolver is still installed.")
        }
        installed = false
        expected = nil
    }
}
