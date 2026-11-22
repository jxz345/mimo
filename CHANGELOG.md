# Mimo changelog

## 2.0 (build 6) — 2026-11-22

- Let the profile own steady Rule/Global routing, bypasses, DNS and IPv6 rejection. Use PF only for startup, verification and detected transitions/failures; Direct releases Mimo packet filtering. Restore older macOS IPv6 changes rather than disabling IPv6 system-wide.
- Label every generated packet rule with `mimo:` and its purpose; document anchor ownership and manual inspection. Keep a persistent boot barrier until Stop/uninstall.
- Publish immutable build tags and include the build in Homebrew's version so same-version upgrades are detected.

- Use one verified full network-release routine for uninstall and Dashboard Stop, including old/nested PF filter/NAT rules and tables, saved IPv6 restoration, removal of Mimo DNS and a system cache refresh. Explicitly verify native Tailnet route/MagicDNS when connected; report failures and retain recovery data.
- Continue anonymous exit IP monitoring in the active account's open GUI after Stop, with services removed. Pause it on account switch/quit and end it before activation.
- Make Stop/Activate visually actionable and permit cleanup when shared-service communication is lost. Add readable cleanup stages and local monitoring lifecycle to Event Log.
- Remove version 1 release narratives from README; archive legacy manual recovery separately.

## 2.0 (build 5) — 2026-11-22

- Build version 2 on the version 1 build 4 UI: restore the top-toolbar mode picker, in-card route summary, existing service buttons, native Settings forms and footer. Add Bypass and Stop/Activate within that layout. Proxy and Bypass use distinct icons. Use “Stop the engine and release network controls.” on one line at normal width.
- Add shared, editable Rule-only bypass blocks with exact/suffix domains, enable switches, Apply/Cancel drafts and revision conflict handling. Preserve existing defaults and managed Tailnet/LAN rules; Global ignores website bypass blocks.
- Extend **Stop engine and use Direct** to full installer deactivation: remove all Mimo services/login items and restore network controls, retaining app/settings. Confirmed completion changes the same button to **Activate Mimo**, which restores all daemons in Direct and reuses installation conflict confirmation. Installed VM checks cover all three modes, app deletion, other-engine coexistence, explicit conflict consent and reboot. Reinstall preserves inactive state; activation failures restore inactive networking before returning an error.
- Persist released intent through service restart and guard repair. Check competing engines and TCP/UDP listener conflicts before explicit startup; preserve released networking when a conflict is found. Use control protocol 6 so older clients receive an explicit compatibility error.
- Document manual version 1 recovery and provide an inspection-first cleanup script that archives owned components, with confirmed removal and scoped network restoration.
- Validate real HTTPS routing after bypass Apply/disable, unchanged Global routing and retained MagicDNS. Release validation is recorded in `Tests/ReleaseEvidence/mimo-build-5-v2.json`; earlier engine-only evidence remains separate.

## 1.0 (build 4) — 2026-11-22

- Keep login-item status/registration calls off the GUI thread, cache their results and serialize/coalesce requests. Pause inactive-account GUI subscriptions and reconnect immediately on return; suppress inactive-window repositioning and deferred activation.
- Isolate optional WindowServer display queries from kernel session sampling, with one outstanding query, a stable-console delay and rejection of old-session replies. Lock/account observation and firewall protection remain in the background supervisor.
- Distinguish GUI communication loss from service failure or overdue inspections. Show the last reply age and Reconnect; preserve independently received supervisor health without treating a running process as a working core connection. Read-only probes use 3 seconds instead of the 75-second service-operation deadline.
- The reported physical login-screen freeze is not reproduced; this release hardens identified blocking paths and does not claim a proven root cause.

- Ask before stopping a competing Clash/mihomo engine during service installation. Identify matching launchd jobs, disable and unload only approved jobs to prevent KeepAlive and login/reboot restart, and verify exit before continuing. Cancel or unavailable confirmation leaves those engines running; changed/restarted processes require a new attempt.
- Allow a downloaded installer to repair an existing sealed app with `install --app`, without building or replacing the app. Finish signature/checksum/staging checks before requesting the interruption; retain the other proxy's app, settings and startup files. Report stopped competitors if later installation fails.
- Treat declining the stop prompt as cancellation in the GUI and allow the package deadline to include confirmation time.

## 1.0 (build 3) — 2026-11-21

- Permit root TCP DNS to Quad100 through the verified native Tailscale policy before the generic DNS group block. Both the root-only and integrated-candidate tests restored full-name answers on the affected physical Mac, including repeated fresh queries and macOS resolution; clearing the native policy revokes the exception. Ordinary direct DNS remains blocked.
- Provide a temporary test of the integrated correction through the live native anchor, with repeated uncached full-name queries and TCP/UDP listener checks. Automatic restoration preserves failure exit status; no owner-independent fallback or app build is required.
- Recognize configd’s native DNS interface-index metadata on Tailnet reconnect only when it matches the current native interface. Preserve verification for wrong/unknown indices, changed DNS servers and unknown fields.
- Use `Healthy(n secs)` consistently for all six dashboard monitoring rows, based on retained inspection timestamps. Show stale or unavailable reports without resetting their age on redraw; retain stopped and failure states.
- Add a bounded, read-only service snapshot script for conflicting dashboard, launchd and controller observations.

- Carry the native search domains in the protected resolver. It becomes the system default in Rule/Global, which previously left no search list, so short names such as `peer` no longer expanded to `peer.<tailnet>.ts.net`. Direct was unaffected. All queries still go only to Mimo's listener.

## 1.0 — DNS recovery and provider-port fallback

- Read the live tailnet provider from a root-owned file, independent of HTTP ports and obsolete pollers. Its diagnostic HTTP listener falls back to a kernel-assigned loopback port if 18766 is occupied; display the actual port. Missing data starts with Reject.
- Recheck the protected DNS entry during active status/heartbeat handling, block on loss or change, and report the cause independently of the full background audit.
- Move the refresh interval and Configure link beside the IP-check details.

## 1.0 — transition classification and calmer dashboard

- Resolve early network callbacks before approving a protected cycle. Owned tunnel setup no longer leaves a false follow-up flag; unresolved or external changes still keep traffic blocked.
- Keep Allowed status/icon stable during successful background audits. Failed audits still block and report their cause.
- Move the uninstall command/deletion note into a separate block below proxy details. Confirm all copy actions with a temporary checkmark or “Copied” label.

## 1.0 — AirPort timestamp correction and proxy card spacing

- Ignore `AutoJoinTimestamp` changes before early PF revocation. The prior filter missed this field, so periodic timestamp updates still caused Rule/Global block/open cycles. Preserve power, association, unknown-field and non-AirPort protection.
- Move the routing summary and LAN/Tailscale note from the dashboard’s bottom row into the space below the proxy details. Keep uninstall instructions together in the footer.
- Show the installed app’s version and build number beside Event Log in the bottom bar.

## 1.0 — AirPort notification filtering and compact dashboard

- Compare AirPort values before the supervisor's early PF callback. Ignore unchanged/known scan and radio telemetry; retain Wi-Fi power/association, unknown changes and read-failure protection. Non-AirPort notifications keep their existing behavior.
- Record ignored telemetry and meaningful Wi-Fi field changes without SSID/BSSID values.
- Put Dashboard/Settings, Refresh now and Direct/Rule/Global in one top row. Put the clean-uninstall command and shorter app-deletion note in one bottom row.

## 1.0 — copyable event diagnostics

- Use one native, selectable Event Log document with multiline copying, ⌘A/⌘C, stable selection during updates, and Pause/Resume.
- Add Copy Diagnostics (⌥⌘C) for bounded, already-redacted GUI/core/supervisor records, preserving trigger and audit fields. Copy All (⇧⌘C) keeps readable events.
- Record selected mode, effective mode, routing phase and reason with GUI status changes. Firewall and event-handling behavior is unchanged; GUI-only records do not establish a repeated Rule cycle's cause.

## 1.0 — country metadata and event handling

- Serialize protected cycles and queue human controls. Hold external events for one fresh check without opening stale traffic; ignore ordinary system/network events in Direct.
- Pause failed lookup providers for eight hours, rotate to the next eligible provider, and show reason/retry time in Monitoring.

- Keep a valid exit IP when its country is unknown; show a globe and a white Allowed shield. Country-only changes never start secondary confirmation or retries. IP allowlist and external-event protection remain unchanged.
- Include supervisor triggers and audit failure reasons in the Event Log; show interface/route details and wrap longer messages.

## 1.0 — 2026-11-20

- Publish the accepted Apple silicon build through `brew install --cask jxz345/tap/mimo`, with pinned mihomo 1.19.34 and Mimo.app. Put complete Homebrew installation and preview-reinstallation steps at the top of README.
- Cancel obsolete IP lookups, serialize one pending follow-up and join tailnet-provider changes without an extra standalone close. Final focused VM checks pass; warm route opening took 3.708 seconds and tailnet on/off took 6.547/8.252 seconds.

- Recover automatically from native Tailscale firewall-update failures only after a successful native update and fresh protected verification; keep the final opening blocked while native-rule health is failed.

- Generate and syntax-check immutable restricted PF rules on a background worker, then install them immediately after blocking is confirmed. Keep the private-probe barrier closed through profile preparation and connection cleanup; release it as the last privileged preparation action before the IP request. Record generation, validation, installation and permission spans separately.

- Run connection cleanup, profile reuse checks and runtime inspection alongside PF closure and probe-policy preparation. Use two explicit joins before IP probing and final opening; fence cancelled controller work, retain the atomic final check, and skip unchanged DNS mutation bookkeeping.

- Retry protected verification after controller startup/cleanup failure once the infrastructure check is healthy; keep traffic blocked and require a fresh IP approval.

- Run PF closure concurrently with local preparation and installation inspection; share the event/prepare closure and fence cancellation under the firewall lock. Reuse unchanged profiles in the same engine process while still requiring fresh runtime and exit-IP checks. Manual Reload and engine changes force loading. Record monotonic spans to show concurrency.

- Load changed protected profiles once behind PF and reuse unchanged profiles in the same engine process; overlap exit-IP verification with mandatory installation/profile/TUN/DNS checks. Use a small blocking barrier before one probe-policy installation, retain old-flow cleanup, fence late results, and show approved-IP/readiness progress without opening early. Keep watchdog inspection off the supervisor's main executor. Exact-build VM qualification is tracked separately.

- Reduce redundant protected recheck work: prepare streams confirmed blocking, supervisor events avoid a second core close request, and unchanged protected DNS is retained. Add per-stage timing while keeping fresh verification and stale-approval protection.

- Detect lock/unlock, login/logout, user switching and display sleep/wake in the root supervisor, independently of the GUI. Revoke old protected approvals and close PF before rechecking; keep Direct open. Re-establish the barrier on wake/cancelled sleep and preserve the sleep hold across session events.

- Enable Rule/Global through real profile validation, private exit-IP verification and the saved allowlist. Empty or mismatched allowlists remain blocked.
- Load an independent saved PF boot policy and monitor PF, launchd registrations and IPv6 policy; show their health and last-check timers on the dashboard.
- Permit installed-app controls without administrator prompts after setup, using the installer-pinned app signature. Keep root-only traffic approval separate.
- Require confirmed PF closure before protected service actions, show progress immediately, and reject stale Allowed displays. Direct selection releases IPv4 before TUN/DNS teardown; normal Direct events check the IP without blocking or allowlist approval.
- Use proxied encrypted public DNS in both Rule and Global, while retaining private MagicDNS and explicit encrypted bootstrap.
- Follow native Tailscale connectivity automatically, repair relay recovery, and report a stopped provider as a failure only when the tailnet is expected.
- Use Dashboard/Settings tabs, stable layout, consistent service typography, compact Monitoring controls, menu shortcuts and the Finder app icon in the Dock. Retain the colored live menu indicators and triggering blocked IP.
- Record exact-build installed tests in [VM acceptance evidence](Tests/ReleaseEvidence/MIMO_NORMAL_RELEASE_ACCEPTANCE.md). Early traffic before the independent PF loader, actual macOS sleep/wake, peer UDP and simultaneous logged-in GUI sessions are not qualified. The user confirms physical mode/Quit shortcuts and sequential account sign-in checks. The final release replaces the earlier 1.0 preview.

## 1.0 — 2026-11-18 (preview)

First Mimo release, with a new source repository and release history.

- Apple silicon and IPv4-only networking; IPv6 stays disabled while installed and its saved service flags are restored on uninstall.
- Compact native dashboard, Settings, menu-bar routing state, login-item control, Refresh now and background-service lifecycle controls.
- Pinned mihomo 1.19.34 dependency, independent supervisor, private profile delivery, exit-IP validation and fail-closed preparation.
- Separate `jxz345/tap/mimo` cask with checksum/signature checks, runtime cleanup and retained settings/Keychain credentials.
- **Preview:** Direct works; Rule/Global activation remains blocked pending protected-routing qualification. Intermittent relay, real sleep/wake and live UI acceptance remain outstanding.

The earlier Exit IP Monitor history remains in https://github.com/jxz345/exit-ip-widget.
