# Native navigation investigation — 26 November 2026

The user reports a regression switching Dashboard/Settings and possibly other
tabs. This investigation changes GUI update scheduling, not core, routing,
verification, firewall or provider behavior. It is an unpublished 3.0 build 11
candidate installed only for local qualification.

## Findings before changes

- Sampling the installed GUI during navigation found the main thread waiting
  for events in 1,954 of 2,029 samples. There was no persistent synchronous XPC
  or login-item-service wait in this capture. This does not exclude an
  intermittent stall on this or another Mac.
- Some Screen Sharing observations initially showed the old tab. A subsequent
  observation showed the requested page. This is insufficient to attribute
  input/display delay to Mimo; selection-to-view timestamps are measured separately.
- A retained-window test exercised all six Settings sections and Dashboard
  while delivering blocked Global status. With the real status-menu controller
  present, 36 switches in mimo-vm measured p95 **63.55 ms**, maximum **75.11 ms**.
  This is main-queue/render work, not physical click-to-screen latency.
- A new deterministic test failed on unchanged scheduling: ten completed daemon
  snapshots queued **130 native status-menu updates**. Each published property
  queued its own update, replacing and synchronously measuring the same label.
- A second test failed on unchanged persistence: ten health-only snapshots made
  **150 writes/removals of unchanged local monitoring preferences**. These
  serializations/defaults operations ran on the GUI's main actor.

The two regressions establish unnecessary UI work. They do **not** prove that
either alone explains the user's reported multi-second slowdown. No such
multi-second stall was reproduced in this capture.

## Change

`StatusItemController` coalesces pending publications into one main-queue update
which reads the latest completed snapshot. Menu actions still refresh, including
when only control availability changes. An unchanged presentation does not
replace or measure the native label. A changed final failure verdict still
updates the menu, tooltip and accessibility text.

`MimoReleasedMonitor` remembers only its relevant preferences, diagnostics,
budget, cooldowns and provider health. Health timestamps/routing publications
do not rewrite that unchanged fallback. Changed monitoring data still persists;
starting the released monitor invalidates the cache so activation can restore
authoritative shared values after local monitoring changes.

Both paths apply in Direct and protected states. Tab navigation initiates no
provider request, service inspection, privileged operation or settings write.
Settings drafts remain retained across navigation.

Navigation diagnostics record the selection request and SwiftUI's applied
selection, linked by an ID and monotonic elapsed milliseconds. They contain
only tab/section names and timing. They do not measure final pixels or the
Screen Sharing transport, so remote input/display delay must be assessed
separately from the view-update duration.

## Validation

- Before-fix failures: [menu](../Tests/MimoAppTests/Evidence/navigation-2026-11-26/red-menu.txt),
  [preferences](../Tests/MimoAppTests/Evidence/navigation-2026-11-26/red-preferences.txt).
- App suite passes, including released-monitor lifecycle, cached login-item
  checks, menu final-state correctness, draft retention, six Settings sections
  and Dashboard. The same ten-snapshot burst now queues **one** menu update,
  **zero** unchanged label layouts and **zero** unchanged preference writes.
- **226 shared tests pass**. Core's installed binary hash remains unchanged from
  the approved IPv4-approval campaign; this patch changes no service behavior.
- Updated retained-window test in mimo-vm: **36 switches**, p95 **66.79 ms**,
  maximum **88.95 ms**. Routine timing is similar to the baseline; the measured
  improvement is elimination of redundant queued work/writes, not proof of a
  large click-latency reduction.
- Native installed-app click-through completed all six Settings sections and
  returned to Dashboard while Global/IPv4 was blocked with an empty allowlist.
  All eight selection requests have matching applied events: **11–38 ms** from
  selection to SwiftUI application. Each requested page was visually confirmed.
  This does not include input dispatch or composited Screen Sharing latency.
  See [native events](../Tests/MimoAppTests/Evidence/navigation-2026-11-26/vm-native-navigation.json),
  [VM render timings](../Tests/MimoAppTests/Evidence/navigation-2026-11-26/vm-timing.json)
  and [host render timings](../Tests/MimoAppTests/Evidence/navigation-2026-11-26/host-timing.json).

Commands: `xcrun swift test`; `bash Tests/MimoAppTests/run.sh OUTPUT`.
The compiled app-test binary also supports `OUTPUT --navigation-only` and
`OUTPUT --released-only` for the same host/VM regression checks. Timing tests
do not use network calls or modify installed machine settings.

## Candidate identity and remaining limits

### First-click follow-up

The user clarified that the apparent delay may be a second-click requirement.
Before changing click handling, this was reproduced in the installed Settings
sidebar: with Finder active and Monitoring selected, one click on General at
03:07:12 UTC activated Mimo but left Monitoring selected. No navigation request
was recorded. A second click produced the General selection at 03:07:31.782 UTC
and applied it in 21 ms. The Dashboard/Settings segmented picker accepted its
first click even from an inactive window in the same session. Active-window
sidebar selection also worked with one click.

This is a reproduced focus/input issue, distinct from rendering delay. Earlier
timing tests started after selection and therefore could not detect it.

Applying the activation modifier to the `List` alone failed the same live test:
the activating click at 03:13:03 UTC still did not select General. The final
change gives each sidebar row an explicit borderless navigation button and opts
that button into SwiftUI window-activation events on macOS 15 and later. The
`List` selection remains for its native highlight and arrow-key navigation.
This is scoped to page navigation, not routing, service or editing controls.
Apple documents the
[activation-event modifier](https://developer.apple.com/documentation/swiftui/view/allowswindowactivationevents%28%29).
macOS 14 builds without that opt-in; first-click behavior there is unqualified.

Installed candidate results in mimo-vm (Global/IPv4, empty allowlist):

| Input case | Observed result |
| --- | --- |
| Finder active → click General once, Monitoring initially selected | General selected with that click; 03:17:00.845 request, applied in 23 ms. |
| Finder active → click Monitoring once | Monitoring selected with that click; applied in 30 ms. |
| Finder active → click Settings once from Dashboard | Settings opened with that click; applied in 13 ms. |
| Focus an unsaved Allowed IPs text field → click General once | General selected; returning retained the draft. The test draft was then cleared without saving. |
| Focus a text field → click Dashboard once | Dashboard opened with that click. |
| Focus the sidebar → Down arrow | Next section selected and native selection highlight updated. |
| Active-window clicks across the six Settings sections | All produced matching request/applied events; Proxy, Allowed IPs, Monitoring, General and Maintenance visually confirmed. Bypass applied in 29 ms, but its final pixels were not separately confirmed before the next click. |

The 14 recorded selections applied in **10–36 ms**. The reproduced inactive-row
failure is fixed in this VM; an active-window lost click has not been reproduced.
Screen Sharing became unavailable during the final supplementary Bypass visual
check. This does not invalidate the earlier observed inactive-window and
focused-field passes. See [before evidence](../Tests/MimoAppTests/Evidence/navigation-2026-11-26/first-click-before.json)
and [candidate evidence](../Tests/MimoAppTests/Evidence/navigation-2026-11-26/first-click-after.json).
The app suite passes on the final button implementation; its 36 retained-window
switches measured p95 **57.42 ms**, maximum **70.82 ms** on the host. These timings
still exclude the physical input and Screen Sharing delivery.

Version **3.0**, unpublished build **11** (local rebuild, not a new upload):

- GUI SHA256: `3de7420cfa5051819feb3ad9e3ea9273c3b31d262094710c398557364e53d21a`
- Core SHA256: `fff99947b06a44095736bc1f212aef37e81860db7568a90e6bcb0f671fc1bb30`
- Package SHA256: `17dec5256f01ec103f64e39e409b66b95361092b49a523434932eb0bda98a30e`
- ZIP SHA256: `c2e1a1bc73b85b35127b8559b98103a70412a20155bf3bf07dc551d6898ed2e7`

The earlier IPv4 qualification report retains its original package hashes.
Private process samples and installation logs stay in `.build/navigation-*`;
committed evidence contains fixture results and sanitized navigation timings.
Physical-Mac and simultaneous
two-account navigation are not qualified by these tests. The original reported
sluggishness needs confirmation on the affected installation before being closed.

## Directional delay follow-up — Settings → Dashboard

The user clarified that the remaining delay is in **mimo-vm** and is
significantly greater returning to Dashboard than opening Settings. This report
remains **open**. The earlier inactive-sidebar fix is not evidence that this
separate delay is resolved.

The previous fixture forcibly lays out an offscreen retained window after
programmatic selection. Splitting its 36 samples by direction gives Dashboard
mean 29.19 ms / maximum 38.01 ms and Settings mean 50.63 ms / maximum 70.21 ms on
the host. This is the opposite of the reported visible behavior: that fixture
does not reproduce this report and cannot qualify it.

A diagnostic-only installed GUI adds current-event age, content transaction
animation metadata and the next AppKit window-update callback. It does not force
rendering or change navigation, routing, provider or service behavior. Current
input-event age can be stale for a programmatic selection; AppKit's callback is
not compositor completion or remote display delivery.

Initial native clicks in the VM showed no animated content transaction. The
04:00:13 UTC Settings selection applied in 14 ms and reached the subsequent
window update in 38 ms; the 04:00:19 Dashboard selection applied in 11 ms and
reached window update in 29 ms. Current mouse-up event ages were 1 and 6 ms.
These samples do not establish the user's slow return. An eight-second process
sample also found the main actor mostly idle, not a persistent blocking core call.

A local experiment removed whole-tab disabled-state changes. It reduced the
fixture's Dashboard mean from 29.19 to 21.37 ms, with Settings mean 43.77 ms.
That small improvement does not explain the report; the experiment was reverted,
including restoration of hidden-tab keyboard isolation. No speculative page
architecture or animation change has been retained.

The user has been asked to trigger one slow return in their VM session and report
whether the tab highlight changes before the contents. Match that action to the
new diagnostics before making a behavioral fix. Tests pass (app suite and 226
shared tests), but this is **diagnostic readiness**, not a fixed/qualified delay.

Latest installed diagnostic candidate: version 3.0, unpublished build 11.

- GUI SHA256: `3f2cf337b2bac5ab01f9e8ca1bd84d74c4a4bff6f8f4eacb02f88fd5a4192250`
- Core SHA256: `fff99947b06a44095736bc1f212aef37e81860db7568a90e6bcb0f671fc1bb30` (unchanged)
- Package SHA256: `81322e553048e81f717cda0316a079534b2d486a91048a2841c4aa2845dd3a51`
- ZIP SHA256: `628563880115becfc64a90363d4115e9a5977cdb78af37f6d4efe2fb762e036d`

## Screen Sharing investigation — 2026-11-26

The user proposed that remote display refresh, rather than Mimo's navigation,
causes the perceived delay. This remains plausible but **not established**.
The inspected connection is Standard Screen Sharing, with scaling enabled,
directly from Delta to the VM's local virtual-network address on TCP 5900.
It is not a Tailnet connection. Screen Sharing's Quality preference already
selected “Adapt quality to network conditions (faster)”; the current-session
View menu did not expose its checkmark through accessibility, so the preference
alone does not prove the session had no override.

Apple documents that [Standard sharing adapts resolution and frame rate to
network conditions](https://support.apple.com/guide/mac-help/mchl1883115d/mac).
This provides a possible mechanism for visible delay after an app updates its
window, but does not diagnose this instance. The separate High Performance mode
was not tested, and its availability for this VM/session is unqualified.

Five single-click transitions were observed in the installed diagnostic GUI:

| Session setting | Destination | Selection applied | Next AppKit window update | First screenshot returned |
| --- | --- | ---: | ---: | ---: |
| Initial session; Adaptive preference | Dashboard | 14 ms | 33 ms | 584 ms |
| Initial session; Adaptive preference | Settings | 16 ms | 37 ms | 579 ms |
| Full Quality explicitly selected | Dashboard | 11 ms | 30 ms | 525 ms |
| Full Quality explicitly selected | Settings | 17 ms | 41 ms | 535 ms |
| Full Quality explicitly selected | Dashboard | 14 ms | 35 ms | 583 ms |

The requested page was visible in every first screenshot; each transition had
an unanimated SwiftUI transaction. The app durations start at its selection
request. Screenshot times start at the automation click call and **include the
tool's input and observation waits**. They are observation bounds, not measured
Screen Sharing latency. Host/guest timestamps were not clock-calibrated and must
not be subtracted to estimate transport delay. See the sanitized
[app-side records](../Tests/MimoAppTests/Evidence/navigation-2026-11-26/screen-sharing-quality.json).

Five new TCP handshakes to the same VM's Screen Sharing port took 0.19–2.86 ms
(median 0.23 ms). This checks basic local TCP reachability, not framebuffer
encoding, throughput, packet loss during updates or display scheduling. ICMP
probes received no replies and therefore supplied no latency measurement; no
firewall changes were made to enable them.

Full Quality did not reproduce a marked directional difference. The session
was explicitly returned to Adaptive Quality, leaving Mimo on Dashboard. There
were no Mimo source changes, builds, service restarts or network-mode changes
for this investigation.

The remaining distinguishing test is the **same slow transition in the same
guest account**, observed through a local VM console and Screen Sharing, with
input and displayed frames captured together. A fast local console and delayed
remote frame would implicate remote presentation; a delay on both would require
examining guest compositor/layout work as well as the app callbacks. The running
Tart CLI exposed no attach-viewer command, so this investigation did not restart
the VM or change account sessions to manufacture that comparison. The reported
delay remains open; these results do not justify another speculative UI rewrite.

## Correlated recovery loop — reproduced before correction

The subsequent report said Settings → Dashboard started a network check. Joining
GUI, core and supervisor timestamps showed a real loop that was already running
before the clicks. In the captured interval, 72 `mimo_network_changed` events
used `source=infrastructure_recovered`; the repeated interval was about 11–12
seconds. For example:

| UTC | Event |
| --- | --- |
| 04:13:39.669 | Supervisor reports infrastructure recovery |
| 04:13:39.675 | Core requests `network_configuration` refresh |
| 04:13:39.771 | Exit lookup begins |
| 04:13:44.666 | GUI requests Dashboard |
| 04:13:44.686 / .708 | Selection applied / window update |
| 04:13:48.230 | Lookup ends |
| 04:13:50.951 | Supervisor reports another infrastructure recovery |
| 04:13:54.299 | Next Dashboard request, after that recovery already started |

No navigation-driven settings write was identified. The supervisor sets
`verificationRecoveryPending` when starting in protected mode, including a
supervisor-only restart while core is already running. It previously cleared the
flag only when approval opened traffic. A successful lookup rejected by the
allowlist never reached that path, so every healthy infrastructure scan requested
another verification. An empty allowlist reproduced this without a provider outage
or a Screen Sharing network change.

Before editing production code, the new read-only installed regression observed
35 seconds of settled rejected Global/IPv4: **three unexpected lookups and three
infrastructure-recovery events**. Core identity, settings and routing stayed the
same and health checks continued, but the rejected observation was repeatedly
replaced. The test exited 1. See [sanitized before evidence](../Tests/MihomoRuntimeTests/Evidence/v3/navigation-recovery/before.json).

The correction consumes the pending recovery when a valid protected `prepare`
starts, before its first suspension. A Direct command also clears pending
verification recovery. A subsequent runtime/liveness failure can independently
rearm it. Rejecting a healthy exit remains a completed policy decision, with the
observed IP visible and monitoring ready. Explicit retry and genuine changes
still request verification. No firewall, profile or allowlist weakening is part
of this correction.

The earlier three-second mismatch check was shorter than the ten-second health
scan and did not exercise supervisor startup while already rejected. It therefore
missed this loop. The new minimum is 35 seconds; native UI testing must join all
three event streams and check expected triggers, completion and absence of
unexplained work. A rendered page or fast AppKit callback is not enough.

Candidate installed in mimo-vm: **3.0 / unpublished build 11**.

- Core SHA256: `0b6c8025b4a849df288673049b63015df1d4b5abb3a6990265ab9a483aa58181`
- GUI SHA256: `9ab66c94e9030baeac9cb31aaaa87d69d73a124a4c121d66c95c7191bba9f6dc`
- Package SHA256: `6d40509bf08d0b08ee6aef387ead879f94ba5857e0d8cfa0704fa33e861bfd3b`
- ZIP SHA256: `2c55060bfb9127c252a94d2004ee0d56e6fc4c2744cb341aa2f47a802af363a3`

The loop explains repeated checking during navigation; it does not establish the
cause of the separately reported directional remote-display delay. That visible
latency investigation remains open.

### Installed correction and event audit — 26 November

All four installed cells passed on the candidate above. Each used the existing
proxy and empty allowlist, entered the protected mode from Direct, restarted only
the supervisor while the exit was rejected, then observed 35 seconds after the
new rejection. Each also completed an explicit Refresh and returned to Direct.
Core identity, credentials and settings were retained; routing was restored after
the campaign.

| Mode | Traffic setting | Restart → rejection | 35-second stable denial | Explicit retry | Direct recovery |
| --- | --- | --- | --- | --- | --- |
| Rule | IPv4 | Pass | Pass | Pass | Pass |
| Rule | Dual-stack | Pass | Pass | Pass | Pass |
| Global | IPv4 | Pass | Pass | Pass | Pass |
| Global | Dual-stack | Pass | Pass | Pass | Pass |

The [matrix evidence](../Tests/MihomoRuntimeTests/Evidence/v3/navigation-recovery/restart-matrix.json)
contains each window and its assertions. Full-campaign event reconciliation
found exactly four infrastructure-recovery requests and four consumed recovery
flags, one per injected supervisor restart. All 16 lookups finished successfully
(12 protected observations were rejected as expected, four were Direct checks);
all 32 core commands finished. There were no stale-command rejections. No new
lookup, gate/control cycle or unexpected network event occurred in any settled
window, and infrastructure health timestamps advanced.

The complete trace also contained 23 heartbeat failures around the four
deliberate supervisor restarts. They ended by supervisor readiness, except one
response delivered 52 ms after readiness. None continued into the settled
windows. Their generic “Another user changed the shared settings” message is
misleading for this startup interval; no settings change or command-rejection
event accompanied them. This diagnostic wording remains a limitation, not an
unexplained event silently discarded from qualification. See
[full-campaign counts and bounded restart events](../Tests/MihomoRuntimeTests/Evidence/v3/navigation-recovery/event-audit.json).

Actual native UI clicks then covered Dashboard and all six Settings sections in
Global/IPv4 with the exit still rejected. The **90-second**
[navigation audit](../Tests/MihomoRuntimeTests/Evidence/v3/navigation-recovery/navigation.json)
passed: ten navigation requests all reached their window-update callbacks,
25–53 ms after the request, with zero new exit lookups, network/control cycles,
settings writes or lost communication. The blocked address remained visible;
provider status stayed ready and service-health timestamps continued advancing.
These timings measure app callbacks, not displayed-frame latency. One remote
observation still showed General after Maintenance had already applied in the
app; a later click on the selected Maintenance row was not a second navigation
event. This reinforces the need to separate remote frames from app event timing;
it does not prove Screen Sharing is the only remaining cause.

An additional scan of all GUI/core/supervisor warning/error records found none
inside the four settled matrix windows or the 90-second navigation window. The
read-only regression now fails on any warning/error, including event names not
in its explicit anomaly list. Local validation passed 226 shared tests, the
service and app suites, Python syntax checks and the Release package build.

Harness limits: an initial campaign exceeded the admin wrapper's 180-second
deadline after three cells; the complete four-cell campaign ran independently
with a saved result. An initial UI window omitted three Settings pages and
correctly failed coverage, although its stability checks passed. Neither partial
run counts as the final pass. These tests qualify this recovery-loop correction;
they do not rerun every historical traffic, sleep/wake or two-account scenario.
