# Workflow second opinion — 20 November 2026

Requested by the user and run through the separate herdr session `mimo-review`, agent `claude-review`. Claude Code displayed Opus 5.5. The agent had only Read, Glob and Grep tools; it reviewed source and sanitized evidence, with no runtime execution or code changes.

Reviewed candidate package: `e8885bd45d9a6d6e71bb1ae6841af534afa6fb3caeade15a9f300a2cdc61914b`.

Claude agrees that the literal-IPv4 dependency graph follows the approved plan. It found no confirmed ordinary-traffic leak in that review, which is not a proof of leak-free operation. It does **not** consider the broader candidate ready for release.

The main actionable finding is **D1: Direct can re-block if native child-rule cleanup throws**. Codex independently checked the throw from `restoreDirect`, the generic supervisor catch calling `close`, and the Direct fence committing only after a successful operation. This path has not been reproduced in the installed runtime. It predates the staged-policy change; the passing ordinary Direct tests do not cover it.

Other findings concern native-failure retry coverage, repeated queued closes, missing mutual exclusion between parent and native PF writes, and unqualified hostname/sleep paths. The cause of the originally observed native PF apply error remains unknown; the proposed collision is a hypothesis. The native lock-timeout regression proves automatic recovery for that tested failure, not for every possible PF apply failure.

The review's statement that older timing evidence lacks stage spans is incorrect. The completed addendum compares the previous stage spans and downgrades D2 to a conditional stalled-worker/scheduling scenario. It is recorded below.

Recommended follow-up order: reproduce and fix D1; refine native failure/recovery handling and test the failure/Direct combinations; instrument final-opening substeps before further optimization; qualify hostname bootstrap; then evaluate caching status reads and pre-validating active rules. The following review recommendations are **not implemented** in this candidate.

## Original review

```text
I've finished the review. The literal-IPv4 path follows the approved dependency graph,
and I found no confirmed way for ordinary traffic to leak before the final open. I did
find one confirmed code-path defect that breaks the rule that "Direct keeps normal
IPv4", and the native-health fix recovers from the failure without preventing it. The
hostname path has no evidence from the installed build.

This was review only: I read source and the sanitized evidence, ran nothing, and didn't
touch the VM or any private files.

1. Dependency graph

The order is sound and these dependencies are unavoidable:
- Rules must be generated before they're validated.
- Install needs both blocking and validation (MimoSupervisor.swift:347-364).
- Permitting the private probe needs the installed policy, connection cleanup and the
  final profile (:373, :441-447, :479).
- The IP lookup needs that permission.
- Opening needs a fresh allowed IP, the readiness receipt, current generation and
  verification, and the power epoch (:505-526).
- For a hostname: cleanup, then bootstrap, then resolve, then re-block, then install
  the endpoint policy, then permit (:396-440).

Checking the generation again after every await, plus fence.activate, correctly drops
late work after Direct, close or sleep. Each check sits directly before the next
synchronous privileged step, with no await in between.

Safe overlap that is still missed:
- The "blocked" progress reply (:368) could be sent right after confirmed_close, since
  the gate is already confirmed blocked then. Right now it waits behind the 1.0–1.3 s
  probe-policy install.
- The final (active) rules could be rendered and syntax-checked while the IP lookup
  runs, using the same receipt pattern. Endpoint, port and mode are all known at the
  first join.

2. Findings, ranked

Confirmed code-path defects (reasoned from code; not reproduced)

D1 – Medium-High: Direct depends on the native writer succeeding, and a failure
re-blocks a user who chose Direct.
- restoreDirect installs directIPv4 first (MimoSystemRuntime.swift:368), then calls
  nativeTransportWriter.update(.init()) (:379).
- If that update throws, the power-guard clear, IPv4 apply and gate.state = "direct"
  are all skipped.
- fence.direct then leaves protected = true (MimoPowerGuard.swift:59-65), and the
  .direct handler's error goes to catch, which calls close()
  (MimoSupervisor.swift:583-585).
- That runs holdApplicationGate plus closeGate, so the user is strictly blocked.
  directRestorationAllowed stays false, so the watchdog never retries.
- Trigger: Rule with a non-empty native child (Tailscale tuples present), then Direct
  arrives while the writer fails. That failure is either a native-transport.lock
  timeout after 5 s or exactly the pfctl status 1 already seen.
- directIPv4 never references anchor "native-transport", so the child is unreachable in
  Direct anyway. Failing to clean it up shouldn't make Direct fail.

D2 – Low-Medium: some native-health failures never schedule automatic recovery.
- When the failure callback runs, it only sets infrastructureRecoveryPending if the
  current mode needs verification (MimoSupervisor.swift:53-56). A write that fails
  while in Direct leaves the writer marked unhealthy with nothing pending.
- If the user then switches to Rule, the whole ~8 s prepare runs and then fails at
  openGate:345. That ends in a plain close() (:585) with no pending flag, so the user
  stays blocked until they press Refresh or the network changes.
- Prepare also never checks native health early, so this failure only surfaces at the
  very end.

D3 – Medium as a hypothesis, but the missing mutual exclusion is confirmed: the
native-health check isn't atomic with the parent install.
- openGate checks nativeTransportIsHealthy under firewall.lock
  (MimoSystemRuntime.swift:345).
- The native writer uses a different lock, native-transport.lock
  (MimoNativeTransportWriter.swift:39). Nothing stops a native pfctl -f running during
  the parent pfctl -f at :351.
- If parent/child overlap is what caused the first failure (still not proven), the
  current fix doesn't prevent it. Each open could trigger close → recovery after up to
  10 s plus the check → re-verification of about 8 s.
- There is also a short window where the parent is active while the child still holds
  stale tuples, which match by address and port, not by process.

D4 – Low-Medium: repeated closes under a persistent native failure.
- While the desired rules keep differing from installed, the socket loop retries about
  every 250 ms. Each failure queues a full close() on the main actor
  (MimoSupervisor.swift:48-56, :608-628), which is about 10 pfctl calls, a controller
  DELETE and firewall.lock.
- That can starve prepare and Direct, and it can push pf-guard.pl --check past its 12 s
  lock deadline (pf-guard.pl:292-293). Recovery then fails too, so the failure feeds
  itself.
- Closing only on the healthy-to-unhealthy transition would fix this.

Hypotheses and low-severity items

- H1 (Low): openGate runs inside fence.activate, holding the fence lock
  (MimoSupervisor.swift:523-526). That's 2.5–4.5 s measured, and worst case is a 5 s
  lock wait plus several 3 s pfctl timeouts. A SystemWillSleep notification waits on
  that lock, so the sleep acknowledgement and barrier are delayed, possibly toward the
  macOS deadline. Sleep is not qualified.
- H2 (Low): the literal-IPv4 probe policy and the active policy always include
  1.1.1.1:443 group _mimo (MimoFirewallPolicy.swift:48). The supervisor and every
  process it spawns also run as _mimo (daemon.sh:60). That's wider than needed when the
  endpoint is a literal address.
- H3 (Info, fails closed): for the literal path, nothing asserts that literalAddress
  (:310) equals the resolved address (:405). It's the same source today, and a mismatch
  would only fail the probe.
- Receipts: I found no misuse. The fileprivate fields confine construction to
  MimoSystemRuntime.swift. Each receipt comes from a per-attempt local, and the group
  is re-read at install. The bytes check at :421 is tautological, which is harmless. A
  cancelled pfctl -n still occupies the serial queue, costing ≤180 ms of head-of-line
  wait.
- Hostname bootstrap: the code order is correct. Cleanup comes before the barrier
  clear, holdApplicationGate re-closes the barrier and flushes states before the
  endpoint install, and resolve is fenced by the generation check. None of this has
  evidence from the installed build.

3. Tests

Meaningful:
- Packet and fault captures, empty and mismatched allowlists, the foreign DNS owner,
  the engine crash, and Direct during preparation and during probing.
- parallel_timing_contract.py correctly checks ordering. It relies on timestamps logged
  by the code under test at millisecond resolution, so it's supporting evidence only.
  The 0 ms join values add little.

Critical gaps:
1. Nothing in the current evidence covers the hostname path: bootstrap, re-block,
   endpoint install, and a packet capture showing only 1.1.1.1:443 is reachable for
   _mimo during bootstrap.
2. The native-failure test injects a lock timeout, not the pfctl apply status 1 that
   actually happened. Nothing tests a native failure during openGate, or Direct while
   the native writer fails (D1).
3. Nothing tests Direct arriving while openGate/installProbePolicy blocks the main
   actor for 1–4.5 s.
4. Nothing tests sleep while fence.activate is held. Physical sleep, unlock and
   first-boot-packet protection remain unqualified, as the evidence itself says.

4. Delays (from the mimo-staged-timing.json trials)

Span: Blocking worker
Measured: 0.76–1.04 s
Assessment: Justified (barrier plus checks)
────────────────────────────────────────
Span: install_probe_policy
Measured: 1.02–1.27 s
Assessment: Biggest prepare-side cost. Includes a second -k pair (:333-334) and
MimoIPv4Configuration.apply (:335). Conjecture: the second flush is redundant, because
 closeBarrier already flushed and the barrier only has no-state passes. No per-command
 timing exists.
────────────────────────────────────────
Span: probe_policy end → preparation_join
Measured: 396 / 53 ms
Assessment: Inferred, strong: preparation had already finished, so this is mostly
response(). That's two launchctl print calls plus a health read (:638-651).
────────────────────────────────────────
Span: preparation_join → permission start
Measured: 281 / 274 ms
Assessment: Same response() cost again (:477). That's about 0.3–0.7 s total of status
building on the critical path.
────────────────────────────────────────
Span: permit_private_probe
Measured: 73–137 ms
Assessment: Justified
────────────────────────────────────────
Span: exit_ip
Measured: 1.16–1.56 s
Assessment: External, justified
────────────────────────────────────────
Span: open_gate
Measured: 2.48–2.56 s (4.476 s outlier)
Assessment: Not broken down. About 7 pfctl/launchctl calls shouldn't take a consistent
2.5 s.

On PF-lock contention: the native writer can't contend for firewall.lock, because it
uses a separate lock. The only firewall.lock contenders are pf-guard.pl --check every
10 s, IPv4 enforcement, service preferences and gate holds. The perl overlap could
explain the 4.476 s outlier, but the steady ~2.5 s floor points to intrinsic cost or
kernel-level PF serialization. Both are conjecture until lock wait and each command are
timed separately.

The slower Rule average (8.25 s vs 6.43 s) can't be attributed to anything: the earlier
runs have no stage breakdown.

5. Verdict

Acceptable for the literal-IPv4 path. Not yet release-ready overall. The ordering
matches the chart and I found no ordinary-traffic leak. However, D1 breaks the Direct
guarantee, the native fix recovers instead of preventing, and the hostname path has no
evidence.

Recommendations, in order:
1. D1: don't let a native child cleanup failure fail Direct. Log it, mark the writer
   unhealthy and finish Direct; never call close() after IPv4 has been released for
   Direct.
2. D3: hold native-transport.lock (always in the order firewall.lock → native) around
   the health check, parent pfctl -f and readback. Log a sanitized first line of pfctl
   stderr in Release builds for both writers, so the next failure is identifiable.
3. D2/D4: set the recovery-pending flag when openGate fails on native health. Check
   native health early in prepare. Close only on the healthy-to-unhealthy transition.
   Trigger recovery directly when the writer becomes healthy again instead of waiting
   for the ≤10 s poll.
4. Add sub-stage timing inside openGate/installPF: lock wait, each pfctl, IPv4 apply,
   token and info. Do this before any further performance claims.
5. Make response() cheap with cached service health, and send the blocked progress
   reply right after confirmed_close.
6. Pre-validate the active rules during the IP lookup, using a receipt bound to
   endpoint, port and mode.
7. After step 4, measure whether the second -k pair can go and whether IPv4 apply can
   be skipped when nothing changed during probe install. Also drop the now-unused
   guard.pf write (:432).
8. Add tests for each gap in section 3, starting with the hostname path and Direct with
   a failing native writer.
9. Omit the bootstrap rule for literal endpoints, and assert that the initial
   probe-policy endpoint equals the resolved address.
```

## Addendum and verification

Codex independently calculated the Rule means from the saved JSON: previous observed time **6.435 s** and opening span **1.166 s** (six Rule cases); current observed time **8.250 s** and opening span **3.123 s** (four Rule cases). These unpaired samples localize the observed regression to the final-opening span; they do not establish a cause. The explicit product-source patch includes the native-health check and the PF stdin change. Neither should be ruled out causally without measuring the individual operations.

D2 is conditional on specific scheduling plus a stalled observer before its next update. It is not a demonstrated failure under ordinary continuous polling. D1 remains code-inspected and not runtime-reproduced. D3's proposed PF collision is still a hypothesis.

```text
Review addendum

This is read-only. It's based on mimo-parallel-timeline.json (previous candidate,
package d5062e8…, 10 cases: 6 Rule, 4 Global) and mimo-staged-timeline.json (current
candidate, e8885bd…, 6 cases: 4 Rule, 2 Global).

A. Correction: the earlier candidate does have stage spans

I wrote that "earlier runs have no stage breakdown". That was wrong. The comparison
localizes the regression.

┌────────────────────────────────┬───────────────┬───────────────┬───────────────┐
│                                │  Previous:    │   Current:    │               │
│           Span (ms)            │ median / mean │ median / mean │    Change     │
│                                │    (range)    │    (range)    │               │
├────────────────────────────────┼───────────────┼───────────────┼───────────────┤
│ open_gate, all                 │ 1153 / 1280   │ 2520 / 2526   │ about 2×      │
│                                │ (803–2941)    │ (1152–4475)   │               │
├────────────────────────────────┼───────────────┼───────────────┼───────────────┤
│ open_gate, Rule only           │ mean 1166     │ mean 3123     │ +1957         │
│                                │ (1040–1278)   │ (2482–4475)   │               │
├────────────────────────────────┼───────────────┼───────────────┼───────────────┤
│ open_gate, Global only         │ mean 1450     │ mean 1331     │ no regression │
│                                │ (803–2941)    │ (1152–1509)   │               │
├────────────────────────────────┼───────────────┼───────────────┼───────────────┤
│ Parent probe-policy install    │ 1136 / 1128   │ 977 / 978     │ about −150    │
│ (probe_policy)                 │ (680–1428)    │ (715–1275)    │               │
├────────────────────────────────┼───────────────┼───────────────┼───────────────┤
│                                │               │               │ unchanged;    │
│ Blocking                       │ 862 / 1328    │ 965 / 1188    │ both have     │
│ (barrier_and_confirmation)     │ (694–2826)    │ (758–2496)    │ ~2.5 s        │
│                                │               │               │ outliers      │
├────────────────────────────────┼───────────────┼───────────────┼───────────────┤
│ Probe-policy end → IP request  │ mean 501      │ mean 616      │ about +115    │
│ start                          │ (392–643)     │ (440–752)     │               │
├────────────────────────────────┼───────────────┼───────────────┼───────────────┤
│ exit_ip                        │ mean 1269     │ mean 1316     │ unchanged     │
│                                │               │               │ (external)    │
├────────────────────────────────┼───────────────┼───────────────┼───────────────┤
│ Rule firewall-open time        │ mean 6.03 s   │ mean 7.84 s   │ +1.81 s       │
├────────────────────────────────┼───────────────┼───────────────┼───────────────┤
│ Rule time before opening       │               │               │               │
│ (firewall-open minus           │ 4.86 s        │ 4.72 s        │ −0.14 s       │
│ open_gate)                     │               │               │               │
└────────────────────────────────┴───────────────┴───────────────┴───────────────┘

What the comparison shows:
- The Rule regression is almost entirely open_gate. The observed mean rose 1.81 s, and
  Rule open_gate rose 1.96 s. Everything before the final opening is slightly faster in
  the current candidate.
- So a speedup in the preparation phase does exist, but a slower final opening more
  than cancels it. My earlier "no stage breakdown, cause unknown" statement should be
  replaced by this.
- I also said response() costs 0.3–0.7 s on the critical path. That cost isn't new. In
  the previous candidate it ran after permission, which is why permission → IP took
  200–430 ms then and takes 2–4 ms now. The new order moved it in front of permission.
  The first-join segment grew only about 115 ms in total. It's still worth optimizing,
  but it isn't a cause of the regression.
- I also said the steady ~2.5 s open_gate floor "points to intrinsic cost". That's
  withdrawn: the previous candidate ran the same nominal command list in 1.0–1.3 s for
  Rule.

Still unmeasured:
- In the reviewed patch, the only change inside openGate is a lock-protected flag read
  (MimoSystemRuntime.swift:345) plus stdin instead of a file path for pfctl. Neither
  plausibly explains +2 s.
- So the cause is either changes between d5062e8 and e8885bd outside this patch, or
  contention. Contention could be waiting on firewall.lock (pf-guard.pl --check) or
  kernel-level PF serialization with native-writer pfctl calls. Neither is timed.
- The split by mode (Rule 2.5–4.5 s, Global 1.2–1.5 s) is a measured observation, but
  from only 4 + 2 samples. Any mode-specific cause is conjecture.
- My recommendation 4 (sub-stage timing inside openGate/installPF, including lock wait)
  becomes the top performance item. Comparing the openGate and installPF code between
  the two packages is also worthwhile.

B. Qualifying D2 (native unhealthy at openGate with no recovery pending)

Two facts constrain this:
- The socket loop calls update about every 250 ms plus the probe's duration
  (MimoNativeTransportObserver.swift:211-237).
- Every call through the observer either clears updateFailed (a successful apply, or
  rules == installed returning early) or fails and queues a callback. That callback
  checks the mode when it runs on the main actor (MimoSupervisor.swift:44-58).

So the writer can be unhealthy at openGate with no pending recovery only if the last
failure's callback saw a non-protected mode, and no later update call reached the
writer before openGate.

There is no definite path while the observer is polling.
- Any later call clears the flag or fails again.
- A failure after policy.begin (:369) has its callback see protected mode, so it sets
  infrastructureRecoveryPending.
- A failure during the synchronous probe-policy install has its callback run only at
  the next suspension point (:373), which is after begin, so it is flagged too.
- If the callback is still queued when openGate fails, it runs afterwards in protected
  mode and sets the pending flag.

Conditional scenario (needs specific scheduling plus a stalled worker):
1. A Direct → Rule/Global prepare starts. policy.state.configuration.mode stays Direct
   until policy.begin (:369).
2. A native apply fails, and its callback runs at one of the suspension points before
   begin (:347 or :355). It sees Direct, so it neither closes nor marks recovery
   pending. A failure that happened while the user was really in Direct gives the same
   starting state.
3. The socket worker then stalls before reaching update for the rest of the prepare,
   probe and IP lookup (about 3–6 s). That's possible because parts of
   MimoNativeTransportProbe.check have no timeout: proc_listallpids plus the
   SecCodeCopyGuestWithAttributes/SecCodeCheckValidity loop over all PIDs. A stall
   inside update doesn't qualify: a lock timeout there is itself a failure, which
   produces a protected-mode callback.
4. openGate:345 fails, and catch → close() (:585) leaves pending false. When the worker
   resumes and the write succeeds, the writer is healthy again, but nothing schedules
   a fresh check. The user stays blocked until Refresh or an unrelated event.

Definite but separate: restoreDirect calls the writer directly
(MimoSystemRuntime.swift:379), not through the observer closure. A failure there sets
updateFailed with no callback at all, regardless of scheduling. A live observer would
clear the flag on its next call, so this doesn't create D2 by itself. Its real
consequence is D1, which stands as written.

Revised D2: Low. It depends on scheduling plus a stalled worker; it isn't a definite
path. The fix is unchanged and cheap: set the pending flag whenever openGate fails on
native health, and check health early in prepare.

There's also a related point that deserves a gap note. isHealthy means "the last
attempt succeeded", not "the native child is current". A stalled worker can leave it
true while the child's tuples go stale. That argues for adding an age bound on the last
successful update (for example, last success within N seconds) to the check at
openGate.

C. Updated recommendation order

1. D1: make Direct tolerate a native child failure.
2. Sub-stage timing inside openGate/installPF, including lock wait, plus a code
   comparison of openGate/installPF between d5062e8 and e8885bd. This is now the main
   performance item.
3. D3: serialize parent loads with native-transport.lock, and log a sanitized line of
   pfctl stderr in Release.
4. D2/D4: set the pending flag when openGate fails on native health, add an age bound
   to native health, recover directly when the writer becomes healthy, and close only
   once per healthy-to-unhealthy transition.
5. The remaining items (a cheaper response(), pre-validating the active rules, the
   second -k pair, and tests including the hostname path) keep their priority. Note
   that the response() item is an optimization, not a regression fix.
```
