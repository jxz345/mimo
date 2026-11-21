import XCTest
@testable import MimoShared

final class MimoProtectedDNSTests: XCTestCase {
    private let native: [String: Any] = ["InterfaceName": "utun8", "ServerAddresses": ["100.100.100.100"],
                                         "SupplementalMatchDomains": ["", "example.ts.net"], "SearchDomains": ["example.ts.net."],
                                         "SupplementalMatchDomainsNoSearch": 1]

    func testMagicDNSSearchDomainSurvivesProtectedDefault() throws {
        let wifi: [String: Any] = ["ServerAddresses": ["192.168.1.1"], "DomainName": "lan"]
        let value = try XCTUnwrap(MimoProtectedDNS.resolver(services: ["State:/Network/Service/native/DNS": native,
                                                                       "State:/Network/Service/wifi/DNS": wifi], primary: wifi))
        XCTAssertEqual(value["ServerAddresses"] as? [String], ["127.0.0.1"])
        XCTAssertEqual(value["ServerPort"] as? Int, MimoRuntime.dnsPort)
        XCTAssertEqual(value["SupplementalMatchDomains"] as? [String], ["", "example.ts.net"])
        XCTAssertEqual(value["SupplementalMatchOrders"] as? [Int], [1, 1])
        // The resolver becomes the default; without these, `peer` never expands to `peer.example.ts.net`.
        XCTAssertEqual(value["SearchDomains"] as? [String], ["example.ts.net", "lan"])
    }

    func testOnlyPotentialDefaultsContributeSearchDomains() throws {
        // configd drops a split-only VPN's own SearchDomains; Direct never searches them.
        let split: [String: Any] = ["ServerAddresses": ["10.0.0.53"], "SupplementalMatchDomains": ["corp.example"], "SearchDomains": ["corp.example"]]
        let value = try XCTUnwrap(MimoProtectedDNS.resolver(services: ["State:/Network/Service/split/DNS": split], primary: nil))
        XCTAssertEqual(value["SupplementalMatchDomains"] as? [String], ["", "corp.example"])
        XCTAssertNil(value["SearchDomains"], "no search list is published when the native default has none")
    }

    func testSearchDomainsAreTrimmedDeduplicatedAndValidated() throws {
        var tailnet = native
        tailnet["SearchDomains"] = [".example.ts.net.", "EXAMPLE.ts.net", "bad domain", "", "."]
        let saved: [String: Any] = ["ServerAddresses": ["192.168.1.1"], "SearchDomains": ["example.ts.net", "home.arpa"]]
        let value = try XCTUnwrap(MimoProtectedDNS.resolver(services: ["State:/Network/Service/native/DNS": tailnet], primary: saved))
        XCTAssertEqual(value["SearchDomains"] as? [String], ["example.ts.net", "home.arpa"])
    }

    func testTooManyDomainsCannotBeOverridden() {
        let domains = (0..<MimoProtectedDNS.maximumDomains).map { "\($0).100.in-addr.arpa" }
        let wide: [String: Any] = ["ServerAddresses": ["100.100.100.100"], "SupplementalMatchDomains": domains]
        XCTAssertNil(MimoProtectedDNS.resolver(services: ["State:/Network/Service/native/DNS": wide], primary: nil))
        let search: [String: Any] = ["ServerAddresses": ["192.168.1.1"], "SearchDomains": (0...MimoProtectedDNS.maximumDomains).map { "d\($0).example" }]
        XCTAssertNil(MimoProtectedDNS.resolver(services: [:], primary: search))
    }
}
