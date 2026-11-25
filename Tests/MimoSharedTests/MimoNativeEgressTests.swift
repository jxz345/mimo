import XCTest
@testable import MimoShared

final class MimoNativeEgressTests: XCTestCase {
    private let sockets = "p42\0u0\0\nf1\0tIPv4\0PUDP\0n*:41641\0\nf2\0tIPv6\0PUDP\0n[::]:41641\0\nf3\0tIPv4\0PTCP\0n192.0.2.2:50001->203.0.113.8:443\0TST=CLOSED\0\nf4\0tIPv6\0PTCP\0n[2001:db8::2]:50002->[2001:db8::8]:443\0TST=ESTABLISHED\0\nf5\0tIPv4\0PTCP\0n192.0.2.2:50003->203.0.113.9:80\0TST=ESTABLISHED\0"

    func testOnlyHeldRootSocketsFromTheVerifiedProcessCanCreateScopes() throws {
        let native = MimoNativeEgress.parse(sockets, process: 42)
        XCTAssertEqual(native.datagrams.count, 2)
        XCTAssertEqual(native.https, ["203.0.113.8", "2001:db8::8"])
        XCTAssertEqual(MimoNativeEgress.parse(sockets, process: 43), .init())
        XCTAssertEqual(MimoNativeEgress.parse(sockets.replacingOccurrences(of: "u0\0", with: "u501\0"), process: 42), .init())
        for rule in try native.rules() {
            XCTAssertTrue(rule.contains("user = 0 no state"))
            XCTAssertTrue(rule.contains("mimo:active:native-vpn-"))
        }
    }

    func testNativeTransportCannotOverrideFakeOrWrongInterfaceTailnetDenials() throws {
        let native = MimoNativeEgress.parse(sockets, process: 42)
        let policy = try MimoFirewallPolicy.activePolicy(group: 10000, nativeInterfaces: ["utun8"], nativeEgress: native)
        XCTAssertTrue(MimoFirewallPolicy.isActiveReadback(policy, group: 10000, nativeInterfaces: ["utun8"], nativeEgress: native))
        XCTAssertFalse(MimoFirewallPolicy.isActiveReadback(policy, group: 10000, nativeInterfaces: ["utun8"]))
        XCTAssertLessThan(try XCTUnwrap(policy.range(of: "mimo:active:tailnet-wrong-path")?.lowerBound),
                          try XCTUnwrap(policy.range(of: "mimo:active:native-vpn-")?.lowerBound))
        XCTAssertFalse(policy.contains("proto tcp from any to any user"))
        XCTAssertFalse(policy.contains("group = 0"))
    }

    func testNativeTransportCanBootstrapBeforeATailnetInterfaceExists() throws {
        let native = MimoNativeEgress.parse(sockets, process: 42)
        let policy = try MimoFirewallPolicy.activePolicy(group: 10000, nativeInterfaces: [], nativeEgress: native)
        XCTAssertTrue(MimoFirewallPolicy.isActiveReadback(policy, group: 10000, nativeEgress: native))
        XCTAssertFalse(policy.contains("label \"mimo:active:tailnet\""))
        XCTAssertTrue(policy.contains("mimo:active:native-vpn-https"))
        XCTAssertTrue(policy.contains("mimo:active:native-vpn-udp"))
        XCTAssertLessThan(try XCTUnwrap(policy.range(of: "mimo:active:tailnet-wrong-path")?.lowerBound),
                          try XCTUnwrap(policy.range(of: "mimo:active:native-vpn-")?.lowerBound))
        XCTAssertTrue(policy.hasSuffix("block drop out quick all label \"mimo:active:deny-native-fallback\"\n"))
        let revoked = try MimoFirewallPolicy.activePolicy(group: 10000)
        XCTAssertFalse(revoked.contains("mimo:active:native-vpn-"))
        XCTAssertTrue(revoked.contains("mimo:active:tailnet-wrong-path"))
        XCTAssertFalse(MimoFirewallPolicy.isActiveReadback(policy, group: 10000))
    }

    func testMalformedSocketsAndUnsafeRuleInputsCannotCreatePermissions() throws {
        let invalid = "p42\0u0\0f1\0tIPv4\0PUDP\0n*:53\0f2\0tIPv4\0PUDP\0n*:99999\0f3\0tIPv4\0PTCP\0n*:1234->203.0.113.8:443\0TST=ESTABLISHED\0"
        XCTAssertEqual(MimoNativeEgress.parse(invalid, process: 42), .init())
        var native = MimoNativeEgress()
        native.https = ["203.0.113.8\npass out all"]
        XCTAssertThrowsError(try native.rules())
        native.https = []; native.datagrams = [.init(ipv6: false, source: "2001:db8::1", port: 41641)]
        XCTAssertThrowsError(try native.rules())
    }
}
