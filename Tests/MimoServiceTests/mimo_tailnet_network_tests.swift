import Darwin
import Foundation

@MainActor
enum MimoTailnetNetworkTests {
    static func run() {
        let source = TailnetSnapshotFixture()
        let prefix = "State:/Network/Service/native/"
        let dns: NSDictionary = ["InterfaceName": "utun8", "ServerAddresses": ["100.100.100.100"], "SupplementalMatchDomains": ["", "example.ts.net"]]
        let ip: NSDictionary = ["InterfaceName": "utun8", "Addresses": ["100.65.243.85"], "AdditionalRoutes": [["DestinationAddress": "100.100.100.100", "SubnetMask": "255.255.255.255"]]]
        source.set([prefix + "DNS": dns, prefix + "IPv4": ip, prefix + "VPN": ["Status": 7], prefix + "Proxies": ["FTPPassive": 1], "State:/Network/Global/Proxies": ["FTPPassive": 1, "__SCOPED__": ["utun8": ["HTTPEnable": 0]]]])
        let changes = MimoTailnetNetworkChanges(read: source.get, interfaceIndex: { $0 == "utun8" ? 32 : 0 })
        changes.start()
        changes.setProxyEndpoint("203.0.113.8", interface: "en0")
        let keys = ["DNS", "IPv4", "VPN", "Proxies"].map { prefix + $0 }
        source.set(["State:/Network/Global/Proxies": ["FTPPassive": 1]])
        require(changes.classify(keys + ["State:/Network/Global/Proxies"]) == Set(keys + ["State:/Network/Global/Proxies"]), "native disconnect updates provider without public verification")
        source.set([prefix + "DNS": dns, prefix + "IPv4": ip, prefix + "VPN": ["Status": 7], prefix + "Proxies": ["FTPPassive": 1]])
        require(changes.classify(keys) == Set(keys), "native reconnect is private")
        require(changes.nonTailnetDNS([prefix + "DNS": dns, "other": ["ServerAddresses": ["192.168.1.1"]]]).count == 1, "only validated native DNS is excluded from public DNS comparison")
        var publicIP = ip as! [String: Any]
        publicIP["AdditionalRoutes"] = [["DestinationAddress": "0.0.0.0", "SubnetMask": "0.0.0.0"]]
        source.set([prefix + "IPv4": publicIP as NSDictionary])
        require(changes.classify([prefix + "IPv4"]).isEmpty, "exit-node routes must revoke the public approval")
        source.set([prefix + "Proxies": ["HTTPEnable": 1]])
        require(changes.classify([prefix + "Proxies"]).isEmpty, "actual proxy changes stay external")
        require(changes.classify(["Setup:/Network/Service/native/DNS"]).isEmpty, "saved configuration changes stay external")
        let privateRoute = RouteChangeObserver.Change(type: RTM_ADD, interfaceName: "utun8", interfaceIndex: 32, processID: 1, addresses: ["100.100.100.100"], destination: "100.100.100.100", prefixLength: 32)
        require(changes.isPrivateRouteChange(privateRoute), "Quad100 host route does not affect the public proxy")
        var route = privateRoute
        route.destination = "0.0.0.0"; route.prefixLength = 1
        require(!changes.isPrivateRouteChange(route), "split-default routes always require verification")
        route.routeFlags = RTF_IFSCOPE
        require(changes.isPrivateRouteChange(route), "a native interface-scoped route cannot change the public proxy interface")
        route.routeFlags = 0
        route.destination = "192.168.0.0"; route.prefixLength = 16
        require(!changes.isPrivateRouteChange(route), "subnet-router routes require verification")
        changes.setProxyEndpoint("100.65.0.1", interface: "utun8")
        require(!changes.isPrivateRouteChange(privateRoute), "a Tailnet proxy endpoint cannot skip verification")
        changes.setProxyEndpoint("203.0.113.8", interface: "utun8")
        require(!changes.isPrivateRouteChange(privateRoute), "a public proxy routed through an exit node cannot skip verification")
        changes.setProxyEndpoint(nil, interface: nil)
        require(!changes.isPrivateRouteChange(privateRoute), "an unresolved endpoint cannot skip verification")
        require(changes.isNativeDNSSelection(["__CONFIGURATION_ID__": "Supplemental: native 0", "ServerAddresses": ["100.100.100.100"]]) == false, "a Direct/unknown public route cannot classify native DNS selection")
        changes.setProxyEndpoint("203.0.113.8", interface: "en0")
        require(changes.isNativeDNSSelection(["__CONFIGURATION_ID__": "Supplemental: native 0", "ServerAddresses": ["100.100.100.100"]]), "configd may select the native resolver while the protected resolver is republished")
        var scoped: [String: Any] = ["__CONFIGURATION_ID__": "Supplemental: native 0", "__IF_INDEX__": 32,
                                     "SearchOrder": 100000, "SearchDomains": ["example.ts.net"],
                                     "ServerAddresses": ["100.100.100.100", "fd7a:115c:a1e0::53"]]
        require(changes.isNativeDNSSelection(scoped as NSDictionary), "configd's current native interface index is expected reconnect metadata")
        for invalid: Any in [0, -1, 33, "32"] {
            scoped["__IF_INDEX__"] = invalid
            require(!changes.isNativeDNSSelection(scoped as NSDictionary), "invalid or different interface indices remain external")
        }
        scoped["__IF_INDEX__"] = 32
        scoped["ServerAddresses"] = ["1.1.1.1"]
        require(!changes.isNativeDNSSelection(scoped as NSDictionary), "a matching interface index cannot authorize a different DNS server")
        scoped["ServerAddresses"] = ["100.100.100.100"]
        scoped["UnknownField"] = 1
        require(!changes.isNativeDNSSelection(scoped as NSDictionary), "unknown resolver fields remain external")
        require(!changes.isNativeDNSSelection(["__CONFIGURATION_ID__": "Supplemental: native 0", "ServerAddresses": ["1.1.1.1"]]), "public DNS selection is never classified as Quad100")
        source.set(["Setup:/Network/Service/native/Interface": ["Type": "VPN", "SubType": "io.tailscale.ipn.macsys"], prefix + "VPN": ["Status": 0]])
        let cold = MimoTailnetNetworkChanges(read: source.get)
        cold.start(); cold.setProxyEndpoint("203.0.113.8", interface: "en0")
        source.set([prefix + "VPN": ["Status": 1]])
        require(cold.classify([prefix + "VPN"]) == [prefix + "VPN"], "a native service known from registration can start without an old interface lease")
        source.set([prefix + "DNS": dns, prefix + "IPv4": ip, "State:/Network/Service/ethernet/DNS": ["ServerAddresses": ["192.168.1.1"]]])
        let disconnect = MimoTailnetNetworkChanges(read: source.get)
        disconnect.start(); disconnect.setProxyEndpoint("203.0.113.8", interface: "en0")
        source.set([prefix + "DNS": ["InterfaceName": "utun8", "ServerAddresses": ["192.168.1.1"]], "State:/Network/Service/ethernet/DNS": ["ServerAddresses": ["192.168.1.1"]]])
        require(disconnect.classify([prefix + "DNS"]) == [prefix + "DNS"], "native disconnect may briefly inherit unchanged physical DNS")
        source.set([prefix + "DNS": ["InterfaceName": "utun8", "ServerAddresses": ["1.1.1.1"]], "State:/Network/Service/ethernet/DNS": ["ServerAddresses": ["192.168.1.1"]]])
        require(disconnect.classify([prefix + "DNS"]).isEmpty, "new custom native DNS still requires verification")
        routeParser()
        print("PASS Tailnet notification and route classification")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    private static func routeParser() {
        func address(_ value: String) -> Data {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            _ = value.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
            return withUnsafeBytes(of: addr) { Data($0) }
        }
        func route(_ destination: String, _ mask: String, host: Bool = false) -> RouteChangeObserver.Change? {
            var header = rt_msghdr()
            header.rtm_version = UInt8(RTM_VERSION); header.rtm_type = UInt8(RTM_ADD)
            header.rtm_flags = RTF_UP | (host ? RTF_HOST : 0)
            header.rtm_addrs = RTA_DST | RTA_NETMASK
            var bytes = withUnsafeBytes(of: header) { Data($0) }
            bytes.append(address(destination)); bytes.append(address(mask))
            return bytes.withUnsafeBytes { RouteChangeObserver.change($0) }
        }
        let host = route("100.100.100.100", "0.0.0.0", host: true)
        require(host?.destination == "100.100.100.100" && host?.prefixLength == 32, "host routes retain their destination and implied prefix")
        require(route("100.64.0.0", "255.192.0.0")?.prefixLength == 10, "Tailnet prefix is decoded from the routing message")
        require(route("0.0.0.0", "128.0.0.0")?.prefixLength == 1, "split defaults cannot look like Tailnet routes")
        require(route("100.64.0.0", "255.0.255.0")?.prefixLength == nil, "malformed masks remain unclassified")
        var header = ifa_msghdr()
        header.ifam_type = UInt8(RTM_DELADDR); header.ifam_addrs = RTA_IFA
        var bytes = withUnsafeBytes(of: header) { Data($0) }
        bytes.append(address("100.65.243.85"))
        require(bytes.withUnsafeBytes { RouteChangeObserver.change($0)?.addresses } == ["100.65.243.85"], "address removal retains the actual address after the interface disappears")
    }
}

private final class TailnetSnapshotFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MimoTailnetNetworkChanges.Snapshot = [:]
    func set(_ value: MimoTailnetNetworkChanges.Snapshot) { lock.withLock { self.value = value } }
    func get() -> MimoTailnetNetworkChanges.Snapshot? { lock.withLock { value } }
}
