# Native-policy receipt and admission investigation

The isolated macOS worker executed **10/10 new controls once: 3 passed and 7
failed**, with no fixture errors. Production source remained unchanged. The host
compiled the harness but executed none of these controls. Sanitized results and
exact source/archive hashes are in [before-evidence.json](before-evidence.json).
All nine production inputs and four executed harness files were hash-checked
against the current repository after the worker run; all matched.

These are source-level failure reproductions, not installed application or native
UI qualification. They are separate from the earlier 22 ManualDemand controls
and the six real-PF mechanism cases on the primary VM. One staging wrapper failed
before guest execution; the corrected wrapper ran this payload once.

## Method and results

`run.py` extracts the actual `MimoSystemRuntime.auditPolicies`,
`refreshBlockedNativeTransport`, `infrastructureStatus`,
`pfHealthReceiptIsCurrent` and `gateState` members. It compiles the actual work
queue, kernel `flock` wrapper, mutation/closure epoch writer, policy renderer,
receipt matcher and health projection. Only PF command/readback facts, native
process facts, sandbox paths, boot identity and file-ownership checks are
substituted. The PF fake expands blocked policy syntax for the existing exact
readback matcher; it does not change policy behavior. No PF, VPN, XPC or network
service is started or changed.

| ID | Outcome | Observed behavior |
| --- | --- | --- |
| R1 | Fail | Active native update writes and reads back the new policy, but leaves no matching receipt. PF becomes Unknown. |
| R2 | Fail | Blocked native update has the same receipt gap; gate remains blocked. |
| R3 | Fail | A newer mutation epoch with identical policy/close epoch does not fence the old snapshot; old work writes policy and changes the epoch. |
| R4 | Fail | Superseding close correctly prevents a policy write, but the rejected active worker first changes the newer mutation epoch and invalidates its receipt. |
| R5 | Pass | A blocked worker superseded by Direct performs no write or epoch change; the new owner's receipt remains valid. |
| R6 | Fail | A newer installed policy prevents the old policy write, but rejection still changes the newer epoch and invalidates its receipt. |
| R7 | Pass | An explicitly supplied matching narrow readback receipt cannot renew the 45-second-old full-guard observation. PF remains stale. |
| R8 | Pass | Failed readback throws and cannot publish a current healthy receipt. |
| R9 | Fail | Active mutation waits on a real held PF lock and blocks MainActor admission for 0.761 seconds. |
| R10 | Fail | Blocked mutation produces the same admission delay: 0.701 seconds. |

R3 proves a missing **proposed epoch ownership fence**, beyond the current
policy-equality checks. It does not prove packet misrouting. R4/R6 are narrower,
concrete health side effects: zero PF writes, but an otherwise-current receipt
becomes invalid because `mutate` stamps before the operation's guard rejects.
The `new_owner_receipt_lost` assertion means its scope no longer matches; it does
not imply that the stored receipt object was overwritten.

R5 supplies the newer owner state/receipt directly. It tests old-work suppression,
not the real Direct release workflow or its health label. R7 deliberately supplies
a current receipt after actual successful readback so the expiry control cannot
pass merely because R1's publication bug left no receipt.

R9/R10 independently release a real held kernel lock after 0.8 seconds. A callback
requests MainActor admission after 0.1 seconds and reads state; the required
admission bound is 0.2 seconds. Both physical mutations completed. These controls
prove actor starvation under contention, not full daemon XPC latency or physical
Direct restoration. Their observations do not by themselves establish the cause
of every historical GUI delay.

## Source findings and proposed change map

1. `MimoSystemRuntime.auditPolicies` and `refreshBlockedNativeTransport` advance
   `pf-mutation.epoch` and publish `guard.expected`, but do not publish the matching
   narrow `MimoPFHealthReceipt`. Return that receipt only after exact successful
   readback, with actual observation/completion times. Adopt it only if the
   current ownership, gate, epoch and expected policy still match.
2. `auditPolicies` puts ownership checks inside `MimoFirewallLock.mutate`'s
   operation. Move them into its existing `admitting:` boundary, so rejected
   work does not stamp an epoch. Retain the blocked path's equivalent pre-stamp
   checks. A same-policy newer owner also needs an explicit epoch/lease fence.
3. Both methods await their probe off-actor but perform the final lock wait and
   PF transaction on MainActor. Move that entire bounded transaction to the
   existing serialized worker using immutable inputs and a cancellable owner;
   do not access mutable actor caches from a detached closure.
4. Integrate owner invalidation and physical joining at existing supervisor
   close/Direct/new-protected-attempt/shutdown boundaries. `cancelReadiness`,
   `beginProtectedIO`/`cancelProtectedIO`, `restoreDirectOnline` and
   `drainInfrastructure` are the relevant boundaries to review. Revocation
   must be prompt, but a newer conflicting write must join the old physical
   work; cancellation cannot abandon an executing child or mutex transaction.
5. Preserve the sequential watchdog's one-active-audit bound. A successful
   native-policy commit can request coalesced health reconciliation, without an
   exit-IP request. No-op/superseded work must not renew freshness or trigger a
   verification loop. Real readback failure remains a failure.

The existing `MimoPFHealthReceipt` and `infrastructureStatus` freshness contract
should stay conservative: a narrow receipt is not a new PF-enablement/root-anchor
or launchd inspection, and cannot extend their 35-second expiry. The broader
workflow proposal and primary mechanism tests are tracked in
[the investigation plan](../../../Design/MIMO_REMAINING_FAILURE_INVESTIGATION.md).
The baseline evidence above remains immutable. The implementation now moves both
native-policy paths onto the serial worker with an immutable owner/scope, rejects
ownership before stamping, and adopts only matching successful-readback receipts.
Runtime cancellation/drain hooks are joined by close, new protected preparation,
Direct and shutdown. The supervisor requests coalesced health reconciliation
only after adoption and treats supersession as ordinary cancellation.

`MimoFirewallLockBusy` now distinguishes acquisition congestion from command or
readback failure. Native maintenance defers only that typed acquisition timeout;
it does not renew health or request exit verification. Existing callers retain
the same localized timeout message. Actual readback failures remain failures.

The seven baseline failures passed on an intermediate source revision after the
first correction. Four additional review controls each failed first, then passed
on that source revision. The complete Shared/Core/Service source typecheck passed.
The isolated worker then ran the original ten and additional four on the same
frozen source: **14/14 passed**, with no fixture errors. All worker source hashes
still matched the repository at the end of that execution. Admission was 0.396 ms (active)
and 0.629 ms (blocked), while real lock contention held the physical operations
for 0.828 s and 0.955 s. These results qualify the extracted-runtime contracts,
not complete installed app behavior or GUI/XPC transitions. Historical failures
remain preserved.

That 14-case worker result predates the replacement of dynamic `(self)` with
canonical literal local destinations. The updated runtime also reconciles blocked
local prefixes and rejects inventory changes under the lock before stamping.
Current-source confirmation of those same 14 contracts passed **14/14** in a
separate primary-VM run; the historical worker result is not relabeled.
[Final-source evidence](../../MihomoRuntimeTests/Evidence/v3/observations/remaining-native-policy-final-source-20261128.json)
records all executed source identities and the two private archive digests. The seven new local Direct
maintenance contracts and final-source compilation are recorded in
[DirectTrackingMaintenance](../DirectTrackingMaintenance/README.md).

| Extra control | Fail-first finding | Corrected contract |
| --- | --- | --- |
| Stale-scope PF read error | Old snapshot failure surfaced as a current policy fault. | Recheck owner/scope before attributing the error. |
| Stale no-op snapshot | A same-native snapshot returned after its epoch was replaced. | Validate scope even when no policy change is required. |
| Cancellation after admission | Cancelled owner still invoked the PF command. | Check cancellation immediately before starting the child; a prior stamp remains uncertain until reconciliation. |
| PF acquisition timeout | Benign lock congestion surfaced as a recovery failure. | Defer without a PF write, epoch/receipt change or reconciliation callback. |

Diagnostic starts are emitted only when a mutation is needed. No-op one-second
watchdog observations add no event noise. Transaction records carry operation,
state/stage, policy digests and epochs, bounded error classifications, and separate
lock-wait/physical-work times; they contain no native transport addresses.

## Invocation

Run only when explicitly authorized; a failure exit is expected on the preserved
baseline:

```bash
python3 Tests/MimoServiceTests/NativePolicyReceipts/run.py .build/native-policy-before
```

Add `--compile-only` to compile without executing. The output path must be new and
under this checkout's `.build`; source snapshots, generated code, method scope,
compile log, test log and individual results are retained there.

The four additional controls are a separate invocation, not new copies of the
original ten:

```bash
python3 Tests/MimoServiceTests/NativePolicyReceipts/run.py .build/native-policy-extras \
  --only stale-scope-read-error-is-superseded stale-noop-snapshot-is-superseded \
  cancel-after-admission-skips-pf-command pf-acquisition-timeout-defers-without-recovery
```
