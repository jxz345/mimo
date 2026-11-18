import XCTest
@testable import ExitIPShared

final class MimoNativeTransportTests: XCTestCase {
    func testBootstrapDiscoveryAcceptsOnlySuccessfulIPv4AddressAnswers() throws {
        let answers: [[String: Any]] = [
            ["type": 1, "data": "192.0.2.8"], ["type": 1, "data": "192.0.2.8"],
            ["type": 28, "data": "2001:db8::8"], ["type": 5, "data": "192.0.2.9"],
            ["type": 1, "data": "2001:db8::9"], ["type": 1, "data": "invalid\npass all"]
        ]
        let valid = try JSONSerialization.data(withJSONObject: ["Status": 0, "Answer": answers])
        XCTAssertEqual(MimoNativeInfrastructure.ipv4Answers(valid), ["192.0.2.8"])
        let failed = try JSONSerialization.data(withJSONObject: ["Status": 3, "Answer": answers])
        XCTAssertTrue(MimoNativeInfrastructure.ipv4Answers(failed).isEmpty)
        XCTAssertTrue(MimoNativeInfrastructure.ipv4Answers(Data("not JSON".utf8)).isEmpty)
    }

    func testBootstrapHTTPSStillRequiresAnAuthenticatedHeldRootSocket() throws {
        XCTAssertTrue(MimoNativeInfrastructure.dnsHosts.contains("derp5.tailscale.com"), "built-in bootstrap names can be absent from the current DERP map")
        var value = MimoNativeTransport.parse("p123\0u0\0\nf2\0tIPv4\0PTCP\0n192.168.64.2:49152->192.0.2.8:443\0TST=SYN_SENT\0\n", process: 123)
        XCTAssertEqual(try value.render(), "\n")
        value.infrastructure = ["192.0.2.8"]
        XCTAssertTrue(try value.render().contains("port 49152 to 192.0.2.8 port 443 user 0 no state"))
        value.sockets.removeAll()
        XCTAssertEqual(try value.render(), "\n", "infrastructure discovery cannot grant an address-wide exception")
    }

    func testRotatingInfrastructureAnswersAreRetainedBrieflyButNeverForever() {
        let now = Date(timeIntervalSince1970: 1_000)
        var cache = MimoInfrastructureCache()
        XCTAssertTrue(cache.needsRefresh(at: now))
        cache.update(["192.0.2.1"], at: now)
        XCTAssertFalse(cache.needsRefresh(at: now.addingTimeInterval(9)))
        XCTAssertTrue(cache.needsRefresh(at: now.addingTimeInterval(10)))
        cache.update(["192.0.2.2"], at: now.addingTimeInterval(10))
        XCTAssertEqual(cache.addresses(at: now.addingTimeInterval(299)), ["192.0.2.1", "192.0.2.2"])
        cache.update([], at: now.addingTimeInterval(300))
        XCTAssertEqual(cache.addresses(at: now.addingTimeInterval(300)), ["192.0.2.2"])
        XCTAssertTrue(cache.addresses(at: now.addingTimeInterval(310)).isEmpty)
        XCTAssertTrue(cache.addresses(at: now.addingTimeInterval(-1)).isEmpty)
    }

    func testIPv6InfrastructureNeverProducesAnException() throws {
        var transport = MimoNativeTransport.parse("p123\0u0\0\nf2\0tIPv6\0PTCP\0n[fd00::2]:49153->[2001:db8::4ff]:443\0TST=SYN_SENT\0\n", process: 123)
        transport.infrastructure = ["2001:db8:0:0:0:0:0:04ff"]
        XCTAssertEqual(try transport.render(), "\n")
    }

    func testTailnetAndDiagnosticSettingsDoNotChangePublicVerificationPolicy() throws {
        let original = MachineSettings()
        var next = original
        next.tailscaleProviderEnabled.toggle()
        next.diagnostics.retentionDays = 30
        XCTAssertFalse(next.affectsVerification(comparedTo: original))
        next.allowlist = AllowedIPList(addresses: ["192.0.2.1"])
        XCTAssertTrue(next.affectsVerification(comparedTo: original))
        let rules = try MimoFirewallPolicy.render(group: 10000, mode: .rule, tunnel: "utun239")
        XCTAssertLessThan(rules.range(of: "block return out quick to { 100.64")!.lowerBound,
                          rules.range(of: "pass out quick proto { tcp, udp } all group")!.lowerBound)
    }
    func testOnlyRootOwnedConnectedHTTPSAndBoundUDPBecomeExceptions() throws {
        let fixture = "p123\0uroot\0\nf1\0tIPv4\0PUDP\0n*:41641\0\n"
        XCTAssertTrue(MimoNativeTransport.parse(fixture, process: 123).sockets.isEmpty)
        let valid = "p123\0u0\0\nf1\0tIPv4\0PUDP\0n*:41641\0\n" +
            "f2\0tIPv4\0PTCP\0n192.168.64.2:49152->203.0.113.10:443\0TST=ESTABLISHED\0TQR=0\0TQS=0\0\n" +
            "f3\0tIPv6\0PTCP\0n[fd00::2]:49153->[2001:db8::10]:443\0TST=SYN_SENT\0\n" +
            "f4\0tIPv4\0PTCP\0n192.168.64.2:49154->203.0.113.10:80\0TST=ESTABLISHED\0\n" +
            "f5\0tIPv4\0PTCP\0n192.168.64.2:49155->203.0.113.10:443\0TST=CLOSED\0\n" +
            "f6\0tIPv4\0PUDP\0n*:53\0\n"
        var value = MimoNativeTransport.parse(valid, process: 123)
        XCTAssertEqual(try value.render(), "\n", "Held sockets alone must not grant arbitrary HTTPS or UDP access")
        value.infrastructure = ["203.0.113.10", "2001:db8::10"]
        XCTAssertEqual(value.sockets.count, 3)
        let rules = try value.render()
        XCTAssertTrue(rules.contains("from 192.168.64.2 port 49152 to 203.0.113.10 port 443 user 0 no state"))
        XCTAssertTrue(rules.contains("proto udp from any port 41641 to 203.0.113.10 port 3478 user 0"))
        XCTAssertFalse(rules.contains("to any"))
        XCTAssertFalse(rules.contains("49154"))
        XCTAssertFalse(rules.contains("49155"))
        XCTAssertTrue(MimoNativeTransport.parse(valid, process: 456).sockets.isEmpty)
        XCTAssertTrue(MimoNativeTransport.parse(valid.replacingOccurrences(of: "u0", with: "u501"), process: 123).sockets.isEmpty)
    }

    func testInterfaceExceptionIsTailnetOnlyAndRejectsMimoOrInjectedInterfaces() throws {
        let rules = try MimoNativeTransport(interface: "utun3").render()
        XCTAssertEqual(rules, "pass out quick on utun3 inet to 100.64.0.0/10 no state\n")
        for invalid in ["utun", "utun239", "en0", "utun3\npass all", "utun-1"] {
            XCTAssertThrowsError(try MimoNativeTransport(interface: invalid).render())
        }
    }
}
