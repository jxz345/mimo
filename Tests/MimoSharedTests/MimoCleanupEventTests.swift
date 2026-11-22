import XCTest
@testable import MimoShared

final class MimoCleanupEventTests: XCTestCase {
    func testOnlyVerifiedMarkersBecomeReadableStages() {
        let output = "command output containing MIMO_CLEANUP tailnet_verified\nMIMO_CLEANUP firewall_removed\r\nMIMO_CLEANUP tailnet_verified\nMIMO_CLEANUP unknown-private-value\n"
        XCTAssertEqual(MimoCleanupEvent.stages(in: output), ["firewall_removed", "tailnet_verified"])
        XCTAssertEqual(EventLogLine.message(event: "mimo_cleanup_step", fields: ["stage": "tailnet_verified"]),
                       "Native Tailnet route and MagicDNS verified")
        XCTAssertNil(EventLogLine.message(event: "mimo_cleanup_step", fields: ["stage": "secret"]))
    }
    func testFailureAndDisconnectedTailnetNeverClaimRestoration() {
        XCTAssertTrue(EventLogLine.message(event: "mimo_cleanup_step", fields: ["stage": "tailnet_not_connected"])!.contains("could not be verified"))
        XCTAssertTrue(EventLogLine.message(event: "mimo_deactivation_failed", fields: [:])!.contains("incomplete"))
        XCTAssertNotNil(EventLogLine.message(event: "mimo_local_monitor_started", fields: [:]))
    }
}
