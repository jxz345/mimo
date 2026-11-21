import XCTest
@testable import MimoShared

final class MimoTailnetChangePolicyTests: XCTestCase {
    func testOnlyPrivateTailnetPrefixesCanSkipVerification() {
        for (address, prefix) in [("100.64.0.0", 10), ("100.100.100.100", 32), ("fd7a:115c:a1e0::", 48), ("fd7a:115c:a1e0::53", 128)] {
            XCTAssertTrue(MimoTailnetChangePolicy.isPrivateRoute(destination: address, prefixLength: prefix))
        }
        for (address, prefix) in [("0.0.0.0", 0), ("0.0.0.0", 1), ("128.0.0.0", 1), ("100.64.0.0", 9), ("192.168.1.0", 24), ("100.128.0.1", 32), ("fd7a:115c:a1e0::", 47), ("::", 0)] {
            XCTAssertFalse(MimoTailnetChangePolicy.isPrivateRoute(destination: address, prefixLength: prefix))
        }
        XCTAssertFalse(MimoTailnetChangePolicy.isPrivateRoute(destination: "100.100.100.100", prefixLength: nil))
        XCTAssertFalse(MimoTailnetChangePolicy.isPrivateRoute(destination: nil, prefixLength: 32))
        XCTAssertEqual(MimoTailnetChangePolicy.prefixLength(mask: "255.192.0.0"), 10)
        XCTAssertNil(MimoTailnetChangePolicy.prefixLength(mask: "255.0.255.0"))
    }

    func testExitNodeAndSubnetRouterConfigurationRemainExternal() {
        var ip: [String: Any] = ["InterfaceName": "utun8", "Addresses": ["100.65.243.85"], "Router": "100.65.243.85", "ServerAddress": "127.0.0.1"]
        ip["AdditionalRoutes"] = [["DestinationAddress": "100.100.100.100", "SubnetMask": "255.255.255.255"]]
        XCTAssertTrue(MimoTailnetChangePolicy.isPrivateIPConfiguration(ip, interface: "utun8", family: 4))
        ip["AdditionalRoutes"] = [["DestinationAddress": "0.0.0.0", "SubnetMask": "0.0.0.0"]]
        XCTAssertFalse(MimoTailnetChangePolicy.isPrivateIPConfiguration(ip, interface: "utun8", family: 4))
        ip["AdditionalRoutes"] = [["DestinationAddress": "192.168.0.0", "SubnetMask": "255.255.0.0"]]
        XCTAssertFalse(MimoTailnetChangePolicy.isPrivateIPConfiguration(ip, interface: "utun8", family: 4))
        ip.removeValue(forKey: "AdditionalRoutes")
        ip["UnknownPolicy"] = 1
        XCTAssertFalse(MimoTailnetChangePolicy.isPrivateIPConfiguration(ip, interface: "utun8", family: 4))
    }

    func testPublicDNSAndEnabledProxySettingsRemainExternal() {
        var dns: [String: Any] = ["ServerAddresses": ["100.100.100.100", "fd7a:115c:a1e0::53"], "SupplementalMatchDomains": ["", "example.ts.net."]]
        XCTAssertTrue(MimoTailnetChangePolicy.isNativeDNS(dns))
        dns["ServerAddresses"] = ["100.100.100.100", "1.1.1.1"]
        XCTAssertFalse(MimoTailnetChangePolicy.isNativeDNS(dns))
        dns["ServerAddresses"] = ["100.100.100.100"]
        dns["SupplementalMatchDomains"] = ["company.example"]
        XCTAssertFalse(MimoTailnetChangePolicy.isNativeDNS(dns))
        XCTAssertTrue(MimoTailnetChangePolicy.isInactiveProxyConfiguration(["HTTPEnable": 0, "FTPPassive": 1]))
        XCTAssertFalse(MimoTailnetChangePolicy.isInactiveProxyConfiguration(["HTTPEnable": 1]))
        XCTAssertFalse(MimoTailnetChangePolicy.isInactiveProxyConfiguration(["ProxyAutoConfigURLString": "https://example.com/proxy.pac"]))
    }
}
