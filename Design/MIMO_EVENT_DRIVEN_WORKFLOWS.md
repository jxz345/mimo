# Mimo event-driven workflows

Current v3 implementation, updated 2026-11-26. Qualification is tracked separately
in [MIMO_3_0_IMPLEMENTATION.md](MIMO_3_0_IMPLEMENTATION.md); this document is not a
claim that every physical scenario has passed. The v3 plan contains its own
adapted workflow specification and does not depend on historical versions of
this file.

## Ownership

| Owner | Responsibility |
| --- | --- |
| `DaemonService` / `MonitoringEngine` | Machine settings/revisions, proxy catalog, local credentials, shared request scheduling/budget, subscriptions and diagnostics. |
| `MimoCoordinator` | Current verification request, cancellation, fresh IPv4 approval observations and display-only last-known history, supervisor communication and client-visible routing state. |
| Supervisor | Profile preparation/delivery, system DNS, PF, readiness, service lifecycle, network/power/session events and recovery. |
| Independent guard | Boot closure and periodic PF/launchd inspection, even if a main service is absent. |
| Bundled engine | TUN capture, strict destination-family policy, silent public echo suppression, DNS policy and proxy transport. |
| GUI / widgets | Display shared results and submit explicit actions. Released GUI monitoring is anonymous and owns no network controls. |

There is no native utun provider, provider file/port, refresh timer, dynamic
interface binding. Old provider paths/names remain only in migration and cleanup.
Native VPN transport is now a bounded signed-process exception in the active PF
policy, collected by core's existing audit. Multiple GUI sessions do not duplicate supervision.

### Configuration changes and non-triggers

An effective family edit in Rule or Global always requests fresh IPv4 verification.
Core closes before persistence and can reuse that acknowledged block on commit
only while the same edit is in flight, the state is still blocked, and network and
transition generations have not changed. Failure, supersession, an intervening
event or the end of the edit invalidates reuse. `prepare` still confirms its own
protection before probing. `mimo_configuration_barrier_reused` explains the
omitted duplicate standalone close; it never means that verification was skipped.
Direct family preferences remain save-only, and selecting Direct still restores
native networking through its separate cancellation/cleanup path.

Read-only navigation, GUI reconnect, widgets, health publication, known telemetry,
owned mutations and settled allowlist rejection do not independently request a
lookup. Relevant external changes, active routing edits, explicit retry, genuine
infrastructure recovery and admitted periodic work remain triggers. The current
periodic timer is fixed from scheduling; a user check does not restart its interval.
See the [complete event audit and evidence](MIMO_EVENT_TRIGGER_AUDIT.md),
`MimoCoordinator.swift`, and `familyChangeClosesOnce` /
`configurationBarrierCannotOutliveItsEdit` in the service tests.
The same candidate's approved-state native audit confirms one fresh check and
opening per family edit in Rule/Global, with no lookup or gate operation from
Dashboard/all-six-Settings navigation during either 90-second observation.

### GUI status delivery and navigation

The compact dashboard reserves status-message height and changes only layout.
Its 26 November installed Direct/all-six-Settings navigation audit produced no
verification/control work while health checks continued. The same core's
protected-mode audits remain separate; see the
[layout validation record](MIMO_3_0_IMPLEMENTATION.md#compact-stable-dashboard--26-november).

On macOS 15 and later, Dashboard/Settings and explicit sidebar navigation buttons
opt into window activation events so an activating click can also select the
page. The List retains selection for native highlighting and arrow keys; an
activation modifier on the List alone does not fix consumed clicks. This changes
GUI navigation only, in Direct and protected modes alike; it does not request
core operations or change routing/service button activation behavior. The
[first-click reproduction and qualification](MIMO_NAVIGATION_RESPONSIVENESS.md#first-click-follow-up)
is separate from selection-to-render timing.

One completed core snapshot assigns several published GUI properties. The native
status item schedules at most one update per main-queue turn and reads the latest
completed state; it skips replacing/measuring an unchanged label while still
refreshing menu action availability. In Direct, blocked and active protected modes,
health-only snapshots do not rewrite unchanged local monitoring preferences.
The released-monitor fallback persists changed preferences/budget/provider health
and invalidates its comparison cache when local monitoring starts.

Dashboard/Settings navigation keeps drafts and does not initiate an IP lookup,
privileged inspection or service restart. The existing login-item controller
continues to perform service reads off-main. These GUI optimizations do not
change core events, network protection or failure recovery. See the
[navigation regression tests and limits](MIMO_NAVIGATION_RESPONSIVENESS.md).
Full GUI diagnostics correlate `mimo_navigation_requested`,
`mimo_navigation_transaction`, `mimo_navigation_applied` and
`mimo_navigation_window_updated` by navigation ID. Requested records include the
current mouse/key event's age when available (which can be stale for programmatic
selection); transaction records describe animation, applied records measure
SwiftUI selection delivery, and window-updated records measure the subsequent
AppKit callback. None measures compositor/Screen Sharing presentation. No key
values, coordinates, draft or credential contents are recorded. Diagnostics do
not force drawing, schedule core work or change the navigation transaction.

Settings → Maintenance is a read-only reference, available even without a core
connection. Copying its commands only changes the clipboard. Executing a copied
release/install/uninstall command in Terminal enters the existing privileged
lifecycle workflow below; it is not a second GUI enforcement path. The page
documents live PF inspection, system DNS, launchd status and owned cleanup.

The canonical profile renderer emits the same explanatory YAML comments for v3
templates and installed private profiles. Comments describe policy, not runtime
health or successful qualification. Settings changes still follow the existing
revision/render/verify path; annotating a profile does not introduce a new event.

## Diagnostic storage lifecycle (Direct and protected modes)

`RuntimeLog` publishes redacted in-memory records and queues disk writes on a
separate utility queue. `MimoLogStore` rolls 5-MiB/UTC-day segments and enforces a
64-MiB/128-file directory budget at rotation and maintenance. Startup, a changed
diagnostics preference and the independent 60-second timer trigger expiry and
service-output rotation; quiet long-running processes do not require a restart
to delete expired logs. The core/supervisor roles read the shared retention
preference without RPC. Multiple roles/accounts serialize only their own shared
directory's storage work; GUIs never maintain the system directory.

The workflow is identical in Direct, active/blocked Rule/Global and released GUI
monitoring. It has no network, gate, profile, provider, service-health or retry
callback. `mimo_log_maintenance` records counters only when work/drops/failures
occur; failed maintenance publishes at most one failure per attempted sweep and
does not recurse into synchronous disk writes. In-memory diagnostics remain
available when persistence fails. Normal GUI/daemon exit and engine exec drain
queued records; a crash can lose the pending tail.

launchd output uses bounded tail-copy/in-place truncation to preserve open
descriptors. It can temporarily exceed the budget between sweeps and can lose
concurrent output during truncation; runtime JSONL writers use the cooperative
directory lock instead. Live readiness markers are not budget eviction targets.
Stop/uninstall retains diagnostics and removes the running schedulers together
with their processes. See [policy and validation](MIMO_LOG_RETENTION.md),
[logger](../Sources/MimoCore/RuntimeLog.swift),
[storage](../Sources/MimoShared/MimoLogStore.swift),
[tests](../Tests/MimoLogTests/run.sh).

## Flat firewall state

The only active root is `com.apple/000.mimo`. Every generated packet rule carries
a `mimo:` context label. Old child anchors are removed on migration/release.

| Phase | Packet policy |
| --- | --- |
| Closed | Block public local proxy/DNS listeners; permit other loopback control, DHCP, IPv6 neighbor/router link control and replies in tracked incoming TCP connections; deny other outbound traffic. Settled blocked state may retain verified signed VPN transport for incoming Tailnet access. |
| Verification | Closed controls plus literal IPv4 TCP proxy endpoint/port for the runtime GID. Hostname bootstrap briefly uses only the fixed encrypted bootstrap resolver. No native Tailnet, broad root/user, LAN or TUN exception. |
| Active Rule/Global | Persistent fallback guard: owned TUN/loopback, engine TCP/UDP, intentional native destinations and link control; drop other native egress. Profile owns routing/DNS/family. |
| Managed Direct | Empty root; no Mimo TUN/system DNS. Engine remains available with an idle profile. |
| Released | All owned rules/children, boot references, jobs and resolver ownership removed; other owners’ PF rules/references remain. |


Every protected policy starts with `mimo:inbound:tcp`: a non-quick incoming TCP
SYN rule on interfaces other than `utun239`, using `keep state (if-bound)`.
The following non-quick `mimo:inbound:loopback` rule overrides state creation on
`lo0`. Local proxy/DNS clients cannot retain an inbound state across closure.
Only that peer-initiated connection gains reply permission, on its interface.
Outbound grants remain `no state`. Closure loads denial before inspecting the
state table and revoking originating sources of outbound (`->`) states; incoming
(`<–`, printed by pfctl as `<-`) states are retained. Unknown/oversized state
output fails the close rather than falling back to a global purge. The core,
independent Perl guard and standalone teardown follow this contract.

After exit rejection, the supervisor publishes Blocked with the actual IPv4
observation. Core derives authorization from that routing result,
including an empty allowlist; a successful provider lookup cannot imply allowed
traffic. Refresh now reports checked-but-blocked, and the GUI offers recovery
without automatically approving the address. Its warning uses `orderFront`
without application activation. `mimo_exit_ip_rejected` records the reason.

Proxy/provider errors enter the existing bounded failure cooldown/rotation path.
The last lookup-error indicator remains visible alongside the pause deadline;
entering cooldown must not erase the failure cause. A successful check clears the
indicator. Exit-policy rejection takes precedence over an unrelated old lookup
error. State subscriptions and health polls do not request another lookup.
Explicit retry still observes provider restrictions; it does not spin until an
exit becomes approved. Event Log distinguishes lookup failure, provider pause,
manual deferral and policy rejection.

Supervisor startup/liveness recovery arms one verification request. An accepted
protected `prepare` consumes that pending request before asynchronous work;
approval is not required to consume it. Direct also clears it. A new preparation,
readiness or liveness failure can arm recovery again. A successful provider
response rejected by the IPv4 allowlist is a settled policy decision, not a
continuing infrastructure failure. Routine healthy infrastructure scans must
not convert it into repeated `network_configuration` lookups.
`mimo_recovery_verification_consumed` carries the existing command correlation
fields and the `prepare`/`direct` outcome. PF and IPv4 approval requirements are
unchanged. See `MimoSupervisor.swift` and the installed
`v3_rejected_exit_stability_test.py` regression. The four Rule/Global × IPv4/Dual
restart/rejection/retry/Direct cases and a separate 90-second native navigation
audit passed; [correlated results and diagnostic limits](MIMO_NAVIGATION_RESPONSIVENESS.md#installed-correction-and-event-audit--26-november)
distinguish intentional restart transients from settled-state anomalies.

UI and failure/recovery qualification must include event handling, not just
pixels: capture GUI navigation and core/supervisor records around each action;
assert the expected trigger and completed outcome; check for duplicate lookups,
configuration writes, stale commands, unexpected gate transitions and repeated
recovery. Observe rejected/idle states for at least 35 seconds (multiple 10-second
infrastructure audits), including supervisor startup while already rejected.
During ordinary navigation there must be no new verification/control cycle.
During explicit recovery, account for every retry and final settled result;
check that health monitoring and Direct recovery remain available. Unexpected
external events invalidate the quiet-window test and require investigation,
not automatic exclusion. Raw records remain private; publish sanitized event
times, correlation IDs, action counts and assertions.

The build-10 same-session lockout is reproduced in
[`MIMO_BLOCKED_VERIFICATION_RECOVERY.md`](MIMO_BLOCKED_VERIFICATION_RECOVERY.md).
Current candidate behavior distinguishes local/transient automatic backoff from
provider restrictions: a manual-urgency repair/Retry may release one local pause,
but automatic rotation/polling never does. Unknown legacy deadlines remain
restricted except recorded transport errors. Failed coordinator lookups already
own closure; scheduler presentation must not send duplicate closes. A necessary
scheduled close captures its epoch before queuing and cannot revoke a newer
check, configuration or Direct selection. Direct lookups never close the gate.
Diagnostic lookup/attempt/command IDs connect admission, private HTTP, provider
pause and gate outcomes; copied timelines identify missing log sources.
This path is qualified in the unpublished build 11 VM candidate for Rule/Global
and IPv4/dual-stack, including preserved HTTP 429/Retry-After restrictions and
actual core/supervisor log correlation. It does not establish the initial trigger
of the user's first HTTP failure.

Explicit Direct supersedes preparation, HTTP verification and readiness. Late
results cannot reopen the old mode. Restoring native networking requires no
provider success or allowlist approval; core confirms DNS/TUN/PF release before
publishing Active Direct. A failed restore remains an error, with cleanup/repair
available. The dashboard keeps recovery actions visible during blocked/checking
states. See the failure/recovery acceptance contract in
[the test plan](MIMO_DUALSTACK_TEST_PLAN.md) and its source/installed results in
[the incoming-access record](MIMO_V3_INBOUND_ACCESS_FIX.md).

The existing supervisor watchdog also samples signed native VPN transport while
settled Blocked. It verifies the close epoch and exact previous readback under
the mutation lock before replacing the closed policy and `guard.expected`.
This grants no application/engine egress or approval and never reopens the gate.
A newer close cancels the update. Counts are logged as
`mimo_blocked_native_transport_updated`; failures remain blocked. Direct skips
this path and keeps an empty policy. Incoming UDP and preexisting untracked
connections are not covered by the new TCP-state guarantee.

Managed Direct and released Direct are distinct. The first retains a running idle
engine and shared services. Stop engine enters the second while keeping Mimo.app
installed; it removes owned service/runtime controls rather than merely pausing
the engine. Both states passed service/network qualification. Released GUI IP
refresh and native button appearance remain separate UI checks.

PF mutations are serialized, and a revocation epoch invalidates older probes.
Close revokes sources of original outbound PF states, retaining original incoming TCP states; open does not flush states. The staged core implements this directly, so upgrading from an older guard does not require the new helper to be installed first. Readback verifies expanded
rule contents, not just labels. Independent checks require the exact active
guard; an empty protected root is a fault. An ineffective or bypassed closed policy is a failure, not an
acknowledged block. The active guard preserves explicit native destination exceptions; closed mode does not grant application LAN/Tailnet/TUN egress.
Tailnet destination permissions bind to a live native tunnel snapshot. Missing or
changed native interfaces invalidate that preparation; Quad100 and Tailnet ULA
are denied on other paths before engine and generic native grants. This is PF
scope validation, not a restored provider or profile interface binding. Synthetic
IPv4/IPv6 addresses are also denied outside the owned TUN.

The active audit also reads held sockets from the official root-owned Tailscale
system extension, checking its running signature and process identity on both
sides of collection. UDP grants require its held source ports plus root ownership;
HTTPS grants require an observed control/relay address, port 443 and root ownership.
Held failed TCP sockets allow the next retry to use a new source port. These
trusted-native-service exceptions do not promise containment of a malicious root
process or compromised VPN. No grant is made for another user or general root HTTPS.
Changed scopes replace only the active policy under the shared mutation lock,
after checking that the old policy/gate/interface snapshot remains current.
Readback and `guard.expected` are committed together. Invalid observations remove
grants. No profile reload, new approval or separate provider/watch loop occurs;
closure supersedes any in-flight observation. `mimo_native_egress_updated` logs
counts without endpoints. Native interface changes still close and reverify.
Public transport observation runs even with no native Tailnet interface. Cached
preparation, fresh preparation and the active audit all collect the same signed
socket evidence; otherwise a disconnected VPN cannot obtain the transport needed
to create its interface. Held public control sockets can remain eligible while
the VPN is disconnected. Their disappearance or failed identity validation
revokes the corresponding scopes. This is distinct from private Tailnet passes,
which require the verified native interface and remain behind wrong-path denial.
Closed/probe behavior is unchanged; Direct has no Mimo filtering or native scope
publication. See the [live reconnect record](MIMO_V3_LIVE_LIFECYCLE_RESULTS.md)
for the startup failure and the corrected candidate's passing dual-stack Rule
and Global reconnects. Protected/managed-Direct sleep remains unqualified because
the operator skipped further attempts after the VM did not sleep.
The pinned engine leaves native overlay destinations to macOS routing rather
than binding Quad100 to the physical default inferred from interface prefixes.
PF denies those destinations outside the verified native tunnel. The capability
`native-dns-route-v1` is required before activation. No provider or YAML interface
binding is involved.

## Protected transaction

1. Validate and admit a shared revision. Cancel superseded requests and mark the
   effective mode unavailable while preserving the requested mode.
2. Request closure; confirm effective policy, PF enable state and state flush.
   Profile rendering, credential reads and immutable preparation may run in parallel.
3. For hostname proxies, remove/drain the old DNS owner while its TUN exists,
   retire that TUN, grant only encrypted bootstrap, resolve A, then revoke bootstrap.
4. Load the exact canonical candidate; install core’s temporary catchall resolver
   with preserved native search domains/scopes. Engine DNS registration is disabled.
5. Confirm process identity, pinned engine capabilities, loaded profile/selection,
   listeners, DNS and capture readiness. Permit authenticated exact-host HTTPS
   verification via the private listener and narrowly scoped proxy endpoint grant.
6. Obtain one fresh IPv4 through a family-pinned proxy connection in both traffic settings. Publish it before approval/readiness finishes; failed/no-address requests retain only labelled display history.
   Each actual provider HTTP request spends the shared budget. The observation must
   belong to this attempt, revision and network generation and pass the IPv4 allowlist.
7. Recheck readiness, close epoch, power hold and deferred external events under
   the grant lock. Install/read back the active guard and publish Active only after success. No optimistic open.

A failed IPv4 check, DNS/TLS/proxy failure, stale result, changed profile or
unresolved external event keeps the gate closed. Unsupported IPv6 traffic never
falls back to native transport. Full readiness also applies to warm profile reuse.
The active guard remains installed through process or route failures. Recovery
is asynchronous, but ordinary native application egress must already be denied.
Liveness loss sets verificationRecoveryPending so a recovered core can reverify.
The corrected candidate passed the separate
[32-row packet/fault rerun](MIMO_V3_CORRELATED_FAULT_RESULTS.md), with both-family
echo attempts during every fault, zero native bypass/public echo replies and
confirmed recovery. Historical failures and the earlier sender limitation remain
evidence; physical, native-UI and actual PF kernel-failure limits remain separate.

## DNS policy and teardown

Public DoH explicitly selects Proxy. Bare names and private suffixes have both
fake-IP exclusions and nonpublic resolver policy. Quad100 handles Tailnet names;
validated native mappings handle LAN/corporate suffixes. Missing private mappings
produce a local negative response. The names-only journal prevents a previously
known disconnected suffix from falling through to public DNS; it does not retain
stale resolver addresses. Saved primary DNS overrides DHCP for the same suffix.

Core publishes a temporary catchall only. Existing native split scopes keep their
precedence, with explicit default/Tailnet search domains carried forward. Native
DNS changes trigger a conservative protected refresh. Direct keeps native DNS.

Direct/Stop/uninstall revoke work, close and drain DNS **before** tunnel removal.
Maintenance closes through the short PF revocation lock instead of waiting for a
normal lifecycle operation. Cleanup then serializes lifecycle/PF ownership and
records a new close epoch. Direct releases only its current epoch; maintenance or
a newer denial supersedes that release. Post-release native connectivity checks
run outside the lifecycle lock. The independent monitor distinguishes a healthy
empty expected-policy file from a missing file.
If an engine repair is still executing the guarded core wrapper and has no TUN,
Direct teardown leaves that wrapper alive. Its controller is not ready yet;
treating the failed reload as a hung engine would cancel each launchd repair.
An actual engine with a failed controller, or a surviving TUN, still requires
teardown before release.
Then retire TUN, restore older saved IPv6 settings and clear all legacy child
policies before emptying/removing the barrier. Stop/uninstall additionally remove
owned jobs and controls using the shared cleanup script. Native Tailnet route/DNS
readback occurs after release. A failure then reports incomplete native recovery;
it must not silently reinstall blocking. A disconnected Tailnet is reported as
unavailable for checking, not as successfully tested.

Full Stop produces a cleanup receipt, continues anonymous GUI IP monitoring and
changes the dashboard action to Activate. Activate/install/reinstall restore all
roles and perform scoped conflict consent. Core remains the sole machine owner;
release does not create another settings writer in each GUI.

## Events

| Event | Protected behavior | Direct / released behavior |
| --- | --- | --- |
| V01 Boot, core/supervisor restart | Inspect durable intent; close before protected setup, honor service Stop/maintenance, restore intended roles and verify a new receipt. Supervisor restart also invalidates approval. | Managed Direct restores without approval. Completed deactivation leaves jobs absent; interrupted release resumes cleanup before activation. |
| V02 Mode, active proxy or family change | Validate candidate, admit revision, close and run section 7.5. Both traffic settings require fresh approved IPv4 from this attempt. IPv6 destination failures are not IPv4 provider failures. | Save proxy/family without activation or an IP check; core-owned family selection survives supervisor status polls. Selecting None/removing the active proxy restores Direct. No selected proxy permits Direct only. |
| V03 Bypass Apply | Rule validates and reloads under a fresh cycle; Global saves blocks for later Rule use without reload. Invalid drafts cause no mutation. | Save only while core is active. Full deactivation cannot create a second machine-settings owner. |
| V04 Inactive proxy CRUD, drafts, display/login preferences, refresh interval | Persist or display only; no unrelated profile reload, lookup or close. Editing the active proxy is V02. | Same admission rules; no protection cycle. Released refresh preferences are isolated to that monitor. |
| V05 Allowlist, verification-provider selection or active provider credential | Invalidate the affected receipt and verify with the new revision. Removing an approved address cannot leave the old receipt effective. Country metadata never grants approval. | Observe under updated preferences when relevant, with no native-traffic gate. Machine credentials remain unavailable to released monitoring. |
| V06 Refresh now, provider Test, Retry, periodic/deferred refresh | Shared scheduler applies quotas/cooldowns and joins/coalesces in-flight work. Every admitted protected lookup uses section 7.5 and reports its real result. Never disables only periodic refresh. | Managed core observes native exit; after full deactivation the anonymous GUI monitor does so. Neither closes PF for a Direct check. |
| V07 External IP/DNS/route/interface/VPN/service-order/location change | Relevant/unknown changes invalidate and request early closure; classify and coalesce a fresh cycle. | No protected cycle or event-only lookup in managed Direct. Released monitoring can follow another VPN's exit. |
| V08 Exact owned mutation or known telemetry | Ignore only positively classified keys; resolve their tickets without clearing unrelated external events. | No routing or lookup side effect from ignored notifications. |
| V09 Proven private-only native DNS/route change | Preserve native scopes/search configuration without provider/PF publication. Current implementation conservatively requests a new protected cycle for changed native DNS; no in-place approval reuse. | Native configuration stays authoritative; no Tailnet control, provider refresh or port retry. |
| V10 WillSleep, wake, sleep cancelled | Establish power hold/epoch and confirm close before normal sleep acknowledgement. Wake/cancel remains closed until the current generation verifies. | No protection guard or event-driven approval. Released monitoring follows account activity. |
| V11 Lock/unlock, login/logout, console/display change | Supervisor invalidates once per real transition. Multiple GUI windows do not each request global rechecks. Bounded display sampling cannot block login/session handling. | No protected cycle; released account monitoring pauses/resumes with that GUI. |
| V12 Core/engine missing or hung; failed process/profile/DNS/route audit | Supervisor/independent checker closes, records observation/effective times, repairs only intended services and requires new verification. | Respect Direct/released intent; stale protected faults cannot reinstall blocking. |
| V13 PF/launchd drift or infrastructure timer | Compare expected live phase. Empty active root is a fault; ineffective closed root is a fault. Repair closed and reverify; never recreate old provider/PF children. | Managed recovery retains empty packet policy; full release removes repair jobs. A stale surviving worker must respect release intent/receipt. |
| V14 Core/engine Start/Stop/Restart or profile Reload | Confirm closure before destructive mutation; persist explicit service Stop intent. Restart/reload requires verification. Lower-level core Stop leaves independent blocking, not silent Direct. | Respect saved service intent and native networking. Dashboard full deactivation is V15. |
| V15 Direct, Stop engine and use Direct, uninstall | Cancel old work and execute section 6.3. Stop/uninstall additionally removes all owned privileged services. | Idempotent cleanup; confirmed Stop shows Monitoring only and Activate. Already-clean Direct causes no new guard cycle. |
| V16 Install/reinstall/upgrade/Activate | Stage/validate, request scoped conflict consent, restore all roles and qualify health; preserve protected mode only with fresh approval. | Previously inactive installations start all services in Direct. No port 18766 or provider readiness dependency. |
| V17 GUI open/focus/reconnect/quit, widgets, logs/copy | Read state or perform the explicit command only. Communication loss causes reconnect/unconfirmed presentation, not an automatic restart, check or close. | Same; anonymous released monitoring is the explicit exception. |
| V18 Timeout, cancellation, crash/reboot during a transaction | Reject stale completions; resume from journaled phase with confirmed closure or fresh verification required. Desired settings and effective profile remain separate. | Resume release, not superseded protected work. A failed native check after release remains incomplete without reblocking Direct. |

## Coalescing, cancellation and observation

Core’s shared scheduler joins concurrent refresh requests, observes provider quotas,
uses a ten-minute failure cooldown and honors longer Retry-After responses. Never
suppresses periodic checks only. Display/login preferences, refresh interval and
inactive proxy edits do not cause protected reloads. Rule bypass edits affect Rule;
Global saves them without a cycle. Session/wake/network checks remain owner-driven.
Manual Refresh bypasses request-gap/burst admission and may retry one local
failure. It does not bypass a provider-imposed restriction or daily budget.
Recovery can select another eligible provider. IPv4 success is provider success
even when the allowlist rejects that address. There is no IPv6 approval request.
Core atomically removes legacy IPv6 allowlist entries before validating stored
settings and logs only the removed count (`mimo_ipv4_allowlist_migrated`).
Fresh rejected results survive polls; a new failed attempt shows timestamped
last-known history without reusing it for authorization. Direct/proxy changes
clear protected history. GUI clients only render the shared result.

Owned mutations are ignored only after positive classification. Unknown/external
changes invalidate approval; deferred events cannot be cleared by a stale completion.
Client cancellation does not erase durable release intent. Health is inspected by
service owners and timestamped; GUI communication loss is not process failure.

## Sources and validation

**Historical pre-guard qualification exceptions (2026-11-25):** active empty PF permits a
short native-fallback interval after engine termination or a newly installed
native route. The contained installed campaign measured public test attempts
before the temporary deny became effective. V12/V13 recovery must not be read as
an instantaneous packet guarantee. A resumed core also remained safely Blocked
after heartbeat expiry in the corrected 100-second recovery test; automatic
reverification is not yet qualified for that path. The supervisor's liveness
closure currently does not set the retry flag used by audit recovery. No new
firewall or recovery behavior has been silently substituted. See
[closure evidence and remaining work](MIMO_V3_QUALIFICATION_CLOSURE.md).

- [Canonical profile](../Sources/MimoShared/MihomoProfile.swift),
  [traffic family and IPv4 approval receipt](../Sources/MimoShared/MimoNetworkFamily.swift),
  [engine patch](../Patches/mihomo-1.19.34-v3.patch).
- [Coordinator](../Sources/MimoService/MimoCoordinator.swift),
  [supervisor](../Sources/MimoService/MimoSupervisor.swift),
  [runtime](../Sources/MimoService/MimoSystemRuntime.swift),
  [PF lock](../Sources/MimoService/MimoFirewallLock.swift),
  [independent guard](../Sources/MimoDaemon/pf-guard.pl).
- [DNS owner](../Sources/MimoService/MimoDNSConfiguration.swift),
  [native policies](../Sources/MimoShared/MimoNativeDNSPolicy.swift),
  [cleanup](../Sources/MimoDiagnostics/release-network.pl),
  [installer](../Sources/MimoDaemon/daemon.sh).
- `xcrun swift test`, `bash Tests/MimoServiceTests/run.sh`, engine patch tests,
  and the [dual-stack/installed plan](MIMO_DUALSTACK_TEST_PLAN.md).
- Current IPv4 approval revision: [four mode/family cells, 16 fault recoveries,
  migration and 22 Direct/Stop/Start assertions](MIMO_IPV4_APPROVAL_RESULTS.md).
  [Native blocked-Global navigation](MIMO_NAVIGATION_RESPONSIVENESS.md) completed
  Dashboard and all six Settings sections. The reported intermittent stall and
  simultaneous two-account navigation remain unqualified.
- Installed trusted-fixture validation: [44 HTTPS assertions](../Tests/MihomoRuntimeTests/Evidence/v3/installed-https.json),
  [13 active recovery assertions](../Tests/MihomoRuntimeTests/Evidence/v3/installed-active-recovery.json),
  and historical, superseded [9 paired-failure assertions](../Tests/MihomoRuntimeTests/Evidence/v3/installed-paired-failure.json).

New events include `mimo_dns_removed_and_drained`,
`mimo_active_firewall_installed`, `mimo_direct_network_released`,
`mimo_native_release_checked`, `mimo_native_release_check_failed` and
`lookup_http_request`. Installation/cleanup outcomes are machine-wide and remain
available with the GUI closed. Tokens/passwords never appear in these events.

Physical login switching, forced sleep, Wi-Fi hardware changes and pre-loader
boot behavior remain separate qualifications. Detection intervals are not maximum
leakage windows. See the v3 plan’s T01–T14 mapping and implementation record for
executed evidence and unresolved limits.
