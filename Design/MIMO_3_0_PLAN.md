# Mimo 3.0 implementation and qualification plan

Status: the original v3 implementation was approved on 2026-11-25. The
2026-11-26 IPv4 approval revision was **approved for both traffic settings**.
Implemented and installed in mimo-vm; the automated IPv4-approval matrix and
Direct/Stop/Start checks pass. Native blocked-Global navigation completed all six
Settings sections; the original intermittent slowdown and simultaneous two-account
navigation remain unqualified. Publication was subsequently requested and
completed as **3.0 build 11** on 2026-11-26. The final package passed 14 installed
Direct smoke checks; the public Homebrew download matched its signature, identity
and binary hashes. See the [release record](MIMO_V3_BUILD11_RELEASE_CHECKS.md).
Earlier candidate evidence below retains its original artifact scope.

The user approved the Delta design preview and authorized implementation, local
installation in mimo-vm and the relevant test campaigns. GitHub publication is
outside this instruction. Preview interactions remain design evidence only.

This file is the complete v3 design contract. Sections 6 and 7 define the firewall
and event workflows for implementation; earlier-version workflows are not
incorporated by reference. Historical documents and source files provide evidence
and refactoring context only. A material behavior change must be specified here.

## Incoming continuity and native-policy transactions — 28 November 2026

**Implemented and qualified for the declared 24-case VM scope in local candidate
`1942a60a`; not published.** The
first candidate `7601ffe3` passed the original 16 targeted checks and four new
race controls, but installed lifecycle check L1 failed before entering Rule:
ordinary Direct's `(self)` destination created no state for the established SSH
connection. The exact installed rule had evaluations without matching packets,
and Apple's `_pf/self` table was empty. A paired real-PF regression reproduced
that failure and created state with `(en0)`; this diagnoses the expression but
does not qualify a per-interface expression as the production solution. Preserve
both the failed installed attempt and the earlier, narrower mechanism passes in
[the before/after report](MIMO_REMAINING_FAILURE_INVESTIGATION.md).

The follow-up implementation uses a single `getifaddrs` inventory of literal local
IPv4/IPv6 host addresses, including link-local and temporary IPv6 addresses and
excluding Mimo's TUN. Canonicalize, deduplicate and sort a bounded set; reject an
invalid or unavailable snapshot rather than widening it to `any`, a network or
an unresolved hostname. Render one non-quick incoming TCP SYN rule per captured
address, with interface-bound state. A following loopback no-state rule prevents
local proxy/DNS sessions from inheriting permission. Rule generation and readback
must use the same captured inventory. Strict canonical prefix parsing plus exact
live equality with root-owned `guard.expected` establishes the committed scope;
labels alone, or a syntactically valid arbitrary host list, are not proof.

Ordinary Direct restores native routing and DNS and retains only that tracking
policy, without outgoing restrictions. Relevant address notifications coalesce
one owned off-actor reconciliation; the sequential watchdog supplies a fallback
inventory comparison. An unchanged inventory performs no PF mutation and renews
no health timestamp. A changed inventory uses the native-policy ownership,
close/mutation epoch and exact previous-readback checks before commit, then adopts
only a current receipt and requests health reconciliation. It must not close the
gate, reload the profile/DNS, check the exit IP or restart a service. Stop and
uninstall cancel/join this work and remove all Mimo rules/references and services;
ordinary Direct tracking is never accepted as full release.

Protected closure retains qualifying incoming states and revokes original
outgoing states. Sessions born before the first tracking install, or on a newly
added address before its prefix refresh completes, can remain untracked and need
a reconnect. No established-flow adoption, arbitrary UDP continuity, recovery
after state loss or interface migration is promised. Non-quick rules permit later
administrator vetoes; earlier non-quick rules still require ordering review.

Final qualification records **24/24 VM checks passed within their declared scope**:
six real-PF mechanisms, fourteen extracted native-policy controls, the paired
destination-expression regression and installed L1/L2/L3. The affected six plus
fourteen were revalidated against final source on primary after the temporary
worker was removed. These repetitions do not create new distinct cases. L1 kept
109/109 authenticated SSH echoes through Rule rejection/recovery, with 27 samples
and a clean 35-second settled-denial event audit. L2 removed all owned jobs,
rules/references, DNS and TUN through the real Stop backend, then Activate restored
the exact literal Direct policy and healthy services for 35 seconds. L3 passed
addition/removal of owned IPv4 and IPv6 loopback aliases with exactly two tracking
updates; the watchdog work joined, and the gate, profile, DNS and jobs were
unchanged with no exit-IP checks. The [installed evidence and cleanup record](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-installed-after-20261128.json)
retains all three results and the expected Stop/Activate communication notices.

Seven local Direct-maintenance controls, 27 focused shared checks, 45 guard-parser
controls, an 84-source Swift 6 typecheck and signed-package verification also
passed; they are separate from the VM denominator. Original product failures and
excluded harness attempts remain in the evidence. L1/L2/L3 use actual RPC/installer
backends, not native button clicks. This is scoped qualification, not a new release
or a claim of UDP, arbitrary pretracking-session or physical sleep coverage. L3
measures loopback-alias inventory reconciliation; it does not qualify a new TCP
connection to an alias, IPv6 ingress or interface/route migration.
Owned test resources and aliases were removed, original settings/routing/hosts
were restored, and primary remains healthy in Direct on the tested candidate.
The temporary worker is absent, the existing backup is preserved and stopped,
and the approved testing CA remains trusted.

Native maintenance remains one sequential watchdog operation, with no per-tick
task fan-out. Capture immutable gate/close/mutation/policy identity, probe native
facts off the actor, and validate that identity again before accepting either a
change or a no-op. Perform the complete bounded PF lock wait, ownership admission,
write and readback on the serial background queue. Check ownership before stamping
the mutation epoch, and recheck cancellation immediately before the PF command.
Close/Direct/new protected intent cancels old ownership promptly; conflicting
physical mutations join before completion. A successful readback returns an
immutable receipt; only a still-current actor owner may adopt it. Receipt adoption
requests one health-only reconciliation, never exit verification or provider pause.

Superseded reads/completions are cancellation, unchanged snapshots are silent,
and a typed lock-acquisition timeout defers to the next sequential watchdog turn.
Actual PF/readback failure remains a fault. These outcomes do not refresh health
age; the independent full PF/root/launchd observation still expires at 35 seconds.
The existing pending-health presentation retains the actual last-observed age.
Log changed-work ownership, stage, input/output epochs/digests and separate lock,
physical and adoption timing, without credentials or native address values.

## Proposed observation and transition workflows — 27 November 2026

**Status: implemented locally; VM qualification in progress on 27 November 2026.**
This approved revision supersedes unconditional blocking for observations in
sections 6/7. It has not been published. The
[qualification report](MIMO_OBSERVATION_TEST_RESULTS.md) separates local tests,
installed VM evidence, harness failures and remaining coverage.
The installed campaign inventories 113 cases, including rapid mixed user
operations. Its first sequential run stopped on an unexpected Global provider-change
runtime audit and retained an intermittent refused-proxy health failure. The current
diagnostic candidate is being qualified in parallel on two isolated 8 GiB/four-CPU
guests on Delta (48 GiB RAM): policy/provider cases on mimo-vm and packet/fault
cases on a temporary clone with Tailscale stopped. Each has independent fixtures
and evidence. The clone must be deleted afterward and mimo-vm restored. Stage-specific
readiness diagnostics precede any behavioral correction; neither earlier failure
is waived by a later successful run.
The [qualification report](MIMO_OBSERVATION_TEST_RESULTS.md) records five completed
native Refresh checks for this revision, with one request each. The earlier
[Refresh audit](MIMO_REFRESH_EVENT_AUDIT.md) retains its separate artifact scope.

### Problem and decision principle

Before this revision, every admitted Rule/Global lookup entered `prepare`, which closed the
application gate, cleaned up connections and validated the profile before the IP
request. Manual refresh, the periodic timer and an allowlist-only edit therefore
interrupt an otherwise unchanged, approved connection. The same provider-failure
callback also closed access, even when no routing change occurred.

Classify the **effect of an event**, not whether a person initiated it. Periodic
and manual checks observe the existing path; switching a proxy is user-initiated
but changes that path. Approval remains IPv4-based in both traffic families.
No IPv6 allowlist is introduced, and existing capture, proxy-only transport and
native incoming-service protections remain in force.

### Event contract

| Event | Before the IP request | Result / follow-up |
| --- | --- | --- |
| Periodic check, Refresh now, Retry; unchanged approved runtime | Keep the existing approved connection open. Use the existing authenticated private proxy probe. No PF rewrite, connection cleanup, TUN/DNS change or profile reload merely to observe IP. | Allowed: update observation and remain open. Disallowed: close immediately and display the rejected IP. |
| Provider selection/pool/token changes | Save monitoring configuration; preserve approved traffic if the network path is unchanged. Supersede obsolete provider work without restarting routing. | Perform one applicable observation; use the same result rules as above. |
| Allowlist edit that still permits the current verified IP | Persist the policy, retain current access and request one fresh observation. No profile reload. | Evaluate the answer against the latest committed allowlist. |
| Allowlist edit removes the current verified IP, including clearing the list | Revoke immediately before acknowledging the edit: the last accepted observation for this path is already disallowed. Do not wait for a provider to confirm the known policy denial. | Run a fresh private check while blocked; show the IP and exact reason. |
| Adding a previously rejected IP while already blocked | Preserve the block; do not manufacture temporary approval from an old result. | One fresh observation plus current runtime validation can reopen. |
| Direct → Rule/Global; Rule ↔ Global; changing active proxy/password or active traffic family | Close application outbound traffic immediately, then mutate/apply configuration and verify. | Open only after an allowed fresh IPv4 and current runtime validation. |
| Active Rule bypass edits; explicit profile reload; engine restart/replacement | Close before mutating the active path. | Apply once and verify once. Inactive proxy edits, future Direct family preferences and bypass edits in Global/Direct remain save-only. |
| Relevant route/interface/DNS/network change, system resume invalidating the path, engine loss or loss of protection | Close immediately, invalidate prior approval and any observation in flight. | Repair/reconcile and run one current verification. Unknown runtime integrity cannot qualify for the observation path. |
| An observation request while already blocked or without a valid approval | Keep blocked. Preserve a bounded private verification path; never open ordinary traffic just to probe. | A successful current approval may reopen. Failure remains blocked and retryable. |
| Selecting Direct or full Stop | Use the existing cancellation/native-release workflow. | Native networking is intentional; an IP-monitor failure must not acquire a gate. |
| GUI navigation/reconnect, display/widget updates, unchanged health inspection, irrelevant/same-value edits | No new exit-IP check and no gate change. | Publish state only. |

Incoming SSH, Screen Sharing and other server connections and their replies must
retain the established incoming-access policy in both open and blocked states.
Required native VPN transport remains available. “Blocked” continues to mean
application-initiated outbound access, not an incoming-service shutdown.

### Failures and races

For an observation on an unchanged, previously approved path, provider timeout,
rate limit, missing token or malformed response means **verification unavailable**,
not a new disallowed IP. Keep the last approval, timestamp it accurately and show
the error. Respect genuine provider cooldown/quota; explicit retry retains its
existing local-backoff rules. Do not use a provider error to clear a block or to
silently switch to native Direct. There is no new approval-expiry cutoff in this
proposal: a prolonged provider outage remains visible while last-approved routing
is intact. An expiry policy would be a separate behavior decision.

This continuity has a deliberate limit: a proxy can change its exit without a
local network event. Traffic may use that changed exit until the next successful
check detects denial. Keeping the path open during checks accepts this detection
window; it does not permit fallback outside the selected proxy. Existing Rule
bypasses remain intentional exceptions defined by the profile.

A real network/configuration event always takes precedence over an observation:
close immediately, advance the routing generation, cancel/discard the old result
and run one required transition verification. A late response cannot reopen the
gate, approve a different proxy/profile or overwrite a newer Direct/Stop request.
The same rule applies to failures: a timeout from an invalidated path must not
pause the provider or delay recovery. Require matching task/generation/token and
the original approved result, plus a supervisor acknowledgement of the failed
observation on that same active path. Recheck after the acknowledgement await;
an ignored, replaced, blocked or unavailable reply is cancellation. Do not send
another gate closure for that obsolete observation. Genuine intact-path provider
errors retain their normal cooldown and quota handling.

For initial blocked verification, qualify the failure-close with that verification
token. The supervisor checks it atomically before any closure or recovery mutation;
an old token cannot close or cancel its replacement. Advance core's generation
only after acceptance. A stale-token conflict is cancellation, not service
unavailability. Add four installed initial-verification preemption cases to the
matrix, covering Rule/Global and IPv4/dual-stack: hold the initial request in the
opposite traffic family, then select the requested final family. Require a new
generation and receipt, obsolete-request cancellation without provider cooldown,
blocked native escape probes and a quiet terminal audit. These extend the
109-case campaign to 113. The fail-first token-close race remains unit evidence;
the installed preemption cases do not claim to reproduce that exact timing race.
The supervisor's approval continuation needs the same ownership rule: after its
readiness await, check cancellation and the exact generation/token before accepting
a baseline. Qualify errors from that await before any generic close. A completed
readiness task can still return after cancellation; it cannot override a newer
Direct selection or preparation. An isolated faithful supervisor test reproduced
eight stale-continuation failures with eight passing controls. Retain that
fail-first evidence, then repeat the existing four installed preemptions and eight
rapid sequences on the correction without counting them as new planned cases.
Coalesce same-generation observations from multiple GUI accounts. Keep one
follow-up only when a distinct path change makes the first result obsolete.

Allowlist versions must be separate from routing generations. A list edit should
not reload a profile or invalidate the network path, but result acceptance must
atomically use the latest committed list. Removing the current IP during an
observation must revoke it immediately; a late result evaluated under an older
list cannot restore access. Existing settings revisions and authorization checks
still serialize multi-user edits.

### Implementation shape

1. Carry an explicit observation/transition intent through scheduler admission,
   queued/retry/fallback work, `MimoLookupClient`, coordinator and supervisor.
   Urgency governs scheduling; it must not implicitly decide traffic permission.
2. Split `MachineSettings.affectsVerification` into monitoring/policy/path effects.
   Preserve shared persistence and revision conflict handling, but remove the
   unconditional configuration closure for allowlist/provider/token-only edits.
   An unrelated save during a check must not promote itself to a path change or
   supersede preparation already in progress. Only known revocation sends an
   ordered policy mutation; completion reads the latest committed allowlist.
3. Add supervisor begin/complete operations for an observation. Admission needs a
   current previously approved runtime, no transition/repair pending, and matching
   network/profile/engine identity. Reuse the existing private probe listener and
   ACL. Do not call the current `permitPrivateProbe` on an open gate: it requires a
   closed gate and installs verification PF policy. Prove the private listener
   works under the active policy without widening its permissions.
4. Keep transition `prepare`/`approve` and confirmed gate closure for actual path
   changes and blocked recovery. Observation completion updates approval in place
   if allowed, or revokes under the same mutation/freshness fences if denied.
   It must not call an opening operation when traffic never closed.
5. Make coordinator failure handling and `requiredCheckUnavailable` intent-aware.
   Provider failure preserves only an intact prior approval; independent runtime
   integrity failure still closes. Health monitoring/peer repair remain owned by
   the supervisor and heartbeat, not by GUI clients.
6. Keep check activity separate from access state. Open observations display
   “Checking exit IP · traffic remains allowed”; errors display “Check failed ·
   using last approved result” with age. Only confirmed denial displays Blocked.
   Transition checks display “Checking exit IP · outbound traffic blocked.”
   Preserve the failed/rejected address and usable Retry/Direct actions.

### Scheduling and diagnostics

Schedule the periodic deadline from the last completed successful IP
observation, including a successful-but-disallowed result. A manual/user-triggered
check then resets the one-hour deadline. Failed attempts follow bounded retry and
provider availability rules instead of repeatedly pushing the periodic deadline
forward. Never disables periodic work only. Keep an in-flight manual request
joined to the current same-generation observation and do not add a timer follow-up.

Log trigger, intent, lookup/attempt IDs, routing generation, policy version,
admission decision, gate before/after, actual HTTP request count, completion,
coalescing/cancellation and next scheduled deadline. A gate change needs an
explicit cause (transition, policy denial or runtime failure). Log the failed
engine-health stage separately from IP-provider errors; the current audit exposed
an Unavailable health change without enough detail to establish its cause.
Keep rotation/caps and privacy controls; no tokens, credentials or unrestricted
raw state in exported evidence.

The installed audit found a false engine-loss event after Global policy repair:
the process had not exited, but its launchd-query Boolean was false. Keep that
failed trace. Use kernel PID/start/executable/credential identity for the frequent
engine-liveness watchdog, while preserving controller and launchd audits. Add
stage-specific failure logs and rerun the observation/fault matrix on the corrected
artifact; the earlier candidate's results cannot qualify this correction.

The worker engine-stall test also reproduced a distinct error-attribution race:
the supervisor closed the path, then its held HTTP request timed out before core
received the recovery event. The obsolete error paused the provider for ten
minutes and prevented fresh approval. The new failure fence must first fail its
regression tests on the old code, then pass locally and on both traffic families
in Rule/Global. Preserve the installed failed trace; assert no cooldown for the
invalidated lookup, confirmed packet closure, and a fresh recovery approval.

The rapid-operation audit subsequently found another qualification failure:
Direct teardown occupies core's control actor for longer than the GUI's
three-second read-only status deadline. The processes remain alive, but the GUI
loses communication during the operation. Preserve these installed failures and
first reproduce the scheduling problem with a failing control-endpoint test.
Move blocking teardown work away from status delivery while preserving serialized
network mutations, cancellation/epoch ownership and truthful transition status.
Do not qualify this by increasing the GUI timeout or renewing old health timestamps.
Retest the entire setup, operation and settled interval, including informational
disconnect events. Earlier summaries without GUI records do not prove continuity.

Use a short-lived fixed-path core worker for the existing Direct cleanup
transaction, rather than another launchd job. The supervisor retains ownership,
publishes the transition before waiting, and joins physical completion even when
the caller cancels. Serialize subsequent network mutations behind that join;
state/event reads remain available. The worker must reject maintenance and check
current parent identity, saved Direct intent/revision and the release epoch before
releasing controls. Failure must not manufacture a completed Direct receipt.
Test slow success, failure, caller cancellation, superseding protected/Direct/Stop
requests, parent loss and stale worker completion. This correction remains
unqualified until the installed whole-case communication audit passes.

**Implemented locally, installed qualification in progress:** candidate core
`9940200f08416e0f8ee3aab9c8cccf22bec020186eb14e4d844518e73010c78d`
adds the owned Direct worker without another persistent daemon. It commits the
Direct marker with empty PF under the release lock, rechecks ownership after
native verification, and joins owner-qualified failure closure on invalid results.
Service admission and power-fence waiting no longer occupy the status actor during
this path. Older infrastructure samples cannot overwrite the new state.

Fail-first controls reproduced four slow Direct status timeouts, four Stop
power-lock timeouts and stale marker publication. Final local validation passed
52 control-endpoint cases, 18 worker ownership/completion cases and four publication
cases, plus 122 prior race/attribution controls, the service suite and 242 shared
tests; [sanitized regression evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/control-responsiveness-regression.json)
retains the before/after results and source identities. The installed follow-up
repeats **91 existing cases**: primary `mimo-vm`
runs 37 workflow and five native UI cases; `mimo-observation-worker` runs 37
workflow, eight rapid-operation and four verification-preemption cases. These do
not enlarge the 113-case inventory. Retain setup, operation and settled GUI records
and stable process evidence in every repeat; do not infer continuity from silence.

There is no overall worker deadline; each existing child command remains bounded
and the supervisor always waits for physical completion. Startup/offline cleanup
and the combined protected-DNS-loss/power-contention path are outside this local
responsiveness qualification. No published binary has been replaced by this candidate.

**Installed follow-up stopped on a new failure:** the first worker repetition on
`9940200f` recorded a three-second status timeout during protected-mode setup.
Probe-policy installation took 1.358 seconds, followed by 2.472 seconds of
profile/DNS/private-probe work without an effective actor suspension. The GUI's
own poll missed that interval, so absence of a disconnect event did not make the
case pass. Primary setup separately passed with a 2.62-second maximum response.
Both partitions were paused: one of 91 repeats executed, zero qualified passes.
Reproduce protected preparation with a failing control-endpoint regression before
changing its scheduling. Keep physical mutation ownership, immediate failure
closure and stale-result fences; a larger timeout or a yield-only workaround does
not qualify slow individual operations.

The same worker repetition retained an unclassified TLS handshake EOF. It preceded
the recorded Direct command by 12–15 ms, while source shows task cancellation can
start before that log. Add a fixed, lookup-qualified cancellation-initiation event
before cancellation; future evidence must bind it to the later committed operation,
the exact cancelled lookup and a distinct fresh success. Preserve the historical
failure as unproven; do not widen timestamp tolerances to make it pass.

**Current execution priority (updated user direction, 27 November):** finish the
focused failure corrections, deploy them in the VMs, and then continue the
remaining tests. The 20 previously failing preparation controls, nine missing
cancellation-diagnostic controls and three attribution controls pass locally.
Additional commit-ownership and observer-ordering controls must finish before
packaging. Protected preparation uses immutable receipts on an owned serial
worker; cancellation revokes admission immediately but still joins physical work.
PF grants recheck current policy and ownership and compensate closed on a failed
commit. Profile loading and resolver installation share an observer window;
deferred notifications are classified with bounded, yielding replay.

Those focused controls now pass: 28 supervisor cases (20 reproduced failures,
four replacements and four pending-policy revocations), 20 transaction-ownership
cases and eight observer cases. Together with the nine cancellation-diagnostic
failures and three attribution failures, the focused correction is 68/68. The
portable suite passes 242/242. Maximum isolated control RPC latency on the final
28-case run was 7.68 ms; this is not an installed latency guarantee. See
[protected-preparation regression evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/protected-preparation-responsiveness.json).
The unpublished candidate core is
`00f51db8ff8690de4a47c8ea98ef6562820054da86011a71319ec621ce943e61`.
It retains local version 3.0/build 11 and has not replaced a published artifact.
Before VM cases began, four additional controls reproduced premature graceful
shutdown completion (0/4). The correction rejects new mutations while stopping
and joins protected closure, physical work and observer completion; the same
four controls now pass. The focused total is 72/72. This does not qualify forced
parent death while an external child is running.

The three failed bursts have now passed on the corrected binary: dual-stack
Rule → Direct rejected IP, IPv4 Rule → Direct allowed IP, and IPv4 Global → Direct
with the proxy down. Their setup, operation and settled communication evidence is
retained alongside earlier failures.

**Latest execution restriction (27 November): only new or previously failed
cases may run. Previously successful cases require explicit user approval before
any rerun.** Before this restriction took effect, four previous-pass rapid cases
also ran: three passed and one failed a settled health assertion. Only that new
failure may now be investigated/retested; no broad partition may resume
automatically when it passes. Primary installation/support setup completed without
starting a counted case. Restore the primary baseline and pause its campaign.
The inventory remains 113 distinct cases; support checks and repeated attempts do
not add cases. Historical passes and failures retain their artifact identities and
cannot qualify the new binary.

### Approved rapid-operation refinement — pending modes

Replace only a contiguous run of waiting mode-only intents with its newest intent.
Proxy/family/allowlist/credential writes remain ordering barriers with revision
checks. Preserve the bounded queue, mode rebasing and cross-account ownership.
Never cancel an already-admitted physical operation to accelerate a newer click.
In particular, complete and join an accepted Direct release before admitting a
pending protected request. Its authorized Direct interval remains real; protected
closure starts when that request is admitted, not merely when it is queued.

Return explicit ordinary `applied`, `superseded` or `cancelled` control outcomes.
Expected caller cancellation must not become a storage error or provider pause.
Keep the existing Refresh behavior: join the active lookup and retain at most one
required follow-up after an invalidating transition. That scheduler behavior was
already present and needs no new production change for this refinement.

Validation is restricted to new/failed cases. The new isolated rapid-intent suite
ran 8 baseline controls: four failed and four passed. Only the four failures were
retested after the queue correction and now pass4/4. The four baseline passes
remain under their original source identity and were not rerun. This is eight
distinct cases/twelve executions, not twelve newly planned cases. The separate health-deferral regression and its proposed repair
must not be presented as proof of the original VM sample's component or cause.
No broad113-case rerun or publication is authorized by this refinement.

The subsequent GUI review found that its settings-busy guard dropped further
mode clicks before core could coalesce them, and delayed replies could overwrite
newer state. Correct the narrow client boundaries: accept up to 32 waiting
mode-only RPCs, keep other edits/services serialized, send explicit `requestedMode`
and preserve latest proxy/family values when core admits it. Number snapshots
monotonically within a core instance; reject stale revisions/sequences, retired
instances and old connection-generation replies. An applied same-instance reply
remains successful when only its snapshot has been overtaken.

Refresh scheduling itself remains unchanged. Correct manual-feedback ownership
so a cancelled older lookup cannot cancel or finish a newer request; a valid
same-generation lookup may still answer a joined request. The 16 new local controls
produced 13 failures and three passes. Only the 13 failures were retested, all now
passing; no prior passing cases were rerun. Full source/evidence identities are
in `gui-intent/focused-validation.json`. This is local control qualification,
not native UI, packet, or installed-VM qualification.

### Issued mode ordering across independent RPC connections

Stamp each GUI's mode request synchronously before launching its RPC task, using
an optional stream UUID and increasing sequence. Core authenticates and validates
the narrow mode against current configuration/proxy before updating the UID+stream
high-water mark. Reject older/duplicate deliveries as ordinary `superseded`
before queue admission, so they cannot replace a newer pending mode. Distinct GUI
streams continue using core arrival order; active physical operations still join.

Retain stream history for the core process lifetime, including beyond the 75-second
RPC deadline. Bound it to 128 authenticated UID+stream entries without eviction or
expiry. At capacity, existing streams continue; new streams receive a distinct
recoverable error requiring dashboard background-service restart. Closing and
reopening only the GUI does not clear the core capacity. Legacy unstamped messages
remain readable but cannot claim issued-order protection.

Nine new controls ran: six failures and three passes before correction; only the
six failures were rerun and all passed.
[The issued-order evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/mode-intent-ordering.json)
retains before/after source identities. Preserve the earlier 17 health, eight queue
and 16 GUI/manual passing histories with their original source identities. Do not
claim all histories ran on the final binary. The earlier `d91336cb` worker candidate passed both planned health timings,
then exposed two harness errors and the genuine stuck-feedback defect in the
first pending-mode case. Those five attempts remain preserved. The congestion
candidate `4263cf39` then passed the failed-case retry and all three unstarted
cases: **5/5 distinct cases have passing evidence across nine attempts**, with
four congestion cases on the new artifact and the health case on the earlier
one. No previously passing case was rerun. See the
[current evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-4263cf39.json)
and [preserved failures](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-d91336cb.json).

### Approved congestion algorithm — request ownership through control holds

**Implemented and qualified in the four focused installed congestion cases.**
This supersedes the earlier assumption that generation-fencing completion alone
was enough.
The eight initial local controls all failed against preserved before-source in
`.build/observation-parallel/manual-demand/before-01`; production edits began only
after that run. Three concrete follow-up controls brought the inventory to 11:
ten reproduced failures corrected and one unchanged provider-fallback baseline
pass, across 21 executions. Passing controls were not rerun after later fixes.
The final nil-ticket admission guard was source-reviewed and compile-validated
before packaging; earlier local passes were not rerun on that refinement. The
four installed cases used the final source. Failed evidence is retained; primary
`mimo-vm` is unchanged. Only new/failed local cases, the failed installed case
and three unstarted cases ran. Neither
passed health timing nor historical passing suites were rerun.

The installed failure is specific: manual request `523AC6B2…` was queued at
12:37:45.377 UTC while control mutations held execution. Mode/allowlist commits
then advanced the lookup lifecycle. The final settings lookup `808360B2…`, in
lifecycle20, marked pending feedback Checking at12:37:50.628 and successfully
finished at12:37:55.177. Core was ready and Rule correctly blocked the rejected
IP, but the manual request had no terminal result after35seconds and remained
Checking in the later readback. This is stuck request feedback, not evidence of a
blocked HTTP request, paused provider or frozen GUI.

Before correction, `MonitoringEngine.refresh` could return for
`controlHolds > 0` before installing its completion defer;
`invalidatePendingLookup` advanced the lifecycle without terminating queued manual
feedback; lookup admission marked any pending manual request Checking; completion
then correctly refused a request owned by a different lifecycle. The original
ticket generation was not logged, so retain that limit instead of inventing its
value. The deterministic held-control/no-HTTP reproduction failed before this
algorithm was edited.

Use a bounded scheduler with these invariants:

1. **Separate demand from execution.** Keep one current lookup and at most one
   pending lookup demand. Demand contains the current routing generation, reason
   flags and an optional explicit manual-ticket identity. Repeated Refresh clicks
   in one current generation join that ticket/work. They must not create one task
   per click or overwrite a manual ticket with a bare `settings_changed` trigger.
2. **Keep control ordering explicit.** Continue coalescing only contiguous pending
   mode-only requests. Preserve edits as ordering barriers and join admitted
   physical operations. Read-only state, heartbeat and health reporting remain
   independent. Protected transitions close at admission as already required;
   observation congestion must not delay that closure. Approved observation-only
   checks still leave traffic open until a rejected exit result.
3. **Terminate obsolete requests atomically.** Before advancing the lifecycle,
   finish any older queued or Checking manual ticket as ordinary Superseded,
   even when no HTTP task exists. Include a finished timestamp and clear reason.
   Cancel the obsolete execution if present, but retain its physical slot until
   it unwinds. A late completion cannot finish, cancel or restart a newer ticket.
4. **Admit feedback with the actual execution owner.** Only a pending ticket
   matching the current generation may become Checking, and record its lookup
   execution ID at that point. Current tickets may join an existing valid lookup.
   When controls drain, the final transition lookup may satisfy current manual
   demand without an extra HTTP request. Never mark an obsolete ticket Checking.
5. **Consume deferred work once.** Deferred manual demand carries ticket ID and
   generation; replay validates both and its pending status. Superseded, completed
   or cancelled demand cannot resurrect a request. Separately required current
   transition checks survive removal of obsolete manual demand. On capacity
   rejection, return a clear outcome before creating pending feedback.
6. **Make completion unambiguous.** Add a structured terminal result distinguishing
   Checked/Allowed, Checked/Blocked, Superseded, Cancelled, ProviderFailed and
   Deferred. A successful lookup with a rejected IP is Checked/Blocked, with the
   observed IP and healthy provider retained. It must not look like provider
   failure or cause a cooldown. Keep wire compatibility with older optional-field
   readers. Do not use a timeout to manufacture success or refresh health dates.
7. **Expose the owner chain.** Queue, join, admission, supersession and completion
   events carry manual ticket ID, lookup ID when present, lifecycle generation,
   routing revision and reason. Every accepted manual ticket must have a terminal
   result, or still be owned by a concrete queued/current operation. Core reconciles
   that invariant at control drain, invalidation and lookup completion; an orphan
   is an explicit internal failure, never permanent Checking or a provider pause.

Initial validation was eight genuinely new local controls: held-control/no-HTTP
invalidation; invalidation without a successor; stale deferred replay after a
new request; current manual demand joining a denied final lookup; completion
before deferred replay without a second HTTP request; real provider failure;
sustained rapid demand with one current/one pending execution; and caller
cancellation while demand is held. The three added controls covered the real
daemon's cancelled-before-admission path, immediate-demand/future-retry merging
and two-provider fallback. The first two failed and were corrected. The fallback
control made exactly two requests, preserved both providers' pauses and completed
the same ticket once before any fallback change; its passing source behavior was
retained. All before/after evidence is preserved in
[manual-demand-regression.json](../Tests/MihomoRuntimeTests/Evidence/v3/observations/manual-demand-regression.json)
and the local source/validation manifest. The durable runner is
`Tests/MimoServiceTests/ManualDemand/run.py`; its aggregate-suite hook was added
without running historical passing suites.

Installed qualification retried only the failed IPv4 Rule/rejected-IP case,
then the three unstarted IPv4 Direct, dual-stack Rule/rejected-IP and dual-stack
Direct cases. All four passed on `4263cf39`. Each earlier accepted ticket ended
Superseded; the final request had exact ticket/lookup/generation ownership and a
fresh result. Denied results retained the IP and healthy provider. All four had
18/18 healthy settled samples, two operation HTTP requests, no provider penalties,
no repair or unexpected settled-check loops, responsive management and zero
native attempts after confirmed protected closure in measured windows. The
35-second manual terminal wait, 35-second health expiry and 36-second settling
window were unchanged. The two earlier harness errors remain failed historical
attempts: captured DNS replies are not native IPv6 egress, and Checked/Blocked
is not an unfinished Refresh. This does not qualify all historical suites on the
new artifact or prove the exact cause of the original missing-component health
sample. Full artifact boundaries and limits are in the
[observation report](MIMO_OBSERVATION_TEST_RESULTS.md).

### Authorized final-candidate confirmation on both VMs

After the completed focused round, the user explicitly requested the quoted
validation be rerun on `mimo-vm`, added a few relevant prior successes, and then
requested both VMs. This authorizes the named repeat scope; it does not authorize
a blanket repeat of the 113-case inventory.

Run all 11 local `ManualDemand` controls inside each VM against the final source.
Run both health timings and all four congestion cases on the same installed
`4263cf39` candidate in each VM. Add the previously passing rapid IPv4 Rule →
Direct/rejected-IP, IPv4 Global → Direct/proxy-down, and dual-stack Rule →
Direct/approved-IP sequences. Total: **22 local-control executions and 18 runtime
runs**, representing eight runtime cases per VM with two timings for the health
case. Preserve baseline settings and all attempt evidence, keep existing strict
oracles, monitor the entire event/health/packet/management window, and stop to
investigate any failure. Keep production frozen during qualification.

The prior worker was deleted, so recreate a temporary worker with a distinct
Tailnet identity before reconnecting its VPN. Boot isolated, log out the copied
identity, and keep automatic VPN connection off while using NAT for setup; finish
the identity reset before fresh Tailnet login. Isolate per-VM fixture ports,
paths and evidence, and avoid compilation during timed tests on that VM. Retain
primary and remove only the temporary worker after all evidence and owned-resource
cleanup are complete. The exact matrix and new results are tracked in
[the dual-stack plan](MIMO_DUALSTACK_TEST_PLAN.md#authorized-confirmation-on-both-vms--27-november-2026)
and [the observation report](MIMO_OBSERVATION_TEST_RESULTS.md).

**New confirmation finding:** all 11 isolated controls passed on each VM, but
primary's first health-timing run failed incoming SSH. A paired diagnostic
confirmed a Direct-born accepted connection without PF state cannot deliver its
reply while verification is closed; a protected-born inbound state survives and
replies. The candidate stayed frozen throughout the completed requested tests,
with strict failing outcomes retained. A possible correction would retain narrow
SYN-only ingress tracking in ordinary Direct while services are active, with
complete removal on Stop/uninstall. That changes the baseline candidate's empty-anchor Direct
contract and cannot recover pre-existing untracked sessions; it is a proposal,
not implemented or approved here. Do not adopt blanket midstream `flags any`,
which can mistake responses to earlier outbound flows for inbound sessions.
Packet/state qualification and a separately reviewed design are required before
changing this firewall behavior.

Two further confirmation findings remain unimplemented. A blocked native-policy
update can invalidate the PF health identity until the next full scan; a narrow
epoch/state/digest-qualified readback receipt could close that gap without
renewing the full-guard freshness baseline. Separately, active native-policy
mutation still runs synchronously on the supervisor actor and can delay Direct
admission under the test's PF-lock hold. Consider an owned off-actor transaction
with generation fencing and exact readback adoption. These are proposals for a
later correction, not changes to the frozen candidate or weakened test deadlines.
The worker's paired confirmation also reproduced missing PF receipts after
active native-policy updates. Receipt publication must cover both active and
blocked mutation paths; an unrelated later successful case does not resolve the
earlier identity gap or the unqualified admission-under-contention case.
The original assertions, timelines and limitations are retained in the
[observation report](MIMO_OBSERVATION_TEST_RESULTS.md).

**Confirmation complete:** 22/22 isolated controls passed. The 18 original runtime
runs finished with 12 passes, four product failures and two unqualified results;
the separately recorded failed-case retry passed (19 total attempts, 13 passes).
Primary has passing evidence for six of its nine planned checks and worker for
seven of nine. Both worker health timings retain the PF-receipt and incoming-SSH
failures. The proxy-down case's setup errors were independently correlated to
the intentional current-request failure and subsequent fresh Direct recovery;
they are not an unexpected event loop. No production correction, broad rerun or
publication occurred. Cleanup passed: primary is restored with candidate and
test certificate retained; the temporary worker was logged out, cleaned and
deleted after archival. The pre-existing backup remains. Cleanup evidence is
linked separately in the observation report and does not waive failed tests.

### Approved health reconciliation refinement

New investigation (28 November): the user authorized targeted tests and workflow
design for the unresolved incoming TCP, native-policy receipt and admission
contention findings. The [16-test investigation](MIMO_REMAINING_FAILURE_INVESTIGATION.md)
is complete: primary passed six real-PF mechanism assertions, including defect
reproductions; the isolated worker recorded three passes and seven failures in
ten extracted-runtime controls. Rejected stale active work also invalidates the
new owner's receipt by stamping an epoch before its ownership check. Candidate
behavior remained unchanged; the worker was archived and removed. Proposed
ordinary-Direct ingress tracking and owned off-actor native-policy transactions
were then authorized and implemented as described in the 28 November section
above. Their new evidence does not alter the completed baseline verdicts.

Keep the 35-second health-expiry bound and actual per-component observations.
Use typed completed/deferred/superseded/failed outcomes. Retry ownership deferrals
at 1, 2, then 4 seconds, returning to the normal 10-second cadence after success.
Coalesce one 1-second health-only reconciliation after physical probe/active/
Direct/close/Stop completion. A deferral does not initiate IP verification, and a
persistent failure causes only one close/recovery episode per current generation.

Publish inspection identity, owner generation, start/completion and reason without
renewing observation timestamps. Separate full PF baseline observations from
narrow grant/Direct policy receipts (epoch/state/digest). Effective PF health uses
the older required scoped observation; progress cannot manufacture freshness.
Preserve actual launchd history when PF checking exits early; heartbeat remains
independent. Failed, overdue and communication-unavailable states outrank Checking.

Local evidence now retains 17 distinct passing histories across revisions; the
latest run covered only two newly failed controls and four new receipt controls.
Do not claim all 17 were rerun on final source. Final source typecheck and guard
syntax checks pass. These mechanism tests do not establish the original VM case 6
component or cause. Only the failed installed case and newly designed pending-mode
cases may run next; previously successful cases remain paused.

### Acceptance before deployment

First write regressions that fail against current unconditional preparation.
Then qualify Rule/Global × IPv4/dual-stack for each observation, policy edit and
transition class. Verify one provider request, fresh display, exact gate behavior
and at least 35 seconds without unexplained follow-ups. During open observations,
use continuous permitted TCP traffic and PF counters/readback to prove continuity;
simultaneously probe direct paths to prove no new proxy bypass. Check incoming
SSH/Screen Sharing throughout and run the existing packet/capture leak matrix.

Cover allowed/denied IPs, empty lists, provider timeout/429/invalid response/token
failure, proxy down, engine/controller failure, list edits during lookup, network
change during lookup, competing GUI requests and late replies after Direct/Stop.
Verify rejection doesn't pause a healthy provider, blocked checks remain usable,
Direct always restores access and user messages match actual gate state. Test the
periodic deadline after success/failure and manual overlap on a virtual clock,
then an installed timer cycle. Preserve failed-before evidence, run native clicks
and rapid overlapping Refresh/mode operations (including blocked recovery),
in addition to API tests and restore the VM. Implementation, local builds/installations and the documented VM tests are
authorized. Publishing a release remains a separate action.

## Approved background item and dashboard revision — 26 November 2026

Expose exactly the existing supervisor, heartbeat and engine jobs using the names
`mimo-core-supervisor`, `mimo-core-heartbeat` and `mihomo`. Install three system
LaunchDaemon plists with distinct signed role executable paths; retain existing
job labels, Mach APIs, sole settings owner and peer repair fencing. Remove old
Application Support plists during upgrade; include both layouts in rollback and
uninstall. Do not create another core process. Engine Stop must remain stopped
across reboot, while Start/install restores it.

Dashboard must separate supervisor, heartbeat, engine, monitoring and profile
health, retain real timestamps and distinguish unavailable communication from a
stopped service. A successful private controller response is required for healthy
engine/profile status; stale evidence cannot remain Healthy. Maintain uniform
Healthy(n secs) format and expiry. Settings Maintenance must describe and inspect
all three roles, provide Direct recovery and correct cleanup/restore commands.
Viewing/copying maintenance commands has no network side effects.

The installed denied-Rule audit exposed repeated deferred PF health scans. The
blocked transport refresh was rotating the mutation epoch before deciding whether
rules needed any change. Conditional writes must inspect under the same mutation
lock and stamp only after deciding to write, before the actual PF operation. This
keeps unchanged inspections from aging out otherwise valid health evidence while
preserving snapshot invalidation for real, failed or interrupted writes. Add a
regression that counts blocked-state epoch changes against actual transport
updates; retain the failed pre-fix observation.

Reproduce the one-name registration before changes; validate three current names,
role identity/API ownership, peer crash/hang recovery, engine controller failure,
Stop→reboot→Start, full Stop/Activate/uninstall/reinstall, dashboard/maintenance
presentation and settled event audits. See MIMO_CORE_INFRASTRUCTURE.md for current
results; the previous 77-check campaign does not qualify new registration changes.

Completed in mimo-vm: latest outcomes for 64 distinct installed checks pass, with
30 passed settled windows. Two pre-fix failures remain recorded, including the
blocked-transport epoch regression; the final artifact passed 27 follow-up checks.
The VM finishes in Direct with all roles enabled, current dashboard health and
retained settings/credentials. Native Login Items showed the requested three
names. See [qualification, artifact scope and remaining limits](MIMO_CORE_INFRASTRUCTURE.md#qualification-completed--26-november-2026).
This revision has not been published.

### User command acceptance extension — 26 November 2026

Qualify IP-monitor Start/Stop/Restart, engine Start/Restart, Profile Reload,
both GUI full-Stop entry points and Activate. Keep backend engine-only Stop
distinct from full deactivation. Supervisor remains the sole network/settings
owner; heartbeat must honor durable Stop and maintenance intent, never undo them.
Use managed Direct and approved/rejected Rule/Global in both traffic families,
plus provider/proxy/controller failures, overlapping two-account requests and
commands arriving during verification, peer repair or a lost GUI connection.

For each case declare expected lookups/gate/process changes, correlate the full
request-to-terminal log sequence and compare live state with the UI. Observe
settlement for at least 35 seconds, removal for at least 50 seconds and repair
races for at least 135 seconds and through pending repair/backoff; verify stopped
intent across reboot. Direct recovery, incoming access, absence of outgoing
bypass and truthful service/communication
status remain acceptance requirements. Native clicks, production RPCs and CLI
lifecycle operations are separate methods and require separate evidence.

The [SC01–SC14 matrix and procedure](MIMO_DUALSTACK_TEST_PLAN.md#user-service-command-and-supervision-matrix)
record the execution requirements and existing coverage. This adds pending
tests; it does not extend the completed counts or change production behavior.

## Approved core infrastructure consolidation — 2026-11-26

The user's clarified requirement is to merge the former Perl boot/health work
into the **existing** supervisor, with no new `mimo-core` launch job. The initial
candidate with `--infrastructure` is superseded: its two same-name Login Items
rows failed the intended presentation. Both `com.mimo.pf-boot` and
`com.mimo.infrastructure` and their repair templates are retired on upgrade.
Rollback preserves old registrations; uninstall still cleans legacy versions.

Boot guarding runs before supervisor admission. The supervisor now owns settings,
IP monitoring, GUI API, mihomo, firewall and DNS, and repairs its heartbeat peer.
The existing monitoring job becomes `mimo-core --heartbeat` with the sole duty of
checking and repairing supervisor progress. Its job identity remains com.mimo.core
for migration/removal; that Mach API moves into the supervisor job. No third core
job is introduced. The internal coordinator calls the supervisor directly, keeping
revision/command fencing while retiring the old cross-process five-second lease.

Independent progress records bind boot/PID, executor advancement and infrastructure
work. Known loss must persist for 45 seconds; startup gets 120 seconds, missing
jobs 10 seconds. Repairs share a lock, check current identity/progress and durable
maintenance/deactivation intent, and cap peer attempts at three per ten minutes
with backoff. Healthy progress observation validates the live executable without
repeated launchctl calls. Maintenance uses the peer lock before intent publication;
deliberate installation resets exhausted budgets after workers drain. Direct CLI
recovery goes through the sole settings owner and preserves IP-monitor intent.
Install/Activate must explicitly start both peers before verifying their health,
while retaining the Stop receipt until successful verification. A live lifecycle
test reproduced the opposite ordering: peer repair respected the receipt, so
the missing heartbeat could not start and activation rolled back. The installer
regression fails against that ordering; watchdog Stop fencing remains unchanged.
Supervisor alone owns network repair. Heartbeat recovery changes no
PF/DNS/profile state. Network failures and rejected exit addresses do not imply a
stalled process. Direct and IP-monitor Stop keep supervision; full Stop/uninstall
removes peers. Startup recovery in Rule/Global requires new verification.

Test SIGKILL, SIGSTOP, absent/disabled jobs, repeated faults/backoff, settled
rejected exits, explicit recovery, ordinary Direct and Stop/Activate. Correlate
all sources; fail unexpected checks, stale commands, recursive restarts or lost
recovery. Observe each terminal state at least 35 seconds. The baseline suspended
supervisor test failed as expected (same PID after 50 seconds); preserve it with
candidate results. Current implementation/qualification status is recorded in
[MIMO_CORE_INFRASTRUCTURE.md](MIMO_CORE_INFRASTRUCTURE.md).

**Prior two-peer candidate implemented and installed in mimo-vm:** 77 unique installed checks passed,
including 26 quiet log windows, real peer hangs/crashes/removal, four protected
mode/family rejection-and-recovery cases, engine/DNS/PF repairs, full lifecycle and
reboot. All 241 shared tests plus service/app/installer suites passed. The final
installer explicitly starts heartbeat before checking health; its reproduced
activation failure and successful rerun are retained. Native GUI click-through
remains unqualified because viewer automation is unavailable. Registry, app-model
and rendered UI checks passed. Candidate is not published; Delta is unchanged.

## Approved IPv4 approval and monitoring recovery revision — 2026-11-26

**Recovery-loop correction:** a correlated installed trace found repeated
`infrastructure_recovered` events before the reported Dashboard clicks. The
supervisor's startup recovery flag remained armed until an exit was approved;
a healthy but rejected observation therefore retriggered verification on every
healthy infrastructure scan. The new 35-second installed regression failed on
the unchanged candidate before production edits. A valid protected `prepare`
now consumes that recovery request before asynchronous work starts. An explicit
Direct command also clears it. New runtime/liveness failures independently rearm
recovery; policy rejection alone does not. Manual retry and real settings/network
changes retain their normal verification behavior. The installed four-cell
restart/denial/retry/Direct matrix passed, with 35 seconds of stable rejection in
each cell. A separate 90-second native Dashboard/all-six-Settings audit passed
with no new verification or configuration change. Full event reconciliation
found one recovery request per injected restart and no continuing loop. Bounded
startup heartbeat failures and their misleading conflict wording are recorded
explicitly in the [results](MIMO_NAVIGATION_RESPONSIVENESS.md#installed-correction-and-event-audit--26-november).
This does not by itself close the visible Screen Sharing latency report.

**Settings → Dashboard delay follow-up:** the user confirms a directional delay
in mimo-vm. Keep this open separately from the inactive-window first-click fix.
Measure current-event age, content transaction animation, applied selection and
the next AppKit window-update callback before changing navigation behavior.
Separate direction-specific results from pooled timing; neither an offscreen
render test nor a window-update callback qualifies final visible latency. See
the [navigation investigation](MIMO_NAVIGATION_RESPONSIVENESS.md).

The subsequent Screen Sharing check found a Standard connection over the local
VM network. Five native transitions reached AppKit window-update callbacks in
30–41 ms; a temporary Full Quality comparison did not reproduce the directional
delay, and Adaptive Quality was restored. Screenshot observation waits prevent
using those captures as precise remote-display latency measurements. Screen
Sharing remains a possible cause, pending a same-session local-console comparison;
no additional navigation behavior was changed on this evidence.

**Navigation follow-up:** the user reported sluggish Dashboard/Settings switches
again after this revision. The [navigation investigation](MIMO_NAVIGATION_RESPONSIVENESS.md)
records two new red tests before functional edits: excessive menu updates and
unchanged fallback-preference writes. The local candidate coalesces native menu
updates, skips unchanged label layout and persists fallback data only on change.
This applies equally to Direct, Rule and Global; core ownership, drafts and
provider behavior remain unchanged. The installed GUI completed all six Settings
sections under failed-state status delivery, with 11–38 ms selection-to-view
updates; the VM retained-window test completed 36 switches below 89 ms. Do not infer that these
optimizations resolve an intermittent multi-second hang merely from passing
render timing tests; retain the affected-Mac/two-account qualification limits.

**First-click clarification:** reproduce activation separately from rendering.
The installed sidebar consumed the first click when Mimo was inactive; the
second click selected its page. Sidebar rows now use explicit navigation buttons
with window-activation events on supported macOS; applying the modifier to List
alone failed the live retest. Preserve unrelated routing/service controls. Qualification
must include one click from another active app, one click while Mimo is already
active, and a sidebar selection after editing a field. Do not substitute direct
model mutation or selection-to-render timing for these mouse-input checks.
The installed candidate passed inactive-window General/Monitoring/Settings
clicks, navigation from a focused field, draft retention and sidebar arrow keys.
The reproduced inactive-window failure is closed in mimo-vm. macOS 14, the
affected physical Mac and simultaneous-account navigation remain unqualified.

**Approval:** the user approved implementation after review, explicitly covering
strict IPv4 and Dual-stack. A new combined scheduler/coordinator regression failed
on the unchanged code before production edits; `.build/ipv4-approval-red2.log`
records the failure. The installed candidate is qualified separately below.
This section supersedes the earlier paired IPv4/IPv6 approval design. Existing
qualification records remain historical evidence, not passes for this proposal.

### Problems established and remaining uncertainty

1. **Traffic-family selection incorrectly determines approval-family selection.**
   Current Dual-stack checks IPv4 and then IPv6, requiring both results before
   sending an approval receipt. In the reported VM sequence all three enabled
   providers returned IPv4 successfully, followed by an IPv6 failure. Core then
   paused each provider and eventually exhausted the pool. The IPv4 allowlist
   decision was never reached in those attempts.
2. **The configured proxy cannot reach the tested IPv6 destinations.** Independent
   SOCKS5 requests from the VM, while Direct released Mimo's gate, returned IPv4
   results from IPWHOIS and ipapi.is. IPv6 attempts to ipapi.co, IPWHOIS, IPinfo's
   v6 endpoint and api6.ipify.org all received SOCKS reply 4 (host unreachable).
   This establishes failure for those tested destinations, not a claim about
   every possible IPv6 destination. The proxy's IPv4 listening address itself is
   not the problem: SOCKS5 can carry IPv6 destinations over an IPv4 connection.
3. **Provider API support and provider transport support are different.** The
   public DNS query for `api.ipapi.is` returned no AAAA record. Its ability to
   accept an IPv6 address as a lookup argument does not mean it can measure an
   IPv6 exit through a forced IPv6 connection. ipapi.co also returned HTTP 429
   during the independent comparison; genuine provider limits remain separate.
4. **Successful observations disappear on a later failure.** Core waits for the
   full paired operation before publishing the address. An IPv6 error discards
   the successful IPv4 result from the dashboard. A subsequent failed request
   can also leave the address blank despite an earlier known exit. Current
   feedback does not distinguish an unapproved address from no returned address.
5. **Paused providers are easily confused with stopped infrastructure.** During
   the captured failure, core, engine and profile hosting remained running; PF
   and launchd checks were current. The provider rows were paused. These records
   do not prove an event deadlock. Successful lookup, allowlist decision, provider
   backoff and daemon communication must be presented separately.
6. **The reported intermittent navigation stall remains unqualified.** Native
   click-through in blocked Global completed Dashboard and all six Settings
   sections. The navigation follow-up removed redundant GUI work and added
   timing diagnostics. No multi-second stall was reproduced. Physical-Mac and
   simultaneous two-account checks remain outstanding; do not mark the original
   report fixed merely from passing rendering tests or changing approval policy.

Private reproduction material is under `.build/direct-global-build11-report/`:
initial state/logs, public provider DNS results, redacted transport outcomes and
GUI sample. Raw guest responses remain owner-only. No credentials or real exit
addresses belong in committed evidence. The unchanged core also failed a new
regression expecting IPv4-only Dual-stack approval: its successful IPv4 lookup
was followed by the deliberately failing IPv6 lookup. Preliminary test/source
edits were removed when implementation was paused; the failure log is retained.

### Required behavior

| Situation | Gate and monitoring behavior | User-visible result |
| --- | --- | --- |
| Rule or Global, either traffic family, fresh IPv4 is allowed | Finish existing runtime/readiness checks, then open. Provider healthy; no failure pause. | Actual IPv4, timestamp and provider; “IPv4 exit approved”. |
| Fresh IPv4 is not allowed, including an empty list | Keep application traffic blocked. The provider request succeeded: no provider failure or cooldown. Keep monitoring and recovery controls available. | The rejected IPv4 remains visible with “Not allowed” and an Allowed IPs action. |
| No address returned because of connection/provider failure | Keep protected traffic blocked; record the real request error and bounded retry policy. A manual retry may release eligible local backoff, preserving actual provider restrictions. | Show last known exit with its timestamp and “Last known · check failed”; if none exists, “No address received”. Never invent a failed address. |
| IPv6 destination unavailable while IPv4 checking works | No IPv6 approval request is made, so it cannot pause a healthy IPv4 checker or block approval. | No IPv6 allowlist or IPv6 approval badge. Dual-stack describes traffic routing, not verified IPv6 connectivity. |
| Provider returns 429 / Retry-After, authentication refusal or quota exhausted | Respect the provider restriction; try another eligible provider without repeatedly closing/reopening. | Explain the restriction/deadline, separately from daemon health and IP rejection. |
| User selects Direct | Restore native networking independently of provider state; no exit approval required. Preserve the existing distinction between Direct with engine and Stop/released Direct. | Direct remains available throughout failure and recovery. |

A healthy response and a policy rejection are independent. A completed usable IP
response must not be reclassified as provider failure because that IP is unapproved
or because an unrelated family/connection fails. IPv6 verification is removed from
this workflow entirely; monitoring eligibility follows the required IPv4 request.
Actual failed requests may use bounded automatic backoff. Success clears only the
applicable local failure state, never a separate server-mandated restriction.

**One IPv4 allowlist:** Rule and Global use the same list in strict IPv4 and
Dual-stack. Remove IPv6 entries during a core-owned migration; preserve all IPv4
entries, proxy secrets and unrelated preferences. An old IPv6-only list becomes
empty and visibly blocks until the user adds an IPv4 exit. Settings and daemon
validation accept IPv4 entries only. Migration logs a count, not private addresses.

**Traffic policy stays distinct:** strict IPv4 still captures/rejects public IPv6;
Dual-stack still routes public IPv4/IPv6 through the selected proxy. The existing
capture, DNS, ICMP and native-fallback firewall protections remain in force. IPv4
approval does not prove the proxy supports IPv6 or establish its IPv6 exit address.
An unsupported IPv6 connection may fail while IPv4 works; it must never fall back
to native public egress. No automatic downgrade to Direct or IPv4 traffic mode.

### Approved implementation sequence

1. Restore the failing regression as the first test, using the real scheduler and
   coordinator. Cover Direct→Rule and Direct→Global, both traffic-family settings,
   with successful IPv4 and deliberately unavailable IPv6. Assert one required
   IPv4 provider request, no IPv6 probe, correct allowlist decision and no provider
   cooldown for successful/rejected results. Preserve pre-fix failure evidence.
2. Change coordinator and supervisor approval together. Every receipt contains a
   fresh IPv4 observation tied to the current attempt, revision, proxy and network
   generation. Preserve readiness, cancellation and stale-command fences. Country
   metadata and cached observations never authorize access. Remove paired-family
   approval requirements and obsolete IPv6 verification state/claims; retain only
   decoding/migration compatibility actually needed for older stored state.
3. Migrate and enforce the IPv4-only allowlist in core. Keep machine-wide ownership
   and multi-user serialization. Log migration and distinguish policy rejection
   from transport/provider failure. Count actual HTTP requests, not selected
   traffic families. Confirm explicit Refresh and settings repair still work in
   the same blocked session without resetting credentials, clocks or processes.
4. Publish the returned IPv4 before slower approval/readiness completes. Keep the
   rejected address visible across status polls. Maintain separate display-only
   history for requests that return no address, with timestamp, provider and proxy
   context. Never label history as current/approved; clear or explicitly identify
   previous-proxy history after a proxy change. No stale result may open the gate.
5. Update dashboard, menu status, Allowed IPs and Monitoring. Explain IPv4-only
   approval in Dual-stack; remove “both exits approved” and IPv6 allowlist inputs.
   Show provider reachability/retry state separately from service health. Keep
   family-routing controls and fixed layout. Measure Monitoring-tab latency during
   failure/rotation; investigate and fix any reproduced main-thread/XPC stall.
6. Update README, event workflows, this plan, profile annotations where relevant
   and the dual-stack test plan. Clearly mark earlier paired-approval qualification
   as historical. Preserve traffic/leakage tests: changed approval expectations
   must not weaken their packet-level assertions.
7. Build a local candidate only after the regression and shared/service/app tests
   pass. Install it in `mimo-vm` and execute the acceptance matrix below. Report
   actual results and remaining limits before any new release claim. Local build/install/testing are authorized; a new public release is not.

### Acceptance and evidence

Run all four base combinations: Rule/IPv4, Global/IPv4, Rule/Dual-stack and
Global/Dual-stack. Start each transition case in Direct; also repeat fault/recovery
from an already active protected session.

- Allowed IPv4: one fresh required HTTP request, no IPv6 lookup, active gate,
  healthy provider, fresh dashboard result. In Dual-stack, independently refuse
  proxy IPv6 while IPv4 approval still succeeds; also test a provider without AAAA.
- Disallowed IPv4 and empty list: stable block, actual rejected IPv4 visible,
  provider healthy/unpaused, no event loop, bounded RPC response. Explicit Refresh
  obtains a new result; allowlist-only repair reopens after fresh verification.
- Proxy down, timeout and authentication failure: correct error classification,
  no invented fresh IP; last known address clearly timestamped where available.
  Repair transient failure and Refresh without Direct, restart, token/store/clock
  resets. Old results and late replies cannot authorize the recovered session.
- Real provider restriction: 429/Retry-After and exhausted quota stay enforced.
  Other eligible providers can work; a valid response outside the allowlist does
  not create a failure cooldown. Provider rows never imply all daemons stopped.
- Recovery controls: Direct works in every failure state; SSH/Screen Sharing replies
  remain reachable. Stop/Activate behavior and both Direct engine states regress.
- Migration: mixed/IPv6-only lists, restart persistence, malformed additions,
  retained IPv4 entries/secrets and consistent state across two GUI accounts.
- Native UI: rejected, never-observed and last-known addresses; copy action,
  country flag where a matching observation exists, stable layout, clear reasons
  and responsive Monitoring navigation during failures and provider rotation.
- Leakage regression: captured public IPv6 stays proxied or fails locally;
  verify no native fallback with proxy IPv6 refusal in both Rule and Global.
  Existing active/transition guard, DNS and incoming-service checks remain.

Record the installed binary hash, mode, traffic family, approval family, request
count, provider status, cooldown classification, receipt/revision IDs, displayed
address freshness and recovery timing. Correlate lookup→gate→decision events;
respect IP redaction and never include credentials. A test that merely observes
“blocked” is insufficient: it must verify explanation, provider health, usable
recovery controls and the absence of repeated event cycles.

### Implementation and qualification progress — IPv4 approval revision

The combined scheduler/coordinator regression was recorded red before production
changes (`.build/ipv4-approval-red2.log`): Direct→Rule/Dual requested IPv6 after
IPv4 success and paused its healthy provider. The revised case now passes all
four mode/family combinations. Shared tests currently pass **226 cases**; app
and service suites pass, including 60 exception/recovery simulations and four
pending-lookup Direct cancellations. No traffic-family/PF policy was relaxed.

Core and supervisor now require one fresh IPv4 receipt. Core publishes a returned
address before readiness finishes and maintains separate, proxy-scoped display
history. The GUI labels failed-request history and replaces the IPv6 exit row
with traffic policy. Core migrates legacy IPv6 allowlist entries atomically;
settings/XPC validation reject new ones. Installed migration preserved the other
settings and credential digests and emitted one count-only event. Historical
paired-approval results do not qualify this revision.

Installed acceptance passed all four cells: Rule/IPv4, Global/IPv4, Rule/Dual and
Global/Dual. Each made 14 IPv4 provider requests and zero IPv6 provider requests;
all 12 explicit rejected-state refreshes obtained fresh results without pausing
the healthy provider. All four allowlist-only repairs opened after fresh IPv4
verification. Sixteen active failure/recovery cases passed (proxy down,
authentication, timeout and HTTP 503); four real 429/Retry-After cases retained
their restriction. Proxy-down repair took 7.116–11.984 seconds, with unchanged
mode, core instance and credential. Incoming SSH and Screen Sharing remained
reachable. IPv4 application traffic worked; strict IPv4 sent no IPv6 request to
the proxy, Dual-stack attempted IPv6 through it, and all four captures recorded
zero native IPv6 packets when the proxy refused/dropped IPv6.

All 22 Direct/Stop/Start assertions passed: managed Direct retained its engine;
full Stop removed owned PF/DNS/TUN and services; Activate restored all services,
native release checks passed, and settings/credentials survived. The guest's
original configuration was restored after each campaign. Migration was checked
on the installed app, with mixed/IPv6-only lists also covered by shared tests.

Native last-known light/dark renders passed visual review. Actual Direct→Monitoring
navigation completed in 616 ms, but this is not the reported failed-state case.
Later live Global/Dual inspection was unavailable because the computer-use tool
could not access Delta's window. Five blocked-state RPC samples took 183–204 ms;
core, engine and profile hosting remained running, with healthy PF/launchd. This
does not establish that the reported slow tab or every multi-user hang is fixed.

The candidate is unpublished **3.0 build 11**, installed core SHA256
`fff99947b06a44095736bc1f212aef37e81860db7568a90e6bcb0f671fc1bb30`.
See [the complete result record](MIMO_IPV4_APPROVAL_RESULTS.md) and
[sanitized evidence](../Tests/MihomoRuntimeTests/Evidence/v3/ipv4-approval/summary.json).
Hashes distinguish it from earlier unpublished build-11 binaries; no published
build identity was reused. Historical broad traffic/fault campaigns were not
rerun or counted as new passes.

## Approved containment revision — 2026-11-25

The user approved a persistent active guard after the closure campaign measured
five native-bypass failures. This supersedes the original empty-active policy.
Implement and qualify before publishing: profile routing alone cannot contain
engine death, and faster asynchronous detection cannot close a pre-detection gap.

The guard must allow the owned TUN/loopback and actual engine TCP/UDP sockets,
preserve intentional native LAN/Tailnet and required link control, and silently
drop remaining native application egress in both families. Rule-mode DIRECT
bypasses remain engine decisions; PF does not duplicate domain lists. No blanket
root/public-HTTPS/any-utun permission is acceptable. Native VPN public transport
compatibility must be measured; socket-group matching cannot be inferred from ps.
The candidate uses the dedicated engine group and explicit native address ranges
(RFC1918, IPv4 link-local, IPv6 ULA/link-local). Tailnet CGNAT/ULA passes are scoped
to currently up native tunnels with Tailnet addresses, snapshotted at preparation
and rechecked before opening/audit; no provider, profile binding or separate
interface watcher is introduced. Tailnet destinations on any other path are
denied before the engine-group and generic ULA grants. This prevents Quad100 DNS
from escaping onto a physical default route after native tunnel loss. Mimo fake
IPv4 and IPv6/TUN address ranges are denied outside the owned TUN before native
exceptions, so fake IPv6 ULA cannot inherit LAN permission. Native transport and interface scoping are qualification gates, not assumed
successes. No removed HTTP/file provider or profile interface binding returns.

The first active-guard compatibility run passed native DNS but blocked real peer
ping in all four cells; the same fixture with the earlier empty policy passed.
A bounded signed-socket experiment restored ping with native HTTPS/UDP transport.
Therefore include a read-only socket snapshot of the official root-owned
Tailscale system extension (Apple signature, identifier and team verified before
and after collection). Allow root UDP only on its held source ports, and root
TCP/443 only to its observed control/relay destinations. A held failed TCP socket
may supply its destination for a retry with a new ephemeral port. This is an
explicit trusted-native-service exception, not protection from a malicious root
process or a compromised native VPN. Other users cannot inherit those permissions.

Core's existing active audit refreshes that snapshot without a provider, CLI,
public DNS discovery, new timer, profile reload or permission-gate opening. Apply
only while the same active prepared policy and native interface snapshot remain
current; use the shared mutation lock, exact readback and atomic expected-policy
update. Closure/Direct/new attempts supersede observations. Invalid/unavailable
identity or socket observations remove the scopes; interface changes still close
and reverify. Boot/verification has no native transport grant. Direct/Stop removes
them. Event Log records scope counts, not private endpoints. Qualification must
cover native ping/DNS and policy updates, not just an existing cached relay.
Bound socket output to 1 MiB and the subprocess to 1.5 seconds: macOS can retain
thousands of closed NetworkExtension sockets. Truncation is an unavailable
observation, never permission to retain an unverified grant.

Live reconnect correction: collect signed transport sockets even when the native
interface snapshot is empty, in cached preparation, fresh preparation and active
audit. A VPN needs its public control/relay transport to create its native tunnel;
requiring that tunnel first deadlocks startup. This does not grant native private
access before connection: CGNAT/Tailnet ULA wrong-path denials precede transport
permissions, and private passes still require a verified interface. Revocation
tracks trusted held sockets, not merely disappearance of the Tailnet interface;
an independently running signed VPN may retain public control sockets while
disconnected. Closed/Verification still grant no native VPN transport. Direct
continues to release all Mimo filtering. Validate a real disconnected-to-starting-
to-connected cycle, cold private DNS, native ping, scope changes and zero public
bypass. [Live qualification record](MIMO_V3_LIVE_LIFECYCLE_RESULTS.md).

The pinned engine's auto-interface finder must leave CGNAT/Tailnet ULA
destinations unbound on macOS. Address-prefix matching cannot infer a remote
peer or Quad100 from a native /32 interface address; falling back to the physical
interface is incorrect. The OS host route chooses the native tunnel and PF still
denies a wrong path. This is engine route selection, with no dynamic interface
name in YAML or provider. Require the `native-dns-route-v1` capability. Test both
UDP/TCP Quad100, peer addressing and the absence of a native route.

All active permissions use `no state`. Closure revokes existing IPv4/IPv6 states;
no TUN-created floating state may authorize a later physical route. Active rules
are installed before publishing approval, checked by supervisor and independent
repair, and persist if all user-space owners disappear. Direct/Stop/uninstall
remove new and legacy controls and preserve foreign firewall material.

Repeat all 28 fault cells and four baselines with independent lab containment
and zero native hits; add wrong-owner, established-flow, Rule DIRECT, private DNS,
Tailnet transport/reconnect and cleanup checks. Record failures and unqualified
coverage rather than treating a passing probe as complete containment. Also fix
the measured core-heartbeat recovery scheduling gap without weakening closure.

### Profile annotations and Settings reference

The canonical renderer must emit explanatory YAML comments in both checked-in
v3 templates and the installed private profile. Explain capture versus destination
family, Rule versus Global, silent echo handling, private/public DNS, proxy
selection and the authenticated verification listener. Settings is the editing
surface; comments must not encourage manual edits that core will overwrite or
disclose local credentials. Preserve the older standalone test inputs.

Settings → Maintenance must document the active, closed/verification and released
PF policies, including labels, native exceptions, no-state passes and cleanup of
legacy controls. Include copy-only CLI commands to inspect PF/DNS and all three jobs
status, release controls, restore all services and uninstall with or without the
app bundle. Describe scope and effects, and remain readable while disconnected.
This page adds no privileged GUI owner or automatic repair action. Validate the
generated YAML with the pinned engine and compile the native Settings page.

Qualification checkpoint: the local revision passed 68/68 installed VM rows,
including all 32 traffic/fault rows with zero native attempts, 17 compatibility
rows, five private-DNS wrong-path checks and the PF/package cleanup checks.
Both Direct states were exercised at the service/network level: managed Direct
with an idle engine, and released Direct after Stop engine with the app still
installed. Released GUI monitoring/button appearance and physical-Mac scenarios
remain unqualified. The VM is restored to its original settings in managed
Direct; the reusable certificate/key remain. See [results and limits](MIMO_V3_ACTIVE_GUARD_RESULTS.md).

## 1. Product decisions

Build on Mimo 2.1, retaining shared proxy lists, Rule bypass blocks, explicit exit
approval, the compact dashboard, monitoring-only operation and installation
conflict handling. Introduce two shared network settings, IPv4 and Dual-stack.

| Setting or action | Required behavior |
| --- | --- |
| IPv4, the migration default | IPv4-only for traffic managed by Mimo in both Rule and Global. Reject captured IPv6 literals, NAT64 destinations and proxy-side IPv6 hostname connections. Preserve explicitly native LAN/Tailnet exceptions. Do not disable IPv6 on macOS network services. |
| Dual-stack | Capture public IPv4 and IPv6; proxy both. Require one fresh, explicitly allowlisted IPv4 exit before opening protected access. IPv6 destinations remain proxied, with no separate IPv6 check/list and no native fallback; see the approved 2026-11-26 revision. |
| Rule | Apply enabled user domain-bypass blocks, subject to the selected family policy. Unmatched public traffic uses the selected proxy; unsupported traffic fails closed. |
| Global | Use the selected proxy for captured public traffic. Ordinary Rule bypass blocks do not apply. Family restrictions, private-probe access restrictions and ping blocking still apply. |
| Direct | Release Mimo routing and owned DNS. The system and other VPNs determine native connectivity. Save the family choice for the next protected activation. |
| Stop engine and use Direct | Release network controls and remove engine/privileged routing services using the shared cleanup path. Keep exit-IP monitoring available using the existing monitoring-only architecture. The same button becomes Activate Mimo. |
| Ping and ping6 | Silently drop captured echo requests. Do not generate synthetic success replies. Native LAN/Tailnet addresses excluded from capture retain real native ping behavior. |
| Tailscale | Remove all Mimo Tailscale controls, provider rows and Tailscale-specific status. Preserve native routing and private DNS compatibility. Never stop or reconfigure the native Tailscale app as part of provider removal. |

All shared settings, health decisions, DNS/PF ownership and privileged operations
remain in mimo-core and its supervisor role. Multiple GUIs display shared state
and submit revision-checked commands; they do not independently enforce policy.
After confirmed full deactivation, the existing GUI-owned anonymous monitor is
the explicit exception: all privileged jobs are removed, so it observes native
connectivity without shared credentials, settings writes or enforcement. Losing
communication with core must never be interpreted as completed deactivation.

## 2. Evidence and deployment blockers

The source templates are `Profiles/mimo-ipv4-template.yaml` and
`Profiles/mimo-dualstack-template.yaml`. Preserve their existing evidence and the
working `mimo-global-ipv6-test.local.yaml`; do not silently replace those files or
rewrite historical failures as successes.

Historical evidence informing the decisions below:

| Input | Carry into v3 | Do not carry forward |
| --- | --- | --- |
| `Design/MIMO_FIREWALL_AND_FAILURE_SCENARIOS.md` | T01–T14 failure cases, failed-close handling, independent guard loading, state-revocation caveats, sleep/session races and limits of sampled verification. | The assumed always-enabled rejecting startup TUN, permanent active allow/deny policies, native PF exceptions, old timer values and historical pass results as v3 evidence. |
| `Design/MIMO_IPV6_PROFILE_ANALYSIS.md` and dual-stack plan/results | Packet evidence, capture and DNS requirements, native exclusions, engine patch provenance and outstanding failures. | Treating standalone profile tests as qualification of installed-app ownership or recovery. |

The first v3 candidate used empty active PF and measured native fallback after
four engine kills and one route change. Preserve that evidence. The approved
revision above adds a persistent active guard; its new results must qualify the
change separately. Saved state and heartbeats never substitute for live PF checks.

The final standalone campaign ran 3,620 cases: 3,610 met expectations and ten
failed. All 24 transport matrix cells passed their then-declared expectations.
Five native short-name DNS assertions failed in each dual-stack mode: macOS
returned a correct native IPv4 address together with an unwanted fake IPv6
address. Full native names and search lists worked. Fix bare-name handling rather
than disabling dual-stack DNS or discarding search domains.

Each of the four shutdown captures also observed one queued DNS PTR query to the
former TUN DNS endpoint on the native interface after teardown began. There was
no such native fake-address packet during the active interval. DNS removal must
complete under a transition guard before the tunnel is retired.

The previous IPv4-oriented template suppressed client AAAA but intentionally
allowed captured IPv6 through the proxy in actual Global mode. This is distinct
from native proxy bypass: its tested capture and silent-ping fixes still passed.
Global ignores its IPv6 rejection rule, and a proxy can resolve a hostname to IPv6.
V3 adds strict IPv4 destination enforcement; `dns.ipv6: false` and
`ip-version: ipv4` alone are insufficient. This stronger contract needs new tests.
See `MIMO_IPV6_PROFILE_ANALYSIS.md`,
`MIMO_DUALSTACK_TEST_PLAN.md` and `MIMO_DUALSTACK_TEST_RESULTS.md` in this directory.

## 3. Profile and engine integration

Replace production dependence on legacy Clash Verge YAML string substitutions
with one typed renderer derived from the two template structures. Address family
is a parameter, not a separate independently maintained routing implementation.
Keep validation, escaping, shared proxy selection, Rule-only bypass insertion,
root-owned runtime files, private Unix controller and profile identity hashes.
Support both existing SOCKS5 and HTTP CONNECT entries. None selected permits
Direct only. Inactive proxy edits must not reload a running profile.

Retain template TUN capture, the engine's default IPv6 TUN address, static native
LAN/Tailnet exclusions and no dynamic interface binding. Use actual engine Rule
and Global modes. Generate terminal `MATCH,Proxy` and `MATCH,REJECT` rules for
Rule; Global safety must not depend on those rules being evaluated. Unlike the
earlier managed-app analysis, this design does not implement UI Global by keeping
the engine in Rule mode. The mode-independent checks below are therefore required,
not optional follow-up work. An incapable
proxy must produce a visible failure, never a native fallback.

Productionize the pinned patched engine used by the template tests. Record source
revision, toolchain, module hashes, patch checksums and binary hash in the build
manifest; update installation/dependency checks so stock mihomo cannot silently
replace it. Preserve the existing Apple-silicon support boundary.

Engine work has three explicit contracts:

1. Keep `gvisor-no-ping`/echo suppression while retaining required IPv6 control and
error handling. Silent echo drops must not break neighbor discovery or PMTU.
2. Add a mode-independent destination-family policy. IPv4 mode rejects captured
IPv6 destinations before dialing. For hostnames, apply domain classification
first, resolve an A address through the approved DNS path, then pass that literal
IPv4 destination to the selected SOCKS5/HTTP adapter; preserve the original host
for rule matching and application TLS. Cover TCP, UDP and DNS transport without
recursive resolution. No A answer means failure. Prevent later sniffing or reverse
DNS mapping from replacing the enforced IPv4 destination with a hostname sent
to the proxy. Intentional Rule-mode website bypasses use IPv4-only resolution
and dialing too; native LAN/Tailnet exclusions remain separate. Dual-stack allows
both families.
3. Enforce authenticated private-probe listener restrictions before the Global
dispatch shortcut. The current listener sub-rule is only evaluated in Rule.
Unknown listener rules, unauthorized destinations and ordinary clients must be
rejected in both modes. Unsupported proxy UDP must reject in both modes.

Name and version new engine-specific fields only after their parser and adapter
tests pass. Do not put speculative unsupported YAML options in production output.
Reject an engine lacking these capabilities before changing the current network.

## 4. Native DNS and provider removal

Managed Mimo owns its protected resolver through core/supervisor. Render
`tun.dns-mode: disabled` in the app-managed profile so the engine does not create
a competing macOS resolver. Standalone templates use native engine ownership;
this deliberate managed-profile difference belongs in documentation and tests.

Preserve native search domains and scoped private resolvers, including non-ts.net
split DNS. The Mimo default resolver handles public queries, while native private
scopes retain native resolution. Validate external DNS data and exclude Mimo's
own resolver when taking native snapshots. Never rewrite another service's DNS
preferences or disable the user's Tailscale DNS setting.

Prevent synthetic answers for unqualified/native names. Bare names arriving at
Mimo must receive a local negative answer that permits native search expansion;
they must not be sent to public DNS or assigned fake IPv6 addresses. Ensure the
policy also covers custom private suffixes and native A-only names. Retain known
private suffix routing during disconnection so a private name does not fall
through to public DNS; remove only when authoritative native configuration changes.
Validate this design with getaddrinfo, native DNS inspection and packet capture,
not just dig against Mimo's listener.

The accepted resolver-policy design applies in both Rule and actual Global:

| Query | Resolver and failure behavior |
| --- | --- |
| Known Tailnet suffix | Native Quad100; failure remains a failure, without public fallback. |
| Known LAN/corporate suffix | Its validated native resolver; no public fallback. |
| Known private suffix without an available resolver | Local negative response, without a public query. |
| Bare one-label name | Local negative response and no fake A/AAAA allocation. Preserve macOS search domains for qualified retries. |
| Public name | Encrypted DNS explicitly through the selected proxy; no direct fallback. IPv4 returns A only; Dual-stack supports A and AAAA. |

Implement the private suffix and bare-name matches in **both** the fake-IP filter
and nameserver policy. The candidate YAML uses blacklist-mode fake-IP exclusions,
`'*'` for bare names, `'+.suffix'` for known private suffixes, and
`rcode://name_error` for local negative responses. Set `respect-rules: false`, an
explicit `#Proxy` public DoH upstream, and no public fallback pool; private
upstreams remain native in either mode. Generate network-specific private
suffix/resolver pairs from validated core snapshots, not invented static defaults.
Unknown corporate suffixes cannot be inferred from a generic template. A literal
proxy endpoint needs no public bootstrap; hostname endpoints require the separately
validated bootstrap path before delivery. These settings must be qualified in the
pinned engine, including negative-answer search expansion and no-public-query
packet assertions. Native scoped DNS and mDNS remain macOS responsibilities; this
is not a claim that every application's DNS is intercepted.

Delete the production Tailnet HTTP provider server, port 18766 requirement, file
publisher, provider refresh timers, TS-NATIVE/TS-DIRECT groups, interface binding,
provider-dependent readiness checks and GUI commands. Keep generic route/DNS
observation for network-generation changes. Do not substitute a new utun watcher
or port fallback. Legacy files/settings remain recognizable by migration and
cleanup; unrelated users of port 18766 are not conflicts after removal.

## 5. Exit verification, shared state and UI

Add a Codable shared `networkFamily` setting with IPv4 as the default when absent.
Migrate existing proxy IDs, secrets, allowlists, bypass blocks and monitoring
preferences without resetting them. Store the field with the routing revision;
a family change invalidates the whole verification attempt. Bump the daemon wire
protocol from 7 to 8, and make incompatible GUI/core pairs request reconnection or
upgrade rather than misinterpret missing fields.

Implemented revision: represent the fresh IPv4 exit, its timestamp/provider and the
approval decision independently of the traffic-family selection. The receipt is
bound to the current attempt, revision, selected proxy and network generation.
Both traffic modes require only a fresh approved IPv4 exit. Display-only history
must be explicitly stale and cannot authorize access. Country metadata never
supplies approval. See the approved 2026-11-26 revision and its qualification limits.

Request a real IPv4 HTTPS connection through the restricted proxy probe in both
traffic modes. Keep the provider pool and quotas and count actual requests. Do
not request an IPv6 exit, maintain IPv6 approval entries or pause a successful
IPv4 provider for an IPv6 failure. IPinfo uses its fixed v4 endpoint for protected
approval. Token transmission remains limited to
the selected provider's authenticated request, never URLs, diagnostics or the site.

Reference: https://ipinfo.io/developers/lite-api

Protected activation and changes always require the complete applicable receipt.
No optimistic opening is permitted: the fresh IPv4 receipt and full runtime
readiness must both pass. Retain one serialized cycle with coalesced external
events; discard stale results. A proxy without IPv6 can still pass IPv4 approval
in Dual-stack. Its unsupported IPv6 application connections fail without native
fallback and do not pause the working IPv4 checker.

Keep monitoring defaults of one hour, Never, ten-minute unavailable-provider
cooldown, manual refresh and monitoring-only Direct. Never disables periodic
checks, not mandatory protected verification or Refresh now. Refresh reports
which families were actually checked; no fresh check means no new timestamp.

The mockup and eventual native UI use the same compact layout:

- Put the IPv4 / Dual-stack segmented control in the dashboard connection card
only; do not duplicate it in Proxy settings. Disable changes during mutations.
- Reserve two address rows with stable dimensions. IPv4 mode marks the IPv6 row
Not selected; Dual-stack shows independent results and approval. Restore country
flags beside available addresses. Long IPv6 strings stay on one line with an
ellipsis, a full-value tooltip and Copy; they must not resize either card or
reflow surrounding controls. Direct describes native connectivity, not a
protected-family promise.
- Put traffic policy, public ping/ping6 behavior and DNS policy details in
Settings → General. Keep uninstall instructions and the copyable Homebrew
command on the dashboard, including the Stop → cleanup → quit → delete path.
- Keep connection, address and proxy information in the left column with compact
16-point minimum section gaps. Following the 26 November layout refinement, both
cards share the taller card's content height, aligning their bottom edges without
stretching to the viewport. Distribute the left column's remaining height around
Monitoring; keep Proxy configuration and Bypass at the normal bottom inset.
Reserve 160 points for the right column's changing status,
including failure details and recovery actions, so service rows stay in place
across approved, checking, blocked and communication states. Align
both columns to common 16 px horizontal insets. Place Stop/Activate beneath the services in the right
column, above uninstall instructions. Keep “Show menu-bar app at login” in
Settings → General only.
Use one compact 40-point row height for both infrastructure and service rows.
Keep endpoint text below names/buttons with consistent row alignment. The status
and Stop sections use 12-point vertical insets, uninstall uses 10, and all use
16-point horizontal insets. Supporting text must not exceed its track. Keep the
1040×640 default window to remove the unused bottom area; trim older standard-width
frames while retaining their top edge and custom widths. Explicit window minimums,
not the hidden Settings tree, own sizing. Shorter windows scroll content without hiding the toolbar
or footer. This is a presentation refinement, not a new verification trigger.
- Use a consistent dashboard type scale: 14 px labels, service status
and section headings (weight distinguishes headings); 12 px secondary metadata;
13 px right-column action buttons; 16 px for both IP address families and the main access-status heading. Retain
relative units, visible country flags and single-line address truncation.
- Render the Stop/Activate explanation at the normal 14 px body size and primary
text contrast. Omit the internal startup-path copy shortcut and the redundant
“Service health is reported by core” footer from the dashboard. Monitoring-only
ownership remains clear in the released-state access banner and removed rows. Do
not duplicate approval as a left-card header badge. Put the shared-account scope
note once in the bottom app footer, beside “Routing continues when this window
closes”, while services are installed. Show the uninstall command in smaller
12 px monospace text with an icon-only copy button immediately beside it. Keep
brief checkmark feedback after successful copying; respect reduced motion
and do not report success when clipboard access fails.
- Keep the shared proxy list, active selection or None, local credential storage,
Rule bypass editor, distinct Proxy/Bypass icons and all prior editing behavior.
- Proposed revision: accept IPv4 allowlist entries only; core migrates old IPv6
entries out while preserving IPv4 entries. Selecting Dual-stack does not add any
address or require an IPv6 approval entry.
- Remove Tailscale-specific service/status controls. Keep equal service rows and
`Healthy(n secs)` timestamps; communication loss means unconfirmed status, not
a fabricated stopped daemon or healthy firewall.
- Show transition guard blocking, active fallback guard and released
network controls separately. Stop retains monitoring visibility; Activate restores
services in Direct and prompts only for a concrete identified takeover conflict.

## 6. Simplified firewall and cleanup ordering

### 6.1 One live anchor, five policy phases

Use one flat live ruleset at `com.apple/000.mimo`. Replace the permission,
open-policy, probe-policy, native-transport and power-guard child hierarchy;
recognize those names only during migration/cleanup. The independent emergency
writer loads the same closed ruleset into the root, so an empty emergency child
is unnecessary. Keep one canonical renderer and validated root-owned artifacts
for Swift, boot and independent repair consumers; do not maintain several copies
of the packet policy.

| Policy | Ordered contents | When used |
| --- | --- | --- |
| Closed | Track initial incoming TCP SYNs to the captured local host-address prefix; override loopback with no state; reject access to Mimo's ordinary loopback proxy/DNS listeners; allow remaining loopback control, DHCPv4 and required IPv6 neighbor/router control; finally drop all remaining outbound IPv4/IPv6. No outbound TUN, LAN or Tailnet grant. | Managed startup, transition, sleep, maintenance or detected fault. |
| Verification | Closed policy plus TCP to the validated literal proxy endpoint/port for the installed runtime group, before the final deny. Proxy-hostname bootstrap temporarily substitutes the fixed HTTPS DNS endpoint; revoke bootstrap before granting proxy transport. | Authenticated exit checks while ordinary listeners and TUN traffic remain closed. |
| Active | Allow the owned TUN/loopback, engine-owned TCP/UDP, intentional native destinations and essential link control; silently drop remaining native outbound traffic. All outbound grants use `no state`; the exact incoming TCP prefix retains interface-bound state. | Approved Rule/Global; protection persists through engine loss or route bypass. |
| Managed Direct | Exact captured local-address TCP SYN tracking plus loopback no-state override; no outgoing restriction and no Mimo TUN/system DNS. | Ordinary Direct with managed services present. Address-only reconciliation is health maintenance, not exit verification. |
| Released | Empty live ruleset, not `pass all`; no reachable Mimo children. | Completed full Stop/uninstall release only. |

Every packet rule has a `mimo:` purpose label. The profile still owns destination
family, DNS and ping decisions for captured traffic; the active guard enforces
native fallback containment. No provider socket table, old anchor hierarchy or
root-wide permission is restored. Native compatibility is qualified independently.

Verification permits only the proxy's outer connection, which may be IPv4 even
for dual-stack destinations. PF cannot inspect its inner destination. The engine
must independently restrict the authenticated probe in **both** modes; ordinary
ingress stays closed, and old engine connections are removed before granting
verification transport. Failed socket-owner matching must fail closed, not add
a root-wide or owner-independent fallback.

The planned Closed rules are explicit below. These are design excerpts for the
owned anchor, not commands to load on Delta. Ports 7890/1053 are the managed
ordinary listeners; the renderer must use the actual validated runtime ports.

```pf
# mimo:v3:closed — prepend the captured local-address prefix, then control/deny
# Documentation-only host literals: core substitutes its validated inventory.
pass in on ! utun239 inet proto tcp from any to 192.0.2.10 flags S/SA keep state (if-bound) label "mimo:inbound:tcp"
pass in on ! utun239 inet6 proto tcp from any to 2001:db8::10 flags S/SA keep state (if-bound) label "mimo:inbound:tcp"
pass in on lo0 all no state label "mimo:inbound:loopback"
block return out quick on lo0 proto { tcp, udp } to { 127.0.0.1, ::1 } port { 7890, 1053 } label "mimo:transition:public-listeners"
pass out quick on lo0 all no state label "mimo:transition:local-control"
pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67 no state label "mimo:transition:dhcp"
pass out quick inet6 proto icmp6 to { fe80::/10, ff02::/16 } icmp6-type { neighbrsol, neighbradv, routersol, routeradv } no state label "mimo:transition:ipv6-link-control"
block drop out quick all label "mimo:transition:deny"
```

Verification inserts exactly the required transport grant before the final deny.
The renderer derives the literal proxy IPv4 address, port and numeric runtime GID
from validated private configuration; the macros below describe those inputs.
The proxy's outer IPv4 transport carries either destination family.

```pf
# mimo:v3:verification — only the selected outer proxy connection
pass out quick inet proto tcp to $mimo_proxy_ipv4 port $mimo_proxy_port group $mimo_runtime_gid no state label "mimo:probe:proxy"
```

For a hostname proxy, bootstrap uses the following grant **instead of** the proxy
grant until endpoint resolution finishes. Revoke it before verification. It is
an explicit, fixed bootstrap exception, not a failed-proxy fallback.

```pf
# mimo:v3:bootstrap — fixed encrypted proxy-endpoint resolution only
pass out quick inet proto tcp to 1.1.1.1 port 443 group $mimo_runtime_gid no state label "mimo:probe:bootstrap-doh"
```

Released is a zero-rule root, with no reachable Mimo children. A readable comment
in an artifact is not a packet rule. There is no `pass all`, port-53/853 blanket
rule, `utunN` pass, active IPv6 deny or ICMP echo rule. The ICMPv6 exception above
is limited to link control; captured ping/ping6 suppression belongs to the engine.
Validate generated syntax and live order in mimo-vm before accepting these forms.

### 6.2 One mutation protocol, separate close and open authority

Keep the independent OS-tool boot/repair path working when mimo-core or mihomo
cannot execute. Supervisor, power handling and independent jobs use the same
bounded PF mutation lock and durable generation/hold protocol. Only the
supervisor can release for protected approval; boot/repair workers can close or
perform explicitly authorized Direct/cleanup recovery, never approve an exit.
No new firewall daemon is needed.

Sleep, maintenance and fault holds are reasons in the transaction journal, not
separate anchors. Clearing one reason cannot release another. Register relevant
events before asynchronous classification; opening must compare the current
attempt, revision, engine/profile identity, network/session epochs and pending
events under the same mutation protocol. Never hold its short lock while waiting
for XPC, controller, DNS, launchd, display queries or a provider request. A late
open must not erase a newer emergency close, including across processes.

Closure is confirmed only after successful load, live rule/reachability readback
and revocation of existing PF states. A failed or partial close is **unconfirmed**,
not Blocked: abort a dependent reload/stop, invalidate approval and report the
failed stage. Recovery must not rely on a saved gate marker or matching file hash
alone. Repeated already-closed requests can join the current confirmed operation;
reusing a profile never skips checking the live barrier.

Existing PF states can bypass new rules. The incoming-access correction supersedes
the original global purge: install denial first, inspect PF state directions,
then revoke originating sources of original outbound states only. Track incoming
TCP SYNs on non-Mimo interfaces with interface-bound state, preserving replies
for SSH, Screen Sharing and TCP servers. Override loopback with `no state` so
public proxy/DNS clients cannot retain access after closure. Never use broad `flags any` recovery or
floating states. Outbound grants stay `no state`; malformed/truncated inspection
makes closure unconfirmed. Settled blocked mode retains only independently
verified native VPN transport so Tailnet incoming connections can continue.

Failure/recovery acceptance is part of this correction: user-visible cause and
recovery actions; bounded retries with no polling-triggered event loop; responsive
core/GUI controls and incoming TCP; repair followed by fresh verification; and
explicit Direct restoring native networking without requiring a successful IP
lookup. Test both Direct→Rule/Global and faults in an already-active protected
mode, for IPv4 and dual-stack. Preserve the lookup error when a provider enters
cooldown, show its deadline, and reject late verification after Direct. Source
simulation, installed networking and native UI rendering are separate evidence
scopes; see `MIMO_DUALSTACK_TEST_PLAN.md` and `MIMO_V3_INBOUND_ACCESS_FIX.md`.
The local build-10 campaign passed 60 exception/recovery simulations, four
pending-lookup Direct cancellation cases and 22 installed exception/repair rows.
Installed state queries took at most 1.597 seconds; explicit Direct restored
native IPv4/IPv6 HTTP in 9.903–12.492 seconds. Those measured bounds and the short
settled-state observations are evidence, not a guarantee against every OS hang.
**Reopened:** these installed repairs changed the fixture token after Direct,
clearing cooldown. They did not qualify same-blocked-session repair. Build 10
fails that regression; the candidate and new diagnostic contract are recorded in
[`MIMO_BLOCKED_VERIFICATION_RECOVERY.md`](MIMO_BLOCKED_VERIFICATION_RECOVERY.md).
Require one coordinator-owned failure close, epoch-fenced scheduler notices,
explicit retry of local/transient backoff, and unchanged enforcement of genuine
provider restrictions. Link every HTTP/command outcome to the check/attempt in
logs, retaining source availability and secret/IP redaction.
Unpublished build 11 now passes the installed same-session regression in all four
Rule/Global × IPv4/dual-stack combinations, with real HTTP 429/Retry-After still
enforced and one correlated close per injected transport failure. The user's
original first private HTTP failure trigger is still unproven.
Final cleanup/release must not globally flush states, disable PF, flush foreign
rules or release another owner's enable reference.

Prepare and validate candidate bytes before interrupting a healthy connection for
a user-requested edit. An external fault or relevant OS event closes promptly;
it does not wait for rendering. Once closed, load the exact final profile, install
the owned resolver, run restricted checks, join full readiness and all required
family approvals, then atomically install and read back the active guard. No post-approval profile reload or
optimistic opening. Direct and already-deactivated events do not arm a protected
cycle merely because a timer, GUI or network callback ran.

### 6.3 Ordered release and interruption recovery

Planned Direct, Stop and uninstall share the network-release transaction:

1. Persist the requested intent and a new operation generation. Cancel obsolete verification; fence service repair and late callbacks. Confirm the temporary closed policy before changing live network resources.
2. Unregister only Mimo's resolver while its listener and TUN remain alive. Read back resolver selection, clear owned fake-DNS/cache state and drain/cancel queued queries before removing their route. A fixed sleep is not completion evidence.
3. Retire the protected profile/TUN and owned routes. Direct keeps the managed services with an idle engine; full Stop/uninstall also removes jobs/login registrations and waits for their workers. The independent cleanup transaction retains control of its closed anchor while those jobs stop.
4. Clear legacy Mimo descendants, redirects, tables, provider files and saved overrides while preserving the current transaction's guard. Restore only journaled Mimo changes; enumerate the owned namespace instead of relying on labels or a fixed list of old versions.
5. Confirm resolver/TUN/route and intended job readback. Ordinary Direct replaces the barrier with the exact captured incoming-TCP tracking policy and retains managed recovery infrastructure. Full Stop/uninstall installs an empty policy and removes owned boot configuration and recorded current-boot PF references; tracking-only Direct is not that full-release receipt.
6. Check native resolution/connectivity after release and record the result. When a connected native Tailnet is available, require the bounded fresh Quad100 TCP PTR check used by cleanup; disconnected means unverified, not a passed peer-access test. Do not restart Tailscale or change its routes/ACLs. Publish a completion receipt only after required checks pass.

Native DNS traffic is blocked by the closed policy, so the actual native DNS
connectivity check occurs **after** guard release; resolver configuration and
queued-query checks occur before it. Do not add a temporary broad DNS exception
just to make cleanup pass. If a post-release check fails, record released controls
with incomplete cleanup/verification and offer retry; do not reapply protected
blocking against the user's Direct intent or claim safe deletion.

The root-owned journal records phase and owned artifacts before each mutation.
An independent cleanup path resumes after core/engine death or a reboot, including
an engine already missing when cleanup starts. It cannot promise to drain a dead
engine; that recovery case needs separate evidence from orderly shutdown. An
unconfirmed initial barrier is a reported recovery failure, never a false blocked
state. Installed startup and repair must finish/respect pending release before
normal activation. A confirmed deactivation receipt skips rearming on later boots;
explicit install/reinstall/upgrade instead restores all services through section 7.8.

### 6.4 Failure scenarios carried forward

These are design obligations and limits, not newly passed tests. Preserve the
historical IDs so the installed-v3 evidence can reference them directly.

| ID | V3 disposition and required check |
| --- | --- |
| T01: initial guard absent | Retain boot guarding in the existing supervisor and wrapper close. Capture from before loading; traffic before PF becomes effective remains outside the guarantee. Historical 118 packets / 4.892 seconds describe one old capture, not a v3 bound. |
| T02: engine without wrapper | Require installed identity/capability checks and wrapper admission. Test bypassed/missing wrapper; do not assume the historical rejecting startup TUN exists. |
| T03: failed/partial closure | Test PF load, readback and state-revocation failure with existing flows. Report unconfirmed, abort dependent mutations and never publish blocked solely from intent. |
| T04: supervisor missing/hung | Retain independent infrastructure detection; test core/engine/supervisor failure combinations. Last approved routing may continue; no automatic kernel expiry of active approval is claimed. |
| T05: detection/reaction delay | Timestamp fault, observation, close request and effective packet denial separately under load and stalled actors. Timer intervals are not maximum leakage windows. |
| T06: running but incorrect engine | Check exact profile, DNS, routes, process and capabilities before release; retain active audits. Fault injection must expose drift outside checked properties as a limit. |
| T07: exit changes between checks | Paired family approvals apply to their observation, not every future packet. Test recheck behavior; Never does not disable mandatory event/fault verification. |
| T08: route/interface/network change | Keep early invalidation and conservative classification. Test new interfaces, specific routes, route reuse and external changes interleaved with owned mutations. The active guard must block native application traffic that bypasses the TUN. |
| T09: sleep barrier missed/fails | Keep independent power callback and epoch/hold fencing. Verify guard before normal sleep acknowledgement; forced sleep and physical login/sleep behavior remain separate qualification. |
| T10: stale native provider grant | Remove the old provider, child anchor and socket-tuple publisher. The active revision uses a scoped native tunnel snapshot and signed-process transport observation inside core's existing audit. Test revocation, exact policy replacement and migration cleanup; native-route coverage remains T08/T13. |
| T11: PF disabled/removed/overridden | Test closed-policy reachability and foreign/state interactions. Empty active PF is expected, not damage; a disabled/bypassed closed guard is not protection. |
| T12: native LAN relay | Native exclusions are intentional. A LAN/Tailnet relay can carry public traffic outside Mimo; do not present this policy as preventing all such relays. |
| T13: relying on TUN capture | Test missing routes, engine death and specific-route/interface binding. The active guard must remain effective without the engine or supervisor; test established flows too. |
| T14: optimistic opening | Remove it: full readiness and all applicable fresh family approvals precede release, including warm reuse. Ongoing drift/detection risks T05/T06 remain. |

The historical VM sleep injection and old process-failure matrix do not qualify
physical sleep or fast account switching in v3. A Network Extension redesign,
permanent active deny policy and always-on startup TUN are outside this plan.

## 7. V3 event workflows

This section and the firewall specification in section 6 define v3 behavior in
full. No earlier event sequence, provider dependency, permission-child layout or
optimistic-open path is inherited implicitly. The following contracts apply to
both IPv4 and Dual-stack and actual engine Rule and Global modes.

### 7.1 Ownership, states and command admission

| Component | V3 responsibility | Boundary |
| --- | --- | --- |
| Core | System-wide settings/secrets, proxy list and selected entry, family, allowlists, revisions, lookup budgets, scheduling and client subscriptions. | No independent GUI settings writer or lookup owner while managed services run. |
| Core coordinator | One admitted verification cycle, generation-bound supervisor requests and authenticated family-specific probes. | Cannot release PF itself or approve from a cached address. |
| Supervisor role of mimo-core | Profile/resolver delivery, runtime inspection, PF transactions, network/power/session events, service intent and recovery. | Sole protected-release authority; independent of GUI lifetime. |
| Existing supervisor and heartbeat roles | Supervisor owns all infrastructure plus monitoring/API; heartbeat only recovers supervisor. Independent progress, serialized bounded repairs and no network changes for heartbeat repair. | No additional core job. Same durable intent/hold protocol; no approval from heartbeats. Damaged executable or removal of both roles requires installation repair. |
| Patched mihomo | Capture, mode-independent family/probe restrictions, ordinary routing, DNS and silent echo drops. | No authority to approve its own exit or clear PF. No Tailnet provider subscription. |
| GUI/widgets | Display authoritative snapshots and inspection ages; submit explicit authorized commands. | Communication loss is unconfirmed status, not proof that a daemon stopped or cleanup completed. |
| Released GUI monitor | After confirmed full deactivation only: anonymous native exit observation in isolated account storage. | No shared secrets/settings writes, privileged operations or allowlist enforcement; pauses with inactive account/closed GUI. |

Core and supervisor each serialize their own mutations. Read-only state,
subscriptions and the authenticated liveness channel bypass those mutation
queues. A machine settings/secret change is one owner-only atomic revision commit.
Full settings edits require the expected revision; mode-only commands apply to
the latest settings rather than overwriting concurrent proxy edits. An installer
maintenance operation excludes new mutations but permits status, close and cleanup
progress. Late GUI responses cannot overwrite a newer shared snapshot.

| State | Required meaning |
| --- | --- |
| Unavailable / protection unconfirmed | Live state or closure cannot be proved. A failed readback cannot appear as Healthy or Blocked. |
| Closing | A close was requested; effective packet blocking is not yet confirmed. |
| Blocked / Validating | The closed policy and required state revocation are confirmed. Validation may prepare/load the candidate while ordinary traffic stays closed. |
| Checking | Restricted Verification policy and private listener are ready; ordinary applications remain closed. |
| Active Rule/Global | A complete current receipt and full readiness passed; root PF readback exactly matches the active guard. The profile/engine owns routing; PF contains native application fallback. |
| Restoring Direct | Intent changed and cleanup is in progress; neither old approval nor a release request proves completion. |
| Direct | Owned protected DNS/TUN controls are removed; the exact committed literal-address incoming TCP tracking policy remains without outgoing restrictions, and managed services remain. |
| Monitoring only | Full deactivation receipt and expected job absence are confirmed. Network controls are released; only the account's anonymous GUI monitor remains. |
| Cleanup incomplete | Report the failed phase and actual live policy. If PF was already released, say so; do not invent blocking or safe deletion. |

Every transaction binds operation ID, settings revision, selected proxy, family,
profile hash, engine identity and network/session epochs. Holds and pending-event
tickets are generation-bound. Readiness cannot clear a sleep/maintenance hold;
a late close/open cannot override newer Direct intent. PF policy and publication
follow section 6.2; a saved marker is not live enforcement evidence.

### 7.2 Complete trigger inventory

| ID / trigger | Protected Rule/Global | Direct / full deactivation |
| --- | --- | --- |
| V01 Boot, core/supervisor restart | Inspect durable intent; close before protected setup, honor service Stop/maintenance, restore intended roles and verify a new receipt. Supervisor restart also invalidates approval. | Managed Direct restores without approval. Completed deactivation leaves jobs absent; interrupted release resumes cleanup before activation. |
| V02 Mode, active proxy or family change | Validate candidate, admit revision, close and run section 7.5. Both traffic-family settings require one fresh approved IPv4 from this attempt (approved 2026-11-26 revision). | Save proxy/family without activation. Selecting None/removing the active proxy restores Direct. No selected proxy permits Direct only. |
| V03 Bypass Apply | Rule validates and reloads under a fresh cycle; Global saves blocks for later Rule use without reload. Invalid drafts cause no mutation. | Save only while core is active. Full deactivation cannot create a second machine-settings owner. |
| V04 Inactive proxy CRUD, drafts, display/login preferences, refresh interval | Persist or display only; no unrelated profile reload, lookup or close. Editing the active proxy is V02. | Same admission rules; no protection cycle. Released refresh preferences are isolated to that monitor. |
| V05 Allowlist, verification-provider selection or active provider credential | Invalidate the affected receipt and verify with the new revision. Removing an approved address cannot leave the old receipt effective. Country metadata never grants approval. | Observe under updated preferences when relevant, with no native-traffic gate. Machine credentials remain unavailable to released monitoring. |
| V06 Refresh now, provider Test, Retry, periodic/deferred refresh | Shared scheduler applies quotas/cooldowns and joins/coalesces in-flight work. Every admitted protected lookup uses section 7.5 and reports its real result. Never disables only periodic refresh. | Managed core observes native exit; after full deactivation the anonymous GUI monitor does so. Neither closes PF for a Direct check. |
| V07 External IP/DNS/route/interface/VPN/service-order/location change | Relevant/unknown changes invalidate and request early closure; classify and coalesce a fresh cycle. | Coalesce an owned off-actor local-address tracking comparison in managed Direct. Changed addresses update only the incoming prefix: no close, profile/DNS reload or event-only exit lookup. Released monitoring can follow another VPN's exit. |
| V08 Exact owned mutation or known telemetry | Ignore only positively classified keys; resolve their tickets without clearing unrelated external events. | No routing or lookup side effect from ignored notifications. |
| V09 Proven private-only native DNS/route change | Preserve native scopes/search configuration without provider/PF publication. In-place resolver update requires proof that public routing/capture/approval dependencies are unchanged; otherwise V07. | Native configuration stays authoritative; no Tailnet control, provider refresh or port retry. |
| V10 WillSleep, wake, sleep cancelled | Establish power hold/epoch and confirm close before normal sleep acknowledgement. Wake/cancel remains closed until the current generation verifies. | No protection guard or event-driven approval. Released monitoring follows account activity. |
| V11 Lock/unlock, login/logout, console/display change | Supervisor invalidates once per real transition. Multiple GUI windows do not each request global rechecks. Bounded display sampling cannot block login/session handling. | No protected cycle; released account monitoring pauses/resumes with that GUI. |
| V12 Core/engine missing or hung; failed process/profile/DNS/route audit | Supervisor/independent checker closes, records observation/effective times, repairs only intended services and requires new verification. | Respect Direct/released intent; stale protected faults cannot reinstall blocking. |
| V13 PF/launchd drift or infrastructure timer | Compare expected live phase. Empty active root is a fault; ineffective closed root is a fault. Repair closed and reverify; never recreate old provider/PF children. | Managed recovery retains empty packet policy; full release removes repair jobs. A stale surviving worker must respect release intent/receipt. |
| V14 Core/engine Start/Stop/Restart or profile Reload | Confirm closure before destructive mutation; persist explicit service Stop intent. Restart/reload requires verification. Lower-level core Stop leaves independent blocking, not silent Direct. | Respect saved service intent and native networking. Dashboard full deactivation is V15. |
| V15 Direct, Stop engine and use Direct, uninstall | Cancel old work and execute section 6.3. Stop/uninstall additionally removes all owned privileged services. | Idempotent cleanup; confirmed Stop shows Monitoring only and Activate. Already-clean Direct causes no new guard cycle. |
| V16 Install/reinstall/upgrade/Activate | Stage/validate, request scoped conflict consent, restore all roles and qualify health; preserve protected mode only with fresh approval. | Previously inactive installations start all services in Direct. No port 18766 or provider readiness dependency. |
| V17 GUI open/focus/reconnect/quit, widgets, logs/copy | Read state or perform the explicit command only. Communication loss causes reconnect/unconfirmed presentation, not an automatic restart, check or close. | Same; anonymous released monitoring is the explicit exception. |
| V18 Timeout, cancellation, crash/reboot during a transaction | Reject stale completions; resume from journaled phase with confirmed closure or fresh verification required. Desired settings and effective profile remain separate. | Resume release, not superseded protected work. A failed native check after release remains incomplete without reblocking Direct. |

### 7.3 Boot, independent recovery and service intent

Before opening managed access, the existing supervisor and engine wrapper consult the
root-owned release/maintenance journal. Confirmed full deactivation means no
Mimo boot barrier or daemon respawn; pending release is resumed by cleanup.
Otherwise establish Closed before protected engine startup or migration. Saved
Direct proceeds to ordered restoration without an allowlist check. A usable
network before the supervisor runs remains the T01 protection gap.

Core loads shared settings/secrets and starts a separate liveness pulse; supervisor
starts bounded power/session/network observation and checks intended jobs. Cold
protected startup and supervisor-only restart require section 7.5 regardless of
an old active marker, cached address or live core heartbeat. The engine wrapper
checks pinned binary identity/capabilities before starting its approved profile.
An unsupported engine remains a visible setup failure, never a stock fallback.

The independent checker compares phase-specific live PF and job state. In active
Rule/Global, the live root must exactly match the prepared active guard alongside
the matching receipt and runtime checks; an empty root requires closure. Missing core,
engine, supervisor or invalid closed policy requests Closed and invalidates the
receipt before repair. A process being present is not evidence that it responds.
Explicit Stop flags prohibit respawn. Full installation is the separate explicit
operation that restores all roles regardless of previous deactivation.

Independent jobs can close, or finish an already-authorized Direct/removal
transaction. They never infer approval from heartbeat renewal. If every observer
is dead while active, the active guard continues blocking ordinary native public
egress. Existing authorized engine/native paths remain permitted: the policy has
no automatic kernel lease expiry. Measure both containment and recovery.

### 7.4 Settings, candidate preparation and cancellation

Prepare and validate candidate bytes before interrupting a healthy connection
for a user edit. Classify the change from its actual fields: inactive proxy,
Global-mode bypass blocks, interval or appearance changes are save-only; active
proxy, protected mode/family, allowlist and verification credentials invalidate
approval. Validate domain blocks and credentials without logging their contents.
A bad draft or revision conflict does not modify routing or persisted settings.

After admission, fence the old receipt and confirm closure before committing an
affected protected configuration. Commit may reuse that pre-commit acknowledgement
only within the same in-flight edit, with unchanged network/transition generations
and a still-blocked state. Otherwise close again. Clear the reusable barrier when
the edit finishes; never reuse a failed or superseded reply. Preparation and fresh
IPv4 verification remain mandatory for effective protected family changes. Emit
`mimo_configuration_barrier_reused` when omitting the duplicate standalone close.
Direct family selection is save-only. Only a confirmed close allows profile/service
mutation. Runtime failure after persistence
retains the desired revision but reports its failed application; it must not claim
that the old profile satisfies the new settings or silently roll back credentials.

One core cycle and one supervisor mutation owner serialize effects. Concurrent
read-only rendering/installation checks are allowed, but join before their
outputs are used and discard results from obsolete generations. Manual refreshes
join an already applicable check; unrelated settings cannot be merged into an
already-approved receipt. External changes mark the cycle dirty and schedule a
coalesced follow-up, not simultaneous profile reloads.

The [26 November event audit](MIMO_EVENT_TRIGGER_AUDIT.md) identifies non-trigger
classes and preserves the failing-before-fix duplicate-close trace. Provider
fallback after a real failure is not an extra user event. The current hourly
timer retains its scheduled cadence after user checks, so it can legitimately
fire shortly afterwards; changing that cadence is outside this correction.

Direct/Stop invalidates protected work first. Cancellation cleans temporary
credentials/artifacts and settles only that generation's tickets/holds. It cannot
clear a newer fault, sleep or maintenance hold, release stale approval, or let a
late callback reblock a completed Direct transition. Communication loss alone
cancels GUI requests, not shared operations.

### 7.5 Protected preparation, verification and opening

1. Register the operation generation, applicable holds and early-event tickets. For external faults, request closure promptly without waiting for rendering. Run bounded read-only preparation concurrently where safe.
2. Load and confirm Closed, including rule/reachability readback and existing-state revocation. A failed stage is unconfirmed and aborts dependent mutation. End old engine connections before permitting private verification transport.
3. If the selected proxy needs hostname bootstrap, unregister Mimo's resolver and drain/cancel queued DNS while the previous TUN/listener is alive, then retire that TUN under the guard. Grant only the fixed encrypted bootstrap transport, resolve the proxy's literal IPv4 address, revoke bootstrap and install the exact proxy grant. Literal proxies skip bootstrap.
4. Load the exact final family/mode profile once. Engine-owned macOS DNS registration is disabled; core/supervisor publishes the protected resolver with native scopes/search domains preserved. Verify binary capabilities, process/profile identity, controller, listener ownership and complete IPv4/IPv6 capture including NAT64. Strict IPv4 still captures IPv6 in order to reject it.
5. Keep ordinary listeners/TUN traffic closed. Permit authenticated IPv4 provider HTTPS through the restricted private listener; its ACL executes before actual Global dispatch. Run one required IPv4 verification in both traffic settings, with credential-host and quota constraints. No IPv6 approval request is made. Proxy outer address family does not prove application connectivity.
6. Join full critical readiness and the fresh allowlisted IPv4 result from this attempt. Recheck revision, proxy/traffic family, process/profile identity, network/session epochs, active holds and unresolved classifications. A missing/stale IPv4 receipt, failure, timeout or pending event cannot open. No warm optimistic exception exists.
7. Under the shared PF protocol, satisfy only this operation's holds and install the prepared active guard if nothing newer supersedes it. Confirm live readback, then publish the receipt and Active state. No profile reload occurs after approval. Subsequent audits detect drift and can revoke, but never substitute for the pre-open checks.

The family restriction is part of readiness: IPv4 rejects public IPv6/NAT64
literals and pins hostname outbounds to resolved IPv4 addresses; Dual-stack allows
proxied IPv6 after the IPv4 exit is approved; no IPv6 exit allowlist is maintained. Unsupported proxy UDP rejects,
not DIRECT. Captured ping/ping6 is silently dropped in both modes. Prove these
capabilities in engine tests; a successful exit lookup alone does not prove them.

### 7.6 Network, DNS, power and account events

The installed supervisor is the only system network observer. Compare AirPort
and network-location values before early closure: exact unchanged values and
known scan/Busy/timestamp telemetry are ignored, but association, power, missing
or unknown fields remain relevant. Ignore owned resolver/TUN/route notifications
only when they match recorded process/configuration identity; an utun name alone
is insufficient. Owned-baseline updates cannot absorb external changes.

A batch may contain both owned and external keys. Register classification tickets
before asynchronous work; resolve only the relevant ticket, retaining unknown or
external changes. Approval waits for all classifications. External changes during
a cycle make it stale and coalesce a follow-up while closed; a new event during
that follow-up can require another cycle. There is no unconditional second-attempt
opening or time-only debounce that discards safety events.

Native private DNS scopes/search domains are preserved by the core-owned resolver
from validated native snapshots that exclude Mimo itself. Update private-only
configuration in place only with positive evidence that public proxy routing,
capture and receipt dependencies are unchanged. Revoke/reverify exit-node,
subnet-router, relevant public-route or unknown changes. There is no Tailnet
provider refresh, separate socket-tuple writer, profile interface binding or port fallback.
While Active, the existing audit can atomically replace signed native-transport
scopes under the shared mutation lock. Native tunnel identity changes close and
reverify; the interface-scoped Tailnet pass cannot transfer to a physical route.
Private-name failure cannot silently fall through to public DNS.

Power handling runs on an independent bounded path. CanSystemSleep is acknowledged;
WillSleep registers its hold/epoch and attempts confirmed Closed before normal
acknowledgement. A failed close is unconfirmed; forced OS sleep remains a limit.
Wake or cancelled sleep advances the epoch, clears only its settled power hold
and verifies the new generation while protection stays closed. Session/display
callbacks cannot remove a power or maintenance hold.

Keep console/session sampling separate from display queries, with at most one
bounded display request and no WindowServer wait on the power/session path. Expire
unknown observations and reject old-account responses. A real lock/login/console
or relevant display transition invalidates once; two GUIs do not double-own it.
In managed Direct these events neither close PF nor request an event-only exit
check. Relevant address changes may reconcile only the captured incoming TCP
prefix, with no profile/DNS mutation; unchanged inventories remain silent. Released GUI monitoring pauses/resumes with its account and observes native
changes independently because no privileged service remains. Physical login/sleep
responsiveness requires physical-Mac qualification, not only injected VM events.

### 7.7 Refresh scheduling, provider failure and inspection timers

Managed core owns one machine budget and in-flight lookup state. Startup, manual,
periodic and admitted retry requests return a real outcome: performed, joined,
skipped with reason, or failed. Same-IP success advances the successful family's
check time; a skip, cached display or failure does not. Never disables periodic
refresh, not manual requests or mandatory protected startup/event/fault checks.
Direct observes without approval; ordinary network/session events alone do not
schedule managed Direct lookups. Released monitoring can follow native VPN changes.

A provider whose required IPv4 request fails is skipped or paused for ten minutes,
or longer when Retry-After requires it; try another eligible provider within the
operation deadline. Keep per-machine budgets across restarts/accounts. No eligible
provider for IPv4 approval leaves protected access closed. Service, profile,
DNS-readiness and PF faults are their own errors, not provider cooldowns. Count
actual requests; display history cannot replace the current attempt's IPv4 result.

| Timer / bound | Initial v3 contract | Expiry or failure |
| --- | --- | --- |
| Periodic exit refresh | One hour by default; Never is available. | Admitted work follows section 7.5 in protected mode; Direct stays native. |
| Provider local cooldown | Ten minutes for automatic retries; longer Retry-After remains binding. | An explicit repair/Retry may retry one local/transient failure. Never bypass provider restrictions or machine quotas; no automatic loop. |
| Managed lookup operation | Bounded overall deadline, initially 60 seconds, including required IPv4 observation and provider attempts. | Cancel/fence late work; missing IPv4 approval cannot open. |
| Core liveness / supervisor watchdog | Separate authenticated pulse and watchdog at one-second intervals; expire a lease after five seconds without a valid pulse. | Protected close/recovery; liveness is not exit approval. |
| Independent infrastructure inspection | Normal ten-second cadence; ownership deferrals retry1/2/4seconds, physical completion coalesces one 1-second reconciliation. Stored health older than35seconds is overdue. | Preserve scoped actual observations; no IP check from a mere deferral. Close/repair once per current failure episode, subject to durable intent. |
| Console/session sampling | 500 ms; bounded separate display work, with stale responses discarded. | Unknown relevant observation invalidates protected approval without blocking loginwindow on the query. |
| GUI state/subscription | Short state probe, initially 3 seconds; subscription freshness deadline initially 8 seconds. | Unconfirmed display/reconnect only; never assume global enforcement failed. |
| Installation health | Up to 120 seconds, requests bounded to 10 seconds, within the 150-second installation bound. | Report the actual failed/unconfirmed stage; timeout is not successful installation. |

These values are initial operating bounds to verify against source during
implementation, not maximum leakage windows. Timestamp fault occurrence,
observation, close request and effective packet denial separately. Queuing, PF
failure and process suspension can extend effective response. No post-open audit
grace period grants traffic pending unperformed critical checks.

### 7.8 Installation, Direct, full removal and resumption

All network release follows section 6.3, including Direct, full Stop, uninstall
and interrupted recovery. The sequence is explicit:

`persist intent / cancel old work → confirm guard → unregister owned DNS with listener/TUN alive → read back and drain queued DNS → retire protected TUN/routes → remove intended jobs and legacy resources → verify resource removal → release guard → check native access → completion receipt`

Direct retains core/supervisor and an idle engine. Stop/uninstall removes all owned
privileged roles, repair/boot jobs and login registrations; a separate privileged
cleanup transaction retains its guard while they exit. Clear every old Mimo
filter/NAT/table descendant, exact persistent boot stanza, provider artifact and
journaled IPv6 override, preserving unrelated owners. Release only recorded
current-boot PF enable references. Labels aid inspection, not ownership discovery.

Native DNS readback before release checks configuration, not connectivity through
a blocked path. After release, a connected native Tailnet must answer a fresh
TCP PTR query to Quad100 for its native IPv4 address, with at most three bounded
attempts; disconnected is explicitly unverified. Do not restart Tailscale or claim
that DNS proves every peer reachable. Post-release check failure leaves controls
released and completion incomplete, offers retry and never reinstates protected
blocking against Direct intent. A dead engine cannot be gracefully drained;
interrupted recovery must record removal/readback as distinct evidence.

Full Stop reaches the Monitoring only state after verified receipt and job absence.
Uninstall additionally removes app-managed installation artifacts; Stop retains
app/settings and the anonymous GUI monitor. Both retain cleanup logs even after
core is absent. Activate ends the anonymous observer before connecting to newly
installed shared services. Shared proxy edits require that core ownership again.

Install/reinstall/upgrade/Activate first validates signature, pinned engine,
capabilities and staged assets, then inspects conflicting jobs, listener owners
and process start identities. Ask for the concrete takeover; Cancel, timeout or
noninteractive conflict aborts without stopping anything. After consent, unload/
disable only the inspected conflicting jobs, terminate the identified standalone
engine, wait boundedly and rescan. A changed/new process requires new consent;
a native Tailscale tunnel alone is not a conflict. Do not delete another package's
files or automatically restart its VPN during Mimo rollback.

Serialize installation under machine maintenance ownership, fence normal repair,
then restore all Mimo roles even if an earlier Stop removed them. A formerly
inactive installation activates in Direct; an intended protected installation
requires fresh section 7.5 verification. Health includes core/supervisor endpoints,
engine identity/controller/listeners, resolver/TUN and phase-correct PF. Port 18766,
Tailnet provider files and their health checks are absent. Do not publish success
from launchctl process presence alone. Rollback restores only Mimo-owned state and
reports whether a consented conflicting service remains stopped.

### 7.9 Runtime failures, GUI health and diagnostics

An authoritative missing/hung runtime, changed profile/capture route, missing owned
resolver or ineffective closed policy invalidates the receipt and requests Closed.
Recovery honors latest intent and service Stop flags, then repeats full readiness
and applicable family checks. UI communication failure alone triggers no such
operation: reconnect read-only, preserve the last observation as dated/unconfirmed,
and reject responses from old sessions or revisions. GUI quit cannot stop managed
protection. Widgets read snapshots without an independent lookup or service owner.

Expose actual inspection ages using `Healthy(n secs)`. A cached response cannot
reset its check time; an old inspection is stale, while a disconnected client is
communication-unconfirmed. Removed jobs are distinct from intentionally stopped
roles, and a loaded profile is distinct from confirmed protection. Pausing or
copying the Event Log has no effect on monitoring or enforcement.

Record operation/attempt, revision, family, source/classification, process/profile
identity, hold reason, monotonic phase timing, requested and read-back PF policy,
approval outcome and cleanup phase. Separate close request, confirmed block,
lookup success, actual release, native readback and completed removal. Preserve
ordered `mimo_cleanup_step` events in a bounded readable installer log after
daemon removal. New schema/event names are implementation work, not claimed
emitted records. Never log tokens, passwords or private DNS contents; address
visibility follows Diagnostics.

T01–T14 in section 6.4 remain explicit limits and qualification obligations. A
confirmed closed policy can survive process death only while PF, state revocation
and the upstream anchor path remain effective. The active guard must prevent
ordinary native fallback on engine/route failure; intentional native destinations
and relays remain outside that claim. Measure faults and recovery; do not call unavailable tests passed.

### 7.10 Implementation and validation mapping

Source names identify work locations, not unchanged behavior to inherit. The
sequences and policies in this plan take precedence over older implementations.

| V3 contract | Refactoring locations | Required qualification |
| --- | --- | --- |
| Shared admission, settings and family receipt | `DaemonService`, `MimoCoordinator`, `MimoCommandFence`, `MimoLookupSession`, shared routing/storage models | Concurrent edits, expected revisions, fresh IPv4 approval, late-result rejection, quotas and Never/manual results (approved revision). |
| Flat PF and independent holds | `MimoFirewallPolicy`, `MimoSystemRuntime`, `MimoPowerGuard`, `Sources/MimoDaemon/pf-guard.pl` | Parsed/live rule order, state revocation, wrong-owner probe denial, independent close versus stale open, partial failures, disabled PF and foreign-rule preservation. |
| Network/power/session faults | `MimoNetworkObserver`, `MimoSupervisor`, readiness/session observers | Mixed batches, exact owned recognition, events during follow-up, all eight core/supervisor/engine presence combinations from closed and active states, hung processes and physical login/sleep. |
| Native DNS and strict family capture | `MimoDNSConfiguration`, `MimoProtectedDNS`, `MihomoProfile`, pinned engine patches | All prior short-name failures, custom split DNS, IPv4 destination pinning, actual Rule/Global, proxy failures, NAT64, silent echo drops and native exceptions. |
| Removal and installation recovery | `release-network.pl`, installer/boot scripts, `MimoReleasedMonitor` | Legacy fixtures, interrupted phases, DNS-before-TUN captures, native access after release, reinstall restoration and monitoring without daemons. |
| Client communication and Event Log | `PublicIPMonitor`, presentation, widgets and installer diagnostics | No mutation on reconnect, correct age/unconfirmed/removed states, two account GUIs and durable progress after daemon removal. |

Section 9 defines the profile and installed-app campaigns. Record scenario counts
and the expected gate state in the case manifest before execution. Historical
profile passes, denied connections and unavailable physical cases are not v3
installed-app success counts.

## 8. Implementation sequence after approval

1. Add shared family/receipt models, backwards-compatible storage and engine
capability checks; cover migration and concurrent GUI edits before UI wiring.
2. Build the pinned engine changes and canonical profile renderer; qualify strict
IPv4, dual-stack, private probes and ping behavior in isolated VM fixtures.
3. Implement core-owned DNS corrections, remove the provider, and replace the PF
hierarchy with the flat policies and shared mutation protocol. Unify guarded
release/recovery; use generation-safe IPv4 verification and diagnostics in both traffic modes.
4. Implement the approved native UI, snapshot/menu/widget states and shared
settings commands. Keep product copy free of internal implementation details.
5. Update installer, dependency manifests and legacy cleanup. Install a local
3.0 candidate in mimo-vm, including upgrade from 2.1 and a clean install.
6. Run the complete profile and installed-app acceptance campaigns, update the
evidence/docs, fix failures and rerun affected groups. Do not publish to GitHub
as part of this instruction; release authorization remains separate.

## 9. Qualification plan

Use Delta only for controlled DNS, SOCKS5 and IPv4/IPv6 service fixtures. Network
control mutations occur only inside mimo-vm. Take a VM recovery snapshot, preserve
settings, use the out-of-band guest/admin channel and enforce watchdog cleanup.
Keep fixture credentials, private hostnames and raw captures in owner-only local
artifacts. Public evidence contains redacted summaries and reproducible hashes.

Run the existing 3,620-case profile campaign against the v3-rendered candidates:
four family/mode combinations, six proxy capability behaviors, 3,120 matrix cases
and 500 focused cases, plus parser/capability checks. Update expectations openly
for strict IPv4, actual Global restrictions and bare-name DNS. Preserve the old
results as the baseline. Expected denial is not counted as successful connectivity.

Repeat all applicable transport, DNS and lifecycle scenarios through the installed
app. Under the approved IPv4 approval policy, a proxy that cannot reach IPv6
may still open after approved IPv4 verification; IPv6 attempts must fail without
native fallback. Earlier paired-approval gate results are historical. Create an explicit installed
case manifest with gate expectations; do not describe a standalone profile test
as installed-app qualification. Use VM-only controlled provider responses and
temporary fixture trust where required, retaining production hostname, TLS and
credential restrictions. Restore all temporary trust and DNS at cleanup.

Add these mandatory regression groups beyond the existing profile cases:

- IPv4 in Rule and Global: literals, hostname remote resolution, A-only/AAAA-only/
mixed records, explicit SOCKS and HTTP CONNECT, NAT64 TCP/UDP, cache/warm reuse,
proxy IPv6 rejection and unsupported UDP; no native fallback in captures.
- Dual-stack: real Delta IPv4/IPv6 HTTP/TCP/UDP exchanges by name and address,
DNS answers and routing provenance, IPv6 connection failure with healthy IPv4
approval, and no native fallback.
- Approval: empty/nonmatching IPv4 list, IPv6-only legacy list migration, lookup unavailable, timeout,
revision race, proxy/family/network changes mid-check and late provider responses.
- Private listener: arbitrary destinations, bad credentials, wrong port/protocol,
ordinary public listener traffic and Global dispatch cannot evade its ACL.
- DNS: all ten previous short-name failures, native A-only and dual-stack names,
FQDNs, non-ts.net split DNS, search suffix changes, reconnects, Rule/Global reload,
Safari/system resolver, no public disclosure of private queries and no fake reply
for native names. Simulated DNS change is distinct from physical network testing.
- ICMP: silent captured ping/ping6 drop in both modes; real native LAN/Tailnet echo;
necessary ICMP errors, PMTU and neighbor discovery remain functional.
- Transitions: active traffic, family/mode changes, stop, Direct, reload, engine
crash, core/supervisor crash, sleep/wake, logout and two concurrently open GUIs.
Capture before, during and after each transition and attribute actual egress.
- Cleanup/migration: old-version PF fixtures, stale resolver settings, provider
files, reinstall after engine removal, upgrade, uninstall, interrupted cleanup,
occupied ports, declined/accepted takeover and unrelated VPN rule preservation.
- Monitoring/UI: fresh manual results with Never selected, cooldown semantics,
IPv4-only allowlist migration, rejected/last-known address freshness, draft/focus preservation,
communication uncertainty and consistent state in two account sessions.
- Correlate every native UI and failure/recovery run with GUI, core and supervisor
events. Record the expected trigger, command, verification attempt and terminal
state; fail on unexplained retries, stale commands, gate changes, service loss or
work that never settles. A visible healthy dashboard alone is not a pass. Observe
settled failures for at least 35 seconds (multiple infrastructure scans), including
supervisor startup while the existing exit is rejected in all four mode/family
combinations. Read-only navigation through Dashboard and all Settings sections
must not cause settings writes, network-change dispatch or exit verification.
- Firewall/failure matrix: map every T01–T14 case to an installed test, an explicit
architectural limit or a physical-Mac follow-up. Exercise all eight combinations
of core/supervisor/engine presence from closed and active states, plus hung
processes. Verify flat policy readback, wrong-owner probe denial, retained-state
revocation, independent close versus stale open, partial writes, disabled PF,
foreign-rule preservation and no obsolete child reattachment after repair.

Acceptance requires no unexplained failures, no unauthorized active test-flow
egress, no synthetic ping successes, no repeated short-name DNS failures and no
stale TUN DNS query on native egress after planned release. Each injected failure
must retain the documented block or cleanup behavior. Verify original native
connectivity, DNS, routes, processes, listeners and temporary trust independently
after the campaign. Report unavailable physical-Mac scenarios rather than marking
them passed. Known architectural windows remain reported limits rather than being
hidden in passing totals; measure their actual exposure and require the specified
recovery. New regression counts are recorded in the manifest before execution.

## 10. Documentation and delivery

Qualification update (2026-11-25): the corrected native transport bootstrap passed
real Rule/dual and Global/dual Tailscale reconnects, with zero measured native
bypass. A separate corrected ICMP/fault rerun passed **32/32**, with zero native
bypass or public echo replies and all 28 faults recovered, closing the historical
sender's coverage gap for those cases. The operator requested skipping sleep because
the VM would not enter it. OS counters stayed at zero, so protected and managed
Direct sleep/wake remain unqualified; screen lock is not a substitute. Preserve
the evidence and remaining obligations in
[the live lifecycle results](MIMO_V3_LIVE_LIFECYCLE_RESULTS.md).

Update README's complete feature table, usage, manual checks, protection limits
and event index in the same future implementation change. Maintain sections 6
and 7 of this plan as the v3 policy and workflow specification, with source and
evidence links added as each contract is implemented. Earlier-version records
remain historical; they cannot silently override these sequences. Extend the
dual-stack plan/results with renderer differences and separate profile versus
installed-app results.

Events must identify requested family, observed family, attempt/revision, profile
identity, approval outcome, transition reason and cleanup/readback phase. Never
record proxy passwords or provider tokens. IP visibility follows Diagnostics.
Correlate requested/confirmed close, actual policy readback, receipt approval,
release, native verification and cleanup completion separately. A successful
request or GUI presentation is not an enforcement result. Preserve installer/
cleanup events after daemon removal.

The 26 November diagnostic-storage implementation adds 5-MiB/UTC-day runtime
segments, a 60-second utility-queue retention sweep (7 days by default), and a
64-MiB/128-file budget per machine/account log directory. Machine maintenance
stays in the core/supervisor executable; the GUI manages only its own logs.
Storage work cannot initiate verification or hold a network actor. Service
stdout/stderr rotates by bounded tail-copy and in-place truncation, preserving
open descriptors without restarts. Account for its between-sweep overshoot and
copy/truncate race; do not claim lossless service-output capture. Keep live
readiness markers outside budget eviction, retain the locked 256-KiB installer
journal, and report cleanup/dropped-record counters. Implementation and test
evidence: [MIMO_LOG_RETENTION.md](MIMO_LOG_RETENTION.md).

The preview's Full plan page and Markdown download mirror this file exactly.
Label v3 behavior as proposed until implemented; do not present preview simulation
as app or physical-Mac validation. Use marketing version 3.0 for the eventual
candidate. Advance `Configuration/BuildNumber.txt` only for a newly published
build, after checking the next unused number; include the matching release
manifest and checksums.

Publication update, 2026-11-25: Mimo 3.0 build 9 and its matching artifacts are
published through GitHub and Homebrew. The public build passed install/uninstall,
bundled Stop/Activate, app deletion after cleanup and reinstall. Native UI
inspection remains partial after loss of desktop automation access; it is not
counted as complete. See [the release checks](MIMO_V3_BUILD9_RELEASE_CHECKS.md)
for the exact inventory, evidence and restored VM state.

### Dashboard access to core diagnostics (26 November)

Dashboard → Event Log now has Events, Core log, Heartbeat log and GUI log tabs.
The two existing core roles supply privacy-filtered recent JSON records through
the existing bounded local read-only API. No filesystem permission change or
new daemon is required. Pause freezes the display and exports; source loss
retains the last records with an explicit unavailable label. Core/supervisor
structured logs and stdout/stderr retain existing rotation and shared directory
budgets; explicit per-role rotation and combined-budget tests cover this path.
See README usage and MIMO_LOG_RETENTION.md for limits, including the scheduled
rather than hard-quota bound on launchd output.
