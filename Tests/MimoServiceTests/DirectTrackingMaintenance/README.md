# Direct tracking maintenance controls

These seven focused local controls cover the new runtime path that refreshes
incoming TCP tracking after the Mac's local address inventory changes. They do
not qualify incoming packets or installed GUI/XPC transitions; those are separate
installed lifecycle tests.

The harness extracts the actual runtime maintenance methods, serial work queue,
PF lock/epoch implementation, receipt validation and policy renderer. PF readback
and local address observations are injected. Only an isolated filesystem and real
kernel file lock are changed. The command fake accepts PF loads only; profile,
DNS, engine or exit-IP operations are absent from this isolated runtime.

| Case | Required result |
| --- | --- |
| Changed inventory | Replace only the tracking snapshot, adopt its receipt, request one health reconciliation. |
| Unchanged inventory | No PF write, epoch change, new receipt or reconciliation. |
| Superseding protected close | Cancel the old refresh without changing the newer epoch or policy. |
| Superseding Stop/release | Same ownership fence; no reacquisition of released controls. |
| Contended PF lock | MainActor callbacks remain responsive while physical work waits. |
| PF acquisition timeout | Defer without a policy/epoch/receipt change or recovery callback. |
| Inventory changes while queued | Reject the captured addresses under the lock before stamping, even if an observer notification has not arrived. |

The first six baseline controls explicitly used a no-op adapter for the then
missing maintenance entry point: one passed, five failed because work/lock entry
was absent. These are feature-contract baseline failures, not five separately
proven production defects. The preserved installed L1 failure establishes the
actual missing incoming tracking problem. All six passed against the new real
runtime methods. The seventh control then reproduced a stale-address install
and receipt, and passed after adding the pre-stamp inventory fence.

The final seven were then executed together against the frozen literal-address
implementation: **7/7 passed**. The separate 84-file Shared/Core/Service Swift 6
typecheck passed, with no source changes during compilation. Exact source
identities and sanitized results are in [after-evidence.json](after-evidence.json).
The contended operation took 0.838 seconds while the independent MainActor
callback was admitted in 0.021 ms. The acquisition-timeout control performed no
PF write or epoch/receipt change. Current-source confirmation of the original 14 native-policy contracts then
passed **14/14** on the primary VM. Its
[separate evidence](../../MihomoRuntimeTests/Evidence/v3/observations/remaining-native-policy-final-source-20261128.json)
retains the exact source and archive hashes; neither isolated suite substitutes
for the installed network lifecycle tests.

The supervisor coalesces genuine Direct network events and periodic inventory
comparisons. They perform no profile/DNS reload, outgoing closure or exit-IP
check. An unchanged comparison does not call PF or renew health. Actual commits
use captured literal destinations and exact readback; Stop/uninstall remain fully
released. Active protected address changes use existing protected recovery;
blocked native maintenance reconciles its local prefix under the same ownership
and receipt rules. This is not kernel-dynamic address tracking: newly assigned
addresses require reconciliation, and pre-existing untracked connections cannot
be safely adopted midstream.

Run the final seven together only when authorized:

```bash
python3 Tests/MimoServiceTests/DirectTrackingMaintenance/run.py .build/direct-tracking-seven \
  --only changed-inventory-refreshes-direct-only unchanged-inventory-is-noop \
  close-supersedes-direct-refresh release-supersedes-direct-refresh \
  direct-contention-keeps-admission-responsive direct-acquisition-timeout-defers \
  inventory-drift-under-lock-is-superseded
```

Default invocation runs the original six; the seventh is explicitly selected so
historical six-case scope remains clear. Each output must be new and under the
checkout's `.build`; all source identities, generated code, compile logs and
individual results are retained. No credentials or external network are needed.
