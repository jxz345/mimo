import Darwin
import Foundation
import SystemConfiguration

/// Runs in the independent supervisor, including while core is stopped. Only changes
/// attributable to the owned engine are self changes; isolated private Tailnet
/// changes use a separate, conservative classification.
@MainActor
final class MimoNetworkObserver {
    private let changed: (String, String) -> Void
    private let earlyBlock: @Sendable () -> MimoEarlyNetworkEvent?
    private let routeOwnership = MimoRouteOwnership()
    private let tailnetChanges = MimoTailnetNetworkChanges()
    var tailnetChanged: (() -> Void)?
    private var engineProcess: Int32?
    private var tunnelSignature: String?
    private var tunnelIndices: Set<UInt16> = []
    private var otherInterfaces: [String]?
    private var tunnelAddresses = Set<String>()
    private var profileChangeDeadline = ContinuousClock.now
    private var expectedDNS: NSDictionary?
    private var globalConfiguration: [String: NSDictionary]?
    private var externalDNSConfiguration: [String: NSDictionary]?
    var diagnostic: ((String) -> Void)?
    private lazy var configuration = NetworkConfigurationObserver(
        deliveryQueue: DispatchQueue(label: "app.mimo.network-configuration", qos: .userInitiated),
        onChangedKeys: { [weak self, earlyBlock, tailnetChanges] keys in
        let timing = MimoTransitionTiming("network_event")
        let privateKeys = tailnetChanges.classify(keys)
        let external = keys.isEmpty || keys.filter { !privateKeys.contains($0) }.contains { key in
            key != MimoRuntime.dnsStateKey && key != "State:/Network/Interface" &&
            !key.hasPrefix("State:/Network/Global/") &&
            !key.hasPrefix("State:/Network/Interface/\(MihomoProfile.tunnelDevice)/")
        }
        let early = external ? earlyBlock() : nil
        Task { @MainActor in
            var timing = timing
            timing.record("configuration_actor_delivery")
            self?.configurationChanged(keys, privateKeys: privateKeys, early: early)
        }
    })
    private lazy var routes = RouteChangeObserver(onChanges: { [weak self, routeOwnership, earlyBlock, tailnetChanges] changes in
        let changes = changes.filter { !tailnetChanges.isPrivateRouteChange($0) }
        guard !changes.isEmpty else { return }
        let receivedAt = ContinuousClock.now
        let timing = MimoTransitionTiming("network_event")
        let early = routeOwnership.isDefinitelyExternal(changes, at: receivedAt) ? earlyBlock() : nil
        Task { @MainActor in
            var timing = timing
            timing.record("route_actor_delivery")
            self?.routesChanged(changes, receivedAt: receivedAt, early: early)
        }
    })

    init(earlyBlock: @escaping @Sendable () -> MimoEarlyNetworkEvent?, changed: @escaping (String, String) -> Void) {
        self.earlyBlock = earlyBlock
        self.changed = changed
    }
    var isRunning: Bool { configuration.isRunning && routes.isRunning }

    func start() {
        tailnetChanges.start()
        otherInterfaces = interfaces()
        globalConfiguration = globals()
        externalDNSConfiguration = externalDNS()
        configuration.start(); routes.start()
    }

    func stop() { configuration.stop(); routes.stop() }

    func setProxyEndpoint(_ address: String?) {
        var interface: String?
        if let address {
            let route = BoundedProcess.run("/sbin/route", ["-n", "get", address], timeout: 1)
            let fields = route.text.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace) }.filter { $0.first == "interface:" }
            interface = route.status == 0 && fields.count == 1 && fields[0].count == 2 ? String(fields[0][1]) : nil
        } else { interface = nil }
        if interface == MihomoProfile.tunnelDevice {
            // Mihomo's auto-detected outbound interface comes from the primary
            // service. Its own catch-all TUN route is not the proxy transport.
            interface = globals()?["State:/Network/Global/IPv4"]?["PrimaryInterface"] as? String
        }
        tailnetChanges.setProxyEndpoint(address, interface: interface)
        RuntimeLog.shared.info("mimo_tailnet_change_scope", fields: ["publicInterface": interface ?? "unknown"])
    }

    func willChangeProfile(engineProcess: Int32?) {
        self.engineProcess = engineProcess
        tunnelIndices.removeAll()
        rememberTunnelIndex()
        tunnelAddresses = addresses(in: currentTunnelSignature())
        publishRouteOwnership()
    }

    func didChangeProfile() {
        rememberTunnelIndex()
        tunnelSignature = currentTunnelSignature()
        tunnelAddresses.formUnion(addresses(in: tunnelSignature ?? ""))
        profileChangeDeadline = .now.advanced(by: .seconds(2))
        expectedDNS = currentDNS()
        publishRouteOwnership()
        // Do not refresh the external-interface baseline here: an external change
        // concurrent with profile loading must still be delivered afterwards.
    }

    private func publishRouteOwnership() {
        routeOwnership.update(engine: engineProcess, indices: tunnelIndices,
                              addresses: tunnelAddresses, deadline: profileChangeDeadline)
    }

    private func addresses(in signature: String) -> Set<String> {
        Set(signature.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, ["inet", "inet6"].contains(fields[0]) else { return nil }
            return IPAddressValidator.normalize(String(fields[1].split(separator: "%")[0]))
        })
    }

    private func rememberTunnelIndex() {
        let index = if_nametoindex(MihomoProfile.tunnelDevice)
        if index > 0, index <= UInt16.max { tunnelIndices.insert(UInt16(index)) }
    }

    private func currentTunnelSignature() -> String {
        let result = BoundedProcess.run("/sbin/ifconfig", [MihomoProfile.tunnelDevice], timeout: 1)
        return result.status == 0 ? result.text : "absent"
    }

    private func interfaces() -> [String]? {
        guard let store = SCDynamicStoreCreate(nil, "Mimo interface inventory" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Interface" as CFString) as? [String: Any],
              let names = value["Interfaces"] as? [String] else { return nil }
        return names.filter { $0 != MihomoProfile.tunnelDevice }.sorted()
    }

    private func currentDNS() -> NSDictionary? {
        guard let store = SCDynamicStoreCreate(nil, "Mimo DNS observation" as CFString, nil, nil) else { return nil }
        return SCDynamicStoreCopyValue(store, MimoRuntime.dnsStateKey as CFString) as? NSDictionary
    }

    private func globals() -> [String: NSDictionary]? {
        guard let store = SCDynamicStoreCreate(nil, "Mimo global network observation" as CFString, nil, nil) else { return nil }
        return SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Global/.*"] as CFArray) as? [String: NSDictionary]
    }

    private func externalDNS() -> [String: NSDictionary]? {
        guard let store = SCDynamicStoreCreate(nil, "Mimo external DNS observation" as CFString, nil, nil),
              var values = SCDynamicStoreCopyMultiple(store, nil,
                ["State:/Network/Service/.*/DNS", "Setup:/Network/Service/.*/DNS"] as CFArray) as? [String: NSDictionary] else { return nil }
        values.removeValue(forKey: MimoRuntime.dnsStateKey)
        return values
    }

    private func isOwnedGlobalDNS(_ value: NSDictionary?) -> Bool {
        guard let expectedDNS, currentDNS() == expectedDNS,
              let value = value as? [String: Any],
              value["__CONFIGURATION_ID__"] as? String == "Supplemental: com.mimo.dns 0" else { return false }
        // configd selects our supplemental resolver as the global default. Only
        // its exact resolver fields plus known configd bookkeeping are expected.
        let metadata = Set(["__CONFIGURATION_ID__", "__FLAGS__", "__ORDER__"])
        let resolver = value.filter { !metadata.contains($0.key) }
        let expected = (expectedDNS as? [String: Any] ?? [:]).filter {
            !["SupplementalMatchDomains", "SupplementalMatchOrders"].contains($0.key)
        }
        return NSDictionary(dictionary: resolver) == NSDictionary(dictionary: expected)
    }

    private func configurationChanged(_ keys: [String], privateKeys: Set<String>, early: MimoEarlyNetworkEvent?) {
        diagnostic?("configuration: " + keys.joined(separator: ","))
        if !privateKeys.isEmpty {
            tailnetChanged?()
            RuntimeLog.shared.info("mimo_tailnet_configuration_updated", fields: ["keys": privateKeys.sorted().joined(separator: ",")])
        }
        let current = interfaces()
        let currentGlobals = globals()
        let currentExternalDNS = externalDNS()
        defer { globalConfiguration = currentGlobals; externalDNSConfiguration = currentExternalDNS }
        let tunnelMatches = tunnelSignature != nil && tunnelSignature == currentTunnelSignature()
        let externalKeys = keys.filter { key in
            if privateKeys.contains(key) { return false }
            if key == MimoRuntime.dnsStateKey {
                // configd can deliver this notification after controller work has
                // occupied the actor. Compare the actual value with the owned
                // value; queue latency is not an external configuration change.
                return currentDNS() != expectedDNS
            }
            if key.hasPrefix("State:/Network/Global/"), let currentGlobals, let globalConfiguration {
                // configd republishes unchanged global keys after supplemental DNS
                // updates. These are notifications, not a network-policy change.
                guard currentGlobals[key] != globalConfiguration[key] else { return false }
                if key == "State:/Network/Global/DNS", let currentExternalDNS,
                   externalDNSConfiguration.map({ tailnetChanges.nonTailnetDNS($0) == tailnetChanges.nonTailnetDNS(currentExternalDNS) }) == true,
                   currentDNS() == expectedDNS,
                   isOwnedGlobalDNS(currentGlobals[key]) || tailnetChanges.isNativeDNSSelection(currentGlobals[key]) {
                    RuntimeLog.shared.info("mimo_network_owned_dns_selected")
                    return false
                }
                return true
            }
            if key.hasPrefix("State:/Network/Interface/\(MihomoProfile.tunnelDevice)/") {
                return !tunnelMatches
            }
            if key == "State:/Network/Interface" { return current == nil || current != otherInterfaces }
            return true
        }
        otherInterfaces = current
        let external = keys.isEmpty || !externalKeys.isEmpty
        early?.resolve(external)
        if !external, early?.awaitingClassification == true {
            RuntimeLog.shared.info("mimo_cycle_owned_event_ignored", fields: ["source": "configuration"])
        }
        if early?.blocked == true || external {
            RuntimeLog.shared.info("mimo_network_configuration_external", fields: [
                "keys": externalKeys.joined(separator: ","), "tunnelMatches": String(tunnelMatches)
            ])
            RuntimeLog.shared.info("mimo_network_event_dispatch", fields: ["source": "configuration", "early_gate": String(early?.blocked == true)])
            changed("configuration", (externalKeys.isEmpty ? keys : externalKeys).joined(separator: ", "))
        }
    }

    private func routesChanged(_ changes: [RouteChangeObserver.Change], receivedAt: ContinuousClock.Instant, early: MimoEarlyNetworkEvent?) {
        diagnostic?("routes: " + changes.map { "type=\($0.type) interface=\($0.interfaceName ?? "unknown") index=\($0.interfaceIndex) pid=\($0.processID.map(String.init) ?? "none") addresses=\($0.addresses.joined(separator: ","))" }.joined(separator: "; "))
        if early?.blocked == true {
            early?.resolve(true)
            RuntimeLog.shared.info("mimo_network_event_dispatch", fields: ["source": "route", "early_gate": "true"])
            changed("route", routeSummary(changes))
            return
        }
        let signatureMatches = tunnelSignature != nil && tunnelSignature == currentTunnelSignature()
        let external = changes.contains { change in
            let owned = change.interfaceName == MihomoProfile.tunnelDevice ||
                (change.interfaceName == nil && tunnelIndices.contains(change.interfaceIndex))
            return !MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: owned,
                recordedTunnelMatches: signatureMatches, eventProcess: change.processID, engineProcess: engineProcess,
                unresolvedInterface: change.interfaceIndex == 0 && change.interfaceName == nil,
                ownedAddress: !tunnelAddresses.isDisjoint(with: change.addresses),
                insideProfileChangeWindow: receivedAt <= profileChangeDeadline)
        }
        early?.resolve(external)
        if !external, early?.awaitingClassification == true {
            RuntimeLog.shared.info("mimo_cycle_owned_event_ignored", fields: ["source": "route"])
        }
        if external {
            RuntimeLog.shared.info("mimo_network_event_dispatch", fields: ["source": "route", "early_gate": "false"])
            changed("route", routeSummary(changes))
        }
    }

    private func routeSummary(_ changes: [RouteChangeObserver.Change]) -> String {
        let descriptions = changes.map { change -> String in
            let kind: String
            switch change.type {
            case RTM_ADD: kind = "route added"
            case RTM_DELETE: kind = "route removed"
            case RTM_CHANGE: kind = "route changed"
            case RTM_NEWADDR: kind = "address added"
            case RTM_DELADDR: kind = "address removed"
            case RTM_IFINFO: kind = "interface changed"
            default: kind = "route event \(change.type)"
            }
            return "\(kind) on \(change.interfaceName ?? "index \(change.interfaceIndex)") (pid \(change.processID.map(String.init) ?? "kernel"))"
        }
        return Array(Set(descriptions)).sorted().joined(separator: "; ")
    }
}

/// The callback uses only this small locked snapshot, never actor-owned state or
/// ifconfig. Assume the tunnel matches: only changes that are external even with
/// that generous self-event assumption qualify for early revocation.
private final class MimoRouteOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: Int32?
    private var indices: Set<UInt16> = []
    private var addresses: Set<String> = []
    private var deadline = ContinuousClock.now

    func update(engine: Int32?, indices: Set<UInt16>, addresses: Set<String>, deadline: ContinuousClock.Instant) {
        lock.withLock {
            self.engine = engine; self.indices = indices
            self.addresses = addresses; self.deadline = deadline
        }
    }

    func isDefinitelyExternal(_ changes: [RouteChangeObserver.Change], at receivedAt: ContinuousClock.Instant) -> Bool {
        lock.withLock {
            changes.contains { change in
                let owned = change.interfaceName == MihomoProfile.tunnelDevice ||
                    (change.interfaceName == nil && indices.contains(change.interfaceIndex))
                return !MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: owned,
                    recordedTunnelMatches: true, eventProcess: change.processID, engineProcess: engine,
                    unresolvedInterface: change.interfaceIndex == 0 && change.interfaceName == nil,
                    ownedAddress: !addresses.isDisjoint(with: change.addresses),
                    insideProfileChangeWindow: receivedAt <= deadline)
            }
        }
    }
}
