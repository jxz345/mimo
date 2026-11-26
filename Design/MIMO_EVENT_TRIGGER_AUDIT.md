# Network-check trigger audit — 26 November 2026

This audit joins GUI, core and supervisor records from mimo-vm. A network check
means a new `lookup_started`/verification attempt, not a GUI status notification,
an infrastructure inspection, or a PF command. User-triggered changes to active
routing **must still request fresh verification**. Opening a page is not such a
change. Rule and Global use one required IPv4 observation in both traffic modes.

## Captured interval and actual checks

The installed candidate trace covers **04:21:26.667–05:23:26.252 UTC**: 3,384
records, including qualification actions from the earlier recovery campaign.
All 37 lookup starts have matching finishes:

| Trigger | Count | Cause |
| --- | ---: | --- |
| `settings_changed` | 19 | 19 routing edits with `reload=true`; seven additional same-value `reload=false` submissions caused no lookup |
| `network_configuration` | 7 | Seven deliberately injected protected supervisor restarts, each with one `infrastructure_recovered` request |
| `manual` | 7 | Explicit qualification retries |
| `recheck` | 2 | Eligible-provider fallback after an ipapi.co rate-limit response, at 04:25 and 05:19 |
| `startup` | 1 | Core installation/startup; preparation failed before an HTTP request, not a duplicate lookup |
| `periodic` | 1 | Hourly timer at 05:21:26, one hour after core startup |

There were no external network-event dispatches, deferred-cycle events, or
navigation-triggered lookups in this interval. There were 15 completed GUI
navigation requests, 79 raw network-configuration notifications, 18 explicitly
ignored owned-cycle records, 79 blocked-native-transport updates, 74 provider
health publications, 306 access-presentation updates and 456 widget reload
notifications. These are not additional checks. Two GUI processes explain paired
presentation records; core still owns one verification operation.

The wider interval contains the already-documented startup/intentional-restart
failures; it is not an assertion that every record is healthy. The separate
[navigation/recovery report](MIMO_NAVIGATION_RESPONSIVENESS.md) bounds those
failures and records the subsequent stable windows.

## User's family switches

| UTC | Action/outcome | Checks |
| --- | --- | ---: |
| 05:18:51 | Global → Dual-stack, revision 1653 | One IPv4 lookup; successful but rejected by the empty allowlist |
| 05:19:00 | Global → IPv4, revision 1654 | One IPv4 lookup; successful but rejected |
| 05:19:07 | Global → Dual-stack, revision 1655 | ipapi.co rate-limited; one follow-up through IPWHOIS succeeded and was rejected |
| 05:21:26 | Fixed hourly timer | One scheduled IPv4 lookup |

The family edits themselves did not produce duplicate HTTP requests. The extra
provider attempt at 05:19:13 is explained by `provider_rotated_after_failure`;
the failed provider was paused. It must not be suppressed as if it were an owned
network notification. The later periodic check was independent of the switches.
The current timer is fixed from scheduling/startup, not one hour after the latest
successful check. Thus it can fire shortly after a user-triggered check. This is
documented current behavior; this change does not silently redefine that cadence.

There **was redundant closure work**: every family edit sent two standalone
`close` commands before `prepare`. Pre-commit closure was immediately repeated
after persistence. The recorded three edits produced seven closes (six for edits
plus one for the provider failure), rather than the required four. The new event
audit fails this trace specifically on `one_precommit_close_per_change`; its
lookup accounting passes. See [before evidence](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/before.json).

## Events that must not independently request verification

| Event class | Examples in logs/code | Required handling / exception |
| --- | --- | --- |
| GUI navigation and presentation | `mimo_navigation_*`, `dashboard_presented`, `dashboard_front_requested`, `mimo_access_presentation_changed` | Read/render state. Never call refresh merely because a page appears. |
| GUI lifecycle and IPC status | `daemon_client_*`, app focus, state request/subscription, reconnect, another account opening GUI | Managed services: reconnect/display uncertainty only. Actual privileged restart requires recovery. Starting an anonymous monitor after full deactivation is a separate ownership state. |
| Widgets, menu bar, copying and logs | `widget_reload_requested`, menu open, Event Log/copy, display timer | Display only; an explicit Refresh or routing action submitted from that surface still performs its command. |
| Routine successful infrastructure checks | Health timestamps, `mimo_infrastructure_check_deferred`, successful heartbeat/audit | Inspect/publish health; do not manufacture `infrastructure_recovered` every time. A newly detected fault followed by recovery justifies one new attempt. |
| Owned route/TUN/DNS notifications | `network_configuration_changed`, `mimo_cycle_owned_event_ignored`, unchanged global resolver publication | Positively classify owned/unchanged values. Never suppress unrelated or unknown external changes by event name alone. |
| Telemetry without a network change | `network_airport_telemetry_ignored`, `network_location_metadata_ignored`, `network_path_unchanged`, initial path baseline | Ignore known Busy/AutoJoinTimestamp/bookkeeping-only changes; initial observer baselines do not duplicate startup checks. Real link, address, resolver or route changes remain triggers. |
| Native transport inventory maintenance | `mimo_tailnet_change_scope`, `mimo_blocked_native_transport_updated` | Update/inspect native transport permissions, not public exit verification. Classified private configuration notifications currently request a conservative protected cycle; proven private route-only changes do not. See the remaining source-audit gap below. |
| Verification progress and completion | Prepare/readiness/gate status, `lookup_succeeded`, `lookup_finished`, approval/publication | Complete the current attempt. Do not use its own outputs as a new trigger. A distinct deferred external change can require one follow-up. |
| Rejected exit | `mimo_exit_ip_rejected`, allowlist warning presented/cleared, indicator publication | A successful lookup rejected by policy is settled. Keep its IP visible and provider healthy. No automatic retry until a real trigger, explicit retry or admitted periodic check. |
| Provider status and metadata | `provider_health_changed`, error/pause display, country metadata change | Publish without an extra verification. Scheduler-authorized failover/retry is distinct and must name its cause. Failed/cooling status must not each enqueue another close. |
| Non-routing settings/drafts | Inactive proxy edits, appearance/login preferences, diagnostics, refresh interval; `reload=false` | Save/display only. Changing an interval reschedules the timer but should not cause an immediate lookup. Editing the active proxy/provider/allowlist is different. Current `.configure` handling has an in-flight exception noted below. |
| Inapplicable bypass edits | Bypass Apply in Global or Direct | Save for future Rule use. Apply in active Rule requires fresh profile verification. |
| Future family choice in Direct | IPv4/Dual-stack selection while Direct | Save only; Direct has no managed traffic-family policy to activate. A subsequent user switch to Rule/Global verifies it. |
| Same edit's repeated closure | Pre-commit close followed by post-commit close | Reuse only the acknowledged pre-commit barrier from that edit and unchanged epochs; retain fresh preparation/lookup. |

Not every row was exercised in this captured hour. Counts above establish what
occurred; the remaining rows are the event contract checked against current
source. Genuine power/session transitions, explicit service restart/reload,
active routing/provider/allowlist changes, Refresh/Retry/Test, relevant external
network changes and admitted periodic work remain valid triggers. Merely showing
those events in the GUI must never create a second trigger.

## Remaining source-audit gaps and startup failure

These are separate from the observed duplicate-close regression; do not present
them as reproduced causes of the user's three switches:

1. **Non-routing settings during verification.** `DaemonService`'s `.configure`
   path sets `affectsRouting` whenever the current phase is `checking` or
   `validating`, even when `MachineSettings.affectsVerification` is false.
   A diagnostics/interval-only save in that window can cancel the attempt,
   close again and request `settings_changed`. The intended behavior is to
   preserve applicable verification while saving unrelated settings. Reproduce
   this race before changing revision/freshness rules; settled same-value edits
   in this trace do not exercise it.
2. **Private configuration notifications without a value delta.**
   `MimoTailnetNetworkChanges.classify` validates known service/interface values
   but does not require inequality for those keys. Every nonempty `privateKeys`
   set calls `tailnetChanged`; `MimoSupervisor` then forces profile reload and
   `native_dns_changed` for an existing protected profile. Unchanged private
   notifications should be ignored. Actual changed DNS scopes must still apply
   safely; a full cycle remains necessary unless independence from public
   routing/capture is proven. There is no such event in the captured user window.
3. **Protected startup preparation failure.** The previous candidate failed
   `prepare` at 04:21:47. The newly installed candidate repeats it: core started
   at 05:27:30.050, supervisor reported ready at 05:27:42.187, and the initial
   `prepare` failed after 20,521 ms at 05:27:50.573 before provider HTTP. Twelve
   heartbeat failures preceded readiness and used misleading shared-settings
   conflict text. There was no repeating lookup loop; one native GUI Refresh
   recovered to the expected ready-but-rejected state. This is an unresolved
   startup/recovery diagnostic issue, not a clean installation qualification.

The fixed hourly timer's closely spaced check is explained current behavior,
not an unexplained event. A future cadence change could schedule from the latest
completed check, but no such change is included in this audit/correction.

## Correction and validation

`MimoCoordinator` now remembers a confirmed pre-commit closure only within its
configuration-edit transaction. Commit reuses it if network/transition epochs and
blocked state still match. Failure, supersession, an intervening network event,
transaction completion or a standalone update cannot reuse it. Preparation still
confirms blocking and every effective family edit still obtains a fresh IPv4
result. Direct continues its separate restore path.

The source regression failed before production edits. Eight combinations cover
Rule/Global, both family directions and approved/rejected outcomes; four negative
cases cover failed closure, network invalidation, finished edit and standalone
update. All pass, alongside 226 shared tests and the service suite. The Release
package builds locally. Nothing was published.

### Installed native qualification

The local **3.0 / unpublished build 11** candidate was installed in mimo-vm:

| Artifact | SHA256 |
| --- | --- |
| Core, verified in the installed location | `0583d13ef48e9ab7443d75a52871e95323ef581316b08a2db611cc785e88c05b` |
| GUI | `fdcc13b8eb057ccd9fd4492d9b7db082c66a1d1c67338790ac66031bad22ff30` |
| Package | `d2ba461ecccef2e7685dd079e3cb0a8b9ab20a9c502fd6fabe5275bc5d799d36` |

After the explicitly recorded startup retry, actual native Dashboard clicks
selected Dual → IPv4 → Dual with an empty allowlist in each protected mode:

| Mode / UTC interval | Lookups | Standalone closes / prepare / approve | Settled observation | Result |
| --- | ---: | --- | ---: | --- |
| Global, 05:32:22–05:34:12 | 2 | 2 / 2 / 2 | 57.627 s | PASS |
| Rule, 05:34:48–05:36:38 | 2 | 2 / 2 / 2 | 41.683 s | PASS |

Every edit caused one fresh IPv4 check and one recorded reuse of the pre-commit
barrier. Both windows had no provider failure/fallback, unexplained check,
network dispatch, stale command, warning or recovery loop. Rejected addresses
remained visible, provider status returned Ready, health timestamps advanced,
and settings/core identity were unchanged. Mode changes outside the windows
were explicit setup/restoration actions. The original Global/Dual configuration
was restored after the Rule window.

Sanitized records: [Global](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/global-after.json),
[Rule](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/rule-after.json).
The observer is [v3_family_switch_event_test.py](../Tests/MihomoRuntimeTests/v3_family_switch_event_test.py).
These first installed windows qualify rejected-state switching. The approved-state
follow-up below uses the same installed candidate. Neither campaign closes the
separate startup failure or the two unexercised source-audit gaps.

### Approved-state follow-up requested by the user

Added the freshly observed proxy exit IPv4 to the system-wide allowlist through
core's normal revision-checked configuration command. The resulting new lookup
approved the exit and reopened traffic. No direct store modification, process
restart or replacement build was used. The address remains allowed as requested;
addresses and credentials are excluded from the saved evidence.

| Native test / UTC interval | Expected work | Actual result |
| --- | --- | --- |
| Global Dual → IPv4 → Dual, 05:40:12–05:42:02 | Two fresh checks; one standalone close/prepare/approve per edit | PASS: two checks, two openings, no provider fallback; 63.536 s settled |
| Rule Dual → IPv4 → Dual, 05:44:13–05:46:03 | Same | PASS: two checks, two openings, no provider fallback; 42.997 s settled |
| Global Dashboard/all six Settings sections, 05:42:05–05:43:35 | Display only; health inspection continues | PASS: eight completed navigation actions; zero lookup, gate command, settings write, warning or recovery event |
| Rule Dashboard/all six Settings sections, 05:47:56–05:49:27 | Same | PASS: nine completed navigation actions; zero lookup, gate command, settings write, warning or recovery event |

Both family windows retained the expected approved outcome, original mode/family,
core identity and settings; infrastructure health timestamps advanced. Both
navigation windows lasted 90 seconds and retained the same observed IP and
healthy monitor. Maximum selection-to-AppKit-window-update measurements were
77 ms in Global and 40 ms in Rule. These measurements do not establish the
latency of Screen Sharing or the final compositor presentation.

The first Rule navigation window (05:45:34–05:47:05) ended before the operator
completed the page sequence. Its assertions correctly failed missing Dashboard
and Settings-section coverage, while all event/stability assertions passed. It
is retained as [incomplete evidence](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/navigation-rule-approved-incomplete.json),
not counted as a successful navigation test. The complete repeat above passed.

Sanitized evidence: [Global family](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/global-approved.json),
[Rule family](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/rule-approved.json),
[Global navigation](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/navigation-global-approved.json),
[Rule navigation](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/navigation-rule-approved.json).
Both installed observers now accept `--verdict approved` while retaining their
default rejected-state regressions.

The [whole approved-campaign reconciliation](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/approved-campaign.json)
covers **05:39:00–05:50:43 UTC, 679 records**. It accounts for seven completed
settings-triggered lookups: one allowlist edit, four family changes and two
explicit mode changes (Global → Rule and restoration to Global). There are
exactly seven standalone closes, seven preparations, seven approvals, seven
traffic openings and seven confirmed-barrier reuse records. All 18 navigation
requests completed, including the one in the incomplete window. The 112 widget
reloads, 80 access-display updates and 14 provider-health publications generated
no extra lookup. There is no external network dispatch, warning/error, failed
command, stale command or exit rejection in this entire interval.

The final **Global/Dual-stack** restoration is approved with the one requested
allowlist entry retained. A separate [35-second final stability observation](../Tests/MihomoRuntimeTests/Evidence/v3/family-switch/approved-restored-stability.json)
has no new lookup, control event or warning; health checks continue. These results
qualify this event campaign on the existing local candidate, not startup, every
physical-network scenario, or a new published build.
