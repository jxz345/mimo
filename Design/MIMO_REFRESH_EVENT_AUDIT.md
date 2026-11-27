# Refresh workflow audit — 27 November 2026

This records the installed **unpublished 3.0/build 11 candidate**, identified by
the [artifact hash](../Tests/MihomoRuntimeTests/Evidence/v3/refresh-events/artifact.json).
It does not qualify the published build or the proposed workflow revision.

## Executed native clicks

Setup used the production RPC, with periodic checking temporarily set to Never.
Each measured refresh was an actual Dashboard click in Screen Sharing. The test
waited 35 seconds after completion and correlated lookup IDs, provider requests,
prepare/approve commands, gate events and process identity. Raw settings/logs stay
root-private in mimo-vm. Exported [results](../Tests/MihomoRuntimeTests/Evidence/v3/refresh-events/results.json)
contain whitelisted diagnostic fields, with no addresses or credentials.

| Starting state | Lookups / HTTP requests | Gate behavior | Settled result |
| --- | --- | --- | --- |
| Direct, saved IPv4 | 1 / 1 | No gate operation | Pass |
| Global IPv4, rejected exit | 1 / 1 | One prepare closure; stays blocked | Pass |
| Global IPv4, approved exit | 1 / 1 | One prepare closure and opening | Pass |
| Global dual-stack, rejected exit | 1 / 1 | One prepare closure; stays blocked | **Fail: transient engine/profile Unavailable** |
| Global dual-stack, approved exit | 1 / 1 | One prepare closure and opening | Pass |

All five produced fresh observations, with unchanged engine/supervisor/heartbeat
PIDs and no additional lookup during the observation window. Protected cases
reused the profile and each sent one prepare and one approve command. Numerous
timing, widget and presentation events did not represent additional IP requests.

The failed dual-stack case remained Ready and policy-blocked, but engine/profile
health became Unavailable at 01:07:12.072 UTC. A later independent readback found
both Running and a successful controller response. This is an unresolved health
failure, not proof of duplicate IP checks or proof that the engine stayed
responsive throughout. The health event lacks a failure-stage detail, so its
root cause is not established by this capture. Earlier service-command testing
also observed controller/PF timeouts and recovery checks; those operations are
not interchangeable with a standalone Refresh click.

The user requested a behavior proposal during the next Rule setup. Testing was
stopped before that click. **Rule, saved-Direct dual-stack, released Direct and
concurrent-click cases are not qualified by this audit.** The interrupted setup
is not a Refresh failure. Original settings and routing were restored, native
controls were released, and the Dashboard visibly returned to healthy Direct.

## Current code and timer behavior

`MimoCoordinator.lookup` sends `prepare` before every admitted protected lookup,
regardless of manual, periodic or settings trigger. `prepare` closes application
outbound traffic, performs cleanup/readiness and permits the private proxy probe.
`approve` either keeps denial or opens after successful approval. Direct observes
its native exit without this protected cycle.

`MachineSettings.affectsVerification` groups provider, allowlist and active Rule
bypass changes together. `DaemonService` therefore closes before committing even
an allowlist-only edit. Provider credential changes also close. The coordinator's
lookup error path and `requiredCheckUnavailable` callback close on lookup failure.
Changing only the initial `prepare` call would leave these other closure paths.

The periodic timer retains its scheduling cadence after manual success.
`LookupBudget.routineFreshness` suppresses routine checks for two minutes, not the
selected one-hour interval. A production MonitoringEngine test now demonstrates:
119 seconds after a manual success, a periodic tick spends no request; at 121
seconds it spends one. `Tests/MimoAppTests/run.sh` passes, including this boundary.
This virtual-clock test exercises the timer callback's production refresh entry;
it is not a claim that a real hour-long VM timer experiment ran.

The [new proposal](MIMO_3_0_PLAN.md#proposed-observation-and-transition-workflows--27-november-2026)
separates observation from routing changes and addresses timer spacing. It is
pending approval; this audit changed tests/documentation only.
