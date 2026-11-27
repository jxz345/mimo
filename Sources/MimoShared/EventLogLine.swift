import Foundation

/// Turns runtime-log records into the Event Log window's lines: one concise line per important event,
/// in UTC ("2026-10-18 13:28:56Z  Lookup OK · IPWHOIS.io · SG"). Routine records (health bookkeeping,
/// unchanged network paths, widget reloads, ...) return nil and are not shown. A new trigger or event
/// that matters to people needs a case here.
public enum EventLogLine {
    public static let maximumMessageLength = 300

    public static func format(timestamp: String, event: String, fields: [String: String]) -> String? {
        guard let message = message(event: event, fields: fields) else { return nil }
        let time = timestamp.count == 24 && timestamp.hasSuffix("Z")
            ? timestamp.replacingOccurrences(of: "T", with: " ") : stamp(timestamp)
        var context: [String] = []
        if let role = fields["processRole"] {
            let sequence = fields["recordSequence"].flatMap(UInt64.init).map { String(format: "%08llu", $0) } ?? "?"
            context.append("\(role)#\(sequence)")
        }
        if let lookup = fields["lookup"] { context.append("check \(lookup.prefix(8))") }
        if let attempt = fields["attempt"] { context.append("attempt \(attempt.prefix(8))") }
        if let sequence = fields["sequence"] { context.append("cmd \(sequence)") }
        let prefix = context.isEmpty ? "" : "[\(context.joined(separator: " · "))] "
        return "\(time)  \(truncated(prefix + message))"
    }

    /// The text after the time stamp, or nil for routine records.
    public static func message(event: String, fields: [String: String]) -> String? {
        let provider = providerName(fields["provider"])
        switch event {
        case "mimo_runtime_command_failed": return "System command failed · \(fields["program"] ?? "unknown") \(fields["operation"] ?? "") · status \(fields["status"] ?? "?") · \(fields["durationMS"] ?? "?") ms"
        case "mimo_infrastructure_started": return "Supervisor infrastructure monitor started · checks every 10 seconds"
        case "mimo_infrastructure_stopped": return "Supervisor infrastructure monitor stopped"
        case "mimo_infrastructure_check_started": return "Inspecting firewall and startup services"
        case "mimo_infrastructure_check_finished":
            return "Infrastructure inspection · \(fields["outcome"] ?? "finished") · \(fields["duration_ms"] ?? "—") ms"
        case "mimo_infrastructure_check_deferred":
            return "Infrastructure inspection deferred · \(fields["reason"] ?? "network controls are changing")"
        case "mimo_infrastructure_retry_scheduled":
            return "Infrastructure inspection retry in \(fields["delay_seconds"] ?? "—") seconds"
        case "mimo_infrastructure_reconcile_requested":
            return "Infrastructure inspection requested · \(fields["reason"] ?? "transition finished")"
        case "mimo_infrastructure_check_failed": return "Infrastructure inspection failed · \(detail(fields["detail"]))"
        case "mimo_infrastructure_repaired": return "Infrastructure repair completed"
        case "mimo_engine_health_changed": return "mihomo controller health · \(fields["health"] ?? "unknown")"
        case "mimo_peer_watch_started": return "\(fields["owner"] ?? "Core") watching \(fields["target"] ?? "peer") progress"
        case "mimo_peer_repair_started": return "Recovering \(fields["target"] ?? "peer") · \(fields["reason"] ?? "unresponsive") · attempt \(fields["attempt"] ?? "?")"
        case "mimo_peer_recovery_wait": return "\(fields["target"] ?? "Peer") recovery · \(detail(fields["reason"]))"
        case "mimo_peer_recovered": return "\(fields["target"] ?? "Peer") recovered · progress confirmed"
        case "mimo_supervisor_recovery_requested": return "Core is restoring the missing traffic supervisor"
        case "mimo_supervisor_recovery_failed": return "Supervisor recovery failed · \(detail(fields["reason"]))"
        case "mimo_infrastructure_start_failed": return "Mimo core boot guard failed · \(detail(fields["reason"]))"
        case "mimo_infrastructure_sweep_failed": return "Mimo core infrastructure check failed · \(detail(fields["reason"]))"
        case "mimo_installation":
            let action = fields["operation"] == "activate" ? "Activation" : "Installation"
            let item = detail(fields["item"].flatMap { $0.isEmpty ? nil : $0 })
            switch fields["stage"] {
            case "started": return "\(action) started · restoring all Mimo services"
            case "reactivating": return "Previous Stop overridden · services will resume in Direct"
            case "conflicts": return "\(action) · checking conflicting services and occupied ports"
            case "conflict_detected": return "Conflicting service found" + item + " · PID \(fields["status"] ?? "?")"
            case "conflict_cancelled": return "Conflict replacement cancelled · competitors left running"
            case "conflict_approved": return "Conflict replacement approved"
            case "conflict_disabled": return "Competing startup service disabled" + item
            case "conflict_stop_requested": return "Competing process stop requested" + item
            case "conflicts_cleared": return "Competing services stopped · resources available"
            case "replacing_services": return "\(action) · replacing Mimo engine and daemons"
            case "services_enabled": return "All Mimo services enabled · saved stop preferences cleared"
            case "infrastructure_merged": return "Startup guard and checks merged into existing supervisor · separate boot and infrastructure jobs removed"
            case "starting_services": return "\(action) · starting all Mimo services"
            case "verifying_services": return "\(action) · checking core, engine and infrastructure health"
            case "services_verified": return "All Mimo services passed health verification"
            case "health_failed": return "Installation health check failed" + item
            case "succeeded": return "\(action) completed · all services installed and healthy"
            case "cancelled": return "\(action) cancelled" + item
            case "failed": return "\(action) failed" + item + " · status \(fields["status"] ?? "?")"
            case "rollback_started": return "Restoring previous Mimo installation after failure"
            case "rollback_succeeded": return "Previous Mimo installation restored"
            case "rollback_failed": return "Installation recovery incomplete · recovery files retained"
            default: return nil
            }
        case "mimo_dns_removed_and_drained": return "Mimo DNS override removed · queued queries drained before tunnel teardown"
        case "mimo_direct_network_released": return "Direct restored · Mimo packet rules and tunnel removed"
        case "mimo_direct_tracking_ready": return "Direct restored · tunnel and DNS override removed; incoming TCP tracking ready"
        case "mimo_direct_tracking_updated": return "Direct incoming TCP tracking updated · \(fields["destinations"] ?? "?") local addresses"
        case "mimo_direct_tracking_reconcile_requested": return "Direct local-address check requested · \(fields["source"] ?? "network event")"
        case "mimo_direct_tracking_refresh_failed": return "Direct incoming TCP tracking update failed · native networking remains open"
        case "mimo_native_release_checked": return "Native network release check completed"
        case "mimo_native_release_check_failed": return "Native networking restored · Tailnet DNS check failed"
        case "mimo_deactivation_started": return "Stop engine · full service uninstall started"
        case "mimo_deactivation_succeeded": return "Network controls released · IP monitoring continues in this app"
        case "mimo_deactivation_cancelled": return "Service uninstall cancelled · removal not confirmed"
        case "mimo_deactivation_failed": return "Service uninstall incomplete · retry cleanup before deleting the app"
        case "mimo_cleanup_step":
            guard let message = MimoCleanupEvent.messages[fields["stage"] ?? ""] else { return nil }
            return fields["step"].map { "Cleanup \($0) · " + message } ?? message
        case "mimo_local_monitor_started": return "Exit IP monitoring started in this app · no network controls"
        case "mimo_local_monitor_stopped": return "Exit IP monitoring in this app stopped"
        case "monitor_started": return "Monitoring started"
        case "monitor_stopped": return "Monitoring stopped"
        case "daemon_ready": return "Background service ready"
        case "daemon_stopped": return "Background service stopped"
        case "daemon_client_started": return "Menu-bar app opened"
        case "daemon_client_stopped": return "Menu-bar app quit"
        case "daemon_client_connecting": return "Service communication · connecting"
        case "daemon_client_connected": return "Service communication · connected · \(fields["duration_ms"] ?? "?") ms"
        case "daemon_client_disconnected": return "Service communication · interrupted · \(fields["source"] ?? "unknown source")"
        case "mimo_session_event":
            if fields["source"] == "session_inactive" { return "User session became inactive · GUI updates paused" }
            return "\(fields["source"] == "display_wake" ? "Display woke" : "User session became active") · service connection refreshed"
        case "mimo_access_presentation_changed":
            let mode = fields["selectedMode"].map { " · selected \($0)" } ?? ""
            return "Access display\(mode) · \(fields["validating"] == "true" ? "validating profile" : fields["kind"] ?? "unavailable") · \(fields["blocked"] == "true" ? "traffic blocked" : "see routing state")"
        case "shared_settings_initialized": return "Shared settings imported"
        case "shared_settings_changed": return "Shared settings changed"
        case "shared_credential_changed": return "Shared credential updated"
        case "mimo_proxy_catalog_changed":
            let action = switch fields["operation"] {
            case "saveProxy": "Proxy saved"
            case "removeProxy": "Proxy removed"
            case "selectProxy": "Active proxy changed"
            default: "Routing selection changed"
            }
            return "\(action) · \(fields["count"] ?? "?") saved · \(fields["mode"] ?? "unknown")" +
                (fields["reload"] == "true" ? " · applying routing change" : " · routing unchanged")
        case "manual_refresh_queued": return "Refresh now requested · waiting for a lookup result"
        case "manual_refresh_joined": return "Refresh now joined the current exit-IP check"
        case "manual_refresh_started": return "Refresh now checking the exit IP"
        case "manual_refresh_finished":
            switch fields["outcome"] {
            case "succeeded": return "Refresh now completed · exit IP updated"
            case "blocked": return "Exit IP checked · outbound access remains blocked by Allowed IPs"
            case "deferred": return "Refresh now deferred · no lookup ran; see provider availability"
            case "superseded": return "Refresh now superseded · a newer network configuration is in use"
            case "cancelled": return "Refresh now cancelled · networking or services changed"
            case "internal_failure": return "Refresh request could not finish · no current operation owns it"
            default: return "Refresh now failed · last successful IP retained"
            }
        case "refresh_demand_queued": return "Exit-IP check pending · waiting for the current operation"
        case "refresh_demand_consumed": return "Pending exit-IP check admitted"
        case "refresh_demand_discarded": return "Obsolete pending exit-IP check discarded"
        case "mimo_network_changed": return "Check trigger · \(trigger(fields["source"]))" + detail(fields["detail"]) + " · generation \(fields["generation"] ?? "?")"
        case "mimo_cycle_owned_event_ignored": return "Own tunnel update ignored · \(trigger(fields["source"]))"
        case "network_airport_telemetry_ignored": return nil // Retained in full diagnostics, not the failure timeline.
        case "network_airport_connection_changed": return "Wi-Fi connection changed" + detail(fields["key"]) + detail(fields["fields"])
        case "network_location_metadata_ignored": return "Network preference timestamp ignored" + detail(fields["fields"])
        case "network_location_changed": return "Network location changed" + detail(fields["fields"])
        case "mimo_verification_audit_failed": return "Verification audit failed" + detail(fields["reason"])
        case "mimo_native_transport_failed": return "Tailnet transport failed" + detail(fields["reason"])
        case "mimo_ipv4_policy_failed": return "IPv4 network policy needs repair" + detail(fields["reason"])
        case "mimo_legacy_network_controls_removed": return "Removed older Mimo firewall policies and DNS override; restored saved IPv6 settings"
        case "mimo_transition_firewall_released": return "Verification passed; transition firewall released to profile routing"
        case "mimo_active_firewall_installed": return "Verification passed; active firewall blocks native application fallback"
        case "mimo_native_egress_updated": return "Updated verified native VPN transport permissions"
        case "mimo_blocked_native_transport_updated": return "Outbound blocked · verified native VPN transport retained for incoming connections"
        case "mimo_blocked_native_transport_failed": return "Blocked-mode native VPN transport update failed" + detail(fields["reason"])
        case "mimo_liveness_lost":
            if fields["heartbeatExpired"] == "true" { return "Check trigger · core heartbeat expired" }
            if fields["engineRunning"] == "false" { return "Check trigger · mihomo stopped" }
            return "Check trigger · firewall gate changed to \(fields["gate"] ?? "unknown")"
        case "mimo_gate_closed": return "Traffic gate · \(fields["confirmed"] == "true" ? "blocked" : "unavailable") · \(fields["reason"] ?? "Verification required")"
        case "mimo_direct_restored", "mimo_direct_recovery_saved": return "Direct networking restored"
        case "mimo_traffic_opened": return "Exit approved · \(fields["mode"] ?? "protected")"
        case "mimo_exit_rejected": return "Exit IP rejected · traffic remains blocked"
        case "mimo_exit_ip_rejected": return "Exit IP rejected · outbound access remains blocked" + detail(fields["reason"])
        case "mimo_recovery_verification_consumed":
            return fields["outcome"] == "direct"
                ? "Recovery cleared · returning to Direct"
                : "Recovery check started · a rejected exit will remain blocked without repeated recovery checks"
        case "mimo_observation_started": return "Checking exit IP · traffic remains allowed"
        case "mimo_observation_approved": return "Exit IP approved · traffic remained allowed"
        case "mimo_observation_failed", "mimo_observation_unavailable": return "IP check unavailable · retaining the last approved path"
        case "mimo_policy_revoked": return "Allowed IP policy changed · current exit rejected · outbound access blocked"
        case "periodic_check_scheduled": return "Next periodic IP check · " + (fields["next"] ?? "scheduled")
        case "mimo_private_probe_ready": return "Checking exit IP · application traffic blocked"
        case "mimo_service_changed": return "\(fields["service"] ?? "Service") · \(fields["operation"] ?? "changed")"
        case "mimo_routing_changed": return "Routing changed · \(fields["mode"] ?? "unknown")"
        case "mimo_supervisor_ready": return "Traffic supervisor ready"
        case "mimo_command_rejected":
            return "Routing command rejected · \(fields["command"] ?? "unknown")" + detail(fields["reason"]) +
                " · revision \(fields["revision"] ?? "?") · generation \(fields["generation"] ?? "?")"
        case "mimo_core_command_started": return "Core → supervisor · \(fields["command"] ?? "unknown") · revision \(fields["revision"] ?? "?") · generation \(fields["generation"] ?? "?")"
        case "mimo_supervisor_command_received": return "Supervisor received · \(fields["command"] ?? "unknown")"
        case "mimo_core_command_finished": return "Supervisor replied · \(fields["command"] ?? "unknown") · \(fields["phase"] ?? "unknown") · \(fields["duration_ms"] ?? "?") ms"
        case "mimo_core_command_failed": return "Supervisor command \(fields["outcome"] ?? "failed") · \(fields["command"] ?? "unknown") · \(fields["errorType"] ?? "unknown") · \(fields["duration_ms"] ?? "?") ms"
        case "mimo_required_check_close_skipped": return "No additional close · \(fields["reason"] ?? "unknown")"
        case "mimo_configuration_barrier_reused": return "Configuration saved · existing traffic block retained · \(fields["family"] ?? "unknown")"
        case "mimo_probe_http_started": return "IP request started · \(provider) · \(fields["family"] ?? "?") · \(fields["path"] ?? "unknown path") · gate \(fields["phase"] ?? "unknown")"
        case "mimo_probe_http_finished": return "IP request \(fields["outcome"] ?? "finished") · \(provider) · \(fields["family"] ?? "?") · \(fields["duration_ms"] ?? "?") ms"
        case "mimo_ipv4_allowlist_migrated": return "IPv4-only approval · removed \(fields["removedIPv6Entries"] ?? "0") legacy IPv6 allowlist entries"
        case "daemon_storage_failed": return "Service could not save state"
        case "mimo_log_maintenance":
            return "Log cleanup · \(fields["rotated"] ?? "0") rotated · \(fields["deleted"] ?? "0") deleted · \(fields["truncated"] ?? "0") trimmed · \(fields["droppedRecords"] ?? "0") queued records dropped · \(fields["writeFailures"] ?? "0") writes failed"
        case "mimo_log_maintenance_failed": return "Log cleanup unavailable · check log directory permissions and free disk space"
        case "provider_listener_failed": return "Tailscale provider listener unavailable"
        case "mimo_dns_configuration_lost": return "Protected DNS resolver missing or changed · traffic blocked for recovery"
        case "tailscale_provider_port_conflict": return "Tailscale provider port \(fields["port"] ?? "18766") occupied · selecting a free port"
        case "tailscale_provider_listening": return "Tailscale provider listening · 127.0.0.1:\(fields["port"] ?? "unknown")" + (fields["fallback"] == "true" ? " · fallback port" : "")
        case "tailscale_provider_prepared": return "Provider endpoint checked · \(fields["port"] ?? "unavailable") · runtime uses local file"
        case "mimo_tailnet_configuration_updated": return "Tailnet settings updated in place"
        case "mimo_native_provider_published": return "Native provider updated after firewall · \(fields["state"] ?? "unknown")" + detail(fields["interface"])
        case "mimo_profile_prerequisites_ready": return "Firewall and provider ready · profile preparation" + detail(fields["interface"])
        case "keychain_operation":
            return "Keychain \(fields["operation"] ?? "operation") · \(fields["outcome"] ?? "unknown")"
        case "duplicate_launch_reopened": return "Existing app reopened · duplicate launch prevented"
        case "single_instance_lock_failed": return "App startup blocked · couldn't acquire the instance lock"
        case "refresh_requested":
            return "Check · \(trigger(fields["trigger"])) · \(provider)"
        case "refresh_coalesced_in_flight": return "Check joined/coalesced · \(trigger(fields["trigger"])) · active check \(fields["activeLookup"].map { String($0.prefix(8)) } ?? "?")"
        case "lookup_started": return "Lookup admitted · \(provider) · \(trigger(fields["trigger"]))"
        case "lookup_finished": return "Lookup finished · \(fields["duration_ms"] ?? "?") ms"
        case "lookup_http_request": return "Provider request budget charged · \(provider)"
        case "lookup_http_refused": return "No HTTP request · \(provider) · \(fields["reason"] ?? "restriction")"
        case "refresh_skipped":
            return "Skipped · \(trigger(fields["trigger"])) · \(skipReason(fields["reason"]))"
        case "refresh_event_merged":
            return "Merged · \(trigger(fields["trigger"])) → follow-up at \(time(fields["trailingAt"]))"
        case "refresh_queued":
            return "Queued · \(queueReason(fields["reason"])) · at \(time(fields["notBefore"]))"
        case "refresh_queue_superseded":
            return "Queued check replaced · \(trigger(fields["trigger"]))"
        case "lookup_succeeded":
            return "Lookup OK · \(provider) · \(fields["country"] ?? "?")"
        case "lookup_country_unknown": return "Exit IP received · country unknown · globe shown; no country retry"
        case "location_metadata_changed": return "Country display updated · IP unchanged · no extra check"
        case "mimo_cycle_event_deferred": return "Event held until check finishes · \(trigger(fields["source"]))" + detail(fields["detail"])
        case "mimo_control_queued": return "Control queued until check finishes · \(fields["command"] ?? "command")"
        case "mimo_control_resumed": return "Running queued control · \(fields["command"] ?? "command")"
        case "mimo_control_superseded": return "Pending mode request replaced by a newer request"
        case "mimo_control_cancelled": return "Pending control request cancelled · \(fields["command"] ?? "command")"
        case "lookup_failed":
            return "Lookup failed · \(provider)" + detail(fields["message"])
        case "lookup_cancelled":
            return "Lookup cancelled · \(provider)"
        case "lookup_rate_limited":
            return "Provider paused · \(provider) until \(time(fields["retryNotBefore"]))"
        case "lookup_all_providers_paused":
            return "All providers paused until \(time(fields["resumeAt"]))" + detail(fields["restrictions"])
        case "lookup_daily_budget_exhausted":
            return "Daily budget used · \(provider) · resets \(time(fields["resetAt"]))"
        case "provider_rotated_after_failure":
            return "Next provider after failure · \(providerName(fields["from"])) → \(providerName(fields["to"]))"
        case "provider_failure_paused":
            let duration = fields["seconds"].flatMap(Int.init).map { "\($0 / 60) minutes" } ?? "\(fields["hours"] ?? "8") hours"
            if fields["explicitRetry"] == "true" {
                return "\(provider) automatic checks paused for \(duration) · \(ProviderFailurePolicy.reason(fields["reason"])) · repair the connection, then Retry"
            }
            return "\(provider) paused for \(duration) · \(ProviderFailurePolicy.reason(fields["reason"])) · retry after \(time(fields["resumeAt"]))"
        case "provider_local_retry_requested": return "Explicit retry of local failure · \(provider) · provider limits remain enforced"
        case "confirmation_deferred":
            return "Country change to confirm · \(fields["from"] ?? "?") → \(fields["to"] ?? "?") · asking \(provider)"
        case "confirmation_result":
            let agrees = fields["agrees"] == "true"
            return "\(agrees ? "Country confirmed" : "Country not confirmed") · \(provider) · \(fields["country"] ?? "?")"
        case "confirmation_failed":
            return "Confirmation failed · \(provider)"
        case "country_change_dismissed": return "Country-change notice dismissed"
        case "allowlist_warning_presented":
            return "Exit IP not on allowlist" + detail(fields["ip"])
        case "allowlist_warning_cleared": return "Allowlist warning cleared"
        case "indicator_error_set":
            return "Error shown" + detail(fields["message"])
        case "error_cleared": return "Error cleared"
        case "clash_profile_written": return "Clash Verge profile written"
        case "daemon_install_started": return "Service installation started · awaiting macOS authentication"
        case "daemon_install_succeeded": return "Service installed · background monitoring available"
        case "daemon_install_cancelled": return "Service installation cancelled"
        case "daemon_install_failed": return "Service installation failed"
        case "clash_profile_write_failed":
            return "Clash Verge profile not written" + detail(fields["error"])
        case "clash_profile_copy_written":
            return "Clash Verge profile copy" + detail(fields["name"])
        case "tailscale_provider_changed":
            if fields["served"] == "direct" {
                return "Tailscale provider · Direct \(fields["interface"] ?? "")".trimmingCharacters(in: .whitespaces)
            }
            return "Tailscale provider · Reject (\(fields["reason"] ?? "unknown"))"
        case "route_monitor_unavailable", "network_configuration_monitor_unavailable":
            return "Network change monitor unavailable"
        case "ipinfo_token_removed": return "IPinfo token removed"
        case "login_item_synced":
            if fields["result"] == "failed" {
                return "Launch at login couldn't be restored" + detail(fields["error"])
            }
            switch fields["action"] {
            case "register": return "Launch at login restored"
            case "unregister": return "Launch at login turned off, as chosen"
            default: return nil
            }
        default: return nil
        }
    }

    // MARK: Pieces

    static func messageForBuffer(event: String, fields: [String: String]) -> String? {
        message(event: event, fields: fields).map(truncated)
    }

    static func trigger(_ raw: String?) -> String {
        switch raw {
        case "startup": "service start"
        case "manual": "Refresh now"
        case "periodic": "timer"
        case "network_path": "network path changed"
        case "network_configuration": "network settings changed"
        case "route_change": "route changed"
        case "system_wake": "Mac woke"
        case "screens_wake": "screen woke"
        case "session_active": "session active"
        case "app_active": "app activated"
        case "queued": "queued check"
        case "trailing": "follow-up after events"
        case "retry": "retry"
        case "recheck": "recheck"
        case "provider_changed": "provider changed"
        case "settings_changed": "settings changed"
        case "infrastructure_recovered": "retry after PF/launchd or verification recovery"
        case "native_recovered": "retry after tailnet transport recovery"
        case "deferred_events": "one follow-up for events received during verification"
        case let other?: other.replacingOccurrences(of: "_", with: " ")
        case nil: "?"
        }
    }

    static func skipReason(_ raw: String?) -> String {
        switch raw {
        case "fresh": "result under 2 min old"
        case "event_window": "absorbed by the check just run"
        case "burst_budget": "burst budget empty"
        case "token_unavailable": "import or save the shared IPinfo token in Settings"
        case let other?: other.replacingOccurrences(of: "_", with: " ")
        case nil: "?"
        }
    }

    static func queueReason(_ raw: String?) -> String {
        switch raw {
        case "provider_gap": "provider gap"
        case "burst_budget": "burst budget"
        case let other?: other.replacingOccurrences(of: "_", with: " ")
        case nil: "?"
        }
    }

    static func providerName(_ raw: String?) -> String {
        guard let raw else { return "?" }
        return ProviderID(rawValue: raw)?.displayName ?? raw
    }

    static func detail(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        return " · " + value.replacingOccurrences(of: "\n", with: " ")
    }

    static func truncated(_ message: String) -> String {
        message.count <= maximumMessageLength ? message : String(message.prefix(maximumMessageLength - 1)) + "…"
    }

    // MARK: Time (always UTC)

    private static func parse(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)
    }

    private static func utc(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter
    }

    /// "2026-10-18 13:28:56Z" for a record's timestamp.
    static func stamp(_ iso: String) -> String {
        guard let date = parse(iso) else { return iso }
        return utc("yyyy-MM-dd HH:mm:ss'Z'").string(from: date)
    }

    /// "13:28:56Z" for a time inside a message.
    static func time(_ iso: String?) -> String {
        guard let date = parse(iso) else { return "?" }
        return utc("HH:mm:ss'Z'").string(from: date)
    }
}

/// The Event Log window's lines, oldest first, at most `limit`. A Tailscale provider line identical to
/// the previous Tailscale line is dropped, so repeated readings (also across launches) never repeat.
public struct EventLogBuffer: Sendable {
    public let limit: Int
    public private(set) var lines: [String] = []
    private var lastTailscaleMessage: String?

    public init(limit: Int = 500) {
        self.limit = limit
    }

    /// Adds a runtime-log record; returns whether it produced a line.
    @discardableResult
    public mutating func append(timestamp: String, event: String, fields: [String: String]) -> Bool {
        guard let message = EventLogLine.messageForBuffer(event: event, fields: fields) else { return false }
        if event == "tailscale_provider_changed" {
            guard message != lastTailscaleMessage else { return false }
            lastTailscaleMessage = message
        }
        lines.append("\(EventLogLine.stamp(timestamp))  \(message)")
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
        return true
    }

    /// Adds every record of a runtime log file (JSON lines), skipping lines that don't parse.
    public mutating func append(jsonLines text: String) {
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = record["timestamp"] as? String,
                  let event = record["event"] as? String else { continue }
            append(timestamp: timestamp, event: event, fields: record["fields"] as? [String: String] ?? [:])
        }
    }
}
