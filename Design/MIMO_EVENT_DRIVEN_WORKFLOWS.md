# Mimo event-driven workflows

Current v3 implementation, updated 2026-11-28. Qualification is tracked separately
in [MIMO_3_0_IMPLEMENTATION.md](MIMO_3_0_IMPLEMENTATION.md); this document is not a
claim that every physical scenario has passed. The v3 plan contains its own
adapted workflow specification and does not depend on historical versions of
this file.

The observation workflow below is implemented locally; qualification is reported
separately. The [earlier native Refresh audit](MIMO_REFRESH_EVENT_AUDIT.md) describes
the superseded blocking behavior and retains its failures.

The first 28 November local correction was packaged as `7601ffe3`; its installed
L1 check then failed before Rule because the dynamic `(self)` destination had an
empty PF address table and did not track the Direct-born SSH connection. Earlier
literal-destination mechanism passes did not cover that expression. A paired
real-PF `(self)`/`(en0)` regression reproduced the difference. The current local
candidate `1942a60a` uses a validated literal local-address snapshot and passed the
declared 24-case VM scope, including installed L1/L2/L3. It is not published.
Ordinary Direct keeps only incoming TCP SYN tracking; full
Stop/uninstall still empties Mimo's rules. Native policy preparation, PF lock
wait/commit and readback run off MainActor. Gate/close/mutation/policy ownership
is checked before stamping, including same-policy epoch replacement. A matching
successful readback receipt is adopted only by its current owner and requests
one health reconciliation, not exit verification. Close/Direct/new protected
intent invalidates and joins native work. Stale work is superseded, no-ops are
silent, and typed lock congestion defers to the next sequential watchdog turn;
real readback failure remains a fault. Full-guard freshness is never renewed by
these narrow receipts. The [before/after report](MIMO_REMAINING_FAILURE_INVESTIGATION.md)
retains the original failures, earlier mechanism scope and excluded harness
attempts. Final-source revalidation passed six real-PF mechanisms and fourteen
native-policy controls on primary. With the paired expression regression and
L1/L2/L3, the declared VM scope is 24/24 passed. L1 retained 109/109 authenticated
SSH echoes and a clean 35-second settled Rule-denial audit; L2 fully deactivated
and reactivated through the actual RPC/installer backend. L3 passed addition/removal
of owned IPv4 and IPv6 loopback aliases with exactly two tracking updates; the
watchdog work joined, and the gate, profile, DNS and jobs were unchanged with no
exit-IP checks. The [installed evidence and cleanup record](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-installed-after-20261128.json)
includes expected communication loss during explicit Stop/Activate; L1 and the
four settled windows had no unexpected communication losses.
Seven local Direct-maintenance controls, 27 focused shared checks, 45 guard-parser
controls, the 84-source typecheck and signed-package verification passed separately.
These are backend/event results, not native button-click qualification. L3 does
not establish TCP delivery to an added alias, IPv6 ingress or route migration.
Owned test resources were removed and original settings/routing/hosts restored
with primary healthy in Direct. The temporary worker is absent; the backup and
approved testing CA are preserved. Earlier proposal/status paragraphs below retain
their dated artifact scope and limitations.

### Literal address snapshots and Direct address reconciliation

`getifaddrs` supplies one bounded, canonical, unique and sorted list of local IPv4
and IPv6 host addresses, including link-local/temporary IPv6 and excluding the
Mimo TUN. Core renders the prefix from that snapshot and validates the same
snapshot on readback. The canonical parser rejects widened or malformed prefixes;
exact equality with the root-owned committed `guard.expected` is also required.
A valid-looking list or copied labels do not establish that a rule belongs to the
current owner. The independent guard validates the committed snapshot, so ordinary
address drift is reconciled rather than misreported as grounds to block Direct.

In active managed Direct, a relevant network notification invalidates obsolete
native work and requests one coalesced comparison. A single owned task performs
inventory/PF work on the serial background queue; the watchdog also requests a
comparison. Unchanged addresses produce no PF command, receipt refresh or exit
lookup. Changed addresses require the current Direct owner, gate/close/mutation
scope and exact previous rules before stamping/commit. Successful readback adopts
only a still-current receipt and requests health reconciliation. It performs no
closure, profile/DNS reload, provider request or service restart. Stop/uninstall
cancels and joins the task, then fully releases Mimo resources. Protected active
address changes retain the existing close/verification workflow; settled blocked
maintenance refreshes an old local prefix even if native socket scopes did not change.

Diagnostics distinguish `mimo_direct_tracking_reconcile_requested`,
`mimo_direct_tracking_updated` and `mimo_direct_tracking_refresh_failed`, correlated
with the native-policy ownership/readback events. Record counts, epochs, digests
and timing, not local address values. No-op inventory comparisons do not renew
full-guard freshness. Connections born before initial tracking or before an added
address is reconciled may need reconnect; established flows are never adopted.
This is a TCP guarantee only, with state-loss/interface-migration limits retained.

Source: [policy snapshots](../Sources/MimoShared/MimoFirewallPolicy.swift),
[owned transaction](../Sources/MimoService/MimoSystemRuntime.swift),
[trigger coalescing](../Sources/MimoService/MimoSupervisor.swift), and
[independent readback checks](../Sources/MimoDaemon/pf-guard.pl).

## Current observation/transition split — 27 November 2026

This section supersedes the historical rule that every Rule/Global lookup enters
`prepare`. Local implementation is under qualification; the result report records
what has actually run.

| Trigger / state | Gate before lookup | Owner and result |
|---|---|---|
| Manual / periodic / retry on an intact approved path | Retain active policy | MonitoringEngine → Coordinator `observe` → supervisor read-only runtime validation → private probe → `completeObservation`; allowed stays open, denied closes |
| Provider/pool/token edit | Retain approval, cancel obsolete provider work | Core commits shared settings, then one observation; failure retains prior approval |
| Allowlist edit retaining current IP | Retain approval | Core commits the shared policy without superseding preparation; fresh or already-in-flight completion reads the latest committed allowlist |
| Removal of currently approved IP | Close immediately before acknowledgement | Supervisor `updatePolicy` calls the application gate; display rejected IP, check while blocked |
| Already blocked / no approval | Keep blocked | Existing `prepare`/`approve`, fresh IPv4 plus runtime validation required |
| Proxy/mode/active family/Rule bypass/profile or runtime change | Close first | Cancel old lookup, advance routing generation; reconcile, verify, reopen only if allowed |
| Direct / engine released | No IP-monitor gate | Native location observation, allowlist not enforced |
| Navigation/reconnect/cosmetic/same-value/inactive edits | Unchanged | No network check |

Observation tokens are distinct from blocking verification tokens. An observation
never calls `beginCycle`, so a real route/power event can revoke immediately,
including before its actor callback. Runtime identity, loaded profile, DNS/TUN,
active PF readback and the power epoch must still match at completion. Policy
revisions do not substitute for network generations. Provider failure cannot
reopen a blocked path. Policy changes and Direct are not queued behind HTTP.
Only a known revocation sends the ordered `updatePolicy` mutation. Other
policy-only saves do not cancel an in-flight preparation or observation. Both
`approve` and `completeObservation` read the current owner-only settings before
acceptance; `approve` checks again after asynchronous readiness work.

No observation starts a profile reload, connection cleanup, PF write or opening
operation. Independent infrastructure audits/repair continue; an integrity failure
invalidates approval normally. Inbound management reply protection is unchanged.

Same-path requests join one lookup; superseded work schedules one follow-up with
transition priority retained. Successful observations reset the periodic deadline;
provider failure retains the prior snapshot and existing quota/backoff behavior.
Before charging an observation failure to a provider, the coordinator checks its
task, routing generation, observation token and original approved result. The
supervisor must acknowledge that exact observation's failure while the same path
remains active. These checks run again after the asynchronous acknowledgement.
Blocked, replaced, ignored or failed acknowledgements cancel the obsolete request;
they do not issue another close or create provider cooldown. This covers a runtime
audit closing the gate before core receives its network notification. Genuine
provider errors on an intact path still follow provider backoff. A transition
error uses a token-qualified `close`: the supervisor atomically checks the exact
current checking token before any gate, readiness or Direct-restoration mutation.
A mismatched token is a conflict/cancellation, not communication loss or provider
failure. Core advances its local generation only after the accepted closure;
rejection cannot invalidate a newer verification. Unqualified network/configuration
closures retain their existing behavior. A newer generation also cancels an error
whose qualified closure was already awaiting acknowledgement.
Approval also checks cancellation and exact generation/token ownership immediately
after awaiting readiness, before baseline acceptance. It checks the same ownership
when that await throws. A readiness task that already completed can still return
after cancellation; neither its receipt nor its error may close a newer Direct
path or replacement verification. Genuine current readiness failures retain their
existing closure behavior.
`mimo_probe_result_cancelled` records a fixed reason code, mode/family and
lookup/attempt identifiers; `lookup_cancelled` confirms the scheduler discarded
the result. Neither event contains provider response bodies or credentials.
`mimo_verification_failure_ignored` identifies a stale token rejected by the
supervisor before closure.
`mimo_approval_result_cancelled` distinguishes `readiness_result_superseded` from
`readiness_error_superseded` before any stale baseline acceptance or failure close.
Logs expose intent, trigger, lookup/attempt IDs, generation, policy revision,
gate outcome and next periodic deadline, with existing privacy and retention.
Dashboard distinguishes checking while allowed from checking while blocked.

The frequent engine-liveness check uses the loaded PID, kernel start time,
executable and UID/GID. It does not infer engine exit from a failed `launchctl`
query. Missing/replaced processes still close immediately; controller, profile
and launchd/infrastructure audits remain independent. `mimo_engine_liveness_failed`
records the failed identity stage before `mimo_liveness_lost` initiates recovery.
Informational `mimo_readiness_probe_unavailable` identifies unavailable controller,
listener, tunnel or route reads, engine/profile comparison and resolver/receipt
confirmation separately. Probe readers do not own the routing generation: an
active audit can resume after Direct has intentionally removed protected DNS and
the tunnel. Its generation-fenced supervisor consumer discards superseded work;
only a current audit failure emits `mimo_verification_audit_failed` and closes the
gate. Preparation and approval retain their existing failure handling.
`mimo_process_readback_unavailable` records launchctl status or a missing PID.
Only stage names, statuses and Boolean outcomes are logged, never controller
responses, profiles or secrets. Diagnostic severity does not change readiness
acceptance, cancellation, generation fencing or fail-closed behavior.

Sources: `MonitoringEngine.swift`, `DaemonService.swift`, `MimoCoordinator.swift`,
`MimoSupervisor.swift`, `MimoSystemRuntime.swift`, `MimoRouting.swift` and
`MimoStatusPresentation.swift`. Validation: [observation results](MIMO_OBSERVATION_TEST_RESULTS.md).
Rapid mode-change validation uses narrowly owned native resolver entries and
leaves the hosts file unchanged throughout each sequence. Separate TLS ingress
records must prove both native Direct and private proxy checks reached the fixture
before measurement. This test-only DNS fixture does not alter the shipped
resolver/profile or provider cooldowns.
Initial verification preemption is exercised through a real traffic-family change;
the exact stale-error/qualified-close timing race has separate fail-first unit evidence.

## Ownership

| Owner | Responsibility |
| --- | --- |
| `DaemonService` / `MonitoringEngine` | Machine settings/revisions, proxy catalog, local credentials, shared request scheduling/budget, subscriptions and diagnostics. |
| `MimoCoordinator` | Current verification request, cancellation, fresh IPv4 approval observations and display-only last-known history, supervisor communication and client-visible routing state. |
| Supervisor process | Hosts DaemonService/MonitoringEngine/Coordinator plus profile delivery, DNS/PF, readiness, engine and heartbeat repair, network/power/session events. |
| Heartbeat peer | Only supervisor progress checks/recovery; no PF, DNS, engine or settings work. |
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
periodic timer resets from a successful IP lookup, including a successful result
rejected by the allowlist. Failed checks retain the provider retry policy; Never
disables only periodic work.
See the [complete event audit and evidence](MIMO_EVENT_TRIGGER_AUDIT.md),
`MimoCoordinator.swift`, and `familyChangeClosesOnce` /
`configurationBarrierCannotOutliveItsEdit` in the service tests.
The same candidate's approved-state native audit confirms one fresh check and
opening per family edit in Rule/Global, with no lookup or gate operation from
Dashboard/all-six-Settings navigation during either 90-second observation.

### GUI status delivery and navigation

The 27 November rapid-operation audit reproduced status-probe disconnections
while synchronous Direct teardown occupied core's actor. The process remained
alive; this was a real communication interruption, not evidence that a service
exited. The unpublished candidate implements the following correction under the
[v3 plan](MIMO_3_0_PLAN.md#proposed-observation-and-transition-workflows--27-november-2026):

1. The supervisor invalidates old approval work and publishes `restoringDirect`.
   It owns a joined task independently of the requesting GUI connection.
2. The runtime invalidates cached profile/DNS/readiness receipts and starts a
   transient copy of the fixed installed core executable on its blocking queue.
   This is not another launchd job. State/events/heartbeat requests remain served;
   service admission reads power-fence busy state without waiting on its lock.
3. The child uses an owner-only request containing operation UUID, parent PID and
   kernel start identity, and saved Direct revision. It verifies current intent,
   parent, maintenance/release state and epoch before mutations. Incoming-only
   tracking and the Direct marker are committed together under the same qualified lock.
4. Native release verification follows the release. The child rechecks owner,
   epoch, marker and exact live tracking policy before returning a receipt. A native
   Tailnet verification failure is displayed separately from control release.
5. The supervisor waits for physical child exit even if the caller cancels.
   Subsequent Direct/protected/Stop mutations wait for that join. A failed or
   malformed receipt invokes a joined, owner-qualified failure-close child; an
   abandoned worker cannot release or close a newer operation. Infrastructure
   samples begun before cleanup cannot overwrite its resulting state.

Sources: `MimoDirectRelease.swift`, `MimoSystemRuntime.swift`,
`MimoSupervisor.swift`, `MimoFirewallLock.swift` and `MimoPowerGuard.swift`.
The durable `ControlResponsiveness`, `DirectPublication` and
`mimo_direct_release_tests.swift` controls reproduce the old failures and pass
74/74 checks on the correction; see the
[sanitized before/after evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/control-responsiveness-regression.json).
Existing underlying commands retain their bounds;
there is no overall parent-worker deadline because the parent must join completion.
Startup/offline cleanup is unchanged. Protected DNS loss combined with power-fence
contention is not qualified by these tests. Installed whole-case qualification is
still in progress.
Do not count earlier error-only or settled-only log scans as communication
qualification. The new audit retains setup, operation and settled GUI records,
including informational disconnects, with process identities and bounded status
requests. No longer GUI timeout or fabricated health timestamp is an acceptance fix.

Protected preparation has a separate responsiveness correction. The first
installed Direct-worker retest exposed 3.8 seconds of consecutive PF/profile/DNS
work during protected setup, exceeding the unchanged three-second status deadline.
The local correction keeps mutable runtime state on the supervisor actor while
fixed-path operations run on one owned serial queue:

1. A replacement or Direct request revokes the old lease immediately and joins
   its physical work before starting another profile/DNS mutation. Status and
   heartbeat requests do not wait for the mutation queue.
2. Worker results carry immutable profile, process, DNS and firewall receipts.
   The actor adopts them only while the same operation still owns the path.
3. Private-probe and active-policy commits check the lease, current configuration,
   close epoch and event fence. Opening additionally checks the current IPv4
   allowlist, native interfaces, process identity and recent readiness receipt.
   Failure after a physical grant compensates closed under qualified ownership.
4. Profile loading and protected resolver installation share one observer window.
   Owned intermediate notifications wait until the final baseline is available;
   external changes remain invalidating events. Replay yields between callbacks
   so a notification burst does not recreate a status stall.
5. Direct still removes the protected resolver, drains queries and releases
   networking through its joined cleanup worker. Logical cancellation never
   means a running privileged command has already stopped.
6. Graceful shutdown rejects new mutating requests, cancels old approval work,
   and joins protected closure, physical operations and observer completion before
   reporting drained. Read-only status remains available during that join.

Sources: `MimoProtectedIO.swift`, `MimoProtectedDNSIO.swift`,
`MimoSystemRuntime.swift`, `MimoSupervisor.swift`, `MimoPowerGuard.swift` and
`MimoNetworkObserver.swift`. The 20 reproduced preparation failures pass locally,
along with eight replacement/policy, 20 transaction and eight observer controls;
see [before/after evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/protected-preparation-responsiveness.json).
Four graceful-shutdown ordering controls separately failed before the join and
pass after it.
Installed qualification is tracked in
[the observation results](MIMO_OBSERVATION_TEST_RESULTS.md). These local controls
do not establish whole-campaign or parent-crash qualification.

Cancellation diagnostics distinguish initiation from eventual task completion.
`MonitoringEngine.invalidatePendingLookup` logs `lookup_cancellation_requested`
before invoking the active task's cancellation handler. It identifies that task's
actual lookup/provider and monitor lifecycle, including duplicate cancellation.
Validated routing edits additionally carry a generated request ID and intended
mode/revision; `DaemonService` logs `mimo_routing_configuration_committed` with the
same ID only after persistence succeeds. Generic invalidation, a rejected/no-op
edit or failed persistence cannot supply a successful routing-commit proof.
These events do not alter cancellation behavior or grant traffic. The diagnostic
regression reproduced nine missing-initiation failures and then passed those nine
plus six negative controls. A historical TLS abort without initiation evidence
stays unproven.

The installed transport audit needs cross-clock ownership proof only for an
actual rejected provider ingress. With zero rejections it reports timing as
`not_required`, retaining raw calibration samples and any drift diagnostic;
it does not claim a successful clock calibration. Provider identity, event validity,
actual native/protected requests and responses, request counts and recovery checks
still apply. Every real rejection retains strict timing and cancellation proof.

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

Dashboard → Event Log can display the concise Events timeline or the full recent
Core, Heartbeat and GUI diagnostic records. Local read-only `.events` requests
to the supervisor-hosted core endpoint and the heartbeat-only log endpoint run concurrently with
two-second timeouts and a two-second polling delay only while the window is open.
The heartbeat log endpoint admits no mutation. Reading logs grants no filesystem access and performs no health inspection, repair,
IP lookup or routing event. Normal accounts read the same privacy-filtered, bounded
records (up to 500 per source). The source status distinguishes a live reply from
last received records after communication loss. Pause freezes presentation/counts
and exports while polling may continue; Resume publishes the latest snapshot.
Changing log tabs starts a separate native text document so a selection in another
tab cannot keep the wrong process's records visible. Copy All copies the current
tab; Copy Diagnostics retains the combined process report. GUI Log Files opens
only local GUI storage. See [viewer](../Sources/MimoApp/EventLogWindow.swift) and
[ordinary-account and selection tests](../Tests/MimoAppTests/event_log_tests.swift).
Required system-command failures also emit `mimo_runtime_command_failed` in normal
builds, with executable basename, PF operation flag, exit status, configured bound
and elapsed milliseconds. Arguments, stdin and captured output are omitted. This
adds failure evidence without changing command execution, retries or protection.

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
| Managed Direct | Exact literal local-address incoming TCP SYN prefix plus loopback no-state override; no outgoing restriction or Mimo TUN/system DNS. Engine remains available with an idle profile. |
| Released | All owned rules/children, boot references, jobs and resolver ownership removed; other owners’ PF rules/references remain. |


Every protected policy and ordinary Direct start with `mimo:inbound:tcp`: one
non-quick incoming TCP SYN rule per validated literal address in the captured local
inventory, on interfaces other than `utun239`, using `keep state (if-bound)`.
The following non-quick `mimo:inbound:loopback` rule overrides state creation on
`lo0`. Local proxy/DNS clients cannot retain an inbound state across closure.
Only that peer-initiated connection gains reply permission, on its interface.
Outbound grants remain `no state`. Closure loads denial before inspecting the
state table and revoking originating sources of outbound (`->`) states; incoming
(`<–`, printed by pfctl as `<-`) states are retained. Unknown/oversized state
output fails the close rather than falling back to a global purge. The core,
core-owned guard helper and standalone teardown follow this contract.

### Boot and infrastructure checks in the existing supervisor

The existing `mimo-core --supervisor` process establishes the boot guard before
accepting control requests, then owns serial PF/launchd checks with a normal 10-second
delay. The engine wrapper also confirms boot protection before exec. There is
no separate infrastructure role or launch job. The fixed Perl helper remains a
bounded subprocess. Upgrade unloads and removes `com.mimo.pf-boot` and
`com.mimo.infrastructure` and both repair copies, including the interim candidate
that used `--infrastructure`. Rollback retains old registrations and bytes.

The supervisor now also hosts the monitoring/settings service and both GUI API
endpoints. The existing `com.mimo.core` job executes `--heartbeat` only; it never
calls the firewall helper. Each process checks the other with boot/PID-bound
monotonic progress records. Supervisor progress includes completion of the serial
infrastructure worker; ordinary network failures still count as completed work.

A healthy peer produces progress every two seconds. Known peers need 45 seconds
of lost progress before forced recovery; new processes receive 120 seconds of
startup grace. Missing jobs wait 10 seconds for launchd. Peer repairs share a
single lock, reread process/progress, check maintenance/deactivation, restore only
the peer's fixed root-owned plist and use a persistent three-attempt/ten-minute
budget with backoff. Healthy observations validate the progress record's live
executable without spawning launchctl; missing/stale observations inspect launchd.
Maintenance takes the same peer lock before publishing removal intent. Deliberate
installation resets budgets after draining workers; routine restarts retain them.
Install/Activate explicitly bootstraps both peers before health verification. The
completed Stop receipt stays until that verification succeeds; peer repair must
continue honoring it. Waiting for watchdog recovery during activation would
deadlock the heartbeat health check against that receipt.
SIGKILL plus launchd recovers a suspended/hung PID. No GUI
owns repair. The supervisor's PF helper repairs only the engine, never its owner
or heartbeat; two recovery mechanisms cannot race over a peer registration.

Supervisor recovery establishes startup protection and fresh protected-mode
verification. Repairing a heartbeat changes no network state and requests no IP
check. Healthy scans, provider failure, exit-IP rejection and private DNS failure
cannot request peer restarts. Managed Direct restores native networking and incoming
TCP tracking without outgoing restrictions; engine release retains monitoring/supervision until full privileged
Stop/uninstall removes both jobs. Maintenance fences prevent resurrection during
removal. Both peers drain bounded workers before termination. If both roles are
removed/disabled or the common executable fails, installation repair is required.
This is redundancy for recovery, not uninterrupted failover; launchd's independent
crash throttle remains 10 seconds and is distinct from the peer repair budget.

Dashboard labels the IP monitor separately and shows Core heartbeat with a
freshness age. Lost supervisor communication cannot certify network/peer health.
The CLI `--recover-direct` uses the supervisor-hosted settings API with root
authorization and revision fencing; it cannot compete for the storage lock or
turn a stopped IP monitor back on. Full release shows Removed services and
Released firewall. Event Log exposes
`mimo_peer_watch_started`, `mimo_peer_repair_started` (owner/target/reason/attempt),
`mimo_peer_recovery_wait` (deduplicated reason), and `mimo_peer_recovered` only after
new live progress. PF, DNS and provider events stay with the supervisor.
See [implementation and VM validation](MIMO_CORE_INFRASTRUCTURE.md).

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
this native-transport path and reconciles only its literal incoming TCP tracking
prefix. Blocked maintenance also compares the address prefix even when native
transport socket scopes are unchanged. Incoming UDP and preexisting untracked
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

## Protected transaction (changed or unapproved paths only)

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
fully released expected-policy file from a missing file. Ordinary Direct requires
the exact tracking policy; an empty managed Direct policy fails its health audit.
If an engine repair is still executing the guarded core wrapper and has no TUN,
Direct teardown leaves that wrapper alive. Its controller is not ready yet;
treating the failed reload as a hung engine would cancel each launchd repair.
An actual engine with a failed controller, or a surviving TUN, still requires
teardown before release.
Then retire TUN, restore older saved IPv6 settings and clear all legacy child
policies before replacing the barrier with ordinary Direct tracking. Stop/uninstall
instead empty the policy and additionally remove
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
| V06 Refresh now, provider Test, Retry, periodic/deferred refresh | Shared scheduler applies quotas/cooldowns and joins/coalesces in-flight work. Approved unchanged paths use the observation workflow above; blocked/changed paths use the protected transaction. Never disables only periodic refresh. | Managed core observes native exit; after full deactivation the anonymous GUI monitor does so. Neither closes PF for a Direct check. |
| V07 External IP/DNS/route/interface/VPN/service-order/location change | Relevant/unknown changes invalidate and request early closure; classify and coalesce a fresh cycle. | Coalesce a local-address inventory comparison in managed Direct; update only changed incoming TCP tracking. No close, profile/DNS reload or event-only exit lookup. Released monitoring can follow another VPN's exit. |
| V08 Exact owned mutation or known telemetry | Ignore only positively classified keys; resolve their tickets without clearing unrelated external events. | No routing or lookup side effect from ignored notifications. |
| V09 Proven private-only native DNS/route change | Preserve native scopes/search configuration without provider/PF publication. Current implementation conservatively requests a new protected cycle for changed native DNS; no in-place approval reuse. | Native configuration stays authoritative; no Tailnet control, provider refresh or port retry. |
| V10 WillSleep, wake, sleep cancelled | Establish power hold/epoch and confirm close before normal sleep acknowledgement. Wake/cancel remains closed until the current generation verifies. | No protection guard or event-driven approval. Released monitoring follows account activity. |
| V11 Lock/unlock, login/logout, console/display change | Supervisor invalidates once per real transition. Multiple GUI windows do not each request global rechecks. Bounded display sampling cannot block login/session handling. | No protected cycle; released account monitoring pauses/resumes with that GUI. |
| V12 Core/engine missing or hung; failed process/profile/DNS/route audit | Supervisor/independent checker closes, records observation/effective times, repairs only intended services and requires new verification. | Respect Direct/released intent; stale protected faults cannot reinstall blocking. |
| V13 PF/launchd drift or infrastructure timer | Compare expected live phase. Empty active root is a fault; ineffective closed root is a fault. Repair closed and reverify; never recreate old provider/PF children. | Compare live rules with the committed exact tracking snapshot; ordinary address drift uses owned background reconciliation, not closure. Full release removes rules and repair jobs. A stale surviving worker must respect release intent/receipt. |
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

### Rapid-operation policy

Caller-requested cancellation is a normal terminal outcome. Closing a superseded
HTTP/TLS connection is not itself a provider outage and must not create a cooldown,
late approval, repair loop or user-blocking recovery delay.

The current source retains a bounded mutation queue (32 tickets, 65-second
admission bound), but replaces older pending mode-only requests within the same
contiguous pending run. Non-mode edits are ordering barriers: mode coalescing
cannot jump across proxy, family, allowlist or credential writes. Mode requests
rebase on current stored settings at admission; other edits retain their revision
checks. Already-admitted operations cannot be superseded and physically join
before another mutation proceeds. State/event reads remain outside the queue.

A skipped pending mode returns `controlOutcome: superseded`; a cancelled waiting
caller returns `controlOutcome: cancelled`. Neither is a storage/provider failure.
An applied mode returns `controlOutcome: applied`. Events
`mimo_control_superseded` and `mimo_control_cancelled` retain request identity.
This is a latest-pending policy, not preemption of active work: an admitted Direct
release completes, even if a protected mode arrives during it. That authorized
Direct interval remains effective until the pending protected request is admitted
and requests closure. No pending label fabricates an earlier physical block.

New local controls in `Tests/MimoServiceTests/RapidIntent/` use real daemon dispatch,
queue, settings storage and monitoring with isolated mutation/client boundaries.
The eight baseline cases produced four failures (three redundant pending-mode
commit sequences and ordinary cancellation reported as storage failure), with
four controls passing. Only the four failures were retested and now pass4/4; the
four baseline passes were not rerun. That is eight distinct cases and twelve
executions, with source identities preserved for each run. The source changes
have not been installed in a VM.

The GUI sends an explicit optional `requestedMode` plus the legacy routing payload.
Core uses the narrow intent to rebase only mode at admission, even when the GUI's
proxy/family snapshot is old. Up to 32 mode RPCs may await completion from one GUI;
the mode picker/menu remain enabled below that limit while unrelated settings,
family edits and service operations stay serialized. Busy state lasts until every
admitted GUI request has received its terminal reply. This is GUI admission only;
coalescing, persistence and physical ownership remain in core.

Mode issuance and state publication use separate ordering identities. Before
launching a mode RPC task, the GUI stamps optional `modeIntent` with its process
stream UUID and increasing sequence. Core authenticates the caller, validates
command/sequence/initialization and the requested mode against the current proxy,
and checks cancellation before advancing that UID+stream's high-water mark.
An older or duplicate issued sequence returns ordinary `superseded` before queue
coalescing; it cannot replace a newer pending ticket or revive after the 75-second
RPC deadline. Other GUI streams retain core arrival order. This does not preempt
already-admitted physical work or remove non-mode ordering barriers.

Tracking has a process-lifetime 128-stream limit, keyed by authenticated UID and
GUI stream UUID, without expiry or eviction. Existing streams continue at
capacity. New streams receive `modeIntentCapacity`, an actionable error directing
background-service restart from the dashboard; GUI reopen alone does not release
capacity. Restart resets the tracker with the core process. Unauthenticated or
invalid requests cannot consume a slot or poison the accepted sequence. Legacy
unstamped mode RPCs remain compatible but do not establish GUI issuance order.
Diagnostics distinguish `mimo_mode_intent_superseded` from
`mimo_mode_intent_rejected`; both carry fixed reasons and request IDs.

Every core snapshot carries an optional monotonic `stateSequence` within its
`instanceID`. A current GUI rejects lower revisions, older/duplicate sequences,
retired instances and control replies from replaced connection generations.
A new core instance may reset revision/sequence. An applied acknowledgment with
an overtaken same-instance snapshot still succeeds without rolling back state.
Legacy messages omit these optional fields; same-revision publication ordering
is only established when sequence metadata is present.

A further 16 new local controls exercised these GUI/service/manual-feedback
boundaries. Thirteen failed before correction and all 13 selectively retested pass;
three baseline controls passed and were not rerun. Their 29 executions are not
additional installed VM cases. See `Tests/MimoAppTests/RapidState/`, the new named
cases in `Tests/MimoServiceTests/RapidIntent/` and `gui-intent/focused-validation.json`.

Nine additional issued-order controls produced six fail-first results and three
baseline passes. Only the six failures were retested, all passing; the three
controls were not rerun. This is nine distinct cases/fifteen executions, separate
from the earlier 17 health, eight queue and 16 GUI/manual histories. These are
cumulative local histories across source revisions, not a full final-binary suite
or installed-VM qualification. See [issued-order evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/mode-intent-ordering.json).

The installed `d91336cb` focused run exposed an additional manual-feedback gap:
a request queued behind control holds had no HTTP task to cancel. Later mode
commits invalidated its generation, but a new settings lookup marked it Checking
and completion refused its obsolete ownership. The lookup succeeded and Rule
correctly stayed blocked; the manual ticket remained Checking beyond35seconds.
This failure is retained in the
[focused record](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-d91336cb.json).

The congestion correction uses one active lookup and one pending `LookupDemand`
for control-held work, retries and follow-ups. Demand carries generation, fixed
trigger reasons and optional manual-ticket identity. Manual admission creates a
concrete owner immediately; the service's later task carries that accepted ID
instead of admitting a fresh request. Cancelled admission creates neither a ticket
nor a task. Repeated current-generation requests share one ticket/lookup.

Lifecycle invalidation immediately terminates obsolete queued or Checking tickets
as Superseded, even without HTTP. Physical cancellation still joins before another
lookup can start. Admission marks Checking only for a current ticket and records
the actual lookup ID. Deferred replay validates ticket/generation/pending status;
it cannot resurrect completed demand. A current transition check may answer joined
manual demand without an extra provider request. Immediate pending work outranks a
later retry deadline, while provider admission still enforces real cooldowns and
budgets. Provider fallback retains the same ticket through its final result; the
new two-provider baseline passed without changing fallback policy.

Control drain, invalidation and completion reconcile ownership. A pending ticket
must belong to current queued work or a current lookup; otherwise it finishes as
an explicit internal failure without charging a provider penalty. Structured
terminal results distinguish checkedAllowed, checkedBlocked, superseded, cancelled,
providerFailed, deferred and internalFailure. Legacy Phase values remain compatible;
the result/message distinguishes successful checking with denied access from a
failed provider. The observed rejected IP remains visible.

Events `manual_refresh_queued/joined/started/finished` carry ticket ID, generation,
bound lookup ID and available routing revision. Demand events record queue,
consumption or discard with fixed reasons. These are core-owned in protected and
Direct modes. Protected routing changes still close promptly; ordinary approved
observations stay open until a disallowed result or real path/runtime failure.
Direct joins physical cleanup, releases controls and uses native observation.
Feedback supersession alone never closes a gate, restarts a service or pauses a
provider. Source: `MonitoringEngine.swift`, `MimoManualRefresh.swift` and the
Refresh admission in `DaemonService.swift`.

Eleven new local controls retain ten before-change failures corrected and one
unchanged fallback baseline pass, across21 executions. Earlier passes were not
rerun after later refinements, and this is not an all-controls-on-final-source
claim. The final nil-admission source guard is reviewed/compiled separately.
Installed candidate `4263cf39` passed all four focused congestion cases: IPv4 and
dual-stack, each ending in rejected-IP Rule and clean Direct. Earlier accepted
tickets ended Superseded; final tickets matched their lookup/generation and fresh
IP timestamps. Each case issued two operation HTTP requests, retained 18/18
healthy settled samples, and had no provider penalty, repair loop or unexpected
settled check. Whole-case GUI communication, incoming SSH and measured protected
packet checks passed. These are production RPC tests, not native clicks; the two
health timings remain on earlier `d91336cb` and were not rerun. See
[manual-demand evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/manual-demand-regression.json)
and [installed evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-4263cf39.json).

A later user-authorized paired confirmation compiled all 11 controls on each VM
from the final frozen source (22/22 passed) and repeated both health timings,
four congestion cases and three named rapid sequences on that same candidate.
All 18 original runs completed: 12 passed, four retained product failures and
two unqualified setup/observation outcomes. One separately recorded failed-case
retry passed. The current implementation still has missing current PF receipts
after active/blocked native-policy mutations, and a Direct-born incoming TCP
session may lose reply delivery during protected verification. An active native
mutation also delayed Direct admission beyond one test's queue-setup bound.
These findings remained unfixed in that confirmation candidate; later corrections
and their separate limits are recorded at the beginning of this document.
See the [paired results and limits](MIMO_OBSERVATION_TEST_RESULTS.md). The campaign
changed only test log-persistence observation, not event scheduling, policy or
application deadlines.

The baseline [remaining-failure investigation](MIMO_REMAINING_FAILURE_INVESTIGATION.md)
defined 16 targeted tests and proposed native-maintenance ownership/receipt
events. At that stage the workflows were not implemented. They distinguish
ordinary Direct ingress tracking from full Stop/uninstall release, require
off-actor native transactions with under-lock ownership checks before epoch
mutation, and prohibit reconciliation from creating an exit-check loop. Preserve
the current full-guard expiry and validate real policy readback before receipt
adoption. Results are tracked separately from the completed paired confirmation.
All 16 new tests completed: six primary PF mechanism assertions and ten worker
controls (three passes, seven failures). The evidence confirms missing receipts,
pre-admission epoch side effects and actor lock contention; that baseline campaign
deployed no correction. Mechanism success includes reproducing broken continuity and
does not qualify a complete installed Direct/Rule/Global lifecycle.

Rapid-operation acceptance focuses on the final accepted intent, bounded/coalesced
checks, uninterrupted control responses, no stale approval or provider penalty,
no unexpected event loops, and usable Direct recovery. Transport teardown details
remain diagnostics. Genuine current-request failure or invalid fixture admission
is distinct from an intentionally cancelled old request. The existing transport
oracle and the proposed outcome-focused refinement are recorded separately in
[the observation report](MIMO_OBSERVATION_TEST_RESULTS.md); historical failed
attempts are retained rather than retrospectively rewritten.

## Background registration and health presentation revision — 26 November 2026

The existing labels com.mimo.supervisor, com.mimo.core and com.mimo.mihomo register
from /Library/LaunchDaemons with distinct LaunchHelpers executables named
mimo-core-supervisor, mimo-core-heartbeat and mihomo. Supervisor still owns the
core APIs/settings. Heartbeat has no network work. The engine launcher execs the
runtime engine; the canonical mimo-core utility has no job. Installer drains
writers before replacing paths and explicitly starts both peers before health
verification. Migration deletes old Application Support plists. Rollback restores
old/new paths and the previously loaded jobs. Full Stop/uninstall removes both
layouts and named helper copies under the existing maintenance fence.

Intentional engine Stop persists intent and disables its boot job before unloading;
Start/installation re-enables it. Supervisor repair enforces disabled state when
engine intent is off. Direct keeps peer supervision and incoming TCP tracking only.
These registration changes do not change protected approval or firewall policy.

The existing ten-second infrastructure worker also checks the engine's private
version/capability endpoint. It does not block the control executor or perform IP
verification. Dashboard engine and profile health use that actual check timestamp,
not the timestamp of a cached state response. A live PID with an unresponsive
controller is Unavailable. State changes log mimo_engine_health_changed. Expired
service evidence is Check overdue; missing communication is No connection or
Unconfirmed. Heartbeat labels likewise expire and reject invalid future timestamps.
Settings Maintenance status reads all three jobs; its Direct command goes through
the supervisor's authorized settings API. Page navigation/copying runs no commands.

The current source distinguishes checker completion, deferral, supersession and
failure. Ownership deferrals retry at 1, 2, then 4 seconds (capped); successful scans
return to the normal 10-second cadence. Probe/active/Direct/close/Stop physical
completion requests one coalesced1-second health-only reconciliation. It does not
request exit-IP verification merely because a scan deferred. A genuine persistent
failure triggers one failure episode per current generation, avoiding a cycle in
which every failed scan closes and reschedules itself.

Health snapshots optionally carry the check identity/generation, outcome/reason,
actual component observation times and completion time. An in-progress/pending
label cannot replace an overdue 35-second observation, real failure or missing
communication. Full guard observations and narrow policy receipts remain distinct:
existing grant/Direct PF readbacks capture their epoch, state and policy digest;
they do not renew the full baseline timestamp. Effective PF freshness uses the
older required observation, and receipts must match the current scope. A scan
that exits before launchd observation preserves its prior real history. Heartbeat
has its own evidence. Superseded checks cannot adopt old records as fresh results.

New local health evidence records17 distinct passing histories across source
revisions, including the original deferred-scan failure and later ownership/loop
failures. Only newly failed and new controls were executed after each correction;
there is no17-on-final-binary claim. See
`Tests/MimoServiceTests/InfrastructureHealth/` and
[the scope-preserving evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/infrastructure-health-reconciliation.json).
The original installed intermittent boolean health failure still lacks component
causal proof; local mechanism reproduction does not resolve it by itself.

In settled blocked Rule/Global, the native transport check inspects under the PF
mutation lock but stamps its epoch only if a rule write is needed. An unchanged
inspection does not invalidate the concurrent infrastructure snapshot or trigger
verification. Real updates stamp before writing, keep exclusion through readback,
and still make overlapping health scans defer. A failed write leaves the changed
epoch in place, so it cannot masquerade as the previously inspected policy.
Direct does not run this blocked transport path. The installed regression compares
epoch changes with actual transport-update events during a 35-second denial.

## Sources and validation

**User-command acceptance extension (2026-11-26, pending):**
[SC01–SC14](MIMO_DUALSTACK_TEST_PLAN.md#user-service-command-and-supervision-matrix)
require Start/Stop/Restart/Reload, full deactivation/activation and concurrency
tests with complete command/progress/terminal log reconciliation. Record native
clicks separately from backend RPC and lifecycle CLI calls. Include both Direct
and protected modes, no watchdog resurrection after intentional removal, and
late-reply/repair races. The existing results below cover only their recorded
operations and artifacts, not every case in this expanded matrix.

**Named-service/status qualification (2026-11-26):** latest outcomes for 64
distinct installed checks pass, including controller-unresponsive reporting,
peer recovery, two reboot paths, lifecycle removal/restoration and maintenance
navigation. Thirty settled windows passed. Two pre-fix failures are retained;
the final conditional-write artifact passed 27 follow-up checks with no
unexplained blocked-state epoch churn. These counts and the earlier transient
connection-probe limitations are scoped in
[core infrastructure qualification](MIMO_CORE_INFRASTRUCTURE.md#qualification-completed--26-november-2026).
Reading dashboard/status/logs remained separate from verification and repair.

**Prior two-peer qualification (2026-11-26):** 77 unique installed checks passed,
including 26 settled windows with advancing health and no unexpected checks,
gate cycles, peer repairs or errors. Full lifecycle windows also reject peer
repair during deliberate removal. A real startup rate limit was qualified only
after exactly one provider pause/rotation and subsequent success; the quiet
window criteria were unchanged. See the [fault harness](../Tests/MihomoRuntimeTests/v3_peer_supervision_test.py)
and [results, reproduced failures and limits](MIMO_CORE_INFRASTRUCTURE.md).

**Historical pre-guard qualification exceptions (2026-11-25):** active empty PF permits a
short native-fallback interval after engine termination or a newly installed
native route. The contained installed campaign measured public test attempts
before the temporary deny became effective. V12/V13 recovery must not be read as
an instantaneous packet guarantee. A resumed core also remained safely Blocked
after heartbeat expiry in the corrected 100-second recovery test; that historical
candidate did not qualify automatic reverification for the path. Its liveness
closure did not set the retry flag used by audit recovery. The current two-peer
implementation retires that lease; its independent qualification is recorded in
[core infrastructure validation](MIMO_CORE_INFRASTRUCTURE.md). For the earlier
packet-policy findings, see
[closure evidence and remaining work](MIMO_V3_QUALIFICATION_CLOSURE.md).

- [Canonical profile](../Sources/MimoShared/MihomoProfile.swift),
  [traffic family and IPv4 approval receipt](../Sources/MimoShared/MimoNetworkFamily.swift),
  [engine patch](../Patches/mihomo-1.19.34-v3.patch).
- [Coordinator](../Sources/MimoService/MimoCoordinator.swift),
  [supervisor](../Sources/MimoService/MimoSupervisor.swift),
  [runtime](../Sources/MimoService/MimoSystemRuntime.swift),
  [PF lock](../Sources/MimoService/MimoFirewallLock.swift),
  [peer watchdog](../Sources/MimoService/MimoPeerWatchdog.swift),
  [bounded guard helper](../Sources/MimoDaemon/pf-guard.pl).
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
