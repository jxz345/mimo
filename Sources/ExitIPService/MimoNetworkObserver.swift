import Darwin
import Foundation
import SystemConfiguration

/// Runs in the independent supervisor, including while core is stopped. Only changes
/// attributable to the owned engine and its recorded tunnel are classified as self changes.
@MainActor
final class MimoNetworkObserver {
    private let changed: (String) -> Void
    private var engineProcess: Int32?
    private var tunnelSignature: String?
    private var tunnelIndices: Set<UInt16> = []
    private var otherInterfaces: [String]?
    private var tunnelAddresses = Set<String>()
    private var profileChangeDeadline = ContinuousClock.now
    private var expectedDNS: NSDictionary?
    private var globalConfiguration: [String: NSDictionary]?
    var diagnostic: ((String) -> Void)?
    private lazy var configuration = NetworkConfigurationObserver(onChangedKeys: { [weak self] keys in
        Task { @MainActor in self?.configurationChanged(keys) }
    })
    private lazy var routes = RouteChangeObserver(onChanges: { [weak self] changes in
        Task { @MainActor in self?.routesChanged(changes) }
    })
    private lazy var power = SystemPowerObserver { [weak self] in self?.changed("wake") }

    init(changed: @escaping (String) -> Void) { self.changed = changed }
    var isRunning: Bool { configuration.isRunning && routes.isRunning && power.isRunning }

    func start() {
        otherInterfaces = interfaces()
        globalConfiguration = globals()
        configuration.start(); routes.start(); power.start()
    }

    func stop() { configuration.stop(); routes.stop(); power.stop() }

    func willChangeProfile(engineProcess: Int32?) {
        self.engineProcess = engineProcess
        tunnelIndices.removeAll()
        rememberTunnelIndex()
        tunnelAddresses = addresses(in: currentTunnelSignature())
    }

    func didChangeProfile() {
        rememberTunnelIndex()
        tunnelSignature = currentTunnelSignature()
        tunnelAddresses.formUnion(addresses(in: tunnelSignature ?? ""))
        profileChangeDeadline = .now.advanced(by: .seconds(2))
        expectedDNS = currentDNS()
        // Do not refresh the external-interface baseline here: an external change
        // concurrent with profile loading must still be delivered afterwards.
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

    private func configurationChanged(_ keys: [String]) {
        diagnostic?("configuration: " + keys.joined(separator: ","))
        let current = interfaces()
        let currentGlobals = globals()
        defer { globalConfiguration = currentGlobals }
        let tunnelMatches = tunnelSignature != nil && tunnelSignature == currentTunnelSignature()
        let external = keys.isEmpty || keys.contains { key in
            if key == MimoRuntime.dnsStateKey {
                return ContinuousClock.now > profileChangeDeadline || currentDNS() != expectedDNS
            }
            if key.hasPrefix("State:/Network/Global/"), let currentGlobals, let globalConfiguration {
                // configd republishes unchanged global keys after supplemental DNS
                // updates. These are notifications, not a network-policy change.
                return currentGlobals[key] != globalConfiguration[key]
            }
            if key.hasPrefix("State:/Network/Interface/\(MihomoProfile.tunnelDevice)/") {
                return !tunnelMatches || ContinuousClock.now > profileChangeDeadline
            }
            if key == "State:/Network/Interface" { return current == nil || current != otherInterfaces }
            return true
        }
        otherInterfaces = current
        if external { changed("configuration") }
    }

    private func routesChanged(_ changes: [RouteChangeObserver.Change]) {
        diagnostic?("routes: " + changes.map { "type=\($0.type) interface=\($0.interfaceName ?? "unknown") index=\($0.interfaceIndex) pid=\($0.processID.map(String.init) ?? "none") addresses=\($0.addresses.joined(separator: ","))" }.joined(separator: "; "))
        let signatureMatches = tunnelSignature != nil && tunnelSignature == currentTunnelSignature()
        let external = changes.contains { change in
            let owned = change.interfaceName == MihomoProfile.tunnelDevice ||
                (change.interfaceName == nil && tunnelIndices.contains(change.interfaceIndex))
            return !MimoNetworkChangePolicy.isExpectedTunnelChange(ownedInterface: owned,
                recordedTunnelMatches: signatureMatches, eventProcess: change.processID, engineProcess: engineProcess,
                unresolvedInterface: change.interfaceIndex == 0 && change.interfaceName == nil,
                ownedAddress: !tunnelAddresses.isDisjoint(with: change.addresses),
                insideProfileChangeWindow: ContinuousClock.now <= profileChangeDeadline)
        }
        if external { changed("route") }
    }
}
