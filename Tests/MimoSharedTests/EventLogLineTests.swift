import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import MimoShared

/// The Event Log window's lines: one concise UTC line per important event, nothing for routine records.
final class EventLogLineTests: XCTestCase {
    func testSystemCommandFailureShowsOutcomeWithoutCommandContents() {
        XCTAssertEqual(EventLogLine.message(event: "mimo_runtime_command_failed", fields: [
            "program": "pfctl", "operation": "-n", "status": "124", "durationMS": "3010",
            "detail": "private data must not be displayed"
        ]), "System command failed · pfctl -n · status 124 · 3010 ms")
    }
    func testCoreInfrastructureMigrationAndFailuresAreVisible() {
        XCTAssertTrue(EventLogLine.message(event: "mimo_installation", fields: ["stage": "infrastructure_merged"])?.contains("existing supervisor") == true)
        XCTAssertNotNil(EventLogLine.message(event: "mimo_supervisor_recovery_requested", fields: [:]))
        XCTAssertTrue(EventLogLine.message(event: "mimo_infrastructure_started", fields: [:])?.contains("10 seconds") == true)
        for event in ["mimo_infrastructure_start_failed", "mimo_infrastructure_sweep_failed", "mimo_supervisor_recovery_failed"] {
            XCTAssertTrue(EventLogLine.message(event: event, fields: ["reason": "test failure"])?.contains("test failure") == true)
        }
        XCTAssertNotNil(EventLogLine.message(event: "mimo_infrastructure_stopped", fields: [:]))
    }
    func testLogMaintenanceReportsDiscardedRecordsAndAnActionableStorageFailure() {
        let message = EventLogLine.message(event: "mimo_log_maintenance", fields: ["rotated": "2", "deleted": "3", "droppedRecords": "4", "writeFailures": "1"])
        XCTAssertTrue(message?.contains("2 rotated") == true)
        XCTAssertTrue(message?.contains("4 queued records dropped") == true)
        XCTAssertTrue(message?.contains("1 writes failed") == true)
        XCTAssertTrue(EventLogLine.message(event: "mimo_log_maintenance_failed", fields: [:])?.contains("permissions and free disk space") == true)
    }
    func testInstallerEventsDistinguishConsentVerificationAndRollback() {
        for stage in ["started", "reactivating", "conflict_detected", "conflict_cancelled", "conflict_approved",
                      "conflict_disabled", "conflict_stop_requested", "conflicts_cleared", "replacing_services",
                      "services_enabled", "starting_services", "verifying_services", "services_verified",
                      "succeeded", "cancelled", "failed", "health_failed", "rollback_started", "rollback_succeeded", "rollback_failed"] {
            XCTAssertNotNil(EventLogLine.message(event: "mimo_installation", fields: ["operation": "install", "stage": stage]))
        }
        XCTAssertEqual(EventLogLine.message(event: "mimo_installation", fields: ["stage": "failed", "item": "verifying_services", "status": "1"]),
                       "Installation failed · verifying_services · status 1")
        XCTAssertEqual(EventLogLine.message(event: "mimo_installation", fields: ["operation": "activate", "stage": "succeeded"]),
                       "Activation completed · all services installed and healthy")
        XCTAssertTrue(EventLogLine.format(timestamp: "2026-11-22T15:30:00.123Z", event: "mimo_installation", fields: ["stage": "started"])!.hasPrefix("2026-11-22 15:30:00.123Z"))
    }
    func testVerificationTriggersAndGeographyAreExplicit() {
        XCTAssertEqual(EventLogLine.message(event: "mimo_network_changed", fields: ["source": "route", "detail": "route added on en0 (pid 42)", "generation": "7"]),
                       "Check trigger · route · route added on en0 (pid 42) · generation 7")
        XCTAssertEqual(EventLogLine.message(event: "mimo_verification_audit_failed", fields: ["reason": "DNS changed"]),
                       "Verification audit failed · DNS changed")
        XCTAssertEqual(EventLogLine.message(event: "mimo_liveness_lost", fields: ["heartbeatExpired": "true"]),
                       "Check trigger · core heartbeat expired")
        XCTAssertTrue(EventLogLine.message(event: "lookup_country_unknown", fields: [:])!.contains("no country retry"))
    }
    private let at = "2026-10-18T13:28:56Z"

    private func line(_ event: String, _ fields: [String: String] = [:]) -> String? {
        EventLogLine.format(timestamp: at, event: event, fields: fields)
    }

    func testLinesStartWithAUTCStamp() {
        XCTAssertEqual(line("monitor_started"), "2026-10-18 13:28:56Z  Monitoring started")
        XCTAssertEqual(EventLogLine.format(timestamp: "2026-10-18T13:28:56.123Z", event: "monitor_stopped", fields: [:]),
                       "2026-10-18 13:28:56.123Z  Monitoring stopped")
    }

    func testChecksNameTheirTriggerAndProvider() {
        XCTAssertEqual(line("refresh_requested", ["trigger": "route_change", "provider": "ipWhois", "urgency": "network_change"]),
                       "2026-10-18 13:28:56Z  Check · route changed · IPWHOIS.io")
        XCTAssertEqual(EventLogLine.message(event: "refresh_requested", fields: ["trigger": "manual", "provider": "ipapiCo"]),
                       "Check · Refresh now · ipapi.co")
        XCTAssertEqual(EventLogLine.message(event: "refresh_requested", fields: ["trigger": "periodic", "provider": "ipapiIs"]),
                       "Check · timer · ipapi.is")
        for (raw, phrase) in [("startup", "service start"), ("network_path", "network path changed"),
                              ("network_configuration", "network settings changed"), ("system_wake", "Mac woke"),
                              ("screens_wake", "screen woke"), ("session_active", "session active"),
                              ("app_active", "app activated"), ("trailing", "follow-up after events"),
                              ("queued", "queued check"), ("retry", "retry"), ("recheck", "recheck"),
                              ("provider_changed", "provider changed"), ("settings_changed", "settings changed")] {
            XCTAssertEqual(EventLogLine.trigger(raw), phrase)
        }
    }

    func testResultsAndPolicyEvents() {
        func message(_ event: String, _ fields: [String: String]) -> String? { EventLogLine.message(event: event, fields: fields) }
        XCTAssertEqual(message("lookup_succeeded", ["provider": "ipWhois", "country": "SG"]), "Lookup OK · IPWHOIS.io · SG")
        XCTAssertEqual(message("lookup_failed", ["provider": "ipapiCo", "message": "timed out"]), "Lookup failed · ipapi.co · timed out")
        // The dashboard no longer shows installation details, so the line doesn't point there.
        XCTAssertEqual(message("daemon_install_failed", ["log": "/tmp/daemon-setup.log"]), "Service installation failed")
        XCTAssertEqual(message("refresh_skipped", ["trigger": "app_active", "reason": "fresh"]),
                       "Skipped · app activated · result under 2 min old")
        XCTAssertEqual(message("refresh_skipped", ["trigger": "screens_wake", "reason": "event_window"]),
                       "Skipped · screen woke · absorbed by the check just run")
        XCTAssertEqual(message("refresh_event_merged", ["trigger": "route_change", "trailingAt": "2026-10-18T13:29:01Z"]),
                       "Merged · route changed → follow-up at 13:29:01Z")
        XCTAssertEqual(message("refresh_queued", ["reason": "provider_gap", "notBefore": "2026-10-18T13:29:01Z"]),
                       "Queued · provider gap · at 13:29:01Z")
        XCTAssertEqual(message("lookup_rate_limited", ["provider": "ipapiIs", "retryNotBefore": "2026-10-19T00:00:00Z"]),
                       "Provider paused · ipapi.is until 00:00:00Z")
        XCTAssertEqual(message("lookup_all_providers_paused", ["resumeAt": "2026-10-19T08:00:00Z"]),
                       "All providers paused until 08:00:00Z")
        XCTAssertEqual(message("lookup_daily_budget_exhausted", ["provider": "ipapiIs", "resetAt": "2026-10-19T00:00:00Z"]),
                       "Daily budget used · ipapi.is · resets 00:00:00Z")
        XCTAssertEqual(message("confirmation_result", ["provider": "ipapiCo", "country": "SG", "agrees": "true"]),
                       "Country confirmed · ipapi.co · SG")
        XCTAssertEqual(message("confirmation_result", ["provider": "ipapiCo", "country": "JP", "agrees": "false"]),
                       "Country not confirmed · ipapi.co · JP")
        XCTAssertEqual(message("allowlist_warning_presented", ["ip": "<redacted-ip>"]), "Exit IP not on allowlist · <redacted-ip>")
        XCTAssertEqual(message("clash_profile_written", ["path": "/x"]), "Clash Verge profile written")
        XCTAssertEqual(message("clash_profile_copy_written", ["name": "Mimo 2026-10-25 (3).yaml"]),
                       "Clash Verge profile copy · Mimo 2026-10-25 (3).yaml")
        XCTAssertEqual(message("keychain_operation", ["operation": "load", "outcome": "started", "duration_ms": "0"]),
                       "Keychain load · started")
        XCTAssertEqual(message("refresh_skipped", ["trigger": "startup", "reason": "token_unavailable"]),
                       "Skipped · service start · import or save the shared IPinfo token in Settings")
    }

    func testRoutineRecordsAreNotShown() {
        for event in ["provider_health_changed", "network_path_unchanged", "network_airport_telemetry_ignored", "widget_reload_requested",
                      "network_configuration_changed", "diagnostic_preferences_changed",
                      "debug_simulation_started", "something_new"] {
            XCTAssertNil(line(event, ["provider": "ipapiCo"]), event)
        }
    }

    func testRecoveryTimelineIncludesCorrelationAndRefusalCause() throws {
        let fields = ["processRole": "core", "recordSequence": "12", "lookup": "12345678-1234-1234-1234-123456789ABC",
                      "attempt": "87654321-1234-1234-1234-123456789ABC", "sequence": "7", "command": "prepare",
                      "revision": "8", "generation": "9", "provider": "ipWhois", "reason": "daily_budget"]
        let line = try XCTUnwrap(EventLogLine.format(timestamp: "2026-11-26T01:02:03.004Z", event: "mimo_core_command_started", fields: fields))
        XCTAssertTrue(line.contains("01:02:03.004Z"))
        XCTAssertTrue(line.contains("core#00000012"))
        XCTAssertTrue(line.contains("check 12345678"))
        XCTAssertTrue(line.contains("attempt 87654321"))
        XCTAssertTrue(line.contains("cmd 7"))
        XCTAssertTrue(line.contains("revision 8 · generation 9"))
        for event in ["lookup_started", "lookup_finished", "lookup_http_request", "lookup_http_refused",
                      "mimo_probe_http_started", "mimo_probe_http_finished", "mimo_supervisor_command_received",
                      "mimo_core_command_finished", "mimo_core_command_failed", "mimo_required_check_close_skipped",
                      "provider_local_retry_requested", "refresh_coalesced_in_flight"] {
            XCTAssertNotNil(EventLogLine.message(event: event, fields: fields), event)
        }
        XCTAssertTrue(EventLogLine.message(event: "lookup_http_refused", fields: fields)!.contains("daily_budget"))
        XCTAssertTrue(EventLogLine.message(event: "mimo_command_rejected", fields: fields)!.contains("prepare"))
        let local = EventLogLine.message(event: "provider_failure_paused", fields: ["explicitRetry": "true", "seconds": "600", "reason": "transport"])!
        XCTAssertTrue(local.contains("automatic checks")); XCTAssertTrue(local.contains("then Retry"))
    }

    func testLongMessagesAreCutToOneLine() throws {
        let text = try XCTUnwrap(EventLogLine.message(event: "lookup_failed",
                                                     fields: ["provider": "ipapiCo", "message": String(repeating: "x", count: 300) + "\nmore"]))
        let cut = EventLogLine.truncated(text)
        XCTAssertEqual(cut.count, EventLogLine.maximumMessageLength)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertFalse(cut.contains("\n"))
    }

    func testMonitoringSummaryDescribesTimerAndEvents() {
        XCTAssertEqual(MonitoringRules.summary(interval: .fifteenMinutes),
                       "Checks every 15 minutes, and after network, route, proxy, DNS, VPN/TUN, lock, login, user-switch, display or system-wake changes.")
        XCTAssertTrue(MonitoringRules.summary(interval: .sixtyMinutes).hasPrefix("Checks every hour, and after"))
        for interval in RefreshInterval.allCases {
            XCTAssertFalse(MonitoringRules.summary(interval: interval).contains("recommended"))
        }
    }

    func testStopSymbolIsAValidSFSymbol() {
        XCTAssertEqual(MimoIndicatorSymbol.lookupError, "xmark.octagon.fill")
        XCTAssertNotEqual(MimoIndicatorSymbol.lookupError, MimoIndicatorSymbol.countryChanged)
        // The allowlist mismatch uses the same stop sign, drawn red.
        XCTAssertEqual(MimoIndicatorSymbol.outsideAllowlist, MimoIndicatorSymbol.lookupError)
        #if canImport(AppKit)
        XCTAssertNotNil(NSImage(systemSymbolName: MimoIndicatorSymbol.lookupError, accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: MimoIndicatorSymbol.countryChanged, accessibilityDescription: nil))
        #endif
    }
}

final class EventLogBufferTests: XCTestCase {
    func testKeepsOnlyTheNewestLines() {
        var buffer = EventLogBuffer(limit: 3)
        for second in 0..<5 {
            buffer.append(timestamp: "2026-10-18T13:00:0\(second)Z", event: "error_cleared", fields: [:])
        }
        XCTAssertEqual(buffer.lines.count, 3)
        XCTAssertTrue(buffer.lines[0].hasPrefix("2026-10-18 13:00:02Z"))
    }

    func testReadsRuntimeLogJSONLines() {
        var buffer = EventLogBuffer()
        buffer.append(jsonLines: """
        {"timestamp":"2026-10-18T13:28:56Z","level":"info","event":"lookup_succeeded","fields":{"provider":"ipWhois","country":"SG"}}
        not json
        {"timestamp":"2026-10-18T13:28:57Z","level":"info","event":"provider_health_changed","fields":{}}
        {"timestamp":"2026-10-18T13:28:58Z","level":"info","event":"refresh_requested","fields":{"trigger":"system_wake","provider":"ipapiCo"}}
        """)
        XCTAssertEqual(buffer.lines, [
            "2026-10-18 13:28:56Z  Lookup OK · IPWHOIS.io · SG",
            "2026-10-18 13:28:58Z  Check · Mac woke · ipapi.co"
        ])
    }
}
