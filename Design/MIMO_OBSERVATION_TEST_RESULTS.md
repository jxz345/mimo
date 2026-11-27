# Exit-IP observation qualification — 27 November 2026

## Authorized two-VM confirmation — complete

The user requested the 11 local controls and five focused cases be rerun on
`mimo-vm`, then added three relevant prior successes and asked for both VMs.
The new scope is **11 local controls and eight installed cases/nine runs per VM**:
22 local-control executions and 18 installed runs overall. Historical results
below remain unchanged; they are not counted as executions in this new round.
See [the exact confirmation plan](MIMO_DUALSTACK_TEST_PLAN.md#authorized-confirmation-on-both-vms--27-november-2026).

All **22/22 isolated controls passed**, 11 in each VM, compiled from the exact
final candidate source. This replaces the earlier cross-revision local limitation
for these 11 controls; it does not qualify installed behavior. See
[two-VM local evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/manual-demand-two-vms-4263cf39.json).

Runtime status: **18/18 planned runs completed: twelve qualifying passes, four
product failures and two unqualified setup/observation failures**. Primary's nine
first attempts contain five passes, two product failures and two unqualified
results; worker's nine contain seven passes and two product failures. One separate
primary failed-case retry passed, making **19 actual runtime attempts: thirteen
passes and six preserved nonpasses**. This is completed testing, not full passing
qualification. See the
[primary ledger](../Tests/MihomoRuntimeTests/Evidence/v3/observations/primary-confirmation-4263cf39.json)
and [worker ledger](../Tests/MihomoRuntimeTests/Evidence/v3/observations/worker-confirmation-4263cf39.json),
with an [independent worker audit](../Tests/MihomoRuntimeTests/Evidence/v3/observations/worker-confirmation-audit-4263cf39.json).

| Planned runtime run | Primary first attempt | Worker |
| --- | --- | --- |
| Approved dual-stack Global → Rule, early health timing | Failed incoming SSH | Failed PF receipt and incoming SSH |
| Approved dual-stack Global → Rule, late health timing | Passed | Failed PF receipt and incoming SSH |
| Queued IPv4 → rejected Rule | Failed PF health receipt | Passed |
| Queued IPv4 → Direct | Unqualified queue setup | Passed |
| Queued dual-stack → rejected Rule | Unqualified log snapshot; separate retry passed | Passed |
| Queued dual-stack → Direct | Passed | Passed |
| Rapid IPv4 Rule → Direct, rejected exit | Passed | Passed |
| Rapid IPv4 Global → Direct, proxy down | Passed | Passed |
| Rapid dual-stack Rule → Direct, approved exit | Passed | Passed |

Primary's early health-timing run passed its Mimo, GUI
and 18 settled health assertions, but one fresh SSH session timed out after five
seconds. It authenticated in 64 ms while Direct was active, just before Rule
closure; the persistent SSH session continued. The late health-timing run passed.
The failure is preserved, not waived by that later pass.

The IPv4/rejected-Rule congestion run completed queue and final-ticket assertions,
including a fresh displayed rejected IP, but one settled health sample reported
PF Unknown after a live native-transport policy update. Its health evidence was
only 12.15 seconds old: the update changed the policy epoch without publishing a
matching narrow health receipt. The next full scan restored Healthy; the provider
stayed ready. GUI, incoming SSH and protected-packet checks passed. See the
[preserved health gap](../Tests/MihomoRuntimeTests/Evidence/v3/observations/primary-native-health-gap-4263cf39.json).

The IPv4/latest-Direct run failed its queue-setup precondition: Direct admission
did not start within the unchanged 1.2-second deadline while the test's PF-lock
hold overlapped an active native-policy update. Source correlation identifies a
synchronous policy mutation on the supervisor actor. No queued-mode requests
were submitted, so their behavior is unqualified. Maximum sampled state latency
was 2.19 seconds, below the separate 3-second communication limit; communication,
incoming SSH, packet checks and Direct cleanup passed. See the
[preserved setup failure](../Tests/MihomoRuntimeTests/Evidence/v3/observations/primary-active-native-contention-4263cf39.json).

The dual-stack/rejected-Rule congestion run stopped at its immediate log-based
queue oracle. Independently reviewed retained records show the intended final
Rule revision and applied reply, with exactly one corresponding commit. The
test reads disk immediately after RPC completion while logging drains
asynchronously, so visibility timing is a plausible cause; the exact failed
input snapshot was not retained and that cause cannot be proved retrospectively.
No wrong queue outcome is demonstrated. The case remains unqualified because
final Refresh and settling did not run. See the
[preserved observation failure](../Tests/MihomoRuntimeTests/Evidence/v3/observations/primary-queue-log-visibility-4263cf39.json).
A harness-only correction is now implemented: wait boundedly for absent terminal
log persistence, preserve exact first/final inputs, and reject wrong, duplicate
or late owned records. The existing strict queue oracle is unchanged; the wrapper
also rejects an extra wrong-mode commit for a request that already has one correct
commit. A three-second read-only synchronization bound changes no application,
queue-setup, health or recovery deadline. Operation attribution ends at RPC join;
later owned records cannot supply missing proof, and a final audit after settling
detects late duplicates. The app remains frozen. One retry of this failed case
passed with its own harness identity; it does not replace the original result.
See the [separate retry ledger](../Tests/MihomoRuntimeTests/Evidence/v3/observations/primary-confirmation-retry-4263cf39.json).
Primary therefore has passing evidence for **six of nine planned runtime checks
across ten attempts**, with two product failures and one queue-setup qualification
gap remaining. The original nine-attempt table above is unchanged.

The retry completed all queue, supersession, revision-barrier and final Refresh
checks, then 18 healthy settled samples. The final rejected-IP result matched its
actual lookup and fresh displayed-IP timestamp. Two HTTP requests each belonged
to one lookup, GUI and fresh/persistent SSH checks passed, and no native attempt
occurred after confirmed protection. Maximum health age was 13.74 seconds and
sampled state latency 1.11 seconds. All three queue-input snapshots were archived;
the collector succeeded on its first read, so this run does not retrospectively
prove the original log-visibility race. No previously passing case was repeated.

Ten deterministic support controls have passing histories across 12 executions,
including two fail-first corrections. These are separate from the 22 compiled
VM controls. The first nine were not rerun after the final duplicate guard;
portable imports and process-sequence ordering then received AST validation.
See [support evidence and source boundaries](../Tests/MihomoRuntimeTests/Evidence/v3/observations/queue-log-visibility-controls.json).

The separate paired diagnostic completed two checks: Direct-born SSH failed to
receive a server-generated reply during confirmed verification/blocking and
received it only after approval, about 7.9 seconds after send. Its exact tuple
had no PF state before or after closure. The protected-born control retained an
inbound state and received its reply in about 0.6 ms while still checking. Both
routes stayed on en0. This confirms reply suppression across the transition;
source inspection explains that Direct has an empty policy and new inbound state
creation is restricted to initial SYNs. Existing protected-born inbound states
are preserved. These two diagnostics are separate from the 18 planned runs.

No production changes were made. Host BPF capture was unavailable; guest pktap's
192-byte snaplen truncated tuple headers, so no tuple-level packet attribution is
claimed from those captures. The state/phase/server-generation/client-receipt
proof is retained. The named matrix finished on the frozen candidate with every
FAIL and strict oracle retained. Worker local controls completed in isolation.
During worker setup, user-assisted Tailscale logout kept its VPN and automatic
connection off on normal NAT. The user installed the local fixture
certificate and its trust was verified. The user ran the guarded reset: copied
machine keys, group-container state, system state, caches and account preferences
are absent. The reset's incomplete result is retained because macOS kept the
share-extension container shell; read-only inspection found only container-manager
metadata and standard sandbox links, with no application data or traversal errors.
This qualifies an identity reset, not a full Tailscale uninstall. After reboot,
trust and clock checks passed. The first bounded status query initialized fresh
keys/state; `Stopped` with a `Self` object initially caused a conservative stop,
but zero assigned Tailnet IPs and no current tailnet show that this was not proof
of copied authentication. Fresh keys were preserved for the user's fresh login.
Authenticated identity and fixture preflight were verified before all nine runs.
The user connected the worker; its authenticated backend reported Running,
online, a node identity and assigned Tailnet addresses. A later reboot invalidated
the earlier helper PIDs, so native TLS/DNS/caffeine fixtures were renewed
before installation. Resolver inode/content/owner/mode still matched the ownership
journal despite a changed APFS device identifier; that discrepancy is retained.
The corrected harness manifest is verified, and the worker/primary identity
comparison remains private. Their authenticated node identities and Tailnet
addresses are distinct. Exact candidate installation, retained settings, healthy
Direct, connected GUI and renewed fixture ownership were verified before testing.
App/core absence was not a clean-preference baseline: initialized preferences
were preserved rather than reset. This does not qualify a clean-preference install.

Worker's early health run had two PF Unknown/current=false samples among 18
settled Rule/active observations, at ages 10.48 and 12.79 seconds. Both followed
active native-policy updates; a full scan restored current evidence. This extends
the missing-receipt finding to the active update path. The persistent SSH session
began during Direct and ended during later closure before approval; fresh SSH
checks passed. Timing is strongly consistent with the previously proven inbound
state gap, but this worker run has no per-tuple PF capture to prove that mechanism.
GUI and transport checks passed, and the provider stayed ready. No additional
primary follow-ups were added after the user prioritized finishing this scope.
Worker's late health timing also failed the same classes: four of 18 settled
samples had PF Unknown after active policy updates. A fresh SSH attempt began in
Direct and crossed closure before timing out; the existing protected-born
persistent connection survived. GUI communication, provider readiness and
transport assertions passed. These are preserved failures, not missing-evidence
passes; the independent audit verified both archives without finding evidence
gaps. The other seven worker runs passed, including all four congestion cases.
Each congestion case retained 18/18 healthy settled observations, final manual
ticket ownership, fresh approved/rejected IP feedback, incoming SSH and GUI
communication checks, with no measured native attempt after confirmed protection.
The three rapid mixed-mode cases have no dedicated packet oracle; their passing
results do not extend the measured packet claim to those sequences.

Worker's proxy-down case contains expected setup errors before its rapid-operation
window. Lookup `0827E699…` failed and closed its own generation 82/revision 608 at
16:45:43 UTC, before the rapid cursor at 16:45:47.819. Fresh Direct lookup
`9720C4A8…` succeeded and the matching manual request ended Checked/Allowed at
16:46:06.240/.241. The independent audit initially applied an overbroad whole-case
zero-error check; it retained that discrepancy and correlated these events to the
deliberate fault. A separate timestamp journal for the fixture toggle was not
retained. This is an expected current-request failure and recovery, not a new
product defect or an unexplained aborted request.

All nine worker archives were independently verified. The 146 staged harness
files and 126 frozen production inputs matched their recorded identities.
Worker evidence archival and cleanup passed. The 314-file whole-scope archive,
all case archives and complete SSH observer histories remain private on Delta.
Original settings/routing/hosts were restored, six owned resolver files removed,
and all owned guest/host fixtures and SSH observers stopped. Tailscale logout
was confirmed by NeedsLogin, no assigned addresses/current tailnet and a
disconnected VPN. Only the exact temporary `mimo-observation-worker` was stopped
and deleted. Primary remains running; the pre-existing backup remains stopped,
with both VM configurations unchanged by deletion. See
[worker cleanup and final inventory](../Tests/MihomoRuntimeTests/Evidence/v3/observations/worker-confirmation-cleanup-4263cf39.json).
Primary's saved settings, routing, hosts and service intent have
been restored; its candidate and trusted test certificate are retained.
Final primary readback confirmed healthy Direct, all saved service intents, no
Mimo native/LAB packet controls and the original resolver files. Owned primary
DNS/TLS/caffeine/capture resources, host fixtures, relay and SSH observers were
stopped after archival. Worker and the pre-existing backup were not changed by
that cleanup. Remaining product failures and the queue-setup gap prevent full
qualification even though all planned runtime attempts have finished.
See the [primary cleanup proof](../Tests/MihomoRuntimeTests/Evidence/v3/observations/primary-confirmation-cleanup-4263cf39.json).
The full archived observer history retains three failures among 1,014 fresh SSH
samples, including activity outside individual test windows. Per-run incoming
checks do not establish uninterrupted whole-campaign or Screen Sharing access.


## Prior completed worker qualification

Status: the approved focused follow-up is complete. **5/5 distinct VM cases
have passing evidence across nine actual attempts: six passes and three preserved
failures.** This is limited qualification, not a rerun of the original 113-case
campaign or a full release qualification.

The unpublished version 3.0/build 11 candidate `4263cf39` was installed only on
`mimo-observation-worker`. Its four congestion cases passed, starting with the
previously failed IPv4 Rule/rejected-IP case. The two passing health timings stay
bound to the earlier `d91336cb` artifact and were not rerun. Primary `mimo-vm`
remained unchanged. Results below use production RPCs with overlapping requests
and controlled PF-lock contention; they are not native button-click tests.

| Case on `4263cf39` | Result | Final Refresh | Settled health | Operation HTTP requests |
| --- | --- | --- | --- | ---: |
| IPv4, latest Rule with rejected IP | Pass | Checked/Blocked | 18/18 healthy | 2 |
| IPv4, latest Direct | Pass | Checked/Allowed | 18/18 healthy | 2 |
| Dual-stack, latest Rule with rejected IP | Pass | Checked/Blocked | 18/18 healthy | 2 |
| Dual-stack, latest Direct | Pass | Checked/Allowed | 18/18 healthy | 2 |

Each accepted earlier manual ticket terminated as Superseded. Every final ticket
matched its actual lookup and generation, with a fresh IP timestamp; denied cases
also matched the displayed blocking-IP timestamp. All four retained queue/edit
ordering, late older-intent rejection, whole-case GUI communication and incoming
SSH checks passed. Logs show zero runtime errors, provider penalties, service
repair/recovery events or unexpected settled checks. Maximum observed PF age was
20.52 seconds, below the unchanged 35-second expiry; maximum sampled core RPC
latency was 1.21 seconds. No native attempt occurred after confirmed protected
closure in the measured packet windows. Explicitly admitted Direct intervals are
recorded separately and permit native traffic.

The original five attempts on `d91336cb` remain two passing health timings, two
harness failures and one genuine stuck-feedback failure. The latter had a
successful lookup and correctly blocked Rule state, but an older manual ticket
remained Checking. The corrected attempt now terminates that ticket before the
later check; it does not erase the original failure. See the
[current focused evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-4263cf39.json)
and [preserved prior attempts](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-d91336cb.json).
Root independently verified the four new archive digests and raw outcome/health/
packet records without rerunning tests.

The congestion correction has 11 new local controls with passing history:
ten failures corrected and one unchanged provider-fallback baseline pass, across
21 executions. Only failed/new controls ran; earlier passes retain their source
identity. The final nil-ticket admission refinement was source-reviewed and
typechecked before the four installed tests, without rerunning earlier local
passes. Release compilation and packaged-app signature verification passed.
Packaging reported AppleDouble metadata; this remains an unpublished local
candidate, not a clean publication artifact. See
[manual-demand evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/manual-demand-regression.json)
and [the algorithm](MIMO_3_0_PLAN.md#approved-congestion-algorithm--request-ownership-through-control-holds).

Cleanup is complete. The temporary `mimo-observation-worker` was deleted after
owned DNS resolver files, guest/host fixtures and SSH observers were stopped and
archived. Primary `mimo-test-macos` remains running with its original `00f51db8`
core, exact settings/routing/hosts and healthy Direct state; the pre-existing
stopped backup was retained. The worker's inherited missing proxy UUID prevented
an exact routing-selection restoration before deletion; that mismatch is retained
in [the cleanup record](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-cleanup-4263cf39.json).
Historical SSH gaps/failures remain in the campaign archive; passing per-case
management checks do not establish uninterrupted whole-campaign connectivity or
Screen Sharing continuity. Test certificate trust on the primary is retained.
No release was published.

Earlier unpublished version3.0/build11 candidate `00f51db8` has **7/113 unique
cases executed: six qualifying passes and one unresolved intermittent failure**. The three failed-first sequences
passed individually: dual-stack Rule → Direct/rejected IP, IPv4 Rule →
Direct/allowed IP, and IPv4 Global → Direct/proxy down. The integrated service
gate passed8/8. Three further rapid sequences passed before the dual-stack
Global → Rule/allowed-IP sequence failed for an unstable final mode or health;
its transport and whole-case GUI audits passed. Two focused diagnostic retries
passed, but do not explain or erase the original failure. No production change
was made during those diagnostic retries. The subsequently approved source
correction and its local evidence are recorded below. Its later installed
qualification on `d91336cb` is summarized above; these older results keep their
original artifact scope.

The original health failure was one of18 settled samples; all18 stayed Rule,
active and ready. Its compact sample omitted individual health components.
The diagnostic-only harness now retains heartbeat, PF/launchd state, checkedAt
and age, with seven new controls passing and the 35-second threshold unchanged.
The two retries (runs `20261127T094316Z-fd30cce9` and
`20261127T094715Z-ce2e7628`) each had18 healthy samples; maximum infrastructure
ages were13.56 and13.36seconds. The second used a documented read-only start-phase
alignment after a successful scan. Source review found that deferred PF scans
retain the previous timestamp and then wait10seconds before retrying, which could
explain an aged health record; the missing original component data prevents a
confirmed diagnosis. Do not claim this intermittent failure fixed merely because
the latest two attempts passed. Raw failures, retries and source analysis remain
archived separately. All worker case drivers are stopped.

The user has now limited further execution to new or previously failed tests.
All previously successful reruns are paused pending explicit approval. Primary
installed the candidate and completed two support-only stages; **zero primary
counted cases (0/53)** started. Its driver stopped at the setup boundary, and
exact-baseline restoration and owned-fixture cleanup have completed. Primary is
healthy Direct with original settings/routing/hosts, owned DNS resolvers removed,
fixture listeners stopped and the approved certificate retained. The113-ID inventory
is retained for bookkeeping, not an active authorization to rerun all cases.

The completed focused VM scope was worker-only: four new pending-mode cases and
the original failed health sequence with two planned scan timings. The initial
six-attempt ceiling gained two harness corrections and one product correction,
ending at nine actual attempts. Neither passed health timing was repeated after
the congestion change. Repeated attempts do not add planned cases. All17 health, eight
queue,16 GUI/manual and nine issued-order local histories retain their tested
source revisions and do not constitute a complete final-binary suite.

The first `00f51db8` attempt remains recorded as FAIL, solely for
`clock_not_qualified`: its GUI audit passed, and its raw fixture evidence contains
one accepted ingress/request/response and zero rejected ingress events. Measured
host/guest clock-offset bounds shifted about12ms over62seconds. The corrected
oracle requires a common clock only when an actual rejected ingress needs
attribution. With an explicitly validated zero-rejection event list it records
clock proof as `not_required`, retains calibration diagnostics, and never reports
clock proof as passed. Provider/core/fixture validation still runs first; actual
rejections retain strict ownership and timing requirements. The new11 controls
failed before correction and pass11/11 after, with73 related controls passing.
The app binary did not change for the retry; the original failure is preserved.

Historical candidate `9940200f` stopped at1/91 attempted repetitions with one
failure, after two primary support stages and zero counted primary workflows.
Candidate `08f98afc` was installed on the worker but ran zero qualification cases;
the later shutdown/join fix produced `00f51db8`. No release has been published.

## Historical independent audit of seven `00f51db8` cases

Read-only evidence audit: **7/7 completed; six qualified passes and one unresolved
intermittent failure. No VM tests were rerun by this audit.** All seven use core
`00f51db8ff8690de4a47c8ea98ef6562820054da86011a71319ec621ce943e61` and overlapping
production RPCs (20 Refresh requests and four mode requests), not native clicks.
Archive digests, full retained reports and terminal records agree. Both actual
native and protected provider-path preflights succeeded in every case.

| Scenario | Whole-case GUI state samples / max RPC | Settled health samples | Qualified outcome |
| --- | --- | --- | --- |
| IPv4 Rule → Direct, allowed IP | 55 / 0.240s | 18/18 healthy | Pass |
| IPv4 Global → Rule, allowed IP | 52 / 0.428s | 18/18 healthy | Pass |
| IPv4 Rule → Direct, rejected IP | 58 / 0.436s | 18/18 healthy | Pass |
| IPv4 Global → Direct, proxy down | 60 / 0.241s | 18/18 healthy | Pass |
| Dual-stack Rule → Direct, allowed IP | 54 / 0.305s | 18/18 healthy | Pass |
| Dual-stack Global → Rule, allowed IP | 53 / 0.381s | 17/18 healthy | Unresolved intermittent failure |
| Dual-stack Rule → Direct, rejected IP | 56 / 0.612s | 18/18 healthy | Pass |

All seven preserved the connected GUI identity and log coverage through setup,
operations and the36-second settled window. Independent raw-event replay found
zero communication interruptions or GUI lifecycle changes. Each issued one or
two provider HTTP requests, with at most one HTTP request per lookup, zero
provider-pause events, zero fixture admission rejections and a successful latest
manual refresh. The original full reports retain the18 health assertions at
two-second intervals; they were recovered read-only after discovering that the
initial four-file archives omitted these samples. This is sampled qualification,
not a claim of continuous health or comprehensive packet-leakage coverage.

The unresolved case stayed Rule/active/ready for all18 samples. Only health sample
index1 was false. The original samples do not include individual heartbeat/PF/
launchd timestamps or ages, so they cannot identify the failed component. Two
diagnostic retries passed but did not reproduce that condition; the latest detailed
retry had a maximum infrastructure age of13.36seconds. Their raw PASS verdicts are
preserved as non-resolving diagnostic outcomes, while the original failing case
remains the qualifying result. No fix is inferred from these later passes.

The allowlisted audit and exact evidence digests are retained locally in
`.build/observation-parallel/seven-case-audit/seven-case-audit.json`. The immutable
`qualification-overlay-diagnostic-repeats.json` binds both diagnostic repeats to
the exact original case/artifact/evidence identity. It does not rewrite raw
reports or add planned cases.

Separate new local test inventory: **6/6 executed, five passes and one failure**,
with production unchanged. These isolate actual guard exit75 dispatch, supervisor
scheduling and status projection using controlled time and OS facts:

| New local scheduling case | Before-change result |
| --- | --- |
| Normal healthy cadence | Pass |
| Two discrete deferred checks | Fail: genuine health record becomes stale briefly |
| Recovery from an already stale record | Pass |
| Slow check with observation-start timestamp | Pass |
| Genuine infrastructure check failure | Pass |
| Sustained deferrals remain visibly stale | Pass |

In the failing local control, checks deferred at10–11s and21–22s, and the next
successful check ran32–36s. The unchanged record became stale at35.25–35.75s.
This establishes a reproducible scheduling mechanism to address in the design;
it does not establish the original VM sample's cause. Local evidence is retained
in `health-deferral-repro/before-01`. These six local controls are separate from
the113 installed-case inventory. The user subsequently approved the health and
rapid-operation corrections, restricting execution to new or previously failed
cases.

Health correction now has 17 distinct passing histories across revisions. The
first implementation controls passed 11/13 and exposed two further defects: an
inspection could adopt older evidence, and a persistent failure could repeatedly
close/reconcile. Only those two failures plus four new policy-receipt controls ran
next, passing 6/6. The earlier 11 passes were not rerun. Final typecheck and guard
syntax checks pass; a later narrow release-snapshot locking/history preservation
change was not represented as another17-case rerun. Full details and source scope
are in [infrastructure-health-reconciliation.json](../Tests/MihomoRuntimeTests/Evidence/v3/observations/infrastructure-health-reconciliation.json).

The source now retries transient ownership deferrals after 1/2/4 seconds, coalesces
one health-only reconciliation after physical transitions and keeps one genuine
failure episode per generation. Progress cannot renew PF/launchd observations.
Full PF checks and exact current-policy readbacks carry distinct scope; effective
freshness uses the older required evidence. Checking/pending cannot hide overdue,
failed or disconnected status. This repairs the reproduced mechanism without
assigning an unproven cause to the original installed boolean sample.

## Rapid-operation policy and current test contract

The installed `00f51db8` code audited above orders mutations through a bounded FIFO queue (32 tickets,
65-second wait limit). Mode-only requests are rebased onto the configuration that
exists when their turn arrives; proxy/family/settings edits retain revision
conflict checks. The final state must match the latest accepted routing request.
This does not implement a latest-intent mailbox or debounce: pending mode changes
may still perform intermediate transitions. See `DaemonService.swift:168` and
`MimoControlQueue.swift:11`.

The subsequently approved source correction replaces only contiguous pending
mode-only requests with the newest one. Other edits remain ordering barriers;
already-admitted operations finish and physically join. Applied, superseded and
cancelled controls have distinct ordinary response outcomes. An active Direct
release is not preempted; a later protected request closes traffic at admission,
without pretending the preceding authorized Direct window was blocked.

The new `RapidIntent` local suite ran 8 distinct baseline cases: four failed and
four passed. After correction, only the four failing cases reran and passed4/4:
final pending Direct, final pending Global, two-user shared pending intent and
normal caller cancellation. The four original passing controls (non-mode barrier,
read-only responsiveness, active Refresh sharing and joined single follow-up)
were not rerun. Evidence is in `rapid-intent/before-02` and
`rapid-intent/after-failed-only-01`. The suite uses production daemon/monitor/queue
code with isolated storage/client admission boundaries; it performs no privileged
network work and does not qualify the new behavior in an installed VM.

Additional GUI and manual-feedback regressions: **16/16 new cases executed;
13 failed before correction, three passed. Only those 13 failures were retested,
and all 13 now pass (29 executions total).** No previously passing control was
rerun. The ordinary outcome, legacy-message and invalidated-manual-without-new-click
controls retain their baseline source identity.

| New boundary | Before | Failed-only retest |
| --- | --- | --- |
| Second same-window mode, accurate pending/busy state, service/edit exclusion, 32-request cap | 4 failures | 4 passes |
| Older revision, older same-revision sequence, duplicate sequence, retired instance/old connection | 4 failures | 4 passes |
| Ordinary superseded/cancelled GUI outcome | Pass | Not rerun |
| Core state sequence and narrow mode rebasing over stale proxy/family snapshot | 2 failures | 2 passes |
| Legacy optional-field decoding | Pass | Not rerun |
| Old cancellation cannot terminate newer manual feedback | Failure | Pass |
| Old pending manual request without replacement reaches cancellation terminal | Pass | Not rerun |
| Applied acknowledgment with overtaken snapshot succeeds without GUI rollback | Failure | Pass |
| Old control error after replacement instance is ignored, even before reconnect | Failure | Pass |

The app controls compile production monitor/app code with only the external RPC
boundary substituted by held continuations. Service controls use real daemon
admission/storage and monitoring with isolated credentials/client boundaries.
They are method-level controls, not native click or installed network tests.
Immutable before/after results and source hashes are recorded in
`.build/observation-parallel/gui-intent/focused-validation.json`; the fail-first
source snapshot is `gui-intent/before-source`. No change is inferred to the seven
installed `00f51db8` outcomes above.

The client now keeps mode buttons usable while bounded mode-only requests wait,
while all unrelated editing remains gated until mutations finish. Explicit mode
intent preserves newer proxy/family configuration. Per-instance sequence ordering
and connection fences prevent delayed state rollback, without discarding a valid
applied acknowledgment. The manual-feedback correction changes ownership only;
Refresh scheduling/coalescing remains as previously described.

Independent RPC delivery-order follow-up: **9/9 new controls executed; six
failures and three passes before correction. Only the six failures were retested,
all six now pass (15 executions).** The cases cover reversed same-GUI delivery,
older packets replacing newer queued intents, independent GUI/authenticated-user
streams, unauthorized/invalid sequence poisoning, retention beyond the RPC
lifetime, capacity without eviction, and synchronous GUI issuance stamps.

Core now validates authorization and current narrow-mode/proxy validity before
tracking the authenticated UID+GUI stream. Older/duplicate sequences return
ordinary superseded outcomes before the pending queue. Cross-stream ordering
remains core arrival order. Tracking retains at most 128 streams for the process
lifetime, with no expiry/eviction; existing streams continue at capacity. A new
stream is rejected with an explicit background-service restart instruction.
Reopening the GUI alone does not recover a full core tracker. This is a deliberate
bounded-state limitation, not a silent request drop or provider failure.

The results preserve the earlier 17 health, eight rapid-queue and 16 GUI/manual
passing histories. They are cumulative across revisions, not one full suite on
the final source or installed artifact. The ordering follow-up performs no VM or
network changes. Before/after evidence remains under
`.build/observation-parallel/mode-intent-ordering/` with separate GUI and service
source identities; the
[sanitized issued-order evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/mode-intent-ordering.json)
records the exact scope and outcomes. No historical installed failure is waived
by these local passes.

Concurrent Refresh requests share the active lookup. An invalidating transition
keeps the old lookup slot until its cancellation unwinds and coalesces required
work into one follow-up. Cancellation must not charge a provider failure, publish
a stale approval or change a newer path. The coordinator checks the current
verification/observation and its supervisor acknowledgement before attributing a
real provider failure. Protected mutations request early denial; Direct cancels
protected ownership, joins physical operations, releases controls and only then
publishes active Direct. State and heartbeat reads remain independent of those
mutation waits. Sources: `MonitoringEngine.swift:448,625,765`,
`MimoCoordinator.swift:329`, and `MimoSupervisor.swift:291,673,845,975`.

The user clarified that a TLS connection aborted by its requesting caller is
normal during rapid operations. The proposed outcome-based harness revision will
separate accepted-provider cancellation diagnostics from actual fixture admission
failure. It must still fail an uncancelled current request, invalid SNI/Host,
provider penalties or late approval from cancelled work, unexplained checks/gate
loops, lost communication, overlapping physical owners, or failure to reach the
latest accepted final intent and recover. Native/protected preflight failures
remain hard failures: they are current requests and are not intentionally
cancelled. This is a proposed test-contract adjustment, not a production behavior
change or retrospective waiver. The presently running harness retains its strict
transport-attribution checks, and all historical failed attempts remain recorded.

## Reproduced before changes

`Tests/MimoServiceTests/mimo_coordinator_tests.swift` first established approved
Rule/IPv4, held a second provider response, and asserted that access stayed open.
The unmodified workflow failed with:

> observing an unchanged approved path must not block before the IP response

The failed run is retained locally in `.build/observation-before.log` (exit 133).
This is a deterministic reproduction, not a native UI or packet-level result.
The earlier native audit remains separate in `MIMO_REFRESH_EVENT_AUDIT.md`.

## Checking strategy

Run shared, app and service suites, including observation/provider errors, policy
edits in flight, denial, stale network/Direct results and actual timer callback
with a virtual clock. Build one local candidate, record hashes, install in
mimo-vm only, and use the trusted closed Delta proxy/provider fixture.

For Rule/Global × IPv4/dual: verify approved refresh, concurrent refresh, policy
retention/revocation/recovery, provider 503/429, network/proxy failure, and recovery.
Measure continuous TCP echo across open observations, unchanged PF closure epoch,
engine PID/profile, actual HTTP counts, rejected IP display, native bypass probes,
health freshness and incoming management responsiveness. Observe at least 35
seconds after each terminal result for unexpected checks, closures or repair loops.
Exercise native Refresh clicks separately from production RPC-driven cases.
Verify Direct remains available and restore the VM's original settings afterward.

The observation itself must not write PF. Independent infrastructure work can
update authenticated native-VPN UDP/HTTPS socket scopes. Record full before/after
rules privately; compare the closure epoch, engine/peer PIDs and every fixed guard
rule exactly. Accept a scope-only difference only for the precise root-owned
native-VPN rule forms and a corresponding `mimo_native_egress_updated` event.
An unexplained difference, closure, profile change or process replacement fails.

Fixture control must be independent of the intentionally blocked outbound path.
`v3_observation_control.py` carries authenticated local fixture commands through
an incoming SSH session to a loopback-only guest listener. It does not add a PF
exception or change SSH authorization. Incoming SSH is independently probed
throughout the campaign. The earlier attempt to use SSH port forwarding failed
because the qualification key disables forwarding; the stdin/stdout relay uses
its existing permitted session access.

A later control session established in released Direct timed out after protected
access was subsequently blocked, while fresh incoming SSH probes continued to
succeed. The fixture relay now reconnects with bounded, logged retries; it grants
no network exception. This is a separate existing-session continuity limitation,
not evidence that long-lived incoming sessions survive every Direct/protected
transition. Do not count fresh SSH success or a reconnect as uninterrupted
Screen Sharing/SSH. The exact packet/state cause remains to be isolated.

The broader fresh-SSH watcher has recorded twelve isolated failures outside the
deliberate clone/reboot window: six primary probes at 02:28:39, 05:28:37,
06:28:38, 07:28:39, 08:28:38 and 09:28:39 UTC, and six worker probes at 05:28:36,
06:28:35, 06:34:55, 07:28:36, 08:28:35 and 09:28:36 UTC. Primary timestamps record probe
completion; worker timestamps record probe start. Each subsequent poll succeeded.
Eleven failed near the three-second connection deadline; one reached the
five-second probe deadline. Existing long-lived SSH
sessions recorded no gap/restart during the overlapping window. The aligned
failures on both VMs may involve their shared host path. Subsequent read-only host
events show the published host installation still closes before its hourly check:
PF denial at 05:28:34.663 through reopening at 05:28:41.946 UTC, and
06:28:34.651 through 06:28:38.097 overlap both VMs' failed fresh-SSH probes.
The subsequent 07:28 host closure, ending at 07:28:40.597, also overlaps both
new failures in that hour. The 08:28 host deny barrier completed at
08:28:34.645 and traffic reopened at 08:28:38.078, overlapping the primary
probe interval 08:28:35.634–38.654 and worker interval 08:28:35.685–38.741.
The 09:28 deny barrier completed at 09:28:34.892 and reopening at 09:28:41.799
also overlap both failed probes (primary 09:28:36.666–39.697; worker
09:28:36.725–39.803).
This supports a shared-host-path explanation, but is not packet-level causal
proof. The worker's 06:34:55 failure has no corresponding full host closure and
remains unexplained. The allowlisted timing evidence is retained locally in
`host-readonly/timing-correlation-sanitized.json`; no host settings were changed.
The watchers did not retain enough error/packet evidence to establish all causes.
These failures are
not waived or labelled as product defects; uninterrupted new incoming connections
are not qualified by this campaign.

### Rapid user operations (added at the user's request)

Run twelve overlapping Refresh requests at 80 ms spacing on each approved
Rule/Global × IPv4/dual path. A held provider reply makes overlap deterministic:
expect one HTTP lookup, uninterrupted permitted traffic, no gate/profile/service
mutation and at least 35 quiet seconds afterward.

Then mix twenty Refresh requests with Direct → Global → Rule changes and a final
explicit selection, at 80–120 ms launch spacing. Test both families, ending in
Rule and Direct; repeat Direct recovery from rejected-IP and proxy-down states.
Mode-only controls must serialize without revision conflicts, obsolete checks
must be cancelled/fenced, and the last acknowledged intent must win. Bound
provider work to one request per accepted path cohort rather than one per click.
Require fresh final health, unchanged engine/peer identities, no unexpected
errors or checks for 36 settled seconds, and released network controls in Direct.
Keep command/lookup IDs and gate events for each sequence. These are overlapping
production RPC tests of the button actions; native clicks remain a distinct check.

The first sequences did not keep native Direct provider requests inside the
fixture. An attributed repeat exposed this: after Direct restored, a native
request received a real provider rate limit and could not meet the terminal-ready
assertion. This is an excluded fixture attempt, not a protected-path cancellation
failure. Earlier sequence results retain their workflow scope but do not qualify
closed-fixture native timing. All eight sequences must be repeated with stable
native resolver entries throughout the burst, as described below.

The first correction used an optional fixture-only provider TLS alias with strict
SNI/Host checks and separate native/proxy ingress. Local TLS/SOCKS tests passed,
but the actual core protected-path preflight did not. The pinned engine applies
`DefaultHosts`, then `Metadata.Pure()` clears the hostname; its later private-probe
admission check requires that hostname and rejects it before SOCKS. Changing the
hosts entry from loopback to another address would not fix this ordering.
Controller evidence confirmed authentication at the private listener without
outbound activity. The unsuccessful preflights remain fixture exclusions.

The replacement fixture therefore leaves `/etc/hosts` unchanged. Narrowly owned
`/etc/resolver` entries send only the supported provider names to a local DNS stub
for native Direct requests; the engine retains its existing closed DoH path.
Separate ingress records must prove a real core lookup through both routes before
measurement. Profiles, provider cooldowns and trust settings are unchanged.
This fixture adaptation does not fix or qualify the engine's hosts-file limitation.
The replacement passed 36 local DNS/TLS checks and 22 harness checks. Actual core
preflights then passed through both `native_relay` and `proxy_configured_dns`, with
one correlated lookup and fixture reply per path, unchanged original hosts bytes
and no rejected ingress. The original oracle reported all eight repetitions passed on
`798f4750174be30b8d0118120a8faed330d7b1a01c77fea705c5cb470c9f08e9`:
one to three HTTP requests per sequence, at most one per lookup, successful final
manual Refresh feedback, unchanged resolver/hosts checks and 36 quiet seconds.
Raw core/fixture evidence was archived before teardown. A later independent audit
found a GUI communication interruption in the dual-stack Rule → Direct rejected-IP
sequence; that attempt is now qualified as a failure, with its original passing
verdict retained. The other seven retain their original scope.

On the corrected `40872d29` candidate, the dual-stack rejected-IP rapid sequence
failed one assertion: the fixture recorded `proxy_configured_dns` rejection with
the broad reason `tls_or_transport`. Direct recovery, final Refresh and bounded HTTP
counts passed. The original quiet audit missed GUI communication events and cannot
establish communication health. The handler caught exceptions across
handshake, request read and response write under that same reason, so the saved
record cannot establish whether this was admission failure or interrupted TLS.
It occurred near SOCKS/DNS setup, before the later Direct cancellation; cancellation
must not be assumed to explain it. The failed attempt and raw logs are retained.
The strict diagnostic repeat also failed: an accepted provider SNI was followed
by `SSLEOFError` during the handshake, before any HTTP request. Its record lacked
wall-clock correlation, so cancellation is still not established as the cause.
The independent final sequence passed on the same production binary.

The fixture now records bounded phase, exception class/errno/SSL reason, accepted
SNI/Host flags, allowlisted provider name, connection identity and monotonic/UTC
times. Authenticated clock samples bound host/guest skew. Forty local transport
audit controls and 24 TLS/fixture-clock controls pass. The proposed narrow oracle
allows only a handshake EOF owned by a unique cancelled private lookup: a higher
generation must have superseded it, no old error/pause/approval may survive, a
different fresh lookup must succeed, and no HTTP may exist on that connection.
Actual SNI/Host rejection, unrelated or ambiguous transport errors, invalid clock
proof and missing ownership still fail. Preflights always require zero rejections.
These local controls do not retrospectively explain or waive failed VM attempts.

The `9940200f` failure exposed a missing ordering record: cancelling a task can
abort TLS before the later supervisor command is logged. The new diagnostic
records the exact active lookup and validated routing request **before** calling
cancel. A separate record proves successful persistence. The future transport
oracle accepts that earlier fence only when lookup/provider and monitor lifecycle
match, cancellation was not already requested, the unique request's command,
mode and revision match the commit, and a same-controller higher-generation
supervisor command carries that revision before the fresh request. Monitor and
supervisor generations are never equated. Clock bounds, actual cancellation,
no old error/pause/approval, unique HTTP ownership and successful fresh lookup
remain required. Missing commit, duplicate ownership or timing ambiguity fails.
Three of 33 new local controls failed before this extension; **33/33** pass after,
and **40/40** related controls for the changed helper still pass. This proves the
future evidence contract, not the cause of an earlier ambiguous abort. The next
installed action remains the failed worker case only, after the protected
preparation correction is validated and installed.

### Communication audit and qualification gap

The retained-log audit completed **3/3 checks**, examining 58 archived event members
(56 containing GUI events). It found six distinct `status_probe` disconnects in
four attempts, with no app/service lifecycle operation authorizing them. Reconnect
does not waive an interruption:

| Core | Sequence | Distinct disconnects | Qualification |
| --- | --- | ---: | --- |
| `798f4750` | dual Rule → Direct, rejected IP | 1 | Original pass retained; audit failure |
| `40872d29` | IPv4 Rule → Direct, allowed IP | 2 | Original pass retained; audit failure |
| `40872d29` | IPv4 Global → Direct, proxy down (setup included) | 2 | Original pass retained; audit failure |
| `40872d29` | dual Rule → Direct, rejected IP, diagnostic repeat | 1 | Original TLS failure plus communication failure |

Immutable local overlays match the exact guest evidence ID, core hash and planned
case, retaining archive/member digests and original verdicts. They do not rewrite
ledgers, add planned cases or change attempt ordering. The three latest failed
case IDs are `ipv4/rule-to-direct/allowed`,
`ipv4/global-to-direct/proxy-down` and `dual/rule-to-direct/denied`.

One diagnostic Direct teardown took 6.529 seconds on the supervisor's main actor
while the GUI's three-second state RPC timed out. Source and event timing point
to synchronous teardown starving state replies; an isolated fail-first
responsiveness reproduction and scoped correction are underway. This is separate
from the provider cancellation/approval fixes.

The primary workflow campaign retained 132 cumulative result rows without
`daemon_client` counts. Three available raw extracts contain no GUI events.
Absence from those extracts is not continuity proof. The workflow harness must
retain setup, operation and settled GUI/core/supervisor events, establish a live
GUI connection and stable PID before setup, and reject disconnection, lifecycle
changes or missing observation coverage. The 74 workflow cases need this evidence
on the corrected candidate; their existing functional outcomes remain historical.

The workflow oracle has a fail-first local reproduction using allowlisted events
from archived false pass `6064fa5dd01d4818939fb9abe19c9ed5`: the old `observe`
function accepted two info-level disconnects and also accepted absent GUI evidence
(two failures out of three controls, with the clean control passing). The revised
oracle passes all three original controls plus two preparation-retention/scoped-DNS
controls (5/5). Its shared connection/event/sampling helper
passes 28 controls, including preparation failure, timeout, process replacement,
quiet GUI, active-log loss and historical segment pruning. A quiet case may qualify without a new GUI event only
when an existing connected receipt, stable live GUI PID, bounded read-only state
RPC samples and complete active/new log inode/cursor coverage are all present. Slow process
inspection is measured separately from the three-second RPC deadline. The full
starting cursor still filters old records, but only the latest segment for each
live Mimo PID and every new/grown segment observed during the case require
continuity. Pruning an unrelated dead process's historical file is allowed;
losing required active/new bytes remains unqualified. Four additional reader
controls pass, including unlink after open and permission errors: only missing
files are skipped, opened handles use `fstat`, and the separate coverage oracle
still rejects missing required segments. Missing evidence is unqualified, not
proof of a product communication failure. Total local communication/reader
controls: **37/37**.

All 74 workflow IDs will be repeated, with dependent sequences kept together
across the two VMs. This replaces evidence under the same planned IDs and does
not expand the 113-case inventory. It is additional to the eight rapid sequences
and four verification preemptions planned on the responsiveness candidate.

### Responsiveness candidate: first installed result

Core `9940200f08416e0f8ee3aab9c8cccf22bec020186eb14e4d844518e73010c78d`
adds the joined Direct-cleanup correction. Its local validation passed 74 new
focused controls, 122 earlier ownership/attribution controls, the full service
suite and 242 shared tests. The isolated before/after evidence and its limits are
in [control-responsiveness-regression.json](../Tests/MihomoRuntimeTests/Evidence/v3/observations/control-responsiveness-regression.json).
These local results do not substitute for installed qualification.

The first worker dual-stack Rule → Direct rejected-IP rapid sequence failed:

- A read-only state sample during setup exceeded the three-second deadline
  (`TimeoutExpired`, 3.003 seconds, starting 08:21:50.211 UTC). The GUI log had no
  disconnect, but that does not waive the independent responsiveness failure.
- The provider fixture recorded an accepted-SNI handshake EOF. Clock calibration
  passed with 1.689 ms uncertainty. The converted EOF interval was
  08:22:04.101008–04.102697 UTC, preceding the logged core Direct command at
  04.115 and supervisor receipt at 04.116. The old lookup was later cancelled at
  04.128 and a fresh Direct lookup succeeded. The strict oracle correctly rejected
  this as `unique_cancelled_owner_not_proven`; the earlier cancellation initiation
  is not observable in the saved log. No inference about the missing initiation
  is used to turn this attempt into a pass.

Primary installation passed six stages, followed by ten baseline/GUI checks with
the exact original settings, routing and hosts preserved. Fixture selection and
Rule/IPv4 setup then passed their whole-case audits: two and 31 read-only samples,
respectively, with no disconnects or failed samples. The latter's maximum RPC
duration was 2.619925 seconds, close to the deadline. The primary stopped at the
next boundary before any of its 37 counted cases. Its fixture remains available
for diagnosis; no production source change or further test was made after the
pause. Both VMs' full raw evidence and per-case archive hashes are retained.

The successor campaign retains all **113 original planned IDs**. Primary owns
53 (37 workflows, 10 IPv4 packet cases, the actual five-minute timer and five
native Refresh clicks); worker owns 60 (37 workflows, 10 dual-stack packet cases,
the detector positive control, four verification preemptions and eight rapid
sequences). Primary also runs a support-only detector control; it adds no planned
case. The first worker actions are burst indices7,1,4 in separate invocations, with
failure stopping the sequence. These are three of the existing eight IDs. After
all three and the service gate pass, the remaining five use `--exclude 7,1,4`;
no repeated attempt increases the planned count.

The exact pre-successor breakdown is **0 new IDs,3 latest failures and110
provisional historical passes**. The110 comprise74 workflows,25 packet cases,
five native checks,one timer andfive rapid sequences. Two of the three failed
rapid IDs originally reported functional success but failed the independent GUI
communication audit; the third is the repeated raw failure on9940200f. Thus the
raw functional totals were112 pass/one fail before applying the communication
findings. The110 prior passes do not provide the new complete whole-case GUI
sampling proof. Repeating them would extend regression/coverage qualification,
not reproduce110 newly failing cases.

The complete-export gate requires an explicit candidate core hash and all 113
latest passing results on that hash, with archived whole-case GUI evidence.
Rapid sequences additionally need both controlled provider paths; native cases
need setup through actual click and settle in one audit, one manual lookup and
fresh successful feedback. Historical passes remain scoped to their own binaries
and never count as new-candidate passes. The timer wrapper restores its prior
interval on success or failure. Both VMs must retain their exact original backup,
fixture ownership and cleanup proofs; unexpected failures stop further actions.

The final00f51db8 source manifest passed the integrated service gate: **8/8
suite groups**, comprising the service binary and159 isolated controls
(28 approval ownership,52 Direct/control responsiveness,4 publication,15
cancellation diagnostics,32 protected preparation,20 protected I/O ownership
and8 observer ownership). The production manifest still matches the packaged
artifact. These are local controls, not additional VM cases.

### Counted installed campaign

The current plan contains **113 VM cases**: 8 mixed-operation bursts, 74
observation/policy/provider/recovery cases, 25 packet/fault cases (including a
positive detector control), 5 native UI checks and 1 installed timer cycle.
The original 109-case plan was extended by four initial-verification preemptions after
follow-up regression testing reproduced a separate stale-token failure race.
See the [case inventory](../Tests/MihomoRuntimeTests/Evidence/v3/observations/planned-cases.json).
Setup/cleanup, failed harness attempts, repeat investigations and local unit suites
are reported separately. Progress reports show executed cases against this total;
not-run or UI-blocked cases cannot count as passes.

### Parallel VM execution

At the user's request, Delta's 48 GiB RAM/18 logical CPUs host two concurrent
8 GiB/four-CPU macOS guests. `mimo-test-macos` remains the primary VM. A clean,
stopped clone, `mimo-observation-worker` (guest `mimo-vm-worker`), runs packet/fault
cases while the primary runs the remaining policy/provider matrix. The clone
first booted on a host-only network; its copied Tailscale connection was stopped
before joining the ordinary VM network. These clone cases do not qualify a
second live Tailnet node.

Each guest has its own fixture token/ports, provider state, root-private evidence,
hosts backup and native TLS relay. The worker control relay uses Tart's guest
channel; fresh incoming SSH is independently monitored. The existing approved CA
is reused. Neither fixture may change the other's provider/proxy fault state.
Guest evidence has unique IDs so repeating a failed case preserves its raw logs.
The packet assertions now require confirmed closure after injection, a fresh
matching verification/reopening, rejection of the old observation token, and
verified removal of the lab containment anchor. Dual observations retain an
independent pre-open IPv6 stream and require zero errors through the final joined
worker snapshot.

Temporary-worker deletion and fixture teardown are required at completion.
Primary settings/routing and exact hosts contents must be restored. The clone
creation/reboot interval is recorded separately from incoming-SSH failures during
test execution. Diagnostic-only core `73ab7093035472795d29cd6dcb83502cf4fdc5d5f030c3131ff82e511382209a`
has additional readiness logs; earlier candidate results retain their original hash.

The first worker detector attempt was setup-blocked: the cloned guest had no
`pflog0` capture interface. It did not exercise a product fault. The lab anchor
was verified empty, the partial capture was stopped, and the VM was restored.
The harness now closes a capture if a subsequent capture fails to initialize and
preserves a fixture proxy when its ID already exists in the saved original list.
After creating the guest-only capture interface, the positive detector control
passed. This failed setup remains separate from the planned qualification cases.
The primary clone/reboot interruption produced 50 failed fresh-SSH probes before
SSH recovered; it is recorded as deliberate maintenance, including boot time,
not included in the active-test continuity claim.

Two subsequent worker attempts were excluded before qualification: its cloned
hosts baseline still contained the exact qualification-only provider pin, causing
TLS failure during protected setup; later a real `screen_locked` event invalidated
an otherwise successful Refresh during the quiet audit. The inherited bytes and
failed evidence were archived. Only the owned hosts block was removed; provider
cooldowns were respected by explicitly selecting another eligible fixture
provider. A bounded `caffeinate` process prevents further idle-sleep contamination.
The rerun passed both IPv4 Rule Refresh and provider-failure packet cases.

### Direct transition diagnostic correction

On diagnostic core `73ab7093035472795d29cd6dcb83502cf4fdc5d5f030c3131ff82e511382209a`,
Rule/dual → Direct restored native access successfully at 04:31:50.472 UTC.
A pending readiness confirmation resumed 2 ms later and logged an error because
the protected resolver and receipt no longer matched. The supervisor's generation
fence correctly discarded that superseded result: no audit closure or recovery
loop followed, and all 35 seconds of health samples passed. The strict event audit
still failed the case on that misleading error-level diagnostic.

The correction makes primitive readback diagnostics informational
`mimo_readiness_probe_unavailable` events. Current-generation terminal failures
still close access and emit errors. No acceptance condition or enforcement changed.
Core `9da5a87493bb8bee0a794ea516ecd84f3522d7666194d05099349f6cd7629bb3` contains
this logging correction; shared tests (242), service tests and local packaging
passed. The installed Rule/dual → Direct retest passed on
`798f4750174be30b8d0118120a8faed330d7b1a01c77fea705c5cb470c9f08e9`,
including the strict settled-event audit. This does not resolve the earlier
intermittent active-path readiness failure.

### Installed periodic timer

On core `73ab7093035472795d29cd6dcb83502cf4fdc5d5f030c3131ff82e511382209a`,
the real five-minute timer passed in Global/dual-stack. The complete interval
followed a successful manual check. Exactly one `periodic` HTTP lookup occurred;
2,368 IPv4 and 2,353 IPv6 persistent echoes completed without interruption.
The guard and process identities stayed stable, native bypass was blocked, and
the 35-second settled audit passed. The timer was then returned to Never for the
remaining controlled tests. This is installed timer evidence, separate from the
virtual-clock unit test.

### Native dashboard Refresh checks

All five checks passed on core
`0b8310ccc29c1e06c9e0d45fa917456446d15aaf96184ef3eee4456ede9c1b55`.
Each used one actual dashboard button click through Screen Sharing, a five-second
held provider response and a 35-second settled audit. Every click produced exactly
one manual HTTP request, a fresh snapshot and successful manual-refresh feedback.
The UI retained its approval and displayed “Checking exit IP · traffic remains
allowed” on protected paths, then returned to its approved message.

| Mode / family | IPv4 echoes | IPv6 echoes | Stream errors |
| --- | ---: | ---: | ---: |
| Direct | Native access check | Not a protected-stream case | Not applicable |
| Rule / IPv4 | 519 | Not applicable | 0 |
| Global / IPv4 | 418 | Not applicable | 0 |
| Rule / dual-stack | 490 | 491 | 0 |
| Global / dual-stack | 438 | 435 | 0 |

All protected cases retained the complete PF readback and daemon identities,
blocked native bypass probes and emitted exactly one `observe` and one
`completeObservation`. Direct emitted neither supervisor command. Earlier attempts
with unavailable remote mouse input sent no HTTP and are excluded UI setup attempts;
they do not qualify the behavior. Reconnecting Screen Sharing restored usable
input before these five measured runs. These results do not prove uninterrupted
Screen Sharing through every fault or transition.

### Fault fixture isolation

The first measured IPv4 Rule engine-stall attempt closed PF after 3.09 seconds
and fenced the held observation, but failed the recovery deadline. Evidence then
showed the harness had left its 12-second provider delay enabled for the fresh
recovery request, equal to the provider client's request timeout. The old held
lookup was cancelled and did not create the cooldown; the fresh delayed request
timed out and did. This attempt is fixture-contaminated and cannot establish a
healthy-provider recovery defect. The corrected test must observe HTTP ingress
for the held lookup, restore zero delay for subsequent requests, and only then
inject the fault. It retains the first request's captured delay and requires
fresh approval after recovery. A passing rerun is required.

### Confirmed stale-error cooldown after an engine stall

The corrected worker test proved the held request entered the fixture, reset the
fixture delay to zero for all subsequent requests, and then stalled the engine.
On diagnostic core `73ab7093035472795d29cd6dcb83502cf4fdc5d5f030c3131ff82e511382209a`,
the observation began at 04:56:01.123 UTC. The engine was stopped from
04:56:04.518 to 04:56:18.679. Runtime failure was detected at 04:56:08.546;
confirmed packet closure followed at 04:56:09.339. The obsolete held request timed
out at 04:56:14.358 and incorrectly created a provider pause until 05:06:14.
Infrastructure recovery at 04:56:16.173 requested verification, but the provider
pause prevented a fresh HTTP request and approval. No native bypass or approval
from the held result occurred. This is a product failure, distinct from the
earlier fixture-delay confound.

The coordinator's old catch path rethrew a provider error even if the observation
had been invalidated. The correction requires a current task/generation/token,
the original approved result, and a supervisor acknowledgement of failure on
that same active path; it checks again after the asynchronous acknowledgement.
An obsolete error becomes cancellation without another gate close or provider
health/cooldown write. Intact-path provider errors keep their normal handling.

The focused regression executed 52 cases before production edits: 48 invalidated
requests wrongly propagated provider failure; four intact-provider controls were
correct. Four blocked cases also sent redundant closes. After the correction all
52 passed. Fourteen additional Direct/transition/close-acknowledgement cases
expanded the final focused suite to 66/66 passing, and the full service suite
passed. Fixed cancellation reason codes now distinguish stale generation/token,
superseded/unavailable acknowledgement and cancellation during closure.
The installed retest is described below. Private raw evidence is retained under worker run
`20261127T045543Z-28492995`, evidence ID `7ff0e3cd8ca94b13b18b89112baf7320`;
local before/after evidence is in the cancellation-regression artifact directory.

Installed retest on core
`0b8310ccc29c1e06c9e0d45fa917456446d15aaf96184ef3eee4456ede9c1b55`
passed the same worker Rule/IPv4 engine stall in 78.8 seconds. Confirmed closure
took 3.8463 seconds. The held request was cancelled without a provider pause or
late approval. The same engine resumed, and a fresh receipt reopened traffic.
The first repair attempt ran while the engine was still stopped and failed as an
infrastructure error without provider cooldown; the next recovery succeeded.
The subsequent 35-second audit found no unexpected work. Native escape probes
remained blocked and the lab containment anchor was removed. Evidence ID:
`1d93d91ddc474546b51e4eca9b435784`. Other mode/family cases remain separate.

### Initial-verification failure race found by follow-up review

A separate isolated regression then covered failure during an initial blocked
verification, rather than an observation of an approved path. Before any further
production change, 20 cases ran: all 16 invalidated-token cases incorrectly
propagated provider errors and issued another close; eight also destroyed a newer
verification token. Four genuine-current provider-failure controls were correct.
Both polled and not-yet-polled blocked/replacement states were tested in
Rule/Global × IPv4/dual. This is local fail-first evidence, not an installed fault
result. The old production snapshot and test output are retained under
`.build/observation-parallel/verification-gap/`.

The implemented correction qualifies a failed verification's close with its exact
token. The supervisor must atomically reject an obsolete token before changing
gate or recovery state. A separate heartbeat followed by an unconditional close
would leave a race and is insufficient. Core must also leave a replacement
request's generation/state untouched when that qualified close is rejected.
The tracked regression expanded to 28 cases by adding invalidation during the
close acknowledgement. Before the correction, 24 cases propagated the wrong
provider failure and sent redundant closes; 12 destroyed a replacement token.
Afterward all 28 passed, together with the 66 observation/Direct regressions and
the full service suite. Four installed initial-verification preemption cases passed
on core `798f4750174be30b8d0118120a8faed330d7b1a01c77fea705c5cb470c9f08e9`,
in addition to the original 109 cases. They hold
the first private request, then change traffic family using the real routing
command and require a newer receipt, old-request cancellation and healthy recovery.
This qualifies installed preemption, not reproduction of the exact unit-only race.

Three exploratory attempts are excluded and retained: an engine-stall/fixture-route
variant did not invalidate the token before HTTP completion; a process-identity
precondition rejected an unexpected helper executable before fault injection;
and a later attempt paused the heartbeat, which does not own the IP lookup.
The supervisor owns both the monitoring engine and routing policy, so the latter
attempt could not establish delayed coordinator delivery. No result from those
attempts is counted as a pass or as proof of a product failure. Temporary process,
route and lab-firewall changes were restored.

The primary's later provider-change repetition was excluded because its selected
provider already had a genuine rate-limit pause (04:57:05–05:07:05 UTC). It sent no
HTTP request and preserved healthy access; it did not satisfy the planned
healthy-provider precondition. The subsequent repetition on
`798f4750174be30b8d0118120a8faed330d7b1a01c77fea705c5cb470c9f08e9`
passed after an explicit healthy-provider eligibility preflight. The original
intermittent provider-change failure remains preserved; its cause was not
established by that passing repetition.

### Stale supervisor approval continuation — additional fail-first review

An independent review found that `.approve` called `acceptBaseline` immediately
after awaiting readiness, before checking whether its generation/token still owned
the path. A completed readiness task can return its receipt after cancellation.
If Direct or a replacement preparation runs before the suspended approval resumes,
confirmation of that old receipt fails. The generic error handler then revokes the
baseline and closes the newer path.

The faithful isolated test generated the actual supervisor control flow with
observable runtime side effects and no real PF, DNS or service operations. It kept
the readiness wrapper on MainActor and queued the intervening operation during its
synchronous completion tail; it did not add an await to the approval path. Across
Rule/Global × IPv4/dual, all eight Direct/replacement races failed before edits;
all eight current-success and cooperative-cancellation controls passed. Direct
became blocked and replacement tokens were destroyed. This is isolated supervisor
evidence, not an installed reproduction of the exact scheduling window.

An earlier harness incorrectly detached the readiness wrapper and also failed its
controls. Its results were rejected and preserved as invalid harness evidence.
Only the faithful 16-case run establishes this defect.

The implemented correction verifies task cancellation and generation/token
ownership after the readiness await and before baseline acceptance. Errors from
that await also need ownership checks before reaching generic failure closure.
Current failures retain fail-closed behavior. The expanded 28-case matrix adds
late errors after Direct/replacement and genuine-current readiness errors. Before
the fix, 16 cases failed and 12 controls passed; afterward all 28 passed. The full
service suite also passed. `mimo_approval_result_cancelled` records fixed reason
codes for discarded stale results/errors without exposing response bodies.

Repeat the four installed verification-preemption
and eight rapid-operation cases on the corrected artifact; they retain their
existing planned IDs and do not inflate the 113-case inventory.
The durable test is `Tests/MimoServiceTests/ApprovalOwnership/run.py`; it retains
the generated supervisor, instrumentation diff and source hashes alongside results.
[Sanitized before/after evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/approval-continuation-regression.json)
keeps all 28 cases and the excluded initial harness separate from VM coverage.
`Tests/MimoServiceTests/run.sh` invokes it after the ordinary service tests. That
combined entry point passed after integration. The corrected unpublished package
has core SHA256
`40872d29e08ccfcf6514970adab890d1ae33add78e21b3b3ffbd6de8fdfc98f6`;
its sealed app/package checks passed. Local build identity remains 3.0/build 11;
it is not a replacement for the published build 11 artifact.

## Local checks

- Shared XCTest: 242 tests passed (the first post-change shared run).
- App suite: passed, including a virtual-clock call through the real periodic
  callback, Never, failure/backoff and manual refresh outcomes.
- Service suite: passed after adding 16 provider-error observations, eight
  in-flight policy changes, 12 denial/network/Direct preemption cases, and
  same-path scheduler coalescing. Existing required-transition failure matrices
  still run; their lookups now explicitly request transition intent.
- A held-preparation regression also passes: saving a policy-only edit preserves
  the running preparation, then rejects its response under the latest policy.
  A second acceptance check after asynchronous readiness protects transition
  completion from a policy edit during that wait.

## VM results

All 113 planned IDs have executed across recorded candidates. Independent
communication auditing revised the latest qualification to 110 passes and three
failures; the primary workflow communication aspect remains unqualified pending
complete retained evidence and repetitions on the responsiveness correction.
Failures, exclusions and artifact identity remain attached to each attempt; a
later pass does not erase an earlier failure or prove its cause.

### Failure found by the installed settled-state audit

On candidate core `7bb3c4f4a89fe3146ce607623de1553012c393a606b219a3362376f2f51be9bf`,
Global/IPv4 policy repair approved successfully, then failed the 35-second audit:
`mimo_liveness_lost` reported `engineRunning=false`, closed access and triggered a
second lookup. Before/after engine PID was 47271; launchd reported one run and
“never exited.” The test failed on extra HTTP, unhealthy settled state and the
liveness error. It was not reclassified as an expected network event.

The frequent watchdog used a `launchctl print` result as a Boolean liveness test.
The exact failed query status was not logged, so timeout versus other query failure
cannot be established retrospectively. The correction checks the already-loaded
engine's live kernel PID/start identity, executable and UID/GID directly. Missing,
exited, replaced or changed-identity processes still fail. Controller responsiveness
and launchd/infrastructure audits remain required. New stage-specific diagnostics
identify kernel liveness failures. This correction requires a new local artifact
and rerunning the affected installed matrix; the earlier partial results remain
separate.

### Historical rapid mixed operations — limited native fixture scope

All eight overlapping RPC sequences passed: Rule → Direct and Global → Rule
from approval, plus Direct recovery from a rejected IP and a failed proxy, for
both IPv4 and dual-stack. Each sent 20 Refresh requests and four mode selections.
The sequences took 50–70 seconds including 36 settled seconds. Provider HTTP
counts were 1–3 per sequence, with one HTTP request per lookup. The final mode,
health, daemon identities and released Direct controls met the assertions, with
no unexplained work during the settled audit. Seven rows retain core hash
`acca5829e2ef571d16e543b5c125bc7accfaa12ab881ca10e2823b684808f6cb`;
the first row's installed hash was not retained and its artifact attribution is
unknown. Replacement runs retain their own hash without rewriting that history.
Six later runs additionally asserted
that the latest manual-refresh feedback reached `succeeded`; the first two rows
predate that assertion and do not qualify it independently.

[Sanitized sequence results](../Tests/MihomoRuntimeTests/Evidence/v3/observations/rapid-mixed-operations.json)
retain each scenario and request count. These exercise the same production
commands as the buttons, but are not native click evidence. Their native provider
traffic was not exclusively fixture-controlled; they do not qualify that scope.

### Provider-backoff and fixture corrections

The first installed HTTP 429 case correctly kept approved Rule/IPv4 traffic open.
The following test incorrectly expected recovery after a short `Retry-After`.
Mimo's documented minimum refusal pause is ten minutes; the test timed out with
zero HTTP and a deferred manual refresh while access remained active. The new
`paused-refresh` case requires that behavior. Cleanup now waits for released Direct
infrastructure without requiring a successful provider response, and its exact
settings/routing restoration passed while the provider was still paused.

An attempted alternate provider check in Direct reached the real provider and
received another refusal. Earlier Direct rows therefore qualify native routing
and control release, not exclusive use of the closed provider fixture. The rerun
pins provider names during Direct checks in the VM's backed-up hosts file to a loopback TLS relay
(`v3_observation_native.py`). It forwards only to the existing trusted Delta
fixture, preserving certificate verification. The original hosts contents are reinstated before protected-mode preparation so
the native stub cannot change mihomo's provider resolution. An initial setup with
the pins still present failed TLS and was restored; it is a fixture failure, not
a passing protected-path result. Protected requests use the authenticated proxy path. The original hosts bytes are restored afterward.
No provider cooldowns or quota counters are erased to accelerate the tests.

### Earlier settled-audit failures — causes remain unresolved

The same candidate later failed Global/IPv4 Direct-to-refused-proxy on one
settled-health sample. It made one HTTP request, remained blocked, and emitted no
unexpected error or retry loop. A repeat passed. The first harness did not retain
the failing health fields, so the cause remains unresolved; repeats are not a
reason to discard that failure. Subsequent tests retain status, heartbeat,
per-service health and infrastructure age for every unhealthy sample.

An explicit change from IPWhois to IPapi.co on the approved Global/IPv4 path
then failed the settled audit: `mimo_verification_audit_failed` closed the gate
and interrupted the persistent stream. The generic reason was “The final
profile, tunnel or protected DNS could not be confirmed.” Provider work itself
was one successful HTTP observation. The campaign stopped and restored Direct.
Additional diagnostics distinguish controller endpoint, DNS listener transport,
tunnel, route family, engine identity, profile comparison, protected resolver
and receipt confirmation; they record command status/booleans, never profile
contents, credentials or provider replies. The diagnostic candidate is not a
behavioral fix. Twelve diagnostic repetitions and the later provider-change
retest passed, but neither establishes the original failure's cause. Both original
incidents remain in the final evidence and are not claimed fixed.

### Primary VM restoration

The primary's final 28-case run passed on core
`798f4750174be30b8d0118120a8faed330d7b1a01c77fea705c5cb470c9f08e9`.
Its exact original settings, routing and hosts contents were restored; all eight
restoration assertions passed. The native TLS relay, control relay, fixture and
owned wake-prevention process were stopped. Six subsequent checks confirmed the
same restored files, healthy Direct state, released controls and removed test
control listener. The installed candidate remains available in mimo-vm. The
trusted test certificate is retained for future testing, as requested.

After the approval-continuation correction, the primary was updated again to
`40872d29e08ccfcf6514970adab890d1ae33add78e21b3b3ffbd6de8fdfc98f6`.
All six installation stages passed with an independent closed provider fixture.
The subsequent 35-second audit passed ten assertions: 16 healthy samples, stable
process identities, advancing progress counters, no unexpected check/gate events,
exact original settings/routing/hosts and released Direct controls. Maximum
state-request time was 0.233 seconds. Six final readback checks passed after the
new fixture processes stopped and its prior test manifest was restored. This
deployment smoke is separate from the 113 planned cases and adds no case count.
