# Dual-stack profile and proxy test plan

## Current failure/recovery acceptance contract (26 November)

User service commands also require the [command and supervision matrix](#user-service-command-and-supervision-matrix)
below. A successful RPC or installer exit alone does not qualify the visible
button, the completed network transition or the subsequent watchdog behavior.

Every UI and failure/recovery run must correlate GUI, core and supervisor events
with the actual actions. Declare expected verification triggers and terminal
states, record command/attempt/navigation IDs, and fail on unexplained repeated
checks, stale commands, gate changes, lost communication or recovery that never
settles. Visible status alone is insufficient. Do not defer anomaly detection to
the user. Read-only Dashboard/Settings navigation must produce no settings write,
network-change dispatch or new exit lookup.

Add a **35-second minimum** settled-denial window, spanning multiple ten-second
infrastructure scans. Exercise supervisor restart while already rejected, explicit
retry, and return to Direct in Rule/Global × IPv4/Dual-stack. The previous
three-second window missed a startup recovery flag that stayed armed until traffic
was approved. `v3_rejected_exit_stability_test.py` reproduced the loop before the
fix; `v3_recovery_startup_test.py` supplies the four-cell installed regression.
Use `--require-navigation` for the actual native Dashboard/all-six-Settings audit;
model assignments or RPC calls are not substitutes for that UI evidence.

**Executed on the recovery-loop correction:** four restart/rejection/retry/Direct
cells passed on unpublished build 11, core
`0b6c8025b4a849df288673049b63015df1d4b5abb3a6990265ab9a483aa58181`.
Every 35-second settled window had no new lookup or recovery event. A separate
90-second native navigation window covered all six Settings pages and Dashboard
without network/control work. Full-campaign reconciliation accounted for four
recovery requests, 16 completed lookups and 32 completed commands; restart-only
heartbeat failures are reported rather than hidden. See
[results and remaining UI limits](MIMO_NAVIGATION_RESPONSIVENESS.md#installed-correction-and-event-audit--26-november).

**Build-10 recovery qualification reopened:** the previous 60 coordinator
simulations bypassed `MonitoringEngine` admission/cooldowns. The 22 installed
exception cases repaired through Direct and replaced the fixture token, clearing
its cooldown. They do not establish recovery within the same blocked session.
The new `v3_blocked_retry_test.py` keeps the mode, core process and credential
unchanged from fault through repair, confirms fixture recovery independently,
and requires a fresh provider request before the local ten-minute pause expires.
No store edits, cooldown clearing, clock changes or service restart are allowed
in that sequence. A credential used by the local fixture may be set once before
the baseline and removed only during final cleanup.

**Earlier candidate result (paired approval, superseded):** unpublished build 11 passes this same-session campaign in
Rule/Global × strict IPv4/dual-stack. Every case preserves a real HTTP 429 with
`Retry-After: 900`, and each injected transport failure has one correlated close
in the actual core/supervisor logs. See
[the red/green evidence and limits](MIMO_BLOCKED_VERIFICATION_RECOVERY.md).
The user's original first private HTTP failure trigger remains unproven.

### Current IPv4 approval campaign

The subsequent [event-trigger audit](MIMO_EVENT_TRIGGER_AUDIT.md) adds a focused
native family-switch regression: start settled with an empty allowlist, click
Dual → IPv4 → Dual in each protected mode, retain the original settings and
observe at least 35 seconds after completion. `v3_family_switch_event_test.py`
observes real clicks without synthesizing them. Require one settings-triggered
lookup and one standalone pre-commit close per effective edit; additional
provider attempts must correlate with real failure/rotation. Preparation still
confirms protection. Assert no unexpected external event, stale command, warning,
recovery loop or health stall. The captured user trace fails the close-count
assertion before the correction; result files and exact candidate identity are
linked from the audit. Startup failures remain separately reported.

For the user-requested approved-state repeat, add the freshly observed proxy exit
IPv4 through core's normal revision-checked allowlist command, await a new approval,
and run the same observer with `--verdict approved`. Require a traffic-open event
for each successful verification and zero exit rejections. Then run
`v3_rejected_exit_stability_test.py --verdict approved --require-navigation` in
each mode: exercise all six Settings pages and Dashboard without changing inputs,
and assert zero lookup, gate command, configuration write, recovery event or
warning while health timestamps advance. The historical script name retains its
default rejected-state regression. The explicitly added allowed address remains
installed; restore the original Global/Dual selection, not the old empty list.

**Approved repeat executed:** native family switching passed in both Rule and
Global (four effective edits, four fresh lookups and four traffic openings).
Both 90-second navigation windows passed all six sections plus Dashboard with
no network/control work and continuing health updates. The incomplete first Rule
navigation run is retained separately, not counted as a pass. See the
[approved-state results and evidence](MIMO_EVENT_TRIGGER_AUDIT.md#approved-state-follow-up-requested-by-the-user).

The 26 November policy revision removes the IPv6 approval request entirely.
`v3_ipv4_approval_campaign.py` runs the installed candidate through four cells:
Rule/IPv4, Global/IPv4, Rule/Dual and Global/Dual. Its closed Delta fixture refuses
IPv6 TCP, drops IPv6 UDP and returns no AAAA answers (`S04`, `nodata6`), while the
IPv4 provider endpoint remains healthy. Each explicit successful refresh must
make exactly one required HTTP request; all recorded provider requests must be IPv4.

Each cell verifies empty/wrong lists, visible rejection and healthy provider,
three explicit rejected-state refreshes, allowlist-only repair, IPv4 application
traffic, no native IPv6 TCP/UDP packet escape, and four active fault/recovery
paths (proxy down/authentication/timeout and HTTP 503). Repairs keep credentials,
core identity and protected mode unchanged. HTTP 429/Retry-After remains a hard
restriction. Incoming SSH and Screen Sharing are checked during failures. Raw
state stays owner-only; only synthetic-address summaries are committed.

Captures must use `tcpdump -p`: promiscuous mode changes interface flags and
causes a real network-change closure, invalidating the traffic baseline. The
initial run exposed that harness error and was retained as an invalid traffic
qualification; application code was not changed for it. The final Global/Dual
cell pauses for native last-known/error/Monitoring inspection before recovery.
`v3_ipv4_lifecycle_test.py` separately verifies managed Direct, full Stop/released
Direct, Activate, native-release checks and retained settings/credentials.

**Executed: PASS for all four cells**, on unpublished 3.0 build 11 core
`fff99947b06a44095736bc1f212aef37e81860db7568a90e6bcb0f671fc1bb30`.
The campaign passed 12 explicit rejected-state refreshes, four allowlist-only
repairs, 16 active fault/recovery cases and four 429/Retry-After checks. Every
cell recorded 14 IPv4 provider requests and no IPv6 provider request. Strict
IPv4 rejected IPv6 before proxy dispatch; Dual-stack attempted TCP/UDP IPv6 at
the rejecting/dropping proxy. Native IPv6 packet captures stayed empty. All
22 Direct/Stop/Start assertions and installed migration checks passed.
See [results, sanitized evidence and UI limitations](MIMO_IPV4_APPROVAL_RESULTS.md).

The earlier installed/fault/inbound/lifecycle harnesses now use IPv4-only
approval assertions; their old result files are preserved as historical evidence,
not silently requalified. The obsolete paired-failure script exits with a pointer
to the current campaign before any mutation. Removing IPv6 rejection from the
old exception matrix leaves 20 current rows; its historical 22-row results below
include two removed IPv6-list scenarios and were not rerun in this revision.

These are required outcomes, not merely successful packet-denial checks:

| Requirement | Pass condition | Evidence |
| --- | --- | --- |
| Clear feedback | Distinguish an unapproved exit (including empty list and an old IPv6-only list migrated to empty) from proxy/provider failure. Show a pause deadline when applicable, retain the selected mode, and offer a relevant settings action plus Direct. Never describe blocked traffic as connected/approved. | Shared presentation tests, native failure renders, installed state and Event Log |
| No event loop | One verification attempt has one terminal outcome. Polling does not start another lookup, restart healthy services or reopen the gate. Legitimate explicit repair/network events remain possible; provider cooldowns and budgets still apply. | Coordinator simulations, monitoring scheduler tests, at least 35 seconds of installed settled-failure observation spanning multiple service audits, and the supervisor-restart matrix above |
| Responsive system | Core state/control requests remain bounded during failure. Incoming tracked TCP service replies remain available. GUI work stays off the main thread; warnings do not activate or seize focus. | XPC/GUI lifecycle tests, measured installed response times, fresh SSH/RFB/HTTP and existing-stream probes |
| Repair works | Editing the proxy/provider/allowlist leads to a fresh check in the same blocked session. A repaired transient connection failure must not require waiting out the local failure pause; real provider Retry-After and quotas remain enforced. Keep credentials, process and clock unchanged during repair. One fresh allowlisted IPv4 approves either traffic setting after readiness passes; IPv6 transport refusal must not pause a healthy IPv4 checker. No auto-approval and no silent fallback to Direct. | Combined scheduler/coordinator tests plus installed fault→repair→Refresh checks; old token-reset repair rows do not satisfy this requirement |
| Direct is an escape | Explicit Direct cancels/supersedes verification and late results cannot reopen protected mode. It does not require a successful lookup. Confirm owned PF/TUN/DNS release before reporting normal networking. A failed release must show an actionable error, not false success. | Coordinator cancellation/failure tests, installed Direct PF/DNS readback and native IPv4/IPv6 HTTP |

Exercise Rule and Global separately, each with strict IPv4 and dual-stack. The
60 coordinator rows cover proxy refusal, timeout, authentication failure,
provider outage, malformed responses, empty/wrong allowlists and migrated IPv6-only
lists from both starting states. Four additional cancellation cases hold the
HTTP lookup pending across Direct in Rule/Global × IPv4/dual-stack; Direct returns
before the held response and the late result cannot reopen. Existing
preparation/readiness tests cover the other activation stages. The 22 installed
Direct→protected cases cover refusal/authentication/provider-503 and the
allowlist variants; they complement rather than replace those simulations.

The installed credential fixture removes its disposable test token before
Direct, preventing any public provider request with that token. It therefore
does **not** qualify Direct-during-pending-HTTP cancellation; that is measured by
the coordinator tests. Neither short settled observation nor bounded RPC tests
prove absence of every possible macOS freeze. Physical sleep/wake, arbitrary
incoming UDP servers, untracked preexisting Direct sessions and asymmetric
public return paths retain their separate qualification limits.

Current results and candidate identity:
[incoming-access and recovery record](MIMO_V3_INBOUND_ACCESS_FIX.md).
The 60 exception/recovery simulations, four pending-HTTP Direct cancellation
cases and 22 installed exception rows passed. Installed state queries completed
within 1.597 seconds (564 samples, including Tart overhead); Direct restored
native IPv4/IPv6 HTTP in 9.903–12.492 seconds. All rows retained incoming SSH/RFB
access and had no extra lookup/open events during the 12-second settled window.
See [installed exception evidence](../Tests/MihomoRuntimeTests/Evidence/v3/inbound/exception-results.json)
and [responsiveness measurements](../Tests/MihomoRuntimeTests/Evidence/v3/inbound/exception-responsiveness.json).
Historical campaigns below remain unchanged and are not added to these counts.

Original Global experiment: **executed, with results and qualification limits recorded**. Prepared
and run 2026-11-24 on Delta and `mimo-vm`. All 48 core cells/6,240 cases matched
expectations; the optional `redir-host` diagnostic retained one functional
difference. See [the execution report](MIMO_DUALSTACK_TEST_RESULTS.md).
The original plan below is retained as the test contract. This is a standalone
profile experiment, not a change to the installed Mimo app.

Final-template campaign: **executed — 3,610/3,620 cases met expectations; ten
dual-stack short-name DNS assertions failed**. See the [final-template results](MIMO_DUALSTACK_TEST_RESULTS.md#final-template-results).
The IPv4-oriented template passed 905 cases in each mode. Dual-stack passed 900
and failed five in each mode, so it is not deployment-ready. These counts remain
separate from the older 6,240-case experiment.

## User service command and supervision matrix

### Focused Refresh now audit — 27 November 2026

Audit the actual Dashboard button in managed Direct (both saved family choices)
and Rule/Global × IPv4/dual-stack × approved/rejected exit: ten starting states.
Use production RPC only to prepare the starting state, then wait 35 seconds,
arm log offsets, click once, and observe completion plus another 35 seconds.
Temporarily select Never for the periodic interval and restore original settings
afterward. Record periodic-timer overlap separately; do not hide it by counting
only the manual trigger. Raw state stays root-private in the VM.

`Tests/MihomoRuntimeTests/v3_refresh_event_test.py` correlates manual request,
lookup ID, provider HTTP count, prepare/approve commands, gate changes and terminal
state. A normal click must produce one lookup and a fresh result. Direct must not
close the traffic gate. Protected modes intentionally close application outbound
traffic, allow the private proxy probe and reopen only for an approved IPv4.
Denial is a completed lookup, not a provider failure. Display/widget notifications
and infrastructure inspections are not additional IP checks. Fail on unexplained
follow-up lookups, errors, process replacement or late gate changes. Record native
clicks separately from API-only concurrency and scheduler tests.

Execution stopped at the user's request for a new workflow proposal: five native
clicks completed (Direct IPv4 and all four Global approval/family combinations),
four fully passed and one had transient engine/profile Unavailable after a single
successful lookup. No duplicate IP request occurred in those windows. Rule setup
was interrupted before its click; remaining cases are pending. See the
[scoped results and evidence](MIMO_REFRESH_EVENT_AUDIT.md). The new
[observation/transition proposal](MIMO_3_0_PLAN.md#proposed-observation-and-transition-workflows--27-november-2026)
has separate acceptance requirements and has not been implemented.

Added 26 November 2026 at the user's request. This is an additional acceptance
matrix, **not a report of newly executed tests**. Keep it separate from the
template packet/query totals below. Record each concrete operation, starting
state, fault and invocation method as a separate case before execution; do not
count one scenario family as one completed test.

### Ownership and invocation methods

- **Native GUI:** click the actual Dashboard controls, including both the engine
  row's Stop and the main “Stop engine” action. Check progress, disabled controls,
  errors, terminal labels and check ages. These both currently invoke full
  deactivation. Activation goes through the installer. Capture the actual click
  and resulting events; an RPC simulation is not native UI coverage.
- **Installed API:** use the production service-control route to the supervisor
  for IP-monitor Start/Stop/Restart, engine Start/Restart and Profile Reload
  (`profileHosting/restart`). Heartbeat observes supervisor progress; it does not
  execute user network commands. Call backend engine-only Stop separately:
  it releases controls and preserves the peers, unlike GUI full deactivation.
- **Lifecycle CLI:** exercise the installed `mimo-manage`/bundled `daemon.sh`
  deactivate, install/restore and uninstall paths. Record which entry point ran.
  For uninstall after app deletion, use the retained management helper. Do not
  treat CLI success as proof that the GUI authorization/progress path works.
- **Deterministic service/installer tests:** inject failures at intent persistence,
  confirmed blocking, launchd operation, profile delivery and final readback.
  Control barriers explicitly when testing races with peer repair; supplement
  these tests with installed observations and real native clicks.

Use managed Direct and Rule/Global × IPv4/dual-stack for applicable commands.
In each protected cell exercise both approved and rejected exits. Repeat relevant
recovery commands while a proxy/provider/controller fault is active. Full release
and activation also need the released-Direct starting state. Use isolated VM
fixtures, save the original settings privately, and restore them in final cleanup.

### Required cases

| ID | User operation or scenario | Required outcome and observations |
| --- | --- | --- |
| SC01 | Stop IP monitor | Logical monitoring stops; supervisor and heartbeat retain their PIDs and advance progress. Persist the monitor preference, allow no new periodic lookup, and cancel or explicitly account for any in-flight lookup. Protected traffic remains safely blocked if approval can no longer be maintained. Direct stays native. Stop must not be mistaken for a dead peer. |
| SC02 | Start IP monitor | Monitoring resumes and a requested fresh check completes or reports its specific failure. Both peers stay running. A rejected but successfully fetched IPv4 is displayed without pausing a healthy provider. Do not clear a genuine provider rate limit to make this pass. |
| SC03 | Restart IP monitor | Stop/start the logical monitor once, without restarting either peer. Fence the old attempt so its late reply cannot overwrite the new result. Require a terminal new check and no duplicate timer or verification loop. |
| SC04 | Start engine from the backend engine-stopped state | Re-enable its launchd registration, start one engine, verify controller/profile health and reconcile to the intended mode. Conflict or launch failure must leave an accurate recoverable state. This does not substitute for full Activate. |
| SC05 | Restart engine | Establish confirmed protection before replacing a protected engine. Observe its PID replacement and unchanged peer PIDs; require actual controller readiness and one accounted-for verification cycle before approved traffic resumes. In Direct, keep native networking and avoid a protected-mode cycle. |
| SC06 | Reload profile | Deliver the current profile and verify its receipt/controller response, normally without replacing the engine PID. Protected mode closes before mutation and verifies afterward; Direct must not install a protected tunnel or DNS override. A malformed profile or controller failure reports failure and permits Direct recovery. |
| SC07 | Full Stop from both Dashboard entry points | Run the shared deactivation lifecycle. Cancel/fence pending verification; remove all three jobs, current/legacy Mimo PF rules, DNS override and owned tunnel/settings. Verify native LAN/Tailnet and incoming-service access. The UI changes to Activate and may continue released IP monitoring; removed daemons must not remain Healthy or reappear. |
| SC08 | Activate after full Stop | Restore all three roles, clear saved stop intent as installation specifies, verify health, and finish in the installation state (managed Direct). Exercise both consent and cancellation for a conflicting engine/occupied resource. Do not replace a competing service before consent or report success after a partial install. |
| SC09 | Backend engine Stop → real reboot → Start | Persist the engine-disabled intent before unloading. Peers remain running and must not restore it, including after a real reboot. Start re-enables the job and restores actual controller/profile health. Record this separately from SC07. |
| SC10 | Duplicate requests and two GUI accounts | Double-click where possible, issue overlapping identical and conflicting commands, and alternate accounts. Require serialization/coalescing or an explicit conflict response; no lost accepted command, competing settings writer, duplicate process or GUI freeze. Both clients converge on the same durable result. An intentionally rejected stale/conflicting request is recorded, not hidden. |
| SC11 | Stop/reload/restart during verification or peer repair | Hold a lookup/profile operation in flight, then request Stop/Direct/Reload/Restart. Repeat with peer loss and maintenance entry. Check cancellation/generation fences and the shared repair lock. Late completions cannot reopen the gate, overwrite newer intent or resurrect a removed job. Repair must honor the final durable service intent. |
| SC12 | Lost reply, GUI exit and partial operation failure | Disconnect/reopen the GUI or interrupt a reply after acceptance; inject service/cleanup failures. Distinguish “not delivered” from “accepted, completion unconfirmed.” Reconcile from core/durable state instead of blindly repeating destructive work. Show communication failure separately from service failure; provide retry or Direct recovery. |
| SC13 | Commands during rejected exit, proxy down, provider failure or hung controller | Exercise relevant Start/Restart/Reload/retry requests without first escaping through Direct. A responsive provider is not paused because its result is disallowed. Recover within the same blocked session after fixing the cause, then separately prove the user can always select Direct. No peer restart may be caused solely by denial/provider failure. |
| SC14 | Uninstall/reinstall, app deletion and repeated cleanup | Test the Homebrew hooks and retained-helper cleanup, not just direct installer calls. Verify old/current rules and registrations disappear, removed jobs do not resurrect, native networking survives app deletion, and reinstall restores all roles. Retain local settings/credentials according to policy and export no secrets. |

### Test procedure and log assertions

1. **Identify the artifact and baseline.** Record version/build, core/engine hashes,
   boot UUID, selected/effective mode, traffic family, saved service intent,
   launchd labels/PIDs and progress sequences. Read live PF/DNS/TUN/controller
   state. Use fresh uncached requests and native LAN/Tailnet plus incoming-service
   probes where release or protection is being qualified. A running PID alone is
   not a health result.
2. **Declare the expected transition before acting.** Specify the permitted
   process changes, block/open sequence, expected lookup trigger and terminal
   state. User Start/Restart/Reload may explicitly request an IP check; ordinary
   state polling/navigation may not. Direct must not enter protected verification.
   A backend-only command and a GUI action that additionally requests Refresh
   need separate expectations. No-op and conflicting requests must not create
   unexplained extra work.
3. **Capture the complete operation.** Collect GUI records from every participating
   account, supervisor/core runtime and service logs, heartbeat repair records,
   installer output and engine errors from before submission through settlement.
   Correlate available request/command, revision, attempt, PID and generation
   identifiers. For paths without a shared identifier, record the invocation
   interval and readback; ambiguous attribution remains a qualification gap.
   Reconcile receipt, admission/rejection, progress and terminal completion.
   `mimo_service_changed` alone does not establish completed re-verification or
   network cleanup.
4. **Verify independently and through the GUI.** Compare returned state with live
   launchd/controller/PF/DNS/tunnel state. Measure bounded API response and UI
   completion against the operation's declared deadline; report durations, not
   just success. Check pending controls settle, stopped/unavailable/communication
   labels are accurate and Healthy ages use genuine inspections. Probe outgoing
   leakage and incoming access throughout protected mutations. Routine monitor/
   profile controls must not restart peers or create additional daemons.
5. **Observe the terminal state.** Require at least **35 seconds** of settled
   observation spanning infrastructure scans. After deactivation/uninstall,
   observe **at least 50 seconds** for resurrection, and use real reboot checks
   for durable Stop intent. Use at least **135 seconds** for repair/Stop races to
   span the 120-second startup grace and another infrastructure scan; extend the
   window through any still-pending repair/backoff. Continue collecting progress
   and logs.
   A healthy/blocked terminal state must not generate unexplained lookup, network
   change, gate transition, stale command, peer repair, repeated PF mutation or
   overdue-health events. Planned repair/backoff/fault errors must match the
   injected case exactly; never blanket-ignore warnings/errors.
6. **Qualify recovery and preserve evidence.** Record one terminal outcome for each
   accepted request and account for joined/cancelled/rejected requests. Test retry
   after the cause is removed and verify Direct remains usable. Restore settings,
   service intent and all test fixtures; confirm no deliberate fault remains.
   Keep raw logs/settings root-private and publish sanitized results with case ID,
   method, artifact, timing, expected/actual event counts, cleanup and limitations.
   Preserve failing evidence before any production fix, then rerun the same case.

### Existing evidence and outstanding coverage

The [named-background-services campaign](MIMO_CORE_INFRASTRUCTURE.md#qualification-completed--26-november-2026)
contains backend IP-monitor Stop/Start, engine Stop→reboot→Start, full
deactivate/activate and uninstall/reinstall checks with settled log audits.
Those lifecycle runs preceded the final conditional-PF-write binary; their
artifact scope is preserved. Final-artifact audits cover rejected Rule/IPv4 and
Global/dual-stack recovery, controller health, normal reboot and other listed
follow-ups. They do not establish every mode/fault/command combination above.

**Still to execute for this expanded matrix:** explicit IP-monitor Restart,
engine Restart and Profile Reload campaigns; actual native clicks on each
mutating control; simultaneous two-account commands; deterministic command/repair
races and lost-reply reconciliation; and the complete mode/fault combinations.
Prior native navigation/copy tests are read-only UI evidence. Do not mark these
new cases passed by reusing RPC tests, historical lifecycle tests or the existing
64-distinct-check summary. This documentation update runs no VM operations.

## Current plan summary

The requirement is **no native bypass for captured test traffic**. Preserve the
working `Profiles/mimo-global-ipv6-test.local.yaml` behavior: capture IPv6 and
NAT64, send allowed TCP/UDP through the selected proxy, and silently drop captured
IPv4/IPv6 echo requests. An IPv6 connection carried by the proxy is an allowed
outcome. Preventing every IPv6 connection at the proxy's destination is not a
requirement of this campaign or an unresolved part of the earlier leakage fix.

| Template | DNS/address-family defaults | Rule mode | Actual engine Global mode |
| --- | --- | --- | --- |
| [mimo-ipv4-template.yaml](../Profiles/mimo-ipv4-template.yaml) | Client AAAA suppressed; node `ip-version: ipv4`; IPv6 capture retained. | Reject known IPv6 destinations, otherwise use Proxy; final REJECT catches fall-through. A remotely resolved hostname can still reach IPv6 through the proxy. | Use Proxy for captured TCP/UDP, including IPv6 when supported; ordinary rules are ignored. This preserves the tested baseline's Global behavior. |
| [mimo-dualstack-template.yaml](../Profiles/mimo-dualstack-template.yaml) | Client AAAA enabled; IPv6 fake pool; node `ip-version: dual`. | Use Proxy for captured IPv4/IPv6 TCP/UDP; final REJECT catches fall-through. | Use Proxy for captured IPv4/IPv6 TCP/UDP. |

Both retain silent dropping of captured `ping` and `ping6`, the previously agreed
native LAN/Tailnet exceptions, and default engine IPv6 TUN addressing. Both require
the tested `gvisor-no-ping` engine. Deriving a Global variant changes only `mode`.
The filename `ipv4` describes its DNS defaults; it does not disable IPv6 capture.
Both final standalone templates now use `tun.dns-mode: native`, with explicit
UDP/TCP port-53 interception and the existing local DNS listener. This replaces
the earlier templates' `disabled` setting; the frozen working profiles stay unchanged.

Executed **3,620 behavioral cases: 3,120 matrix + 500 focused**, covering both files
in both modes. Four parser checks passed separately. All matrix cases and 490
focused cases met expectations. Dual-stack native short names returned an unwanted
fake IPv6 address alongside the correct native IPv4 answer; D02/D04/D07/D09/D10
failed in both modes. Captured transport and ping checks passed. Shutdown produced
one native PTR request to the former TUN DNS endpoint in each lifecycle run, after
teardown began; active protection had no such packets. This transition limitation
is retained, not hidden by successful resolver removal.

The 48 native-DNS cases include controlled search/scope changes, actual VM Tailscale
disconnect/reconnect and resolver ownership. D10 uses temporary DNS entries instead
of switching physical networks; D11 injects process death after registration.
The own-tailnet short-name target is this VM itself because no same-tailnet peer
is available. Those scope limits are not broader deployment qualifications.

## Final template decisions and DNS comparison

This section describes the tested template configuration, not additional measured
results. The [IPv6 analysis](MIMO_IPV6_PROFILE_ANALYSIS.md#updated-comparison-and-proposal-table)
retains the full installed-Mimo/sample/Clash comparison and separates confirmed
packet bypasses from inference. The final standalone files use actual engine
Rule or Global; the managed-app proposal keeps engine Rule beneath both GUI modes.

| Area | `mp-sg-global.example.yaml` | `clash-verge 2.yaml` | Final IPv4-oriented template | Final dual-stack template |
| --- | --- | --- | --- | --- |
| IPv6 operation and TUN | Top-level `false`; native IPv6 is not captured. | Top-level `true`; default IPv6 routes. | Top-level `true`; default engine TUN IPv6 address; explicit `::/1` and `8000::/1`. | Same capture settings. |
| Client DNS | AAAA suppressed; IPv4 fake pool. | AAAA enabled; no explicit IPv6 fake pool. | AAAA suppressed; IPv4 fake pool; node `ip-version: ipv4`. | AAAA enabled; separate IPv6 fake pool `fdfe:dcba:9876:1::/64`; node `ip-version: dual`. |
| Captured ping/ping6 | Native IPv6 can escape; stock stack is not a silent-drop guarantee. | Stock forwarding bypass was observed. | Patched `gvisor-no-ping` silently drops captured echo requests. | Same. |
| Rule/Global selection | Global; effective selection can depend on saved/runtime state. | Global; effective selection can depend on saved/runtime state. | Explicit `GLOBAL → Proxy → TEST-PROXY`, no DIRECT member; only `mode` changes. | Same. |
| Terminal rules | Not enforced in Global. | Not enforced in Global. | Known IPv6 REJECT, then `MATCH,Proxy`, then `MATCH,REJECT`. | `MATCH,Proxy`, then `MATCH,REJECT`. |
| Native LAN/Tailnet | Static Tailnet IPv4/IPv6 exclusions; connected LAN routes remain native. | No explicit Tailnet exclusions. | Adopt the sample's static exclusions and native Quad100 policy; no dynamic utun provider. | Same. |
| DNS entering TUN | `dns-hijack: [any:53]`. | Same. | Explicit `any:53` and `tcp://any:53`. | Same. |
| macOS system DNS | No `dns-mode`; the pinned engine defaults to disabled on macOS. | Same YAML omission; a surrounding app may separately configure DNS. | `dns-mode: native` temporarily registers the TUN DNS endpoint. | Same. |
| Public upstream DNS | DoH explicitly through `#MP-SG`. | Plain DNS/DoH without an explicit proxy suffix. | DoH explicitly through `#Proxy`; no public/native fallback resolver added. | Same; IPv4 DoH transport can return AAAA records. |
| Proxy bootstrap | Separate DoH resolver. | Separate DoH resolvers. | Preserve separate bootstrap DoH. The IPv4-literal test proxy needs no bootstrap query. | Same. |
| MagicDNS received by engine | `.ts.net` → native `100.100.100.100`, fake-IP excluded. | No explicit MagicDNS policy. | Preserve the sample's Quad100 policy and fake-IP exclusions. | Same. |
| Firewall | No Mimo PF rules in the YAML. | Same. | No new PF rule; capture and upstream decisions belong to TUN/profile. | Same. |

### Why the sample's DNS mechanism is insufficient on its own

`auto-route` plus `dns-hijack` intercepts matching DNS **that reaches TUN**; it does
not itself replace macOS resolver settings. DNS sent on a more-specific native
LAN route can bypass that interception. Conversely, disabled system registration
does **not** mean all applications must query the local listener explicitly:
their existing DNS path may already enter TUN. Do not confuse `dns.enable`, client
AAAA suppression, or `fake-ip-filter` with system resolver registration. A fake-IP
filter requests real answers; it does not by itself select a native DNS server.

The explicit UDP/TCP entries document both required transports. Do not claim the
sample necessarily loses TCP interception on this exact engine: its pinned
`listener/sing_tun/server.go` normalizes entries to address/port pairs, and
`dns.go` applies the shared match to TCP and UDP handlers. Both transports still
need packet tests. The substantive new setting is native system registration.

The sample can therefore be useful for ordinary IPv4 hostname traffic without
being a complete DNS/IPv6 capture policy. IPv6 echo/native TCP bypass with its
switches was observed; its NAT64-specific bypass is still code/configuration
inference, not a separate sample packet test. The templates retain explicit
IPv6/NAT64 capture and the silent-echo engine patch rather than copying those gaps.

Mihomo's [TUN documentation](https://wiki.metacubex.one/en/config/inbound/tun/)
distinguishes `dns-mode` from `dns-hijack`, documents the macOS disabled default,
and warns about native-LAN DNS interception. The pinned engine source agrees:
`sing-tun/tun.go` selects that default; `tun_darwin.go` registers DNS only when
enabled; `internal/systemconfiguration/dns.go` publishes a temporary catch-all
resolver at the TUN DNS address. These files are in the dependency identified by
[the engine manifest](../Patches/no-ping-test-engine.json).

### DNS ownership, delivery and restoration

For these **standalone templates**, the engine is the sole resolver owner:

1. Start with unchanged saved Wi-Fi/Ethernet DNS preferences and existing native
   VPN resolvers. Engine startup adds a session-owned dynamic-store DNS entry.
2. Ordinary system clients use the registered TUN endpoint for matching queries;
   queries entering TUN are served by the internal DNS module. The explicit
   `127.0.0.1:1053` listener remains available for diagnostics, not as a required
   application setting. More-specific scoped resolvers may still win.
3. Public upstream queries received by the engine use proxied DoH. `.ts.net`
   queries received by the engine use native Quad100 through the static exclusion.
   Preserve Tailscale's scoped resolver and intentional native split-DNS paths;
   do not claim native registration overrides every scope or application DoH.
4. Stop/exit/crash removes the process-owned registration, exposing the existing
   resolver configuration. Do not rewrite `/etc/resolv.conf`, saved network-service
   preferences, or Tailscale's DNS settings. No persistent DNS backup/restore job
   or PF policy is introduced. Engine exit also ends capture; this is not a kill switch.

For **Mimo-managed integration**, core/supervisor already owns a temporary resolver
and search-domain handling in [MimoDNSConfiguration.swift](../Sources/MimoService/MimoDNSConfiguration.swift)
and [MimoProtectedDNS.swift](../Sources/MimoShared/MimoProtectedDNS.swift). That owner
must remain exclusive: the managed renderer must use `dns-mode: disabled`, remove
its own entry on Direct/Stop/uninstall, and retain its existing lifecycle checks.
Do not load the standalone `native` default alongside that resolver. This change
does not edit or qualify the installed app's renderer, events or lifecycle.

### Search domains and deployment acceptance

The engine's native registration does **not explicitly copy `SearchDomains`**.
Replacing the default resolver can change short-name expansion, even when a
Tailnet FQDN works. Neither the sample YAML nor the final templates alone prove
search-domain preservation. P10 proved system lookup, Safari and forced-exit
cleanup for its separate configuration; it did not qualify all short-name or
Tailscale reconnect behavior for the two final templates.

The executed DNS cases retained the search list, but dual-stack short names gained
fake AAAA answers for unqualified names. Packet correlation confirmed that path.
This blocks dual-stack deployment acceptance even though fully qualified names,
public DNS and cleanup passed. Correct unqualified/native-name handling and rerun
the affected tests; do not disable Tailscale DNS, hardcode a private suffix or
reclassify these failures as expected. Physical primary-network changes and a
different same-tailnet peer remain additional qualification. Keep real credentials
in an owner-readable, ignored local copy; public endpoints are placeholders.

The frozen IPv4-oriented and P07 working files keep `dns-mode: disabled`. Relative
to those public baselines, the final templates change only the default mode, rule
list and system-DNS registration. Capture, local listener, upstream policy, native
exceptions and patched ping behavior are retained.

## Completed experiment scope

The original experiment enabled IPv6 DNS answers and real IPv6 application traffic through
an **IPv4-addressed SOCKS5 proxy**, while preserving Global mode, zero rules,
silent dropping of captured pings, and native LAN/Tailnet access. An unsupported
destination or proxy capability must produce a failure, never a native fallback.

## Preserve the working configuration

`Profiles/mimo-global-ipv6-test.local.yaml` is the frozen working profile. Do not
edit, rename, replace, load into a host engine, or use it as a runner's output.
Record its hash, permissions and modification time in an ignored, owner-only run
manifest, then compare them after every phase. Leave its public template and the
previous qualification evidence unchanged too.

Generate **separate** local files from the public template, substituting only the
local fixture endpoint and the declared variant settings. The working profile's
remote proxy credentials are unnecessary for these tests. All generated files
are mode 0600, under the existing `Profiles/*.local.yaml` ignore rule.

Use the already qualified `v1.19.34-mimo-no-ping.1` test engine, identified by
[the pinned build manifest](../Patches/no-ping-test-engine.json) and its recorded
binary checksum. Stock Mihomo does not implement `gvisor-no-ping`. No engine or
app rebuild, installation, release, Homebrew operation or production profile
replacement is part of this experiment.

## Delta fixtures and VM topology

```text
mimo-vm client → test TUN → GLOBAL → Proxy → SOCKS5 on Delta (IPv4 listener)
                                                    ├→ Delta IPv4 HTTP/HTTPS/UDP
                                                    ├→ Delta IPv6 HTTP/HTTPS/UDP
                                                    └→ Delta controlled DoH
```

Use actual sockets and actual service responses. A SOCKS success reply, a fake-IP
answer or a synthetic echo server alone does not qualify application transport.

| Component | Arrangement |
| --- | --- |
| SOCKS5/control listener | Delta's VM bridge IPv4 address; dynamically allocated unprivileged ports. No IPv6 proxy listener. |
| IPv4 application address | Delta's existing LAN IPv4 address, **different from the bridge/proxy/control address**. Delta currently has both; rediscover them at execution. |
| IPv6 application address | Delta's existing non-link-local IPv6 address reachable from the VM. Bind an IPv6-only socket and verify its actual family. |
| HTTP/HTTPS | Separate IPv4/IPv6 listeners return a per-case nonce, family marker and deterministic body with a checked hash. |
| UDP | Real IPv4/IPv6 nonce services, with request/response lengths and address families recorded. |
| Controlled DNS | Local DoH answers for names under `mimo-lab.test`; A-only, AAAA-only, dual-stack and nonexistent names. No query for this zone leaves the lab. |
| TLS | Per-run local CA and SAN-correct certificates. Client `--cacert`; engine-local CA configuration. No OS trust-store changes and no disabled verification. |

Before TUN starts, prove native IPv4/IPv6 service reachability and independently
exercise the SOCKS implementation. If either service or the fixture is broken,
mark dependent cases invalid; their timeouts cannot be counted as leak protection.

Connected LAN routes normally bypass the profile intentionally. Add temporary,
exact VM `/32` and `/128` capture routes **only for the two application addresses**
when needed, verifying both routes select the test TUN. Keep the bridge proxy,
SSH/control path and unrelated native LAN/Tailnet routes outside TUN. These are
test instrumentation, not proposed YAML routing changes. Fail preflight if the
data and control addresses coincide or native controls become captured. Do not
add addresses or change routes on Delta to make a test pass.

The proxy accepts only the VM's client address and exact fixture names,
destination addresses and ports. It never becomes an unrestricted relay. SOCKS5
UDP relay traffic requires a live authorized UDP ASSOCIATE connection and is
revoked when that connection closes. Keep control operations authenticated with
a temporary local token. Use fixed destination mappings inside the proxy's test
zone resolver; preserve the requested hostname/ATYP in evidence. Do not rewrite
an IPv6-only request to IPv4 to simulate IPv6 success.

Delta's existing VPN/Clash engine, PF, routes, DNS and system trust remain
untouched. Engine and route experiments run only inside `mimo-vm`.

## Profile files

All core variants retain these properties:

- `mode: global`, `rules: []`, and `GLOBAL → Proxy → TEST-PROXY`, with no DIRECT
  alternative or fallback; verify the live selectors, not only the YAML.
- Top-level `ipv6: true`, `stack: gvisor-no-ping`,
  `disable-icmp-forwarding: true`, the default engine IPv6 TUN address, IPv4
  auto-routing, and explicit `::/1` plus `8000::/1` route coverage.
- Static native Tailnet exclusions and native Quad100 policy; no dynamic utun
  provider, interface binding, provider port or provider fallback.
- Fake-IP DNS, current IPv4 fake range, current filter, TCP/UDP DNS interception,
  `tun.dns-mode: disabled`, and the IPv4 local DNS listener.
- An IPv4-literal SOCKS5 endpoint, `udp: true`, isolated state/controller paths,
  no persisted selections or fake-IP mappings, and no added firewall rules.

For reproducible DNS, a common **lab-only overlay** replaces public DoH with
`https://<Delta IPv4 data address>:<DoH port>/dns-query#Proxy`. Keep `.ts.net` on
Quad100. Explicitly exclude system/hosts-file data from the lab zone; no `/etc/hosts`
edits. The literal proxy needs no bootstrap DNS: retain the existing bootstrap
configuration but assert it sends no queries during lab cases. Inject the local
CA using this pinned engine's actual YAML spelling, `tls.custom-certifactes`
(a misspelling in upstream), with PEM contents. Assert loading succeeds; never
silently substitute insecure TLS. Record this overlay separately from the
features being compared.

Proposed IPv6 fake range: `fdfe:dcba:9876:1::/64`. Check for conflicts before use;
it must not overlap the default TUN address prefix or native Tailnet ranges.

| ID / local file | `dns.ipv6` | `fake-ip-range6` | Node `ip-version` | Purpose |
| --- | --- | --- | --- | --- |
| P00 `mimo-dualstack-p00.local.yaml` | false | omitted | ipv4 | Baseline copy with lab endpoint/DNS overlay only. |
| P01 `mimo-dualstack-p01.local.yaml` | false | omitted | dual | Isolate destination-family preference from client AAAA suppression. |
| P02 `mimo-dualstack-p02.local.yaml` | false | present | ipv4 | Negative control: an IPv6 pool alone should not enable client AAAA. |
| P03 `mimo-dualstack-p03.local.yaml` | false | present | dual | Same negative control with dual-family destination resolution. |
| P04 `mimo-dualstack-p04.local.yaml` | true | omitted | ipv4 | Negative control: enabling AAAA without an IPv6 fake pool. |
| P05 `mimo-dualstack-p05.local.yaml` | true | omitted | dual | Isolate the missing fake pool from node-family restrictions. |
| P06 `mimo-dualstack-p06.local.yaml` | true | present | ipv4 | Expose IPv6-only UDP hostname resolution constrained to IPv4. |
| P07 `mimo-dualstack-p07.local.yaml` | true | present | dual | Main candidate: IPv6 fake answers and dual-family destination support. |

These eight files cover every combination of the three core switches. They
share the same proxy IPv4 address; `ip-version: dual` does not require an IPv6
address on the proxy listener.

Focused comparison files, outside the full Cartesian matrix:

| ID / local file | Delta from P07 | Question |
| --- | --- | --- |
| P08 `mimo-dualstack-p08.local.yaml` | Node `ip-version: ipv6-prefer` | Does a family preference improve IPv6 selection without bypass on failure? |
| P09 `mimo-dualstack-p09.local.yaml` | `enhanced-mode: redir-host`; remove fake ranges | Separate fake-IP mapping problems from transport problems. This changes behavior and is not the preferred replacement. |
| P10 `mimo-dualstack-p10.local.yaml` | `tun.dns-mode: native` | Qualify macOS system resolver delivery, including removal after exit/crash. This is a separate integration experiment. |

If P07 qualifies, copy it to the **new**
`Profiles/mimo-global-dualstack-test.local.yaml`, then remove the lab-specific
endpoint/DNS/CA overlay for the intended deployment and document what that
deployment still needs to qualify. Do not overwrite the working IPv6 test file.
Lab success proves the profile and a capable proxy can work; it does not prove
the supplied remote proxy supports IPv6.

## Proxy behavior versions

The following six modes keep IPv4 TCP and UDP working and use the same IPv4
SOCKS listener. IPv6 UDP lacks a SOCKS per-datagram error reply, so unsupported
IPv6 datagrams are deliberately dropped and must time out at the client.

| Mode | IPv6 TCP CONNECT | IPv6 UDP forwarding |
| --- | --- | --- |
| S00 | Forward to the real IPv6 service | Forward |
| S01 | Explicit failure reply, no upstream socket | Forward |
| S02 | Stall within the test deadline, then close | Forward |
| S03 | Forward | Drop |
| S04 | Explicit failure reply | Drop |
| S05 | Stall, then close | Drop |

Apply these policies after resolving a domain too, not just to literal IPv6 ATYP.
Keep DoH transport on IPv4 in this core matrix, so refusing application IPv6
does not accidentally make DNS unavailable. A-only and AAAA-only names have
exactly the stated family. Two dual-stack names have opposite **proxy-side TCP**
resolution preferences. Record actual UDP destination selection separately:
Mihomo resolves SOCKS UDP names locally, so the proxy's hostname preference does
not control that decision.

Test unsupported UDP ASSOCIATE, authentication errors and unavailable proxies
separately; these are different faults from IPv6-only refusal. Do not represent
an unsupported operation by replying success and manufacturing a response.

## Bounded exhaustive matrix

[The machine-readable matrix](MIMO_DUALSTACK_TEST_MATRIX.json) defines these axes.
“Exhaustive” means all combinations of these declared axes, plus the focused
scenarios below; it does not mean every macOS version, application or protocol.

### Application matrix: 2,880 planned cases

`8 profiles × 6 proxy modes × 10 client targets × 3 protocols × 2 cache states`.

Ten client targets are:

1. Actual Delta IPv4 literal.
2. Actual Delta IPv6 literal.
3. A-only hostname using this engine's A/fake-IPv4 answer.
4. The same A-only hostname using this engine's AAAA/fake-IPv6 answer.
5. AAAA-only hostname using this engine's A/fake-IPv4 answer.
6. The same AAAA-only hostname using this engine's AAAA/fake-IPv6 answer.
7. Dual-stack, proxy-prefers-IPv4 hostname using A/fake-IPv4.
8. The same hostname using AAAA/fake-IPv6.
9. Dual-stack, proxy-prefers-IPv6 hostname using A/fake-IPv4.
10. The same hostname using AAAA/fake-IPv6.

Protocols: HTTP, certificate-verified HTTPS, and UDP nonce exchange. Cache
states: a new per-case name/connection, then a repeat using its established DNS
mapping but a **new application connection/UDP association**. Literal cases
repeat fresh connections too; they have no DNS cache to warm. Pin the requested
answer in the client while preserving the HTTP Host/TLS SNI name, so each DNS
family path is actually exercised. Do not inherit an address from another engine.

For profiles without client AAAA answers, the forced-AAAA case records
`EXPECTED_DNS_SUPPRESSION`, not a successful connection or a passed leak test.
Other literal/hostname paths still test that profile's capture and failure
behavior. A fake-IPv6 client connection can reach an IPv4 upstream after name
restoration; label both legs. Only an observed real IPv6 service exchange proves
IPv6 forwarding. In particular, client AAAA suppression does not establish that
SOCKS remote hostname resolution is IPv4-only.

### DNS delivery matrix: 2,880 planned queries

`8 profiles × 6 proxy modes × 5 name classes × 2 query types × 2 transports × 3 paths`.

- Names: A-only, AAAA-only, both dual-stack names, and nonexistent.
- Types: A and AAAA. Transports: UDP and TCP.
- Paths: explicit `127.0.0.1:1053`; captured IPv4 destination port 53; captured
  IPv6 destination port 53. Both captured destinations use the controlled data
  addresses and their verified VM capture routes. There is no assumption that
  the IPv4 listener also binds `::1`.

Fake-IP responses may be generated without an upstream DNS request, even for
a nonexistent hostname. Check the expected fake-pool response separately from
real resolution; do not require NXDOMAIN from the fake mapping layer. Attempted
service access for nonexistent names must fail with no native fallback.

### Real resolver matrix: 480 planned queries

`8 profiles × 6 proxy modes × 5 name classes × 2 query types`, through the engine's
`/dns/query` API, using unique names. This path queries its real resolver rather
than allocating a client fake IP. Correlate each response with the DoH fixture's
question/answer and proxy connection logs. Explicitly check real NODATA and
NXDOMAIN, independently of fake-IP behavior. The controller is not proof that
the local listener or macOS resolver works; those have separate cases.

Total: **6,240 planned cases across 48 profile/proxy cells**, before the focused
tests. Keep expected DNS suppression, expected transport denial, successful
service access, invalid fixture and unexecuted cases as distinct result classes.
Do not count planned or inapplicable connection attempts as transport passes.

## Focused failure and regression scenarios

Run these after the P00/P07 smoke comparison, with P07 as the default unless
another profile is specified. Use separate variants for one changed condition;
do not alter a running cell's proxy policy while its requests are in flight.

| ID | Scenario | Required observation |
| --- | --- | --- |
| F01 | DoH over an IPv4 versus IPv6 destination, S00 and S04 | IPv4 DoH can answer AAAA when application IPv6 is refused. IPv6 DoH refusal must fail resolution without trying native/public backup DNS. |
| F02 | AAAA NODATA, DNS SERVFAIL, NXDOMAIN, delayed/dropped DoH reply, invalid TLS certificate | Distinguish a valid empty answer, DNS error, timeout and TLS failure. No silent direct resolver fallback. Test cold names, then expiry/recovery. |
| F03 | SOCKS rejects domain ATYP but accepts IP literals; explicit replies 3, 7 and 8 | Separate remote-name support, network failure and unsupported command/address-family behavior; preserve the actual error. |
| F04 | UDP ASSOCIATE refused, all UDP dropped, UDP relay unavailable, association closed | IPv4 TCP remains a control. Both UDP families fail without direct fallback; closed associations no longer relay packets. |
| F05 | Wrong credentials, no acceptable auth method, closed proxy port, midstream TCP reset | Real services remain healthy; captured applications cannot bypass the failed proxy. No secrets in logs. |
| F06 | Warm DNS followed by IPv6 support withdrawal, then restoration | Fresh connections follow current capability; failures do not escape. Recovery works without selecting DIRECT. |
| F07 | Dual-stack normal client/Happy Eyeballs, P07 and P08, IPv6 refused or delayed | IPv4 retry is acceptable only through the same selected proxy. Record client and upstream families, retries and timing. Add a Safari smoke check after deterministic probes. |
| F08 | P09 real-address DNS versus P07 fake-IP; literal mixed-listener versus TUN controls | Isolate mapping, name restoration and DNS-family selection. Direct SOCKS success alone cannot pass the TUN case. |
| F09 | UDP payloads 96/1,232/8,224 bytes; large HTTPS body; IPv6 error/control packets | Check payload hashes, fragmentation/reassembly and useful ICMP control handling. Silent echo dropping must not suppress all ICMPv6. |
| F10 | Captured IPv4/IPv6 echo: literal, fake IP, default TUN prefix and both NAT64 ranges | Requests enter TUN; zero echo replies and zero native forwarding. No synthetic successes. Reuse the existing no-ping packet runner. |
| F11 | Real native LAN/Tailnet IPv4/IPv6 ping and service controls, before/during/after | Controls stay outside forced data capture routes and retain real responses. Quad100 and engine `.ts.net` queries work; disconnect is reported separately. |
| F12 | Both NAT64 ranges: literal TCP/UDP and failure with proxy stopped | Verify TUN coverage and preserved SOCKS destination. A fixture may map these only for a labeled transport test; that does **not** qualify NAT64 translation. |
| F13 | P10 macOS resolver registration, normal system lookup, repeated load, exit and forced engine termination | Compare scoped resolvers/search lists, test system A/AAAA resolution, and restore only test-owned DNS state. P00–P09 keep DNS registration disabled. |
| F14 | Repeated P00→P07→P00 loads; occupied ports; wrong engine hash/stock engine; SSH loss/runner interruption | Abort invalid setup before route changes; never stop an unrelated engine. Watchdogs clean their own processes/routes. No stale mappings or resources between cells. |
| F15 | Engine exit/crash while service traffic is active; deliberately native route/interface control | Document the limit: YAML cannot enforce capture once its engine/TUN is gone or on intentionally excluded routes. This is not a passed fail-closed test. Installed Mimo's transition guard needs separate qualification. |

For F11, identify already responding peers privately; do not treat an offline peer
or missing IPv6 service as a configuration failure or a pass. Do not toggle the
host's Tailscale connection. Test-zone DNS answers and proxy capabilities stay
local and deterministic; public Internet access is not a prerequisite.

## Evidence and pass criteria

Every case records profile ID/hash, engine identity, fixture mode, monotonic
start/end, query/connection IDs, requested hostname/address/ATYP, client family,
actual upstream family, response/error, service nonce/hash and packet counts.
Capture the VM TUN and relevant native interfaces, plus Delta's actual service
leg (including loopback where local connections use it). Fixture socket logs
must prove that AF_INET6 requests used IPv6-only service sockets.

A functional pass requires the right application payload from the intended
service. A failure-mode pass requires the expected error/timeout **and no native
destination or unintended DNS egress**, with services healthy before/after. A
single native service-bound packet outside the intended exceptions is a leak,
even if no reply arrives. Exclude SSH, fixture control, the authorized proxy
TCP/UDP relay, Quad100 and explicit native controls by exact endpoints, not broad
subnets. Count both IPv4 and IPv6 escape attempts.

Fresh case names and fresh engine state prevent stale-answer false positives.
Warm cases deliberately reuse a known mapping; retain both observations. Do not
flush a shared cache concurrently with another case. Give each case at most five
seconds, with separate connect/read deadlines; collect timeout evidence instead
of retrying indefinitely. Run at most four independent cases concurrently within
a cell, serializing cold/warm pairs and all mutations. Start a new engine and
fixture mode for each cell. Calibrate resource limits during smoke tests; record
any timeout-policy change before the full run.

Keep raw captures/configuration/temporary keys and tokens in ignored mode-0700
run directories, with mode-0600 sensitive files. Never commit the supplied proxy
or private Tailnet identities. Save only sanitized reports under a **new**
`Tests/MihomoRuntimeTests/Evidence/dualstack/` directory; do not replace the older
successful no-ping evidence. Record every planned case as executed, intentionally
suppressed, invalid or not run. Unexpected results remain in the report.

## Execution order and cleanup

1. **Preflight:** verify VM identity, engine checksum, clean VM engine/TUN/port
   state, native service reachability, existing host address separation and the
   frozen profile fingerprint. Snapshot routes/resolvers and launch identity.
2. **Fixture self-test:** independently prove IPv4/IPv6 service and DNS behavior,
   both SOCKS address forms and all six failure modes before drawing conclusions
   about Mihomo. Reject requests outside the endpoint/client allowlists.
3. **Generate and parse profiles:** produce the eleven private files plus a
   redacted setting diff. Run engine configuration validation, without starting
   an engine on Delta. No profile is installed into the managed app; “install”
   here means loading it into an isolated test engine in `mimo-vm`.
4. **Smoke:** P00/P07 with S00/S04, covering both literals, AAAA-only names, both
   listener transports, real resolver queries, real services, ping and cleanup.
   Fix fixture/runner defects first; retain the failed smoke evidence.
5. **Full matrix:** all 48 cells and their declared 6,240 cases. If a leak is
   observed, stop the affected phase, clean up and investigate before continuing.
6. **Focused regressions:** F01–F15 and P08–P10; keep system-DNS/lifecycle mutations
   sequential and separate from the disabled-DNS baseline.
7. **Candidate decision:** compare actual results, retain P07 only if qualified,
   and save the new dual-stack candidate with its deployment limits. Report any
   required profile/code changes; do not silently change the frozen baseline.

Each VM cell has an independent watchdog (initial limit six minutes); Delta's
fixture has a bounded lifetime (eight minutes). A whole-run budget of six hours
prevents abandoned runs; an interrupted/expired run is incomplete, not passed.
Stop only identity-verified child processes, close all associations/listeners,
remove only test-owned exact routes and resolver entries, and restore saved
values only when they still match the test's own values. Verify no test engine,
TUN, capture route, listener or resolver survives. Recheck native LAN/Tailnet
access and the frozen profile fingerprint before moving to the next phase.

The runner must perform cleanup on success, errors, signals and parent loss. It
must not globally flush PF, routes, DNS configuration or other services. Preserve
unrelated network changes made during a run and report any cleanup conflict.

## Implementation references and limits

- [Existing real-service runner](../Tests/MihomoRuntimeTests/ipv6_local_service_test.py):
  restricted Delta forwarding, certificate-verified IPv6 HTTPS, UDP and exact VM
  capture-route cleanup. Extend through a new dual-stack runner; retain the old
  qualification as a regression.
- [Existing Global runner](../Tests/MihomoRuntimeTests/ipv6_global_profile_test.py)
  and [no-ping runner](../Tests/MihomoRuntimeTests/no_ping_profile_test.py).
- Pinned source: [fake-IP A/AAAA allocation](https://github.com/MetaCubeX/mihomo/blob/0455d0d28c4526937380505153e65a843d8612e8/dns/middleware.go),
  [IPv6 fake-pool enablement](https://github.com/MetaCubeX/mihomo/blob/0455d0d28c4526937380505153e65a843d8612e8/dns/enhancer.go),
  [local UDP name resolution](https://github.com/MetaCubeX/mihomo/blob/0455d0d28c4526937380505153e65a843d8612e8/adapter/outbound/base.go),
  [SOCKS transport](https://github.com/MetaCubeX/mihomo/blob/0455d0d28c4526937380505153e65a843d8612e8/adapter/outbound/socks5.go),
  [real DNS query API](https://github.com/MetaCubeX/mihomo/blob/0455d0d28c4526937380505153e65a843d8612e8/hub/route/dns.go).
- [SOCKS5 protocol](https://www.rfc-editor.org/rfc/rfc1928) separates IPv4/IPv6/domain
  destinations from the address used to contact the proxy.

The [execution report](MIMO_DUALSTACK_TEST_RESULTS.md) distinguishes measured
outcomes from the original inferences above. The campaign qualifies the declared
local matrix, not the remote commercial proxy, production lifecycle, public NAT64
translation or every protocol. Host BPF access and crafted ICMPv6 Packet Too Big
injection remain documented limits. Disabled macOS DNS registration is an
intentional **completed-experiment** baseline limitation, not a guarantee of
universal system DNS interception. The final templates now register native DNS.

## Rule and Global template campaign

Status: **executed with ten retained functional failures**. This is a separate
campaign, not a reinterpretation of the completed Global-only results above.
All four native-DNS template/mode combinations passed configuration parsing in `mimo-vm`
with the pinned engine; see [preparation evidence](../Tests/MihomoRuntimeTests/Evidence/templates/preparation.json).
Parsing started no TUN or service. The temporary VM directory was removed.

### Files and mode switching

- [IPv4-oriented template](../Profiles/mimo-ipv4-template.yaml)
- [Dual-stack template](../Profiles/mimo-dualstack-template.yaml)

Both default to `mode: rule`. Derive each Global case by changing **only** that
value to `global`. Retain the same proxy, groups, DNS, TUN and complete rule list.
`GLOBAL` selects `Proxy`; `Proxy` selects only `TEST-PROXY`, with no DIRECT member.
Use a documentation-only proxy endpoint in public files. Substitute restricted
Delta fixture addresses and temporary trust/controller details in private lab
copies, never in the published templates or existing working local files.

The IPv4-oriented template has:

```yaml
rules:
  - IP-CIDR6,::/0,REJECT,no-resolve
  - MATCH,Proxy
  - MATCH,REJECT
```

The dual-stack template omits the first rule. Custom rules belong above these
terminal rules. The last REJECT is useful when Rule matching skips a proxy that
declares no UDP support; otherwise the engine can reach its default DIRECT
selection. It does not retry a failed proxy connection against later rules.
Global does not evaluate this list, so test its UDP failure behavior separately.

### IPv6 expectations and no-bypass qualification

The IPv4 filename identifies **IPv4 DNS defaults with IPv6 capture retained**.
The frozen `mimo-global-ipv6-test.local.yaml` is the reference for that behavior.
It uses actual Global mode with zero rules and already passed captured IPv6/NAT64
proxy transport and silent-ping tests. Keep top-level IPv6/TUN capture enabled in both files.
The IPv4-oriented version disables client AAAA and uses node `ip-version: ipv4`;
the dual-stack version enables AAAA, adds the IPv6 fake pool and uses `dual`.

- In IPv4-oriented Rule mode, a known IPv6 destination should hit REJECT before
  MATCH. `no-resolve` does not turn a hostname into an IPv6 address for matching.
  Fake-IP restoration or remote SOCKS name resolution can therefore still lead
  to an IPv6 upstream. Record the metadata/selected rule and actual upstream.
- In IPv4-oriented Global mode, the IPv6 rule is ignored. Captured IPv6 can be
  carried by the proxy, as already observed in the P00 baseline. A correct
  service response through the selected proxy with no native test-flow egress
  is a valid success. If the proxy cannot carry it, require failure without
  native fallback. No additional IPv6-rejection engine mechanism is required.
- Distinguish client address family, SOCKS destination form, actual upstream
  family, client AAAA suppression, expected denial and direct/native leakage.
  IPv6 access through a proxy must never be misreported as native bypass.
- Compare the two modes explicitly. Known IPv4-template differences must remain
  visible in the report: Rule may reject an IPv6 literal that Global proxies.
  Identical behavior is required for capture, absence of native fallback and
  silent echo dropping, while policy-driven rejection may differ. The managed
  app proposal in [the IPv6 analysis](MIMO_IPV6_PROFILE_ANALYSIS.md#managed-rejection-and-final-fallback)
  keeps engine Rule mode in both GUI modes; that is a separate policy from the
  actual engine Rule/Global switch tested here.

### Exact case budget

The native-DNS proposal adds 12 lifecycle/search-domain cases per configuration
to the previously scheduled 3,572: **3,620 total**. Existing system-DNS/browser
cases now use the templates' actual `native` default, not a separate DNS overlay.

Four configurations: two templates × Rule/Global. For each, use the same six
proxy capability modes S00–S05 and the ten target classes in the original matrix.

| Core cases | Calculation | Count |
| --- | --- | ---: |
| HTTP, verified HTTPS and UDP, cold/warm | 4 configurations × 6 proxy modes × 10 targets × 3 protocols × 2 cache states | 1,440 |
| DNS delivery/interception | 4 × 6 × 5 name classes × A/AAAA × UDP/TCP × 3 delivery paths | 1,440 |
| Real resolver API | 4 × 6 × 5 name classes × A/AAAA | 240 |
| **Core matrix** | **24 cells × 130 cases** | **3,120** |

Apply the following focused groups to **each** of the four configurations.
The counts are planned assertions, not promises that all will succeed. Adapt
expected responses and target-address selection to the template's DNS/routing
policy; never enable AAAA silently to make an IPv4-template case pass.

| Focused group per configuration | Count | Coverage |
| --- | ---: | --- |
| Main focused suite | 83 | Six service baselines; F01 DNS transport (4), F02 DNS/TLS errors/recovery (10), F03–F05 SOCKS/UDP/auth faults and controls (15), F05 password/proxy-off (6), F06 warm capability changes (3), F07 automatic/explicit IPv4 retry (4), F09 payload sizes (8), F10 captured ping targets (7), F11 native ping/MagicDNS (6), F12 NAT64 (8), F14 reload/parser/admission (6). |
| Additional focused suite | 13 | Two service baselines, eight mixed-listener IPv4/IPv6 literal/hostname TLS/UDP cases, two expired-DNS/recovery cases, one UDP association-revocation case. |
| Isolated startup/ownership faults | 3 | Wrong binary hash, independently occupied port, parent-loss watchdog recovery. |
| System DNS/browser/crash | 10 | Resolver registration; three system lookups and three HTTPS requests; Safari fetch; DNS and TUN cleanup after forced exit. Use the exact templates' `dns-mode: native` default. |
| Native DNS lifecycle/search domains | 12 | D01–D12 below, including native Tailscale DNS, short-name expansion, reconnect, reload and restoration. |
| Declared UDP-disabled proxy | 4 | Two destination families × TUN/mixed SOCKS paths, with `udp: false`, plus a working IPv4 TCP control in each case. Rule must reject via the IPv6 rule or terminal fallback. The pinned SOCKS5 adapter in Global can still attempt UDP despite that declaration: a real proxied response or a proxy failure is acceptable, but native fallback is always a failure. Record the selected path and actual payload/egress evidence. |
| **Focused subtotal per configuration** | **125** | **4 × 125 = 500** |
| **Complete campaign** | **3,620** | **3,120 core + 500 focused** |

Each row below is one compound behavioral case per configuration; its supporting
state/packet assertions are not separate cases. Use controlled names/services,
fresh DNS queries and a known-working native baseline. Unavailable prerequisites
remain NOT RUN, never PASS. Journal VM-only setting changes and restore them.

| ID | Case | Required outcome |
| --- | --- | --- |
| D01 | Register native DNS with an existing search list | Search-domain precedence/expansion stays equivalent to the native baseline; saved service DNS is unchanged. |
| D02 | Resolve a native LAN short name | Correct controlled native answer/service, with the native suffix retained. |
| D03 | Resolve a Tailnet FQDN through the system resolver | Fresh answer agrees with native Quad100; record the resolver path. |
| D04 | Resolve the same peer by short name | Correct expansion and answer; an FQDN-only success cannot pass this case. |
| D05 | Disconnect Tailscale while the engine remains active | Fresh private query cannot appear successful solely from cache or escape to public DNS; ordinary proxied DNS remains functional. |
| D06 | Reconnect Tailscale, then resolve the peer FQDN | Fresh resolution recovers without profile/provider reload or hardcoded interface. |
| D07 | Resolve the peer short name after reconnect | Search-domain expansion recovers with the current native Tailscale configuration. |
| D08 | Resolve a non-`.ts.net` native split-DNS name | Existing scoped resolver still answers on its intended native path; no public fallback. |
| D09 | Reload Rule → Global → Rule (or reverse) | Exactly one engine-owned registration; normal DNS, native short names and search lists remain correct. |
| D10 | Change temporary native default/supplemental DNS and search configuration | New search list and native scope take effect. Executed with session-owned fixtures; a physical primary-network switch remains NOT RUN. |
| D11 | Abort startup immediately after DNS registration begins | No orphaned owned resolver or TUN. Executed via SIGKILL at observed registration; an internal initialization-error injection remains NOT RUN. |
| D12 | Gracefully stop the engine | Owned resolver/TUN removed; native LAN/Tailnet full and short names work; saved DNS unchanged. |

The seven captured-ping targets cover IPv4 literal/fake IP, ordinary IPv6,
the default TUN IPv6 prefix, the IPv6 fake pool and both NAT64 ranges. Send two
echo requests per target. In **both modes and both templates**, require captured
IPv4 `ping` and IPv6 `ping6` requests, zero echo replies, zero synthetic replies
and zero native forwarding. The prior native LAN/Tailnet exceptions remain:
test real IPv4/IPv6 responses separately. Preserve non-echo ICMPv6 control/error
handling; do not equate blocking ping with dropping every ICMPv6 packet.

Syntax checks, fixture health checks, packet-counter assertions, cleanup
readbacks and retries of already counted cases are reported separately from
the 3,620 behavioral-case budget. Smoke runs select cases from that matrix,
rather than being counted as additional distinct cases. Preserve any preliminary
failures. Mark unavailable/not-run cases explicitly; never count them as passes.

### Execution and evidence requirements

1. Validate both public templates in Rule and Global using the pinned patched
   engine. Confirm that deriving a mode variant changes only `mode`; compare
   group membership, terminal rules, native DNS, listener/upstream fields and TUN
   capture invariants. Preserve the prior disabled-DNS parser evidence separately.
2. Use the runner's implemented `--templates` mode to load these exact files and
   parameterize mode/rule expectations. Omitting this flag generates the old
   Global/zero-rule matrix. Preserve the old matrix and evidence. Enforce no more
   than the declared lab overlay changes;
   never disable native registration to make a final-template case pass. Adapt
   Rule rejection expectations without treating proxy-carried IPv6 as a leak.
3. Run a smoke subset for all four configurations, then 24 complete matrix cells,
   then the 500 focused cases. Treat successful resolution, suppression, routing
   rejection, proxy failure and actual service exchanges as different outcomes.
4. Capture TUN and native paths, correlate each request with proxy/service logs,
   and compare Rule/Global behavior. Stop and investigate unexpected native
   egress. IPv6 carried successfully through the selected proxy is not a leak.
   Retain the previously documented host-capture/PMTU qualification limits.
5. Use the same independent watchdogs, private inputs, bounded requests and owned
   cleanup. Verify removal of engines, listeners, routes, resolver entries and
   test browser tabs; restore and check native LAN/Tailnet access.
6. Save a new report and sanitized evidence under a separate `templates/` evidence
   directory. List all 3,620 scheduled cases with outcomes, additional checks and
   any mode differences. Existing working profiles and prior results stay intact.

## V3 adapted execution — 2026-11-25

Canonical inputs: `Profiles/mimo-v3-ipv4-template.yaml` and
`Profiles/mimo-v3-dualstack-template.yaml`; only `mode` differs between Rule/Global.
Use `dualstack_lab.py --v3` and the engine hash in the dependency manifest.
Historical profiles/evidence and the frozen working profile remain unchanged.

The same 3,120 matrix + 500 focused assertions apply, with these material changes:

- IPv4 means strict destination-family enforcement in **both** modes. Warm AAAA-only
  destinations remain denied even when the proxy supports IPv6. Hostname A records
  are pinned before outbound SOCKS/CONNECT; literal IPv6/NAT64 stays denied.
- `udp: false` denies UDP in both modes; no permissive Global exception remains.
- System DNS is installed/removed by the production core owner, not sing-tun.
  The native lifecycle fixture checks exactly one core-owned registration, native
  search/scopes, removal before TUN teardown and cleanup after process loss.
- Safari/HTTPS IPv6-only requests are expected to fail in strict IPv4 and succeed
  in dual stack. A fake A record alone is never treated as successful access.
- First three main-focused runs had no native peer overlay (79 rather than 83
  cases). A separate four-case native ping/MagicDNS run for each fills those
  twelve cases. The fourth configuration includes them in its main run.
- The complete passing count is **3,620**; preliminary expectation failures and
  reruns remain recorded separately. See the new results section and sanitized
  `Evidence/v3` manifest. Installed app qualification remains a separate campaign.

Current installed work must cover fresh IPv4 approval in both traffic settings, private probe ACL in Global,
flat PF state, exact family/profile readback, DNS ownership, cleanup order, stale
revision/close fencing, app/service loss, multi-client control and reinstall after
full release. Source/model tests do not qualify physical login or forced sleep.

### Installed v3 regression campaign

Run the following separately from the 3,620 profile assertions; keep original
private state in the disposable VM and export only sanitized verdicts.

- `v3_probe_acl_test.py`: 36 live-engine loopback cases (2 families × 2 modes ×
  9 allowed/denied request forms), with nonce exchange and upstream admission
  counts. This does not change system PF, TUN or DNS.
- `v3_lifecycle_test.py`: 38 installed lifecycle assertions. The strengthened
  role-only repetition adds nine observations requiring the pinned controller
  version, including baseline and eight presence combinations. Stop/uninstall
  inspect owned filter, NAT, tables, DNS, tunnel, boot stanza and native recovery;
  reinstall must return every intended role.
- `v3_failure_test.py`: 27 executed failed-verification/recovery assertions (all passed):
  16 across family/mode (denied verification, public listeners closed, flat PF,
  restored Direct), a closed baseline, eight closed role combinations, closed
  parent-rule removal/repair, and final Direct. It uses an unavailable/untrusted
  closed lab fixture; it does not prove successful HTTPS approval. Recovery times
  are observations and are not bounds on packet exposure.
- `v3_installed_test.py`: **44 assertions** across four production family/mode
  cells, actual fresh family observations, public access and manual freshness.
  Requires explicit temporary fixture certificate trust; production TLS remains
  unchanged. Mihomo's inline `Compatible` provider is engine internals, not the
  removed external native provider; no File/HTTP/native provider may be present.
- `v3_active_recovery_test.py`: **13 assertions** covering a dual-stack Global
  baseline, all eight daemon-presence combinations with fresh paired approval,
  live family/mode changes and final Direct restoration. These observations do
  not establish a fault-to-packet-denial bound.
- Historical `v3_paired_failure_test.py`: **9 assertions** (paired-approval expectations superseded on 26 November) using the trusted closed fixture:
  paired baseline, IPv6 proxy refusal, IPv6 absent from the allowlist, closed
  public listeners for each failure, recovery after each correction, and Direct
  cleanup. Also assert that Refresh respects provider cooldown; recovery from
  transport refusal selects another eligible fixture provider. IPv4 success alone
  must never release the protected gate.

The [implementation record](MIMO_3_0_IMPLEMENTATION.md) maps T01–T14 to actual
model, profile and installed evidence and names the remaining physical/security
qualification limits. Passing counts from these scopes must not be merged into
an unexplained aggregate or used to erase preliminary failures.

### Remaining qualification campaign

The [closure campaign](MIMO_V3_QUALIFICATION_CLOSURE.md) records 54 planned
scenarios separately from all historical assertion counts: four active traffic
baselines, 24 installed fault/traffic combinations, two PF failure paths, four
IPv6 control cases, eight Release package/coexistence cases, six native UI cases
and six physical-Mac cases. It uses the user-trusted reusable TLS fixture and an
independent, temporary native-egress containment anchor after Mimo. Positive
controls qualify that detector; any matching packet is a Mimo bypass attempt,
even though the lab rule prevents it leaving the VM.

The new engine-kill and route-change findings are **failures of the no-native-
fallback objective**, not successful qualification merely because reapproval
eventually occurs. Core-stall recovery is rerun with complete effective-state
polling after correcting a cached-Active harness assumption. Preserve both runs.
Actual PF kernel-operation failure, physical network/session testing and UI
inspection must remain explicitly unqualified unless executed.


## Active guard revision qualification — 2026-11-25

Approved after the empty-active installed candidate produced five native-bypass
failures. Standalone templates and historical counts above are unchanged. Test
installed production core/engine with the persistent guard in all four
IPv4/Dual × Rule/Global combinations.

- Four baseline traffic cases; require successful permitted TCP, persistent TCP
  and UDP payloads, silent public ping/ping6, zero native fallback.
- Twenty-eight fault cases: engine kill, engine stall, core stall, supervisor
  stall, both owners stalled, more-specific native routes, and both owners
  stalled while killing the engine. Use independent continuation/watchdog.
- Continuously probe both families: service TCP/UDP, persistent streams, raw
  echo, DNS TCP/UDP, and synthetic IPv4/IPv6 destinations. Include Direct positive
  detector control. The lab trap must observe **zero** packets after Mimo's guard;
  successful later recovery never cancels a leak result.
- Rule bypass versus Global selection through actual connection-chain inspection;
  real Tailnet ping, native Quad100 and engine private DNS versus a Direct baseline.
  Preserve private names/addresses in owner-only raw evidence; export booleans.
  Capture actual engine-group counter matches. Public Tailnet/DERP transport must
  not be assumed qualified merely because a nearby peer works.
- Five native wrong-path checks: a Direct positive detector control followed by
  the four protected cells. Bind root/runtime-group TCP and UDP sockets to the
  physical interface for Quad100 and a Tailnet ULA DNS destination. Require
  counters on Mimo's earlier wrong-path deny and zero hits on the lower lab
  containment rule. Protected mode's IPv6 exclusion can reject the socket before
  PF; add one temporary interface-scoped IPv6 host route to the closed fixture
  so every TCP/UDP request must exercise PF. Require per-request deny-counter
  increments. Remove that exact added route with independent recovery; never
  delete/replace a user's native VPN routes. This does not qualify every VPN
  reconnect sequence.
- The signed native socket probe must remain bounded with a large retained
  NetworkExtension socket table. Record live grant counts and update events;
  do not publish relay/peer addresses. Exercise actual native DNS after the
  pinned engine's OS-route correction, in addition to interface-binding denial.
- Repeat the four live IPv6 PMTU/native-control cases, PF contention/parser-error
  checks, and eight package/Stop/reinstall/uninstall/foreign-rule cases. Require
  exact empty Direct/cleanup rules and persistent protected rules, not vice versa.
- Record candidate hashes, test revisions, recovery and final restored VM settings.
  Keep the reusable certificate/key. Physical network/session and actual kernel
  PF syscall-failure scenarios remain separately scoped.

Harness: `v3_active_guard_campaign.py`, updated `v3_fault_traffic_test.py`,
`v3_active_guard_compat_test.py`, `v3_native_wrong_path_test.py`, existing
IPv6-control/firewall/package scripts. This revision has 68 distinct case rows
(32 traffic, 17 compatibility, 5 wrong-path, 4 IPv6 control, 2 PF failure and
8 package/cleanup); repeated compatibility preflight is additional execution,
not additional unique coverage.
Results: [active guard qualification](MIMO_V3_ACTIVE_GUARD_RESULTS.md).

Execution completed: **68/68 rows passed**, plus the repeated 17-row compatibility
preflight and four annotated-template parser checks. All 32 traffic/fault rows
had zero native attempts; every fault recovered. Both managed Direct and Stop
engine/released Direct passed service/network checks, with the app retained in
the latter. GUI monitoring-only refresh/button appearance was not visually tested.
Original VM settings/catalog/selection and managed Direct were restored, all
temporary lab controls and the host fixture were removed, and the reusable
certificate/key were retained. Historical failures and diagnostic retries remain
recorded separately; this does not extend qualification to physical-only or
kernel PF syscall-failure scenarios.

### Live lifecycle continuation

The subsequent human-operated Tailscale reconnect reproduced a startup failure
not covered by the established-peer compatibility rows: `Starting` with verified
pending public transport sockets, but no permissions because no native interface
existed. The corrected candidate removes that circular prerequisite while
retaining private wrong-path denial. Its shared/service tests pass; installed
reconnect and real sleep/wake results must be recorded separately from the
historical 68-row package. See [the live lifecycle record](MIMO_V3_LIVE_LIFECYCLE_RESULTS.md).

That continuation also corrected the failure-traffic harness's IPv4 echo checksum
padding and reply correlation. Historical IPv4 echo subprobe coverage from that
harness is invalid and retained as such. Separate standalone/system-ping tests
are not affected. Both-family native positive controls and a focused protected
echo rerun passed; those alone did not replace fault-time ICMP coverage. The
subsequent corrected 32-row campaign below now provides that separate coverage.

Current manual continuation: the corrected Rule/dual reconnect passed. The VM
did not enter sleep during the operator's attempts; sleep/wake is skipped at the
operator's request and remains unqualified in protected mode and managed Direct.
Screen lock/unlock is recorded separately. Global/dual also passed its connected,
disconnected and reconnected checks. Its finalized corrected capture had zero
native bypass and zero matched public echo replies in either family. The manual
test setup was restored. The separate corrected baseline/fault rerun passed
**32/32**, with zero native bypass and public echo replies, all 28 faults recovered,
and at least 12 actual send attempts per family during every fault. It closes
the earlier ICMP coverage gap for these scenarios; results remain separate from
the historical 68-row campaign. Original VM state and native Tailnet access were
verified after restoration, all test controls and the host fixture were removed,
and certificate/key were retained. See
[the corrected fault results](MIMO_V3_CORRELATED_FAULT_RESULTS.md).
See the live lifecycle record and its separate sanitized evidence for each scope.

### Public build 9 Homebrew and UI continuation

Mimo 3.0 build 9 is published. Real Homebrew install/uninstall/reinstall, bundled
Stop/Activate, deletion of the app after cleanup, old PF cleanup and restoration
passed on mimo-vm. Native button inspection is partial because desktop automation
lost access to all host windows. These lifecycle checks do not replace the traffic
matrix or qualify the remaining buttons. See [the release check inventory and
evidence](MIMO_V3_BUILD9_RELEASE_CHECKS.md).

### Dashboard layout follow-up — 26 November

The unpublished build 11 layout update passed 59 native dashboard/Settings
renders, including five narrow normal/checking/failure states, and a 90-second
installed Direct navigation audit. Dashboard and all six Settings sections
generated no new lookup, gate command, settings change, warning or recovery
event; core health checks continued. The observer now accepts `--verdict direct`
without changing its approved/rejected assertions. The first incomplete run
overlapped a periodic refresh and is retained separately, not counted as a pass.
See [the layout record and evidence](MIMO_3_0_IMPLEMENTATION.md#compact-stable-dashboard--26-november).
This is presentation/navigation coverage, not a new traffic or fault campaign;
the existing running core and the user's Direct/IPv4 settings were preserved.

## Approved observation workflow regression — 27 November 2026

The installed inventory now contains 113 distinct cases (original 109 plus four
initial-verification preemptions). Run these in Rule/Global × IPv4/dual-stack:
enter protected mode from Direct in the opposite initial family, prove ingress
of the held private IP request, restore subsequent fixture replies to healthy/no-delay,
then select the requested final family through the production routing command.
Require higher-generation closure, cancellation of the obsolete verification
without a provider pause or accepted stale close, a distinct fresh approved
receipt for the final family, unchanged engine identity, blocked native escape
probes and 35 settled seconds without extra work. Preserve the unit-only
fail-first stale-token race separately from this installed preemption coverage.

Run the [observation qualification strategy](MIMO_OBSERVATION_TEST_RESULTS.md)
after the new core/supervisor split. This changes the expected active refresh
trace from `prepare → approve` to `observe → completeObservation`; it must show
zero profile reloads, connection cleanup and PF permission writes for successful
unchanged-path observations. Blocked verification keeps the existing transition
trace. Do not reuse the historical five-click audit as qualification of this change.

Provider errors must preserve approved traffic; path/runtime faults must revoke.
Keep incoming SSH/Screen Sharing replies usable, check the displayed rejected IP,
and inspect all logs during at least 35 seconds of settled operation. Exercise
both traffic families in Rule and Global; approval remains IPv4 only. Native UI
clicks and RPC-driven cases must be reported separately, with artifact identity.

Include rapid user operations: twelve overlapping Refresh requests, then twenty
Refresh requests interleaved with mode changes and a final explicit selection.
Run Rule/Global and both families, including denied-IP/proxy-down recovery to
Direct. Audit cancellation, bounded lookup counts, last-intent ordering, service
health and 36 seconds of settled logs. Details and results are maintained in
the observation report; a sequence of RPC calls is not native-click evidence.

Before a mixed Direct/protected sequence, prove that actual core requests reach
both closed fixture routes, with correlated lookup IDs and distinct native/proxy
TLS ingress. Keep exact original hosts bytes throughout the sequence. The native
fixture uses journaled, exact-provider `/etc/resolver` files and a loopback DNS
stub; the engine uses its existing closed DoH route. Verify resolver ownership and
contents before, during and after the burst. Do not clear provider cooldowns or
count a failed fixture preflight as a product failure or a qualifying pass. Archive
raw evidence before removing owned resolvers/listeners and deleting the worker VM.

Audit GUI communication across setup, the operation and the settled interval,
starting from a known connected GUI process and a saved log cursor. Retain raw
GUI/core/supervisor records and process identities. Treat informational
`daemon_client_disconnected` events as failures too; an error-level-only scan
missed real status-probe interruptions during synchronous Direct teardown.
Missing GUI records are an evidence gap, not proof of continuity. Preserve the
original verdict and append an audit correction rather than rewriting raw results.

The initial joined Direct-cleanup follow-up planned 91 existing IDs on candidate
`9940200f08416e0f8ee3aab9c8cccf22bec020186eb14e4d844518e73010c78d`:
74 workflow cases, eight rapid-operation cases, four verification preemptions and
five actual dashboard Refresh clicks. The primary VM owns 37 workflow cases and
the five UI clicks; the temporary worker owns the other 49 cases. Require complete
GUI communication evidence for all 91, including preparation and cleanup where
applicable. Local scheduling/ownership regressions are separate evidence and do
not increase the 113-case installed inventory. Remaining 22 packet/timer results
retain their recorded older artifact scope until explicitly repeated.

**Latest execution restriction:** only new or previously failed cases may run.
The three original failed rapid cases now pass. Four previous-pass rapid cases
ran before the user stopped those reruns: three passed and one failed a settled
health assertion. Investigate/retest only that new failure; preserve the original
boolean-only health result and add component-level diagnostics before attributing
its cause. Do not widen health freshness limits to make it pass. Previously
successful cases, including the remaining primary/worker partitions, require
explicit user approval before rerunning. No automatic broad resume follows a
focused pass. Keep native UI clicks distinct from RPC cases; preserve every
attempt and its artifact identity.

### Focused health and pending-mode follow-up — 27 November 2026

The approved installed scope is **five distinct cases, at most nine VM
attempts**, all on `mimo-observation-worker` (`mimo-vm-worker`). The original
six-attempt limit gained two explicitly approved retries: the first new IPv4
case failed its DNS setup oracle before any queued operation; the next attempt
incorrectly required a `succeeded` manual phase for a completed lookup whose IP
was rejected. The congestion follow-up adds one retry of the subsequently
reproduced stuck manual-feedback failure. All failed attempts remain in the
total with unchanged evidence. Five attempts are consumed; only that failed
case retry and the three unstarted new cases remain. Nothing in this
appendix authorizes rerunning the six retained passing cases, other passing
members of the 113-case inventory, or the paused primary/worker partitions.
The worker waits for a packaged candidate and recorded core/helper hashes.

| Case | Attempts | Trigger and required evidence |
| --- | ---: | --- |
| Existing failed `rapid mixed / dual/global-to-rule/allowed` | Up to 2 | Retain the original failure and both later non-resolving diagnostic passes. Retry at 0–1 seconds, then if useful 5–6 seconds, after a newly completed successful infrastructure scan. Record actual scan/receipt timestamps and the phase reached. Stop once the failure is captured; a later pass alone does not explain the original failure. |
| New `pending mode / ipv4/latest-rule-denied` | 4 | Retain both failed oracle attempts and the stuck-feedback failure, then retry after the congestion fix is packaged. Queue overlapping mode intents and Refresh requests behind an admitted Direct cleanup; an accepted allowlist edit separates two mode groups. The newest pending mode ends in Rule, with the observed IPv4 exit excluded. |
| New `pending mode / dual/latest-rule-denied` | 1 | Same queued-operation proof with dual-stack routing. |
| New `pending mode / ipv4/latest-direct` | 1 | Same edit barrier and coalescing proof; the newest pending mode ends in clean Direct. |
| New `pending mode / dual/latest-direct` | 1 | Same final Direct proof with dual-stack routing. |

The four new cases use real production RPCs, **not native button clicks**. A
separate native inspection may validate the pending-mode buttons and health
labels; it must not be represented by these RPC results. Local harness controls
are also separate: the first 28 controls, expanded with two PF/status-bracket
checks, three current-policy-evidence checks and three delayed-intent checks,
plus seven single-case runner/incoming-coverage controls, do not increase the VM
case or attempt counts. Five additional DNS-precondition controls exposed one
false rejection and two missing native-proof checks; only those three failures
were rerun after correction, and all three passed. The two baseline passes were
not rerun.

On core `d91336cb60f39d6b62e3cc2aed3c998b49a8214f0857a105c7149f8cefec142a`,
both planned health offsets passed, with real deferred scans and bounded retries.
The first new IPv4 attempt failed because its precondition counted intercepted
IPv6-carried DNS A responses as successful IPv6 application egress. Its protected
window contained 12 UDP and 12 TCP DNS replies, zero IPv6 application/echo
successes, and zero native packet attempts. The managed profile intentionally
intercepts both DNS transports. The corrected oracle excludes only the known
`dns-udp` and `dns-tcp` probe kinds from that application-success check; unknown
successful kinds still fail. A separate captured-packet assertion requires zero
native attempts throughout the approved precondition window, including when
setup fails. DNS escape therefore still fails. The original setup failure is
retained and does not qualify the new queued-operation behavior.

The new contention fixture briefly acquires the existing PF mutation lock on
the worker, without writing its contents, replacing its inode, or changing PF
rules. Its independent helper has a hard maximum of eight seconds (the current
case requests four) and releases immediately when queue admission is proved.
Verify its PID, exact lock identity, exit, and unchanged inode. A case does not
qualify unless at least two mode-only requests demonstrably wait behind an
active physical operation, with an exact superseded-request/replacement pair.
Use one authenticated mode-intent stream with increasing issued sequence numbers.
After the newest request is proved pending, deliberately deliver one older
sequence from that stream. Require an ordinary superseded response with no queue
entry, replacement of the newest ticket, or configuration commit.
The allowlist edit must be accepted at its expected revision and retain its
position between the two mode groups; a conflict is not an accepted edit.
Refreshes superseded by later admitted mode changes may be cancelled normally.
After the queue drains, issue one final current Refresh and require its successful
HTTP result; in denied Rule that success still leaves traffic blocked and displays
the rejected address. First wait boundedly for the prior manual operation to reach
a terminal state, then capture the new request's response ID and requested time.
Wait for that exact ID's finished time and correlate its HTTP success and terminal
event. A completed denied lookup intentionally has manual phase `failed` and
event outcome `blocked`; neither that phase alone nor an old ready state qualifies.
Require ready provider, fresh expected rejected IP, closed PF and no provider
pause/failure/cancellation. Direct requires a matching `succeeded` completion.
Archive the complete owner-only final response and state. Ten new completion
controls exposed seven deficiencies in the old phase-only assertion; only those
seven failures were rerun after correction, all passing. Three baseline controls
were not rerun. Three additional fresh-result controls require the snapshot time
to fall within the final HTTP lookup and the rejected-IP timestamp to match that
snapshot; two failed first and then passed, with the baseline pass not rerun.
Swift Date values are converted explicitly by adding 978307200 seconds before
comparison with Unix/log time. No production behavior changed for either oracle correction.

The approved congestion follow-up keeps that bounded wait and requires the new
structured result and owner fields. Every manual ID accepted during the burst
must have exactly one matching-generation terminal event; explicit `superseded`
or `cancelled` may finish an obsolete prior request without HTTP. An arbitrary
`failed` phase does not qualify. The final request requires `checkedBlocked` or
`checkedAllowed` with matching request ID, lifecycle, lookup ID and routing
revision, plus the existing successful HTTP and fresh-IP evidence. Seven new
typed-ownership controls produced six deficiencies; only those six were rerun
after correction, all passing. The initial passing control was not rerun.

**Historical interruption after attempt five:** both health phases passed; the first
two new-case attempts retain their oracle failures. The next IPv4 denied-Rule
attempt proved queue coalescing, the edit barrier, delayed-old-intent rejection,
closed protected traffic, and responsive GUI/management access, but its earlier
burst manual Refresh remained `checking` for the full 35-second terminal wait.
The final settings lookup had succeeded and core was ready/blocked; no matching
manual completion followed. The explicit final Refresh was not issued. This is
a reproduced pending-feedback failure, not the earlier blocked-result assertion
error. The three remaining new cases were held until the congestion fix was
packaged. The exact historical manual lifecycle generation was not public/logged;
the ownership-mismatch hypothesis requires a deterministic local reproduction.
The [sanitized focused evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-d91336cb.json)
binds the artifact, five consumed attempts, private archive hashes, both oracle
corrections, setup support failures and current limitations. Nothing here claims
native button-click coverage or separately measured private PF receipt age.

**Focused execution completed:** all four new cases passed on
`4263cf39e9779b03d00bc73b40fd523e4ba8e42012ec2aa84f824ba5dd48e067`,
version3.0/build11, unpublished. The failed IPv4 denied-Rule case ran first;
the three previously unstarted cases followed. Neither passed health offset nor
any other previously passing case was rerun. Total: **five distinct cases
qualified across nine actual attempts**, with six passing attempts and the three
earlier failures retained. The two health-offset passes remain scoped to
`d91336cb`; this is not a blanket rerun of the 113-case inventory on the newest
binary.

| New RPC case | Final manual result | Settled health | Operation HTTP requests | Protected native attempts |
| --- | --- | ---: | ---: | ---: |
| IPv4 → denied Rule | `checkedBlocked` | 18/18 | 2 | 0 |
| IPv4 → Direct | `checkedAllowed` | 18/18 | 2 | 0 |
| Dual stack → denied Rule | `checkedBlocked` | 18/18 | 2 | 0 |
| Dual stack → Direct | `checkedAllowed` | 18/18 | 2 | 0 |

Each case proved five queued control requests, two exact supersessions, an
accepted allowlist revision barrier and rejection of a delayed older intent.
The earlier manual ticket terminated as `superseded`; the final ticket bound
its typed result to the exact request, lifecycle, lookup and fresh IP timestamps.
All four whole-case event audits found zero runtime errors, provider penalties,
service repairs/recovery loops or unexpected settled checks. Each had five HTTP
requests including setup and two during the operation, never more than one per
lookup. GUI communication and both fresh/persistent incoming SSH controls passed.
The maximum effective PF age was20.521seconds, maximum sampled full-guard PF age
18.773seconds and maximum sampled state RPC1.206seconds; no35-second health bound
was exceeded. These maxima are conservative rounded-up summaries.

The [candidate-scoped summary](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-4263cf39.json)
records installation proof, exact case/archive digests, per-component health,
typed request ownership and independent retained-event verdicts. Direct windows
explicitly authorized native traffic; zero escape applies after confirmed
closure and while protected, not to the whole mixed-mode sequence. Native button
clicks, Screen Sharing and separate private PF-receipt age remain outside this
qualification. Cleanup is a separate support action; it does not rerun cases or
authorize publication.

**Cleanup completed:** the temporary `mimo-observation-worker` was stopped and
deleted after its six journaled resolver files, guest helpers and host fixture
processes were removed. Its settings and hosts file were restored, and healthy
Direct with empty Mimo/LAB policies was confirmed. Exact proxy-selection/routing
restoration remained impossible because the cloned baseline referenced a missing
proxy UUID; that mismatch is preserved in the evidence. Read-only checks confirmed
the primary `mimo-test-macos` still has core `00f51db8`, its original settings,
routing and hosts file, and healthy Direct. The primary VM and stopped
`mimo-pre-v3-20261125` backup remain. The [cleanup summary](../Tests/MihomoRuntimeTests/Evidence/v3/observations/targeted-health-rapid-cleanup-4263cf39.json)
binds archive hashes, owned-resource removal and final VM inventory. No tests were
rerun during cleanup; existing primary certificate trust was preserved.

Capture infrastructure state continuously across setup, transition and settling:
separate PF/launchd observations and ages, heartbeat, inspection ownership and
outcome, producer `checkedAt`, component timestamps, completion time, PF mutation
epoch/state/digest, and scan started/finished/deferred/retry/reconciliation events.
The existing **35-second** health threshold remains unchanged. Preserve real
producer evidence; never advance timestamps to hide an inspection delay. Keep
at least 36 settled seconds and retain each sample, including failures.
A healthy/released PF claim cannot coexist with explicitly non-current policy
evidence. A historical inspection's `isCurrent: false` alone is not a failure:
current PF receipts and independent launchd evidence must be assessed separately.

The packet audit distinguishes an admitted Direct operation from a merely queued
intent. An already admitted Direct cleanup may finish and release native
networking. Record queued, admitted, confirmed-closure and observed native-window
times explicitly. Once protection is confirmed, or while protected operation is
active/blocked, require zero native escape attempts. Do not call the entire
mixed-mode sequence leak-free: its explicitly authorized Direct window has a
different policy. Calibrate the packet detector in Direct within each new case,
prove proxy TCP/UDP traffic for the selected family, and verify public ping and
ping6 remain blocked while protected. The lab contains any detected escape and
must be empty after cleanup. Bracket status samples with actual PF readback so
an active protected display over a stably released policy cannot pass.

Require whole-case GUI communication coverage, bounded read-only state RPCs,
stable service identities, a visible rejected exit IP for the denied Rule cases,
no healthy-provider pause, no stale approval, and no repeated settled work.
Retain fresh incoming SSH observations and the existing persistent incoming
connection across each case; missing coverage or unexplained interruption is a
failure, even if a host event overlaps. Do not change the host to improve the
result. Archive full reports, raw events, packet captures, health samples and
cleanup evidence before advancing. No successful targeted result automatically
restarts the broader regression campaign or authorizes publication.

Harness sources: [`v3_rapid_policy_test.py`](../Tests/MihomoRuntimeTests/v3_rapid_policy_test.py),
[`v3_rapid_policy_oracle.py`](../Tests/MihomoRuntimeTests/v3_rapid_policy_oracle.py),
[`v3_health_trace.py`](../Tests/MihomoRuntimeTests/v3_health_trace.py), and the
optional `--health-phase=early|late` path in
[`v3_observation_burst_test.py`](../Tests/MihomoRuntimeTests/v3_observation_burst_test.py).

### Authorized confirmation on both VMs — 27 November 2026

The user explicitly authorized rerunning the completed focused tests on
`mimo-vm`, adding a few relevant prior successes, and running the same scope on
both VMs. This supersedes the earlier no-rerun restriction **only for this named
scope**. No full 113-case rerun or publication is authorized.

Each VM runs all 11 `ManualDemand` controls from the exact final candidate source,
plus eight distinct installed cases across nine runs. Total: **22 local-control
executions and 18 installed runs**. The prior worker was deleted; its replacement
is a temporary clone, initially booted without network access. After user-assisted
logout, setup may use NAT with the Tailnet VPN and automatic connection disabled;
copied identity removal and a fresh login are required before Tailnet connection
or runtime qualification. Primary baseline settings, routing, hosts, service intent and
certificate trust are captured before mutation. Core identity is
`4263cf39e9779b03d00bc73b40fd523e4ba8e42012ec2aa84f824ba5dd48e067`.

| Installed case, repeated on each VM | Runs per VM | Why included |
| --- | ---: | --- |
| Dual-stack Global → Rule, approved exit | 2 | Repeat both early and late infrastructure-scan timings on the final candidate. |
| Queued IPv4 → rejected-IP Rule | 1 | Recheck the reproduced stuck-Refresh failure. |
| Queued IPv4 → Direct | 1 | Confirm supersession and clean Direct completion. |
| Queued dual-stack → rejected-IP Rule | 1 | Confirm denied result/IP display and healthy provider under dual-stack congestion. |
| Queued dual-stack → Direct | 1 | Confirm dual-stack cleanup and final native observation. |
| Rapid IPv4 Rule → Direct, rejected exit | 1 | Previously passing failure-to-Direct recovery with overlapping Refresh/mode requests. |
| Rapid IPv4 Global → Direct, proxy down | 1 | Previously passing physical cancellation and recovery from a real provider-path failure. |
| Rapid dual-stack Rule → Direct, approved exit | 1 | Previously passing normal rapid transition, without denied-IP recovery obscuring the result. |

Compile controls inside each VM in isolated test directories. Do not run timed
installed cases during compilation on that VM. Runtime fixtures have separate
roots, client addresses and bound ports. Keep the established whole-case event,
GUI communication, health, ticket ownership, packet and incoming SSH assertions;
retain the 35-second health expiry and at least 36-second settled observation.
These remain production RPC simulations, not native clicks. Preserve every
failed attempt before diagnosing or making any change. Record per-VM results
separately from all historical evidence and restore owned test resources afterward.
The recreated worker is deleted only after evidence is archived; primary remains.

The primary's nine first attempts are recorded in the
[current report](MIMO_OBSERVATION_TEST_RESULTS.md). A single extra attempt is
performed only for its unqualified dual-stack/rejected-Rule log-observation case.
The harness now preserves first/final queue inputs and waits at most three
seconds for absent asynchronous disk records. Wrong, duplicate or late owned
records fail; existing application timing, queue semantics and health/packet
assertions remain unchanged. Recheck ownership after settling. Record this retry
separately from the 18 original runtime slots and retain the original failure.
That extra attempt passed all queue, final Refresh, settled-health, GUI, incoming
SSH and protected-packet assertions; it does not waive the other failures.
Use the corrected observer for the worker's unstarted cases with exact staged
hashes; keep the installed candidate unchanged on both VMs.

**Final test results:** all 22 local controls passed. All 18 original runtime runs
are terminal: primary 5 PASS / 2 product FAIL / 2 unqualified; worker 7 PASS /
2 product FAIL. The separate primary failed-case retry passed, giving 19 actual
runtime attempts with 13 passes and six preserved nonpasses. The two standalone
incoming diagnostics and ten harness support controls are separate counts.
The [observation report](MIMO_OBSERVATION_TEST_RESULTS.md) retains the per-run
matrix, exact artifacts, event audit and unresolved PF-receipt/incoming-state
findings. No broader successful cases were rerun. Primary is restored with its
candidate and test certificate retained. Worker archival, owned-resource cleanup,
verified Tailscale logout and exact temporary-VM deletion passed; the pre-existing
backup remains. These support actions are recorded separately and do not change
test verdicts.

### New remaining-failure investigation — 28 November 2026

The user authorized new tests and workflow design using both VMs. The exact
[16-case matrix and boundaries](MIMO_REMAINING_FAILURE_INVESTIGATION.md) cover
incoming-state continuity on primary (six real-PF mechanism cases) and native
policy receipt/ownership/actor congestion on the isolated worker (ten actual
extracted-runtime controls). No prior successful suite is rerun. Preserve failed
expectations and evidence before changing production behavior; neither mechanism
tests nor extracted-method tests imply full installed/UI qualification.

Completed 16/16: primary's six mechanism assertions passed (including expected
reproductions of broken continuity); worker controls recorded three passes and
seven failures. Exact evidence, capture limits and proposed fixes are linked in
the investigation. No production fix was deployed. Primary's owned resources
were removed and its Direct policy preserved; the isolated temporary worker was
deleted after archival. The pre-existing backup remains unchanged.


### Literal-destination follow-up and installed lifecycle checks — 28 November

The first corrected candidate `7601ffe3` passed sixteen targeted post-fix checks
and four additional race controls. Its installed L1 supplement then failed
**before the Direct-to-Rule request**: the authenticated Direct-born SSH connection
had no PF state, despite a captured handshake and working echo. The exact dynamic
`(self)` rule recorded no packet matches and `_pf/self` was empty. The six earlier
PF mechanism tests had used a literal destination, so they did not exercise this
expression. Preserve [the installed failure](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-installed-before-20261128.json).

A separately counted paired real-PF regression reproduced no state with `(self)`
and interface-bound state with `(en0)` under the same narrow fixture. Preserve
[its packet/state/table proof](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-dynamic-destination-20261128.json).
This is a passing reproduction of the expression defect, not proof that dynamic
per-interface addressing covers all IPv6 addresses or that installed L1 passed.

The final-source acceptance target is a single captured `getifaddrs` inventory of
validated literal IPv4/IPv6 host addresses, excluding Mimo's TUN. It must retain
SYN-only/interface-bound/non-quick tracking and the loopback no-state override.
Test canonical/sorted/bounded snapshots, exact `guard.expected` ownership and
live equality; malformed or widened prefixes must not qualify. Reconcile Direct
address changes off the actor, without close, exit checking, profile/DNS mutation
or service restart. An unchanged snapshot must not write PF or refresh health age.
Preserve the initial-install/address-refresh loss window: a connection born
before the applicable prefix exists may require reconnect. No UDP continuity or
established-flow adoption is claimed.

| Installed check | Required evidence | Final result on `1942a60a` |
|---|---|---|
| L1 — Direct-born SSH through rejection and recovery | Prove the actual installed literal prefix matches the current local inventory and creates state before switching; retain that session through settled Rule rejection and explicit recovery. Correlate packets, PF state, commands, monitor results and a minimum 35-second settled event audit. | PASS: 109/109 authenticated SSH echoes, 27 samples and a clean 35-second settled Rule-denial/recovery audit. The earlier dynamic-expression failure remains recorded. |
| L2 — full Stop/Activate | Invoke the real dashboard action's RPC/installer backend. Stop removes every Mimo packet rule/reference and owned service; Activate restores the intended Direct tracking and services. Confirm full release is not confused with tracking-only Direct. | PASS: all owned jobs/rules/references/DNS/TUN removed; Activate restored the exact literal Direct policy and healthy services for 35 seconds. Backend lifecycle evidence, not a native button click. |
| L3 — Direct address addition/removal | Add and remove owned IPv4/IPv6 loopback aliases and require the exact committed prefix and current PF health to converge. Keep Direct usable and GUI/control responsive. Require no exit-IP request, profile/DNS reload, gate closure, restart or event loop from tracking reconciliation. Restore the exact address/interface baseline. | PASS: Addition/removal of owned IPv4 and IPv6 loopback aliases with exactly two tracking updates; the watchdog work joined, and the gate, profile, DNS and jobs were unchanged with no exit-IP checks. |

L3 measures local-address inventory reconciliation, not a TCP connection to an
added alias. The loopback no-state override remains intentional. L1 separately
proves non-loopback IPv4 SSH continuity; IPv6 ingress, new-alias connection
boundaries, and interface/route migration remain unqualified by these supplements.
The four settled 35-second windows had healthy current-PF samples, with maximum
observed age 13.19 seconds. Nine GUI daemon-disconnection notices occurred only
during the explicit Stop/Activate service-removal window; reconnect completed,
with no unexpected L1 or settled-window communication losses. These expected
lifecycle notices remain recorded rather than filtered out as nonexistent.

The declared VM inventory is **24/24 passed**: original sixteen, four added race
controls, one paired destination-expression regression and L1/L2/L3. The six PF
mechanisms and fourteen native-policy controls were revalidated against final
source on primary after the temporary worker was deleted. Repeated executions do
not add distinct cases. The original installed L1 failure, other before failures
and excluded harness attempts remain preserved; later passes do not erase them.

Seven local Direct-maintenance controls cover no-op/change, supersession and
congestion separately. Also passed: 27 focused shared checks, 45 guard-parser
controls, the 84-source Swift 6 typecheck and signed-package verification. These
support checks do not enlarge the VM denominator. Candidate `1942a60a` remains
local and unpublished. Actual RPC/installer backends and event evidence do not
stand in for native UI clicks, arbitrary UDP continuity, pretracking-session
adoption or physical sleep qualification. Final artifact identities and cleanup
are recorded in [the installed evidence](../Tests/MihomoRuntimeTests/Evidence/v3/observations/remaining-inbound-installed-after-20261128.json)
and [the investigation](MIMO_REMAINING_FAILURE_INVESTIGATION.md). Owned test roots,
helpers, transfer files and aliases were removed; original settings/routing/hosts
were restored, with primary healthy in Direct on the tested candidate. The
temporary worker is absent, the pre-existing backup is preserved and stopped,
and the approved testing CA remains trusted.
