# Remaining failure investigation — 28 November 2026

This is a new, user-authorized investigation following the completed
[paired confirmation](MIMO_OBSERVATION_TEST_RESULTS.md). It does not replace its
failed attempts or restart the earlier successful suites. Baseline candidate
`4263cf39` (unpublished 3.0/build 11) stayed unchanged during reproduction. The
subsequently authorized implementation and its results are recorded below;
baseline observations are retained rather than rewritten as passes.


## Final result

**24/24 distinct VM cases pass: the original 16 plus eight focused supplements.**
Seven new local Direct-maintenance controls also pass. Candidate `1942a60a`
(3.0/build 11, unpublished) is installed on `mimo-vm`; original settings, routing
configuration and hosts file are restored, with healthy ordinary Direct.
Earlier failures and fixture errors remain recorded below, not relabeled.

| Scope | Passed / planned | Evidence |
| --- | --- | --- |
| Original incoming-PF cases, corrected renderer | 6 / 6 | [Literal-destination packet/state audit](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-literal-20261128.json) |
| Original native transaction cases | 10 / 10 | [Final-source runtime controls](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-native-policy-final-source-20261128.json) |
| Added native ownership/error/congestion races | 4 / 4 | Same final-source controls; previous failing attempts retained |
| Added dynamic-destination regression | 1 / 1 | [Actual PF table/state comparison](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-dynamic-destination-20261128.json) |
| Installed SSH, Stop/Activate, address reconciliation | 3 / 3 | [Installed qualification](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-installed-after-20261128.json) |
| New local Direct-maintenance controls (separate) | 7 / 7 | [Actual-source controls with substituted PF/address observations](../Tests/MimoServiceTests/DirectTrackingMaintenance/after-evidence.json) |

The installed SSH case retained 109/109 authenticated echoes through Rule
rejection and recovery, with the same inbound PF state before and after closure.
Four 35-second observation windows each retained 27 healthy samples with current
PF evidence; maximum observed infrastructure age was 13.19 seconds. No unexpected
settled events or error-level events appeared in the final lifecycle archive.
Stop removed all owned jobs, PF rules/reference, DNS override and TUN; Activate
restored the exact candidate and healthy Direct. The address case added and
removed owned IPv4/IPv6 loopback aliases, observed two exact tracking updates,
and left gate, profile, DNS and process identities unchanged. It triggered no
exit-IP check. Alias cleanup and its independent watchdog join were verified.

These are real packet tests, extracted-method controls, and installed RPC/service
backend tests within their stated scopes. They do not claim native GUI clicks,
general UDP/IPv6 service continuity, or all-site leakage qualification. Sessions
predating first tracking or local-address reconciliation may need reconnecting.
No broad unrelated suite was rerun and no new release was published.

## Baseline scope and evidence

**16/16 new tests completed: six on primary `mimo-vm`, ten on an isolated temporary
worker.** Record diagnostic assertions separately from observed product behavior:
a test which successfully reproduces a dropped reply is evidence of the defect,
not a successful incoming-connectivity result. Compiler/setup actions are not
additional test cases. Failed execution/setup attempts are retained separately.

Primary uses an independent, narrowly scoped PF test anchor while installed Mimo
remains in Direct. It exercises actual macOS packet filtering, dedicated TCP
connections and tuple/state readback. These are mechanism tests, not installed
mode transitions or native GUI clicks. The worker runs actual extracted runtime
methods with real filesystem locks/epoch files and injected PF/native process
facts. It does not qualify a complete XPC/GUI/physical Direct transition.

The worker remains on an isolated drop-only NIC. No copied Tailscale identity is
allowed to connect; no new login or certificate trust is needed for these tests.
Only owned resources may be changed. Preserve primary settings, production PF,
root PF, unrelated states, host network settings and the pre-existing backup.
Archive evidence before restoring resources and deleting the temporary worker.

| ID | VM | New test | Required evidence |
| --- | --- | --- | --- |
| I1 | Primary | Connection born with empty Direct policy, then outbound closure | No original PF state; server generates response but client does not receive it while blocked. |
| I2 | Primary | Install narrow SYN tracking before connection birth, then close | Inbound, interface-bound state exists and response still reaches client. |
| I3 | Primary | Add SYN tracking after connection birth | Established ACK/data cannot acquire a new inbound permission; explicitly retain the startup limitation. |
| I4 | Primary | Old outbound connection receives peer data after tracking/closure | Reply traffic cannot manufacture reverse inbound permission or authorize further outbound payload. |
| I5 | Primary | Loopback listener exclusion | Local listener connection has no retained ingress state that bypasses its outbound block. |
| I6 | Primary | Remove test controls and close owned endpoints | Owned anchor empty, temporary states expire, native echo works, production/root policies unchanged. |
| R1 | Worker | Active native-policy update | Exact current PF readback yields current health evidence immediately. |
| R2 | Worker | Blocked native-policy update | Same receipt contract without opening traffic or changing gate state. |
| R3 | Worker | Same-policy mutation epoch replacement | Evaluate the proposed epoch-lease fence independently of a close or changed rule bytes; a failure is not by itself packet-misrouting proof. |
| R4 | Worker | Superseding close | Old active work cannot invalidate the close or publish its receipt. |
| R5 | Worker | Superseding Direct | Old blocked-native work cannot replace released controls. |
| R6 | Worker | Newer native policy | Old work cannot overwrite or qualify a newer committed policy. |
| R7 | Worker | Full guard expires | A narrow receipt cannot renew PF enablement/root-anchor/launchd observations. |
| R8 | Worker | Failed PF readback | No healthy receipt may be published without matching actual readback. |
| R9 | Worker | Active update waits on real PF lock | MainActor state/Direct-intent callbacks remain admissible while physical work waits. |
| R10 | Worker | Blocked update waits on real PF lock | Same responsiveness contract on the denied path. |

R7 supplies a matching narrow receipt after the actual policy update to exercise
the reader's expiry boundary even while the current writer omits that receipt.
This is an explicit test input, not a production fix. R9/R10 use a new 200-ms
actor-callback budget under an independently released 800-ms lock hold; they
measure actor starvation rather than rerunning the prior 1.2-second XPC admission
deadline. Any fixture failure is separated from a product assertion failure.

No test removes global PF states or relaxes the 35-second full-guard freshness
limit. Short TCP close/FIN timeouts, if used, apply only to new fixture states for
cleanup; record that difference from production. Retain exact source hashes,
rules, operation ownership, timestamps, exception output and cleanup readback.

## Initial causes and proposed workflows

### Incoming TCP continuity

Current `MimoFirewallPolicy.direct` is empty. Protected policies create inbound
states only from an initial TCP SYN. A session established while Direct was empty
has no such state, so a later outbound block also drops its server replies. The
previous paired diagnostic established this using exact state and response
timing; it did not retain usable tuple-level packet capture.

Candidate workflow: while Mimo services are active in ordinary Direct, retain
narrow, non-quick, interface-bound inbound SYN tracking, with the loopback/TUN
exclusions maintained. Protected closure preserves those inbound states while
revoking original outbound states. Stop/uninstall must still release all Mimo
rules and references. This changes Direct's empty-policy contract and requires
updates to Direct readback, health expectations, installer/cleanup and docs if
adopted. It is not implemented by this investigation.

Tracking cannot safely adopt arbitrary connections established before startup or
before the new tracking rule was installed. Do not use `flags any`, blanket
midstream state adoption or generic UDP reverse-state permission: those can turn
responses to old outgoing traffic into permission for further outgoing traffic.
The six primary tests establish the narrow TCP mechanism and its limits; they
do not claim UDP service continuity or complete incoming-network qualification.

### Native-policy receipts and actor responsiveness

`MimoSystemRuntime.auditPolicies` and `refreshBlockedNativeTransport` update PF
and `guard.expected` under the mutation lock, advancing the epoch, but do not
publish a corresponding `latestPFHealthReceipt`. The status reader correctly
rejects the old identity and temporarily reports Unknown until a full scan.
Both methods also wait synchronously for the final PF transaction on MainActor,
which can delay control admission when the lock is occupied.

Proposed workflow:

1. Capture immutable generation, gate state, close epoch, expected policy identity
   and native transport facts. Coalesce refresh demand to one active task and one
   latest pending task; it is infrastructure work, not an exit-IP request.
2. Perform bounded PF work off the control actor. Check ownership under the PF
   lock **before** stamping a mutation epoch. A no-op or stale request must not
   invalidate current evidence. Closure keeps its existing lock priority.
3. Recheck maintenance/release and cancellation fences before committing. Read
   back the complete expected policy under that same lock. Return an immutable
   receipt with actual epoch, gate state, policy digest and observation times.
4. Adopt cache/receipt changes on the actor only while ownership and the on-disk
   identity still match. Stale completion is discarded, never published Healthy.
   A close/Direct request cancels old ownership immediately and joins physical
   work before completing its own conflicting mutation.
5. Request one coalesced health reconciliation after a real commit. The narrow
   receipt does not refresh full PF/root attachment or launchd timestamps and
   cannot extend their expiry. A failed commit/readback remains uncertain or
   failed and follows bounded recovery, without an exit-check loop.

Return typed `unchanged`, `committed(receipt)`, `superseded`, `deferred` or
`failed` outcomes instead of treating every lost-ownership conflict as a failed
active-path audit. Only a genuine fault belonging to the current generation may
enter its existing failure/recovery episode. During a pending physical mutation,
present checking/pending with the real last-observed age; do not invent a fresh
Healthy timestamp, pause the IP provider, or label pending communication as a
service failure. A completed matching receipt restores current-policy evidence;
the independent full-guard expiry still wins if it is too old.

The existing protected I/O lease/receipt pattern is the starting point. Merely
moving closures into a detached task while retaining mutable actor state would
not satisfy ownership or race safety. Implementation decisions follow the new
failing evidence and must be distinguished from this proposal.

### Event and recovery contract for a future implementation

Native-policy maintenance must identify its operation, generation, expected gate
and close epoch, input/output policy digests and terminal outcome. Proposed
events are `mimo_native_policy_started`, `mimo_native_policy_deferred`,
`mimo_native_policy_committed`, `mimo_native_policy_superseded` and
`mimo_native_policy_failed`, followed by receipt adoption or rejection. Record
lock-wait, physical-work and actor-adoption durations separately. Native transport
addresses remain subject to Diagnostics privacy; counts and digests suffice for
routine logs. These names are a proposed diagnostic contract, not emitted events.

A no-op native snapshot does not stamp an epoch, refresh health age or trigger an
exit check. A superseding Direct/close operation revokes old ownership before
waiting for physical work. It must receive a prompt queued/admitted response;
that response does not claim network release before readback. A failed mutation
cannot publish Healthy. Existing generation-owned recovery handles a genuine
policy fault once; routine ownership deferral or receipt reconciliation alone
must not initiate fresh exit verification, penalize the provider or form a loop.

The current watchdog already awaits its native audit sequentially. Preserve that
bound when introducing off-actor work; never spawn an unbounded task on each
one-second tick. Direct has no native-policy refresh work. Ordinary Direct ingress
tracking, if adopted, needs an explicit health/readback contract distinct from
Stop/uninstall's fully released state.

## Results

**16/16 completed. Worker: 3 PASS / 7 FAIL, zero fixture errors. Primary: 6/6
mechanism assertions passed after one separately recorded host-client setup
failure (zero cases executed in that attempt).** The primary assertions include
expected reproduction of broken continuity; they are not six product-fix passes.
Historical results remain in their original ledgers. Worker source and results:
[focused controls](../Tests/MimoServiceTests/NativePolicyReceipts/README.md) and
[VM evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-native-policy-20261128.json).
Primary source is the [PF mechanism harness](../Tests/MihomoRuntimeTests/v3_inbound_state_mechanism_test.py);
its [independently audited evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-mechanism-20261128.json)
retains both setup attempts, packet/state correlations and cleanup proofs.

| Test | Result | Observed cause or boundary |
| --- | --- | --- |
| R1, R2 | FAIL | Successful native update performs one PF write and advances the epoch; current receipt is missing and PF projects Unknown. Both active and blocked paths reproduce it. |
| R3 | FAIL against proposed ownership contract | Replacing only the mutation epoch, with identical prior policy bytes, does not stop an old active snapshot from committing. This establishes a missing epoch fence, not observed packet misrouting. |
| R4, R6 | FAIL | Close/new-policy supersession correctly prevents a stale PF write, but the rejected operation has already stamped a new epoch. The newer owner's receipt becomes non-current despite zero PF writes. |
| R5 | PASS | Blocked-native work superseded by Direct does not write policy or invalidate the newer epoch/receipt. |
| R7 | PASS | A matching narrow receipt does not renew a 45-second-old full-guard observation; PF stays stale. |
| R8 | PASS | Failed readback does not publish a current healthy receipt. |
| R9, R10 | FAIL | Real lock contention delays MainActor callbacks by 0.761 / 0.701 seconds against the new 200-ms responsiveness criterion. Mutations eventually complete. |

These failures sharpen the proposed workflow: receipt publication alone is not
enough. Ownership checks must precede mutation stamping, and the lock wait plus
physical commit/readback must leave MainActor. A denied stale update must be a
true no-op. Continue using the existing blocked path's pre-stamp guard and the
reader's conservative expiry behavior as required negative controls.

Primary attempt 01 failed before I1 connected: host Python returned EHOSTUNREACH
for the dedicated fixture and for existing SSH port 22, while system `nc` reached
SSH and host/guest routes were correct. Guest Application Firewall was disabled.
This isolates a host-client reachability difference; it does not prove a specific
TCC cause or a Mimo defect. No case completed. The dedicated anchor was cleared,
endpoint/capture/watchdog processes joined, no test states remained, and production
and root PF rules were unchanged. Attempt 02 used system `nc` for host-origin
fixture connections without changing permissions or production firewall policy.

| Test | Mechanism assertion | Observed behavior |
| --- | --- | --- |
| I1 | PASS: defect reproduced | No original ingress state. Server generated the nonce reply; client received none during the two-second blocked window, then received it after release. |
| I2 | PASS: candidate mechanism | A SYN-observed, interface-bound ingress state existed before closure. Reply arrived in approximately 0.54 ms while the scoped deny remained installed. |
| I3 | PASS: limitation reproduced | Adding SYN tracking after establishment did not create state or restore replies during the two-second blocked window. Release restored delivery. |
| I4 | PASS: outbound negative | Peer data on an old outgoing connection did not create an ingress state; the following guest payload did not reach its peer while denied. |
| I5 | PASS: loopback negative | The no-state loopback override prevented a retained state from bypassing fixture-listener closure. Delivery resumed after release. |
| I6 | PASS: cleanup | Native echo resumed. Owned endpoints, clients, captures and watchdog joined; owned states expired; test rules emptied; production and root rules stayed unchanged. |

Independent capture review found 105 en0 packets and 10 lo0 packets, with no
truncated records or kernel-reported capture drops. Exact tuple, initial SYN,
state and endpoint nonce evidence supports I1–I5. These are guest BPF captures,
not a blanket on-wire leakage qualification. I4's generated outgoing nonce was
not separately stored in its case row: the live exact-nonce assertion, frozen
source, raw packets and endpoint events remain, but the case row alone cannot
reconstruct that binding. This limitation is retained without a rerun or a
weakened assertion.

The scoped SYN candidate is therefore a viable mechanism for connections born
while ordinary Direct tracking is present. It is not an installed fix. Its rule
scope/placement must respect administrator ingress policy, target local servers
rather than forwarded traffic, and retain TUN/loopback exclusions. A non-quick
pass does not by itself guarantee neutrality toward earlier non-quick rules.
Interface-bound state intentionally does not survive a change of interface.
Apple's [PF implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pf.c)
supports this flags/original-direction explanation; the tested installed kernel
behavior, not an assumption that source versions match, is the primary evidence.

Primary's first and second guest archives are retained before removal of their
two owned temporary directories. No Mimo configuration, proxy or real mode was
changed. The worker's isolated temporary VM was removed after archiving and
cleanup; primary and the pre-existing backup remain. No broad regression suite,
native UI qualification, IPv6/UDP continuity or production deployment is claimed.

## Authorized implementation and post-fix qualification

The user authorized implementation and improvement until the original 16-case
scope passes. First local candidate `7601ffe3` (3.0/build 11, unpublished) implemented:

- Ordinary Direct installs `directTracking`, consisting of incoming TCP SYN
  tracking to dynamic `(self)` and a loopback no-state override. No outgoing
  restriction is installed. Closed, probe and active policies use the same
  local-destination scope. Stop/uninstall retains the empty release policy.
- Direct restoration and its independent guard require exact tracking readback;
  owner/close-epoch checks run before mutation stamping. The child returns a
  current health receipt. Settings maintenance text and Event Log distinguish
  ordinary Direct tracking from full release.
- Native-policy preparation and the complete PF transaction run on the existing
  serial background queue. Immutable scope includes gate, close epoch, mutation
  epoch and expected policy. Cancellation and under-lock admission precede any
  write; same-policy epoch replacement also supersedes old work.
- Exact successful readback produces a receipt, adopted only under matching
  actor ownership and current disk identity. A successful adoption requests one
  health reconciliation. It does not initiate exit verification or renew the
  independent full-guard age.
- Close, Direct and new protected ownership invalidate native work and join its
  physical queue before conflicting work completes. A stale read/no-op is
  superseded, a genuine readback failure stays a failure, and bounded lock
  acquisition congestion defers to the next sequential watchdog turn.
- Routine unchanged snapshots produce no per-tick event pair. Changed work logs
  operation/state/stage, input/output epochs and policy digests, physical and
  admission timing, and commit/supersession/deferral/failure. No native addresses
  or credentials are needed in these new events.

Implementation: [policy](../Sources/MimoShared/MimoFirewallPolicy.swift),
[runtime transactions](../Sources/MimoService/MimoSystemRuntime.swift),
[owner/value types](../Sources/MimoService/MimoNativePolicyUpdate.swift),
[supervisor](../Sources/MimoService/MimoSupervisor.swift),
[guard](../Sources/MimoDaemon/pf-guard.pl).

For `7601ffe3`, the original **16/16 post-fix checks passed**: ten extracted-runtime controls on the
worker and six revised actual-PF checks on primary. I1 now requires positive
ordinary-Direct continuity, I2 crosses protected-born → Direct → closure, and I3
retains the pretracking limitation while requiring a new reconnect to succeed.
I4–I6 retain outgoing/loopback negatives and complete fixture cleanup. The primary
mechanisms use compiled production policy bytes with recorded exact fixture
narrowing; the baseline installed app remains unchanged during those six cases.
This is policy qualification, not an assertion that the new app was installed
for those cases. [Primary evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-postfix-20261128.json).

Four additional controls first reproduced failures on the initial patch, then
passed after refinement: stale-scope read error, stale no-op snapshot,
cancellation after admission, and a real five-second lock-acquisition timeout.
The worker ran these four separately from the original ten, once each on the
same final source payload: **14/14 passed, zero fixture errors**. Active/blocked
MainActor admission was 0.396/0.629 ms under 0.828/0.955-second physical lock
contention, versus the baseline 761/701 ms. These are actor-admission controls,
not complete XPC or physical Direct restoration timings.

Additional local validation: 25/25 routing tests, 40/40 guard assertions, whole
Shared/Core/Service Swift 6 typecheck, and the complete signed app/package build
passed. One local Perl-test invocation omitted its required source-path argument
and executed no assertions; the corrected invocation is retained separately.
Generated Xcode copies of all 111 Swift sources match the source tree. No build
number was advanced because nothing was published.

## Installed supplement exposed a destination-expression defect

The first installed supplement failed before changing to Rule: an authenticated
SSH session established in ordinary Direct had no PF state. Its full-snapshot
capture retained the initial SYN, SYN-ACK and successful echo; the exact installed
tracking rule had evaluations but zero matching packets. The kernel `_pf/self`
table was empty. This failure is retained in
[installed before evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-installed-before-20261128.json).
The earlier fixture narrowed the destination to a literal and therefore did not
exercise the production `(self)` expression. Its six mechanism passes remain
valid only within that recorded scope.

A new paired real-PF regression preserved the destination expression: `(self)`
created no state, while `(en0)` created an interface-bound state and passed echo.
Both used narrowly owned fixture tuples and changed no production rules. The
[paired evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-dynamic-destination-20261128.json)
retains packet, state, table and cleanup proof. Apple's
[PF interface implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pf_if.c)
supports the inference: dynamic `self` maps to the synthetic ALL interface, but
address population requires a concrete interface pointer. Dynamic per-interface
addresses also omit some IPv6 addresses, so that is not the production solution.

The corrected implementation renders canonical literal local host addresses from
one `getifaddrs` snapshot, including IPv6 link-local and temporary addresses;
Mimo's TUN is excluded. Every address is validated, deduplicated and sorted.
All generated policies retain SYN-only, interface-bound, non-quick tracking and
the final loopback no-state override. Readback must match captured policy bytes;
arbitrary hosts, networks, `any` and invalid or widened prefixes cannot qualify.
The owner-only `guard.expected` binds the exact committed inventory. The guard
does not mistake legitimate address drift for a reason to block ordinary Direct.

Core reconciles changed Direct inventories on its serial worker without a gate
closure, profile/DNS reload or exit check. It captures ownership and epochs,
checks them before mutation, publishes exact readback/health evidence, and drops
superseded work. Unchanged inventories do not mutate or refresh the health age.
Blocked native maintenance also replaces an old local-address prefix when the
inventory changes, even when native transport sockets are unchanged. Protected
active path changes retain their existing close/verification workflow. Sessions
born before initial tracking or address reconciliation can still need reconnect;
this change does not adopt arbitrary established flows or qualify UDP continuity.

Three installed checks use actual RPC/installer backends, not native UI clicks:
L1 Direct-born SSH through settled Rule rejection/recovery; L2 full dashboard
Stop/Activate cleanup and restoration; L3 Direct address addition/removal with
exact tracking and a clean event audit. Together with the original sixteen,
four race controls and paired destination regression, the VM scope is **24 cases**.
Seven new local controls cover Direct-maintenance no-op/change, supersession,
congestion and inventory drift while waiting for the PF lock. Final-source affected checks and installed results follow
below; earlier unrelated suites are not rerun.

### Final-source validation before the installed supplements

Candidate `1942a60a` was built, signed and installed on primary without changing
its saved settings or routing configuration. Its 13-address incoming prefix
matched an independently executed production renderer in the guest; Direct was
healthy and the Mimo TUN was absent. This remains unpublished 3.0/build 11.

The original **16/16** and four additional native race controls pass on the
literal-address implementation. The [six PF cases](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-literal-20261128.json)
now preserve actual guest local destinations instead of substituting them in the
fixture. The [14 native controls](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-native-policy-final-source-20261128.json)
were revalidated on primary after the temporary worker had been removed. Their
active/blocked actor-admission delays were 1.387/1.217 ms during 959/885-ms physical
lock contention. This validates actor scheduling, not a complete network roundtrip.

The [seven local Direct controls](../Tests/MimoServiceTests/DirectTrackingMaintenance/after-evidence.json)
also pass on final source. The absent-entrypoint baseline used an explicitly
documented no-op adapter; its five failures are feature contracts, not five
independent production reproductions. The seventh control used actual prior
code and reproduced stale address installation after a lock wait, then passed
with the new under-lock inventory fence. Other current checks passed: 27 shared
routing tests, 45 guard assertions, the 84-source Swift 6 typecheck, and the signed
app/package build. All 111 generated Swift files matched their authoritative
sources, and all 141 recorded build inputs remained unchanged after packaging.

An installed L1 attempt reached genuine Rule rejection with matching fresh
observed/rejected IP, current healthy PF and 33/33 SSH echoes, then stopped on a
harness DTO error before its 35-second settled interval. It is retained as an
incomplete attempt, not a pass. The assertion was corrected to compare addresses
within the typed IP observations, with fail-first oracle checks. The live-health
predicate also requires explicit healthy/current evidence. L1–L3 final results
and cleanup are recorded in the final-result section above.
