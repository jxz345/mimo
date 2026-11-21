#if SWIFT_PACKAGE
import MimoShared
#endif
import Foundation
@preconcurrency import SystemConfiguration

/// Observes macOS SystemConfiguration changes that do not necessarily alter an
/// `NWPath`, including proxy settings, default route/DNS changes, service state,
/// and tunnel-interface changes.
final class NetworkConfigurationObserver {
    private var store: SCDynamicStore?
    private let onConfigurationChange: ([String]) -> Void
    private let deliveryQueue: DispatchQueue
    private let classificationLock = NSLock()
    private var airPortChanges = AirPortChangeFilter()
    private var locationChanges = NetworkLocationChangeFilter()

    init(onConfigurationChange: @escaping () -> Void) {
        self.onConfigurationChange = { _ in onConfigurationChange() }
        deliveryQueue = .main
    }

    init(deliveryQueue: DispatchQueue = .main, onChangedKeys: @escaping ([String]) -> Void) {
        self.deliveryQueue = deliveryQueue
        onConfigurationChange = onChangedKeys
    }

    var isRunning: Bool { store != nil }

    func start() {
        guard store == nil else { return }

        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let dynamicStore = SCDynamicStoreCreate(
            nil,
            "com.mimo.network-configuration" as CFString,
            networkConfigurationDidChange,
            &context
        ) else {
            Self.logUnavailable(step: "create")
            return
        }

        // Every key must be unique: SystemConfiguration rejects the whole registration
        // ("Key already defined") if one repeats, which would silently disable this observer.
        let keys = Self.notificationKeys()
        let patterns = Self.notificationKeyPatterns()
        guard SCDynamicStoreSetNotificationKeys(
            dynamicStore,
            keys as CFArray,
            patterns as CFArray
        ) else {
            Self.logUnavailable(step: "set_notification_keys")
            return
        }

        // Seed before enabling delivery. Classification runs on the delivery queue,
        // before the supervisor's early PF callback or any verification-cycle flag.
        classificationLock.withLock {
            airPortChanges = AirPortChangeFilter()
            let keys = SCDynamicStoreCopyKeyList(dynamicStore, "^State:/Network/Interface/[^/]+/AirPort$" as CFString) as? [String] ?? []
            for key in keys { airPortChanges.seed(key, reading: Self.airPortReading(dynamicStore, key: key)) }
            locationChanges.seed(SCDynamicStoreCopyValue(dynamicStore, SCDynamicStoreKeyCreateLocation(nil)) as? [String: Any])
        }
        // The supervisor supplies an independent queue for early PF revocation;
        // other consumers retain main-queue delivery.
        store = dynamicStore
        guard SCDynamicStoreSetDispatchQueue(dynamicStore, deliveryQueue) else {
            store = nil
            Self.logUnavailable(step: "set_dispatch_queue")
            return
        }
    }

    private static func logUnavailable(step: String) {
        RuntimeLog.shared.error("network_configuration_monitor_unavailable", fields: [
            "step": step,
            "error": String(cString: SCErrorString(SCError()))
        ])
    }

    func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }

    fileprivate func notifyConfigurationChange(changedKeys: [String]) {
        // An empty system callback remains a conservative unknown change. A batch
        // reduced to empty by this filter is telemetry and must never reach early PF.
        let relevant = changedKeys.filter { key in
            if key == SCDynamicStoreKeyCreateLocation(nil) as String {
                let value = store.flatMap { SCDynamicStoreCopyValue($0, key as CFString) as? [String: Any] }
                let decision = classificationLock.withLock { locationChanges.evaluate(value) }
                RuntimeLog.shared.info(decision.shouldNotify ? "network_location_changed" : "network_location_metadata_ignored", fields: [
                    "fields": decision.changedFields.isEmpty ? "unchanged" : decision.changedFields.joined(separator: ",")
                ])
                return decision.shouldNotify
            }
            guard AirPortChangeFilter.matches(key) else { return true }
            let reading = store.map { Self.airPortReading($0, key: key) } ?? .unavailable
            let decision = classificationLock.withLock { airPortChanges.evaluate(key, reading: reading) }
            RuntimeLog.shared.info(decision.shouldNotify ? "network_airport_connection_changed" : "network_airport_telemetry_ignored", fields: [
                "key": key,
                "fields": decision.changedFields.isEmpty ? "unchanged" : decision.changedFields.joined(separator: ",")
            ])
            return decision.shouldNotify
        }
        guard changedKeys.isEmpty || !relevant.isEmpty else { return }
        RuntimeLog.shared.info("network_configuration_changed", fields: ["keys": relevant.joined(separator: ",")])
        onConfigurationChange(relevant)
    }

    private static func airPortReading(_ store: SCDynamicStore, key: String) -> AirPortChangeFilter.Reading {
        guard let value = SCDynamicStoreCopyValue(store, key as CFString) else {
            return SCError() == kSCStatusNoKey ? .absent : .unavailable
        }
        guard let dictionary = value as? [String: Any] else { return .unavailable }
        return .value(dictionary)
    }

    private static func notificationKeys() -> [CFString] {
        [
            // State:/Network/Global/Proxies (the same key as the kSCEntNetProxies global entity, so
            // that entity must not be listed again).
            SCDynamicStoreKeyCreateProxies(nil),
            SCDynamicStoreKeyCreateLocation(nil),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv6),
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetDNS),
            // Service order (which service owns the default route) and the interface list, so a
            // utun/VPN interface appearing or disappearing is noticed even before it has addresses.
            SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainSetup, kSCEntNetIPv4),
            SCDynamicStoreKeyCreateNetworkInterface(nil, kSCDynamicStoreDomainState)
        ]
    }

    private static func notificationKeyPatterns() -> [CFString] {
        let strings: [String] = [
            "^State:/Network/Service/[^/]+/IPv4$",
            "^State:/Network/Service/[^/]+/IPv6$",
            "^State:/Network/Service/[^/]+/DNS$",
            "^State:/Network/Service/[^/]+/Proxies$",
            "^State:/Network/Service/[^/]+/PPP$",
            "^State:/Network/Service/[^/]+/IPSec$",
            "^State:/Network/Service/[^/]+/VPN$",
            "^Setup:/Network/Service/[^/]+/IPv4$",
            "^Setup:/Network/Service/[^/]+/IPv6$",
            "^Setup:/Network/Service/[^/]+/DNS$",
            "^Setup:/Network/Service/[^/]+/Proxies$",
            "^State:/Network/Interface/[^/]+/Link$",
            "^State:/Network/Interface/[^/]+/AirPort$",
            "^State:/Network/Interface/[^/]+/IPv4$",
            "^State:/Network/Interface/[^/]+/IPv6$"
        ]
        return strings.map { ($0 as NSString) as CFString }
    }
}

private func networkConfigurationDidChange(
    _: SCDynamicStore,
    changedKeys: CFArray,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let observer = Unmanaged<NetworkConfigurationObserver>
        .fromOpaque(info)
        .takeUnretainedValue()
    observer.notifyConfigurationChange(changedKeys: (changedKeys as? [String]) ?? [])
}
