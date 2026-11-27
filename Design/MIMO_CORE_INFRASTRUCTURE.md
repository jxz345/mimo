# Mimo core infrastructure consolidation

## Current revision: three named background items

The user expects `mimo-core-supervisor`, `mimo-core-heartbeat` and `mihomo` in
Login Items. The installed before-test failed: only the generic `mimo-core`
registered under com.mimo.supervisor was visible in the BTM registry. The
installer regression also rejected the old shared executable/system-plist shape.

Keep the existing labels com.mimo.supervisor, com.mimo.core and com.mimo.mihomo.
Install all three plists in /Library/LaunchDaemons, using signed copies of the
same core code in the owned LaunchHelpers directory with the requested basenames.
The engine launcher execs Runtime/mihomo. No fourth job or new API owner is added.
Peer identity and repair validation use the exact role path. Upgrade removes old
Application Support plists; rollback restores their original locations and loaded
jobs. Full Stop/uninstall removes new helpers and old registrations. Intentional
engine Stop disables boot loading; Start/installation enable it again.

Dashboard health: supervisor infrastructure and peer progress retain their actual
inspection times. A live engine PID is insufficient: the existing background audit
checks its private version/capability endpoint with a bounded timeout. Profile
delivery depends on engine responsiveness. Old evidence reads Check overdue;
communication loss reads No connection/Unconfirmed, never a fabricated Healthy.
Settings Maintenance describes the three roles, reads all three through status,
provides supervisor-owned Direct recovery and links users to bounded Event Logs.
No command is executed by viewing a page.

### Qualification completed — 26 November 2026

Installed in **mimo-vm**, left in managed Direct with all three jobs enabled and
healthy. The campaign contains **98 check attempts**, including two preserved
pre-fix failures; the latest result for each of **64 distinct checks** passes.
There are **30 passed settled observation windows of at least 35 seconds**.
The final artifact passed **27 follow-up checks** after the conditional PF-write
fix. See [sanitized results and artifact identities](../Tests/MihomoRuntimeTests/Evidence/v3/named-background-services/results.json)
and the [installed harness](../Tests/MihomoRuntimeTests/v3_peer_supervision_test.py).

| Check | Observed result |
| --- | --- |
| Naming baseline and migration | Before: one generic mimo-core entry. After: three named BTM registrations, signed role paths and three system plists; old Application Support plists absent. The three requested names were also seen in native Login Items. |
| Dashboard and Maintenance | Native navigation/copying produced no network verification. Final rendered fixtures retain full status ages and highlight Unavailable. The status CLI reads all three jobs; Direct recovery preserves the IP monitor's Stop preference. |
| Peer hangs | Suspended heartbeat and supervisor each recovered with one repair in about 52–54 seconds. Heartbeat repair in Global did not trigger a gate or verification cycle. |
| Hung engine controller | A still-running PID with a suspended controller reports engine and profile delivery Unavailable. Core API/peers remain responsive; explicit resume restores Healthy without a peer restart. |
| Rejected Rule/IPv4 and Global/Dual-stack | Rejected IP remains visible; monitoring stays ready; manual retry finishes; approval recovers without restarting peers. Final blocked windows had zero epoch changes/zero transport updates in Rule and one change/one update in Global, with no deferred scan. |
| Stop/Activate and uninstall/reinstall | All three jobs/helpers/plists removed; native controls released; no resurrection during 50-second observations. Activation/reinstallation restores all roles. Lifecycle logs contain no unexpected errors or peer repair during removal. |
| Two reboot paths | Intentional engine Stop survives a real reboot; Start restores engine/profile health. Normal reboot starts all three roles, with current health and native Direct networking. |
| State and log access | Original settings and credential fingerprints retained. An ordinary-account GUI model reads both service logs; Pause freezes visible/copied records. |

The denied-Rule observation initially failed after three deferred PF scans made
the inspection age expire. Investigation found that unchanged blocked transport
checks stamped the mutation epoch before deciding whether any rules needed to
change. A stronger test then failed on **23 epoch changes for only 11 actual
transport updates**. `MimoFirewallLock.mutateIfNeeded` now evaluates the condition
under the same lock and stamps only before a real write. Failed writes still
invalidate prior snapshots and release the lock. The original failures are kept
in the evidence; they were not waived or replaced by a wider freshness threshold.

Local validation passed: 241 shared tests; the service suite including 60
exception/recovery simulations, four pending-lookup Direct cancellations and
conditional-write/exclusion tests; installer/PF contracts; 52 manual cleanup
checks; installation cleanup; native app/model/render tests; and release packaging.

Scope and limits:

- Peer-hang, lifecycle and stopped-engine reboot checks preceded the final
  conditional-write follow-up. The final binary repeated Rule/Global rejection
  and recovery, controller health, normal reboot, retained-state and registration
  checks. Artifact hashes in the evidence distinguish these candidates.
- The final measured incoming-connection window passed 268 TCP probes with zero
  timeouts. Earlier probes recorded 14 transient timeouts; their cause remains
  unattributed. There were no further probe failures after the final installation,
  but this is not a claim that every remote-access interruption is fixed.
- The controller-hang test resumes the engine explicitly; it qualifies accurate
  detection/reporting, not automatic controller-hang repair. Later Screen Sharing
  inspection attempts returned `cgWindowNotFound`; those attempts supply no new
  native visual evidence. Final display changes were checked in rendered fixtures.
- This remains an unpublished local 3.0/build-11 candidate, different from the
  published build 11. Publication must advance the build number. Delta's installed
  app and network settings were not changed.

The expanded [user-command matrix and test methods](MIMO_DUALSTACK_TEST_PLAN.md#user-service-command-and-supervision-matrix)
cover Start/Stop/Restart/Reload, both full-Stop buttons, activation and overlapping
requests from multiple accounts. They require request-to-terminal log correlation,
live readback, watchdog-fencing checks and separate native UI/API/CLI evidence.
Explicit Restart/Reload and concurrency coverage are pending; the completed
results above must not be read as qualification of every user control.

Previous results below qualify the prior two-peer runtime separately.

## Two-peer runtime foundation

Authorized 26 November 2026. Supervisor hosts DaemonService (settings, credentials,
IP monitor and GUI API) plus network supervision. The former monitoring job keeps
its installation identity `com.mimo.core` but executes only `--heartbeat`; the
`com.mimo.core` API endpoint moves into the supervisor's MachServices. No third
core job is added. Supervisor checks/repairs the heartbeat. Heartbeat only checks/
repairs supervisor. The PF helper repairs the engine only; it cannot restart its
own supervisor or restore the former monitoring process.

A before-change VM reproduction suspended the running supervisor for 50 seconds.
Its PID did not change: the old missing-process recovery failed to detect the
hang. SIGCONT restored it afterward. Evidence is retained separately from prior
candidate successes; no prior campaign qualifies this revision.

Progress records bind boot, PID, sequence, monotonic executor time and work time.
Two-second peer observations require executor progress newer than 15 seconds and
infrastructure progress newer than 90 seconds. A known unresponsive peer needs
45 seconds of sustained loss; cold/replaced process grace is 120 seconds. Missing
jobs wait 10 seconds for launchd. Repair uses one cross-process lock, a fresh PID
and progress readback, a fixed root-owned plist backup and maintenance/deactivation
fences. Three peer repair attempts per target per ten minutes persist across
watchdog restarts, with 30/60-second delays between the three permitted attempts. launchd separately retains its
KeepAlive/10-second throttle; this is recovery redundancy, not hot failover.

Healthy checks read the root-owned progress record and validate its live executable;
launchctl is inspected only when progress is missing or stale. Maintenance takes
the same peer-repair lock before publishing its marker, so removal cannot race an
already approved repair. Deliberate installation resets persisted repair budgets.
CLI Direct recovery uses the supervisor's authorized, revision-fenced settings
API; it neither stops peers nor changes IP-monitor Start/Stop intent.

An unapproved IP, provider outage or blocked application traffic is healthy control
execution. Those conditions cannot trigger peer recovery. IP-monitor Stop affects
only monitoring; full Stop/Activate/uninstall retain their cleanup lifecycle.
Heartbeat repair does not alter PF, DNS, routes, profile or credentials. Supervisor
restarts establish startup blocking and require fresh verification in protected
modes; Direct restores native networking. Log view exposes merged core records
and heartbeat records, with existing rotation/caps and privacy filtering.

Dashboard must show live peer health/age, and unconfirmed communication on a lost
supervisor. Tests must audit errors and causal events through crash, SIGSTOP,
removed registrations, unapproved IP, manual recovery, Stop/Activate and quiet
windows of at least 35 seconds. Current results follow; candidate is not published.

## Prior two-peer qualification — completed 26 November 2026

Implemented and installed in **mimo-vm**. The final campaign passed **77 unique
installed checks**, including **26 settled windows of at least 35 seconds**.
The VM is restored to its original managed Direct configuration. Shared settings
and private credentials are retained. Delta's installed app/network was not
changed. This is an unpublished 3.0/build-11 candidate; publication requires a new
build identity. See the [sanitized evidence](../Tests/MihomoRuntimeTests/Evidence/v3/core-peer-supervision/results.json)
and [installed fault harness](../Tests/MihomoRuntimeTests/v3_peer_supervision_test.py).

| Scenario | Observed result |
| --- | --- |
| Existing jobs and API ownership | Supervisor owns both control APIs; the existing core job runs heartbeat only. Retired Perl jobs are absent; no third core job. |
| SIGKILL each peer in Direct | launchd restored heartbeat in 0.33 s and supervisor in 21.66 s, including health confirmation. The surviving peer was not restarted. |
| SIGSTOP each peer in Direct | Heartbeat recovered in 50.66 s; supervisor in 64.06 s. One peer repair per fault. |
| Disable and remove each registration | Heartbeat recovered in 16.77 s; supervisor in 28.58 s. One repair per fault; original surviving PID retained. |
| SIGSTOP each peer in active Global/dual stack | Supervisor recovered in 69.89 s with one fresh verification/opening cycle. Heartbeat recovered in 49.99 s without triggering verification or a gate cycle. |
| Rule/Global × IPv4/dual stack | Rejected IPv4 displayed, monitoring remained ready, manual refresh completed while blocked, and explicit allowlist recovery succeeded without restarting peers. Both rejected and approved terminal states passed quiet audits. |
| Engine crash, removed DNS override, replaced PF policy | Supervisor repaired each fault and freshly approved Global; neither peer restarted. Each settled audit passed. |
| IP-monitor Stop/Start | Both peers remained running. Authorized CLI Direct recovery worked with monitoring stopped and preserved its Stop choice. |
| Full Stop → Activate; uninstall → reinstall | Corrected lifecycle passed. Removed jobs did not resurrect for 50 s; owned packet rules, DNS override and TUN were absent. Reactivation restored healthy roles. |
| Real VM reboot | Boot UUID changed; boot guard and both progress records matched the new boot. Direct and fresh health returned, followed by a quiet audit. |
| Dashboard/log access | Current service and heartbeat timestamps; one `mimo-core` background-task registration. Ordinary-account app model read Core/Heartbeat records and verified Pause freezes visible/exported text, repeated after the final reboot. |

All 241 shared tests passed, along with service, native app model/render and
installer/helper suites. Service coverage includes 60 exception/recovery
simulations and four cancellation cases. Watchdog unit tests cover stalled work,
startup grace, PID changes, monotonic timestamps and persistent restart budgets.
Installer tests reproduce the activation ordering failure below before the fix.

The corrected lifecycle run passed 188 TCP probes per port (22 and 5900) through
each of the VM hostname and LAN address: 752 successful handshakes, no failures.
These checks stopped before deliberate reboot; they do not qualify uninterrupted
interactive SSH/Screen Sharing sessions.

### Failures caught and addressed

1. **Old supervisor hang:** baseline SIGSTOP left the same PID after 50 seconds.
   New peer progress detection recovered both Direct and protected-mode hangs.
2. **False peer inspection alarms:** the initial peer candidate failed its quiet
   audit because repeated healthy launchctl inspections produced transient errors.
   Healthy observations now use local progress and live executable identity;
   launchctl is reserved for missing/stale progress. Subsequent quiet audits passed.
3. **Activation deadlock against Stop intent:** Activate retained its completed
   Stop receipt until verification, while the watchdog correctly refused to start
   the absent heartbeat under that receipt. Installation timed out and rolled
   back. The authorized installer now explicitly starts both peers before health
   verification. The receipt remains until verification succeeds; repair fencing
   is unchanged. The new installer contract failed before this change, and the
   actual package installation and repeated lifecycle passed afterward.
4. **Real provider rate limit:** one activation received an ipapi.co rate limit.
   Core recorded a ten-minute provider pause, rotated once to IPWho.is and succeeded
   about 2.3 seconds after the error. No peer restart occurred. The full-window log
   audit positively checks this exact bounded failover; arbitrary errors, repeated
   retries and every warning/error in settled windows still fail the tests.

Two earlier rejected-state assertions sampled `refreshing` before the terminal
`ready` snapshot. Captured service health was running, so the harness was corrected
to await ready + blocked + an observed address. No production change was made for
that sampling error. Earlier failed checks remain in the evidence.

The first candidate package also failed PF parent inspection once. Bounded command
and inspection diagnostics were added; later normal package installations passed.
That first occurrence was not conclusively attributed. The earlier hostname-only
incoming probe recorded two failures per port shortly after failed activation
rollback; their cause was not established. The corrected lifecycle's hostname and
literal-address probes had no failures; this is not proof of the earlier cause.

### Prior two-peer identity and practical limits

These identities and limits belong to the preceding two-peer campaign. The
named-background-item revision and its newer UI evidence are documented above.

- Core SHA256: `6f8e9e4600df725102943cbcde39d6f009742526951dacf2ddbfe947629cff6b`
- Package SHA256: `67ccbcfccf8cfc4c4d9c9f0730d573f5b4ca9fb038fd3bd5149b2124c7f314d7`
- The installer fix changed packaged resources; the final core binary exactly
  matches the binary used for the fault/recovery matrix.
- Local raw logs are under `.build/core-peer-supervision/`; guest-private originals
  remain under `/var/tmp/mimo-peer-supervision/`. Credentials and raw state were
  not exported into repository evidence.
- Screen Sharing automation returned `cgWindowNotFound`; Tart returned a timeout.
  Native window click-through and visual Login Items inspection remain unqualified.
  The registry and app model/render checks passed; these are distinct evidence.
- Restart budget exhaustion/backoff is unit-tested, not a live fourth-fault test.
  Reboot was tested in Direct, without a new protected cold-boot packet capture.
- Both roles depend on one executable. If both are disabled/removed at boot, or
  that executable is broken, installation repair may be necessary. The design
  provides bounded recovery, not hot failover.

## Historical candidate: separate infrastructure role (superseded)

Date: 2026-11-26. User authorized implementation and installation/testing in mimo-vm.
Candidate only; not published. Local build identity remains 3.0/build 11, with
candidate binary hashes recorded separately from the published build.

Implemented and installed in mimo-vm. All 39 final installed checks and 239 shared
tests passed. Delta's installed app was not changed. The VM is back in its original
Direct configuration, with machine settings and credentials retained. See the
[sanitized results](../Tests/MihomoRuntimeTests/Evidence/v3/core-infrastructure/results.json).

## Observed problem and change

Build 11 registered `com.mimo.pf-boot` and `com.mimo.infrastructure` with
`/usr/bin/perl` as their executable. Login Items showed two generic Perl entries.
Its repair helper also reinstated disabled registrations. The installed VM
baseline confirmed both jobs used Perl. A new installer contract failed against
unchanged production code on the executable assertion before implementation.

One launchd job now runs `/Library/PrivilegedHelperTools/mimo-core --infrastructure`.
It performs boot guarding followed by serial checks with a 10-second delay.
The fixed Perl helper remains a bounded internal child, not a launch daemon.
The supervisor still audits and repairs a missing infrastructure role; the
infrastructure role can restore the supervisor and intended core/engine jobs.
Normal GUI clients neither launch nor schedule this work.

Upgrade removes the old boot plist and repair copy, replaces the health plist,
and retains both old registrations in rollback backups. Full Stop/uninstall
removes current and legacy jobs. Ordinary Direct leaves the worker installed,
with empty packet policy and native DNS. Existing protected-mode rules, locks,
incoming connections, release intent and health freshness are preserved.

SIGTERM drains a running helper before exit; launchd/installer allow that bounded
drain. Boot failure exits and uses launchd throttling. Sweep failure logs and waits
before retrying. A broken core executable now requires installation repair; unlike
the old interpreter jobs, this worker cannot execute independently of that binary.

## Validation

- Before: installer contract failed with “Login Items must attribute the guard
  to mimo-core, not Perl”; VM launchctl confirmed both Perl jobs.
- Portable shared suite: 239 tests passed, including migration/failure log text.
- Installer/helper suite: passed, including previous-version rollback and conflicts.
- Service suite: passed, including boot-before-check, no tight retry, no overlap,
  and cancellation waiting for an in-flight operation.
- Release compilation and sealed candidate installation in mimo-vm passed.
- Installed migration confirmed the core executable, retired boot registration
  and repair copy, and no current Mimo launch plist executing Perl. macOS's
  background-task registry identifies the new worker as `mimo-core`.
- A 35-second settled Direct audit passed with advancing health and no unexpected
  network check, gate transition or error. SIGKILL recovery and mutual
  infrastructure/supervisor repair passed, followed by another quiet Direct audit.
- Rule/Global × IPv4/Dual-stack all passed: real unapproved IPv4 visible, 35 seconds
  of stable rejection with advancing health, explicit allowlist edit recovery,
  and another 35 seconds of stable approved access. No unexpected lookup, gate
  transition, network-change dispatch, warning or error occurred in those eight
  settled windows. Each cell restored original Direct settings.
- Full Stop completed and removed all current/legacy system jobs, owned packet
  rules, DNS override and TUN. Activate restored the core-owned roles without
  recreating Perl jobs, followed by another 35-second quiet Direct audit.
- A real VM reboot produced a new boot-session UUID and matching guard boot
  marker, restored Direct and passed another 35-second quiet audit. Final checks
  confirmed original settings/credentials, healthy services, released network
  controls and macOS background-task attribution to `mimo-core`.

The first recovery harness incorrectly counted a still-exiting worker's PID as
restored, then removed the second watchdog too. The resulting heartbeat failures
were captured and failed the settled audit. The corrected harness requires a new
PID and a fresh post-fault health timestamp before the next injection; that run
passed without a production-code change. Both attempts are retained. A first
protected-mode harness wait also used the computed Swift `rejectedExit` property
as if it were encoded; the corrected test checks its wire field `blockingIP`.

## Historical consolidation candidate identity and limits

- Core SHA256: `15f6349063bb5bd24c1f94a77eab19e565532dca6e8ecdb78f4c6cab9eeefbdf`
- Package SHA256: `1dff27ed7bc4ee810c25d6893f931e155479c0c8ba92154a9b4237a1d14852b7`

Local raw logs: `.build/core-guard-merge/`. Guest-private originals remain under
`/var/tmp/mimo-core-guard-merge/`; private settings and credentials are not included
in the repository evidence.

Stop/Activate tests used the real installed backend, not native button clicks.
Background-task registration was inspected with `sfltool`; physical-Mac Login
Items rendering remains unqualified. Reboot was tested in managed Direct, without
a new protected cold-boot packet capture.

Early SSH runner sessions dropped during installation/fault work. The guest
journal confirmed successful installation; later tests used Tart's guest agent.
Uninterrupted incoming SSH/Screen Sharing across transitions is not qualified by
this campaign. No packet-policy change was made for the consolidation.

## Historical supervision limit (superseded by current candidate)

The previous missing-job-only recovery did not restart a hung-but-running
supervisor. The current progress watchdog addresses that gap; installed results
must demonstrate recovery before qualification.
