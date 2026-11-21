import XCTest
@testable import MimoShared

final class MihomoRuntimeInspectionTests: XCTestCase {
    private var config: [String: Any] {
        ["mode": "rule", "ipv6": false, "allow-lan": false, "bind-address": "127.0.0.1",
         "port": 0, "socks-port": 0, "redir-port": 0, "tproxy-port": 0, "mixed-port": 0,
         "ss-config": "", "vmess-config": "", "interface-name": "", "routing-mark": 0,
         "tuic-server": ["enable": false], "tun": ["enable": false]]
    }
    private var rules: [[String: Any]] { [["index": 0, "type": "Match", "proxy": "REJECT", "payload": ""]] }

    private func matches(_ config: [String: Any], _ rules: [[String: Any]]) -> Bool {
        MihomoRuntimeInspection.matches(profile: MihomoProfile.blocking(), active: false, proxy: nil,
                                        config: config, rules: rules, proxies: [:])
    }

    func testBlockingRuntimeRejectsUnexpectedListenerModeOrTunnel() {
        XCTAssertTrue(matches(config, rules))
        for (key, value): (String, Any) in [("mode", "direct"), ("ipv6", true), ("allow-lan", true),
                ("mixed-port", 7890), ("socks-port", 8888), ("tproxy-port", 9999), ("port", 8080),
                ("bind-address", "*"), ("interface-name", "utun1"), ("routing-mark", 3),
                ("ss-config", "unexpected"), ("tun", ["enable": true]), ("tuic-server", ["enable": true])] {
            var changed = config; changed[key] = value
            XCTAssertFalse(matches(changed, rules), key)
        }
    }

    func testSameRulePayloadAndTargetCannotHideDifferentTypeOrDisabledRule() {
        for (key, value): (String, Any) in [("index", 1), ("type", "Domain"), ("proxy", "DIRECT"),
                ("payload", "example.com"), ("extra", ["disabled": true])] {
            var changed = rules; changed[0][key] = value
            XCTAssertFalse(matches(config, changed), key)
        }
        XCTAssertFalse(matches(config, []))
        XCTAssertFalse(matches(config, rules + rules))
    }

    func testClosedPolicyBlocksMixedLoopbackBeforeItsLoopbackException() throws {
        let rules = try MimoFirewallPolicy.render(group: 10000)
        let block = try XCTUnwrap(rules.range(of: "block return out quick on lo0"))
        let allow = try XCTUnwrap(rules.range(of: "pass out quick on lo0"))
        XCTAssertLessThan(block.lowerBound, allow.lowerBound)
        XCTAssertTrue(rules.contains("{ 127.0.0.1, ::1 } port { 7890, 1053 }"))
    }
}
