# IPv4 approval and recovery qualification — 26 November 2026

Implemented the approved revision in [the v3 plan](MIMO_3_0_PLAN.md). Rule and
Global now use one fresh allowlisted IPv4 exit for both strict IPv4 and
Dual-stack. IPv6 application policy is unchanged. This is a local, unpublished
candidate installed in `mimo-vm`, not a GitHub/Homebrew release.

## Installed identity

| Artifact | Identity |
| --- | --- |
| Version / build | 3.0 / 11, unpublished |
| Installed core SHA256 | `fff99947b06a44095736bc1f212aef37e81860db7568a90e6bcb0f671fc1bb30` |
| Package SHA256 | `d2f2cb4cf69cba2d9e2d4b0b20b29116e46bd161ddfb3992db5dd430b219db62` |
| ZIP SHA256 | `f765bf44c75c84b6402a6d116664f13ccc3f236d5a0da1260382121064459790` |

The previous unpublished build-11 artifacts remain privately preserved. Build
number alone does not identify those local iterations; these hashes identify the
tested app. No published number was reused for different binaries.

## Reproduce before changing

The earlier installed VM evidence showed successful IPv4 responses followed by
unavailable IPv6, then provider cooldowns. Independent IPv4 SOCKS requests worked;
the tested IPv6 destinations were refused by the selected proxy. An absent AAAA
record on one provider and a real HTTP 429 on another were recorded separately.

Before production edits, a new regression using the actual monitoring scheduler
and coordinator failed with:

> Direct→rule/dual: successful IPv4 must not request IPv6 or pause the healthy provider

The red log is retained privately at `.build/ipv4-approval-red2.log`. The corrected
test passes Rule/Global × IPv4/Dual-stack. This reproduces the approval-family
failure; it does not prove the cause of every previously reported network event
loop or slow UI interaction. The separate build-10 cooldown lockout and duplicate
close reproduction are documented in
[the earlier recovery record](MIMO_BLOCKED_VERIFICATION_RECOVERY.md).

## Installed four-cell campaign

Run with `v3_ipv4_approval_campaign.py` against the installed app, not an isolated
engine. The closed Delta fixture serves a working IPv4 IP provider, returns no
AAAA answers, refuses IPv6 TCP and drops IPv6 UDP. Its disposable credential stays
unchanged throughout each fault/repair sequence and is removed before cleanup
returns to native networking. The fixture cannot forward to the Internet.

| Installed case | Result | Provider HTTP IPv4 / IPv6 | Proxy-down repair | Native IPv6 packets |
| --- | --- | --- | --- | --- |
| Direct → Rule / strict IPv4 | PASS | 14 / 0 | 8.107 s | 0 |
| Direct → Global / strict IPv4 | PASS | 14 / 0 | 7.147 s | 0 |
| Direct → Rule / Dual-stack | PASS | 14 / 0 | 7.116 s | 0 |
| Direct → Global / Dual-stack | PASS | 14 / 0 | 11.984 s | 0 |

Each cell passed:

- Empty and mismatched IPv4 lists: actual rejected fixture address visible,
  successful provider healthy, stable blocked state. Three explicit refreshes
  each made exactly one fresh IPv4 request; polling did not add requests.
- Allowlist-only repair: fresh approval opened the existing protected session.
- Proxy down, authentication refusal, timeout and provider HTTP 503: no invented
  current address; display-only last-known IPv4 retained. All 16 fault repairs
  succeeded without Direct, process restart, token replacement or clock changes.
- Real HTTP 429 with `Retry-After: 900`: explicit Refresh did not bypass the
  restriction or extend/reset its deadline. Four cases passed.
- Incoming SSH and Screen Sharing remained reachable during failure.
- IPv4 application traffic used the proxy. Strict IPv4 dispatched no IPv6
  connection to it; each Dual-stack cell recorded an IPv6 TCP and UDP attempt at
  the proxy. Refusal/drop produced no native IPv6 packet escape.

The first traffic run was invalidated by the capture tool entering promiscuous
mode, which triggered a legitimate interface-change closure. The harness now
uses `tcpdump -p`; no app change was made to suppress that event. The invalid run
is retained privately rather than counted as a pass.

Evidence: [matrix](../Tests/MihomoRuntimeTests/Evidence/v3/ipv4-approval/matrix.json).
Raw state, settings, credentials and captures stay owner-only under `.build/` and
the guest's `/var/tmp/mimo-ipv4-*` directories. Committed addresses are synthetic.

## Migration, lifecycle and local suites

- **226 shared tests passed**, including mixed/IPv6-only allowlist migration,
  idempotence, revision persistence, malformed/IPv6 additions, fresh receipt
  validation and display-only history.
- **Service and app suites passed**, including 60 failure/recovery simulations,
  four pending-lookup Direct cancellations and native light/dark last-known
  renders. Both generated managed profile templates passed the pinned engine's
  parser checks. No routing/PF or bundled-engine change was needed.
- **Installed migration passed**: removed a seeded legacy IPv6 entry, preserved
  IPv4 settings and credential digests, and emitted one count-only migration event.
- **22 installed lifecycle assertions passed**: managed Direct retained the
  engine; full Stop removed owned PF/DNS/TUN and services; Activate restored all
  services. Native release verification passed in all three states. Settings and
  credentials survived restart. Original routing/settings were restored.

Final installed-state readback after restoring the user's configuration was
Global/Dual-stack with an empty IPv4 allowlist. It correctly remained blocked
with “No exit IPs are approved. Review Allowed IPs in Settings.” The actual
returned IPv4 and rejection were present, monitoring was `ready`, and core,
engine and profile hosting were running. No address was added to the user's
allowlist by the test.

Evidence: [summary](../Tests/MihomoRuntimeTests/Evidence/v3/ipv4-approval/summary.json),
[migration](../Tests/MihomoRuntimeTests/Evidence/v3/ipv4-approval/migration.json),
[lifecycle](../Tests/MihomoRuntimeTests/Evidence/v3/ipv4-approval/direct-lifecycle.json).
These lifecycle assertions exercise the core-owned daemon operation used by the
dashboard; they do not claim an actual mouse click on Stop/Activate.

Earlier installed/fault/inbound harnesses have been adapted to IPv4-only approval
without weakening their traffic assertions. Their historical campaigns were not
rerun in this revision. The obsolete paired-approval failure script refuses to
run and directs callers to the current campaign.

## UI and remaining limits

**Subsequent coverage gap found:** the rejected-state stability assertion in this
campaign observed only three seconds, shorter than the supervisor's ten-second
infrastructure scan. It also did not restart the supervisor while an existing
exit was rejected. A later installed regression reproduced repeated
`infrastructure_recovered` checks in that state. The historical passes above
remain valid for their recorded windows and explicit fault repairs; they do not
establish long-term settled rejection. The current harness now observes 35 seconds,
and the separate startup/recovery matrix and navigation audit are recorded in
[the navigation investigation](MIMO_NAVIGATION_RESPONSIVENESS.md).

Actual Rule dashboard rendering and Direct→Monitoring navigation were observed;
the latter took 616 ms including click and UI-state capture. Native light/dark
last-known renders were visually checked for address, flag, timestamp, error and
stable layout. Later failed-state Global/Dual desktop inspection was unavailable
because computer use returned `cgWindowNotFound` / `noWindowsAvailable` on Delta.
No completed user handoff was available. **Slow Monitoring navigation during an
active failure and two simultaneous GUI accounts remain unqualified.**

Five RPC samples in blocked Global/Dual took 183–204 ms. Core, engine and profile
hosting remained running; PF/launchd were healthy. The last-known fixture address
was present without a current observation, and the core instance was unchanged.
This distinguishes service health from provider backoff, but does not prove a
GUI latency fix or absence of every macOS freeze.

Evidence: [service health](../Tests/MihomoRuntimeTests/Evidence/v3/ipv4-approval/blocked-service-health.json),
[native UI scope](../Tests/MihomoRuntimeTests/Evidence/v3/ipv4-approval/native-ui.json).
Physical sleep/login switching and broad historical traffic/fault qualification
retain their existing limits. IPv4 approval does not establish IPv6 exit identity
or guarantee that the selected proxy supports every IPv6 destination.
