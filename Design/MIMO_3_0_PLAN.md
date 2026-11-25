# Mimo 3.0 implementation and qualification plan

Status: approved for implementation and VM qualification on 2026-11-25.

The user approved the Delta design preview and authorized implementation, local
installation in mimo-vm and the relevant test campaigns. GitHub publication is
outside this instruction. Preview interactions remain design evidence only.

This file is the complete v3 design contract. Sections 6 and 7 define the firewall
and event workflows for implementation; earlier-version workflows are not
incorporated by reference. Historical documents and source files provide evidence
and refactoring context only. A material behavior change must be specified here.

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
legacy controls. Include copy-only CLI commands to inspect PF/DNS and supervisor
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
| Dual-stack | Capture public IPv4 and IPv6; proxy both. Require fresh, explicitly allowlisted exits for both families before opening protected access. If either family cannot be verified, remain blocked; do not silently downgrade. |
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

Represent observed exit state per family: address, check time, provider, result
and approval status. A verification receipt binds both observations to the same
attempt, settings revision, selected proxy, profile hash and network generation.
IPv4 opens only with an approved IPv4 observation. Dual-stack opens only after
both fresh observations are approved. Country metadata never grants approval.
Do not reuse an IPv4 observation from a prior generation with a new IPv6 result.

Request a real family-specific HTTPS connection through the restricted proxy
probe. Do not infer the exit family from the DNS record or the proxy's outer IPv4
address. Keep the provider pool and quotas, count actual requests, and skip a
provider that cannot serve the requested family. IPinfo provides explicit
`v4.api.ipinfo.io/lite/me` and `v6.api.ipinfo.io/lite/me` endpoints; extend the
exact-host credential allowlist if used. Token transmission remains limited to
the selected provider's authenticated request, never URLs, diagnostics or the site.

Reference: https://ipinfo.io/developers/lite-api

Protected activation and changes always require the complete applicable receipt.
Disable optimistic opening for the initial v3 qualification rather than opening
after IPv4 while IPv6 is pending. Retain one serialized cycle with coalesced
external events; discard stale results. A proxy without IPv6 produces an explicit
IPv6 verification failure in Dual-stack and remains blocked. IPv4 still works
when deliberately selected and approved.

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
- Keep connection, address and proxy information in the left column with clear
spacing between sections. Distribute the connection, monitoring and routing
groups through the card; Proxy configuration and Bypass sit near the bottom
with a normal bottom inset, rather than leaving unused space below them. Align
both columns to common 16 px horizontal insets. Place Stop/Activate beneath the services in the right
column, above uninstall instructions. Keep “Show menu-bar app at login” in
Settings → General only.
Use one compact row height for both infrastructure and service rows (48 px in
the desktop preview; the narrow layout reserves equal extra space for controls).
Fit service names/buttons and endpoint text into separate 22 px and 16 px tracks,
with consistent 4 px vertical row padding. Right-column sections use 12 px
vertical and 16 px horizontal insets; supporting text must not exceed its track.
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
- Accept IPv6 allowlist entries with canonical equality; adding one is explicit,
never an automatic outcome of selecting Dual-stack.
- Remove Tailscale-specific service/status controls. Keep equal service rows and
`Healthy(n secs)` timestamps; communication loss means unconfirmed status, not
a fabricated stopped daemon or healthy firewall.
- Show transition guard blocking, active fallback guard and released
network controls separately. Stop retains monitoring visibility; Activate restores
services in Direct and prompts only for a concrete identified takeover conflict.

## 6. Simplified firewall and cleanup ordering

### 6.1 One live anchor, four policies

Use one flat live ruleset at `com.apple/000.mimo`. Replace the permission,
open-policy, probe-policy, native-transport and power-guard child hierarchy;
recognize those names only during migration/cleanup. The independent emergency
writer loads the same closed ruleset into the root, so an empty emergency child
is unnecessary. Keep one canonical renderer and validated root-owned artifacts
for Swift, boot and independent repair consumers; do not maintain several copies
of the packet policy.

| Policy | Ordered contents | When used |
| --- | --- | --- |
| Closed | Reject access to Mimo's ordinary loopback proxy/DNS listeners; allow remaining loopback control, DHCPv4 and required IPv6 neighbor/router control; finally drop all remaining outbound IPv4/IPv6. No TUN, LAN or Tailnet pass. | Managed startup, transition, sleep, maintenance or detected fault. |
| Verification | Closed policy plus TCP to the validated literal proxy endpoint/port for the installed runtime group, before the final deny. Proxy-hostname bootstrap temporarily substitutes the fixed HTTPS DNS endpoint; revoke bootstrap before granting proxy transport. | Authenticated exit checks while ordinary listeners and TUN traffic remain closed. |
| Active | Allow the owned TUN/loopback, engine-owned TCP/UDP, intentional native destinations and essential link control; silently drop remaining native outbound traffic. All grants use `no state`. | Approved Rule/Global; protection persists through engine loss or route bypass. |
| Released | Empty live ruleset, not `pass all`; no reachable Mimo children. | Restored Direct or completed network release only. |

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
# mimo:v3:closed — control/link establishment only, then deny
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

Existing PF states can bypass new rules. Initially retain the existing IPv4/IPv6
state clear when entering closure from released or permitted verification access;
it is global and can interrupt unrelated connections. Keep transition/probe pass
rules `no state`, and avoid redundant flushes for preparation stages that remain
confirmed closed. Selective revocation is not assumed safe without evidence.
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
5. Confirm resolver/TUN/route and intended job readback, then release the guard. Full Stop/uninstall also removes owned boot configuration and recorded current-boot PF references. Direct retains managed recovery infrastructure.
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
| T01: initial guard absent | Retain independent boot loader and wrapper close. Capture from before loading; traffic before PF becomes effective remains outside the guarantee. Historical 118 packets / 4.892 seconds describe one old capture, not a v3 bound. |
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
| OS-tool boot/infrastructure jobs | Load the saved closed policy and detect/repair infrastructure when core/engine cannot execute. | Use the same durable intent/hold protocol; never approve an exit or reopen from a heartbeat. |
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
| Direct | Owned protected DNS/TUN controls are removed, PF is empty and managed services remain. |
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
| V02 Mode, active proxy or family change | Validate candidate, admit revision, close and run section 7.5. IPv4 requires fresh approved IPv4; Dual-stack requires both fresh approved families from this attempt. | Save proxy/family without activation. Selecting None/removing the active proxy restores Direct. No selected proxy permits Direct only. |
| V03 Bypass Apply | Rule validates and reloads under a fresh cycle; Global saves blocks for later Rule use without reload. Invalid drafts cause no mutation. | Save only while core is active. Full deactivation cannot create a second machine-settings owner. |
| V04 Inactive proxy CRUD, drafts, display/login preferences, refresh interval | Persist or display only; no unrelated profile reload, lookup or close. Editing the active proxy is V02. | Same admission rules; no protection cycle. Released refresh preferences are isolated to that monitor. |
| V05 Allowlist, verification-provider selection or active provider credential | Invalidate the affected receipt and verify with the new revision. Removing an approved address cannot leave the old receipt effective. Country metadata never grants approval. | Observe under updated preferences when relevant, with no native-traffic gate. Machine credentials remain unavailable to released monitoring. |
| V06 Refresh now, provider Test, Retry, periodic/deferred refresh | Shared scheduler applies quotas/cooldowns and joins/coalesces in-flight work. Every admitted protected lookup uses section 7.5 and reports its real result. Never disables only periodic refresh. | Managed core observes native exit; after full deactivation the anonymous GUI monitor does so. Neither closes PF for a Direct check. |
| V07 External IP/DNS/route/interface/VPN/service-order/location change | Relevant/unknown changes invalidate and request early closure; classify and coalesce a fresh cycle. | No protected cycle or event-only lookup in managed Direct. Released monitoring can follow another VPN's exit. |
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

Before opening managed access, the boot loader and engine wrapper consult the
root-owned release/maintenance journal. Confirmed full deactivation means no
Mimo boot barrier or daemon respawn; pending release is resumed by cleanup.
Otherwise establish Closed before protected engine startup or migration. Saved
Direct proceeds to ordered restoration without an allowlist check. A usable
network before the independent loader runs remains the T01 protection gap.

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

After admission, commit the desired revision and operation state, fence the old
receipt and request closure for an affected protected configuration. Only a
confirmed close allows profile/service mutation. Runtime failure after persistence
retains the desired revision but reports its failed application; it must not claim
that the old profile satisfies the new settings or silently roll back credentials.

One core cycle and one supervisor mutation owner serialize effects. Concurrent
read-only rendering/installation checks are allowed, but join before their
outputs are used and discard results from obsolete generations. Manual refreshes
join an already applicable check; unrelated settings cannot be merged into an
already-approved receipt. External changes mark the cycle dirty and schedule a
coalesced follow-up, not simultaneous profile reloads.

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
5. Keep ordinary listeners/TUN traffic closed. Permit authenticated family-specific provider HTTPS through the restricted private listener; its ACL executes before actual Global dispatch. Run IPv4 verification, and IPv6 verification for Dual-stack, with credential-host and quota constraints. Proxy outer address family does not prove exit family.
6. Join full critical readiness and all required fresh allowlist results from this attempt. Recheck revision, proxy/family, process/profile identity, network/session epochs, active holds and unresolved classifications. A missing/mismatched family, failure, timeout or pending event cannot open. No warm optimistic exception exists.
7. Under the shared PF protocol, satisfy only this operation's holds and install the prepared active guard if nothing newer supersedes it. Confirm live readback, then publish the receipt and Active state. No profile reload occurs after approval. Subsequent audits detect drift and can revoke, but never substitute for the pre-open checks.

The family restriction is part of readiness: IPv4 rejects public IPv6/NAT64
literals and pins hostname outbounds to resolved IPv4 addresses; Dual-stack allows
proxied IPv6 only after both exits are approved. Unsupported proxy UDP rejects,
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
check. Released GUI monitoring pauses/resumes with its account and observes native
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

A provider unavailable for a requested family is skipped or paused for ten minutes,
or longer when Retry-After requires it; try another eligible provider within the
operation deadline. Keep per-machine budgets across restarts/accounts. No eligible
provider for a required family leaves protected access closed. Service, profile,
DNS-readiness and PF faults are their own errors, not provider cooldowns. Count
actual requests, and never merge an old IPv4 result with a new IPv6 attempt.

| Timer / bound | Initial v3 contract | Expiry or failure |
| --- | --- | --- |
| Periodic exit refresh | One hour by default; Never is available. | Admitted work follows section 7.5 in protected mode; Direct stays native. |
| Provider local cooldown | Ten minutes, extended by longer Retry-After. | Retry only eligible providers within machine quotas. |
| Managed lookup operation | Bounded overall deadline, initially 60 seconds, including required family observations and provider attempts. | Cancel/fence late work; required-family failure cannot open. |
| Core liveness / supervisor watchdog | Separate authenticated pulse and watchdog at one-second intervals; expire a lease after five seconds without a valid pulse. | Protected close/recovery; liveness is not exit approval. |
| Independent infrastructure inspection | Ten-second cadence; stored health older than 35 seconds is stale. | Read actual policy/jobs; close/repair only as permitted by durable intent. |
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
| Shared admission, settings and family receipt | `DaemonService`, `MimoCoordinator`, `MimoCommandFence`, `MimoLookupSession`, shared routing/storage models | Concurrent edits, expected revisions, paired observations, late-result rejection, quotas and Never/manual results. |
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
release/recovery; add generation-safe paired verification and diagnostics.
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
app. Its paired-approval gate changes outcomes: a dual-stack proxy that cannot
verify IPv6 must remain blocked for both families. Create an explicit installed
case manifest with gate expectations; do not describe a standalone profile test
as installed-app qualification. Use VM-only controlled provider responses and
temporary fixture trust where required, retaining production hostname, TLS and
credential restrictions. Restore all temporary trust and DNS at cleanup.

Add these mandatory regression groups beyond the existing profile cases:

- IPv4 in Rule and Global: literals, hostname remote resolution, A-only/AAAA-only/
mixed records, explicit SOCKS and HTTP CONNECT, NAT64 TCP/UDP, cache/warm reuse,
proxy IPv6 rejection and unsupported UDP; no native fallback in captures.
- Dual-stack: real Delta IPv4/IPv6 HTTP/TCP/UDP exchanges by name and address,
DNS answers and routing provenance, one-family failure, and both-family approval.
- Approval: empty list, one family missing/mismatched, lookup unavailable, timeout,
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
IPv6 allowlist normalization, independent family times, draft/focus preservation,
communication uncertainty and consistent state in two account sessions.
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

The preview's Full plan page and Markdown download mirror this file exactly.
Label v3 behavior as proposed until implemented; do not present preview simulation
as app or physical-Mac validation. Use marketing version 3.0 for the eventual
candidate. Advance `Configuration/BuildNumber.txt` only for a newly published
build, after checking the next unused number; include the matching release
manifest and checksums. This plan makes no app-release claim.
