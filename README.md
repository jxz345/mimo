# Mimo for macOS

**Mimo 3.0 (build 10)** provides strict IPv4 or dual-stack proxy routing and exit-IP
monitoring. The [current implementation record](Design/MIMO_3_0_IMPLEMENTATION.md)
separates code, executed tests and remaining qualification. Each published build
has a distinct build number, including updates with the same marketing version.

Build 10 preserves incoming TCP services while outbound access is blocked and
improves failure messages, recovery actions and the dashboard layout. See the
[fix and qualification record](Design/MIMO_V3_INBOUND_ACCESS_FIX.md).

Requires Apple silicon and macOS 14 or later; Control Center integration requires
macOS 26. V3 bundles the pinned, patched Mihomo engine described in
[the dependency manifest](Configuration/MihomoDependency.plist). It verifies the
binary hash and runtime capabilities; a stock engine is not a compatible substitute.

## Install and activate

For the published release:

```sh
brew install --cask jxz345/tap/mimo
open /Applications/Mimo.app
```

To replace an existing 3.0 installation with the latest build of the same version:

```sh
brew update
brew reinstall --cask jxz345/tap/mimo
```

For a built v3 app, copy the complete bundle to `/Applications/Mimo.app`, then run:

```sh
sudo /bin/bash /Applications/Mimo.app/Contents/Resources/daemon.sh install
```

Install, reinstall, upgrade and Activate enable all owned services, including an
engine previously stopped. Shared proxies, credentials, bypass blocks and allowlist
are retained. A previously deactivated installation resumes in Direct. Core owns
machine state and health; GUI clients in different accounts share the results.

The installer validates the sealed bundle and pinned engine before mutation. A
conflicting Clash/mihomo service requires **Stop and Continue** consent. Approval
stops the listed process and disables its identified startup job before proceeding;
cancellation leaves it running. It never stops Tailscale. Noninteractive installation
refuses conflicts. Installation, consent, replacement, health checks and rollback
appear in Event Log. Other apps and their configuration remain installed.

## First launch

1. Add an HTTP or SOCKS5 proxy in Settings → Proxy and select it. None permits Direct only.
2. Add allowed exit addresses in Settings → Allowlist. Dual stack needs both actual exit families approved.
3. Choose **IPv4** or **Dual stack** on the dashboard, then select Rule or Global.
4. Use **Refresh now** for a fresh observation. Protected modes close, verify the current profile and required exit families, then reopen only on success.

Proxy lists/passwords and the IPinfo token live in root-owned local storage shared
across accounts. New values are not written to Keychain. Credentials are omitted
from public state, logs, source control and release artifacts. IPinfo’s token is
sent only as authentication to its fixed HTTPS API endpoints; redirects cannot
forward it. Legacy Keychain import is read-only.

## Modes, families and protection

| Choice | Behavior |
| --- | --- |
| Direct | Native system networking, no Mimo TUN or packet restrictions; engine stays available. IP monitoring continues without allowlist enforcement. |
| Rule | Apply enabled bypass blocks, then the selected proxy. |
| Global | Actual Mihomo Global mode; GLOBAL selects Proxy only. Rule bypass blocks are saved but inactive. |
| IPv4 | Capture IPv6/NAT64 and reject it; pin hostname outbound connections to A records before SOCKS/CONNECT so a proxy cannot re-resolve them to AAAA. Applies in Rule and Global. |
| Dual stack | Capture and proxy IPv4/IPv6. Require fresh allowlisted exits from both families in the same revision and verification attempt. Unsupported IPv6 fails closed; no native fallback. |

Public captured ping and ping6 requests are silently dropped. There are no
synthetic echo replies. Native LAN/Tailnet exclusions retain real ping and IPv6
link control. The engine uses its default IPv6 TUN address and static Tailnet
route exclusions. There is **no utun provider**, provider file, provider port,
interface-name refresh, or provider socket table.

Core owns one temporary catchall macOS DNS resolver. Native split scopes retain
precedence; their explicit search domains are preserved. The engine does not
register another system resolver. Bare names and known private suffixes are
excluded from fake-IP allocation and public forwarding. Tailnet names use
Quad100; other known private suffixes use validated native resolvers. Missing
private resolvers return a local negative answer. Public DoH goes through Proxy
with no fallback. A hostname proxy needs a narrowly permitted encrypted bootstrap
lookup; a literal proxy does not. See [the canonical profiles](#profile-templates).

PF uses one flat, labeled anchor. Closed permits local control, DHCP, IPv6
link control and tracked incoming TCP replies; Verification additionally permits the dedicated runtime group to
reach exact proxy TCP endpoints (or the fixed bootstrap DoH endpoint). Approved
Rule/Global installs a persistent **active guard**: owned TUN/loopback, engine
TCP/UDP sockets, intentional native LAN ranges, Tailnet destinations on a verified
native tunnel, and essential link traffic
are allowed; remaining native application egress is silently dropped in both
families. The profile still decides proxy versus Rule DIRECT and destination family.
The signed Tailscale system extension has a native transport exception: root UDP
on its held source ports and root HTTPS to its observed control/relay addresses.
Core refreshes those scopes during its existing audit, without a provider or
profile reload. Verified transport sockets are eligible before a Tailnet interface
exists, so starting Tailscale does not depend on already being connected. Private
Tailnet/Quad100 traffic still requires the verified native interface; transport
scopes disappear when their trusted socket observations disappear. The pinned engine uses macOS host routes for native overlay DNS
and peers instead of binding them to the physical default interface. This trusts the native VPN and does not protect against malicious
root processes. No root-wide public access is granted. Quad100/Tailnet destinations on other
interfaces and synthetic addresses outside the owned TUN are blocked, including
engine-originated queries. All passes use `no state`; closure revokes
old states so TUN permissions cannot float onto a physical interface.

Direct has an empty Mimo packet policy. Stop/uninstall uses the same guarded
cleanup, removing current and legacy rules, owned DNS and jobs while preserving
foreign rules. Independent checks require the exact active guard in protected
mode and an empty policy in Direct. Event Log records active guard installation.

The active guard revision passed the scoped VM checks documented below, after
the earlier empty active policy admitted five native attempts during fault
testing. Source implementation alone is not leak qualification. Native VPN public
transport and socket identity have separately recorded compatibility checks. Boot traffic
before PF loads, intentional native exceptions and privileged PF tampering are
outside the fallback-containment claim. See the [v3 plan](Design/MIMO_3_0_PLAN.md),
[current workflows](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) and
[failure scenarios](Design/MIMO_FIREWALL_AND_FAILURE_SCENARIOS.md).

## Dashboard and Settings

The dashboard implements the approved Delta mockup: family control and fixed-width
address rows with country flags on the left; compact equal-height service rows,
Stop/Activate and uninstall command with an animated copy icon on the right.
IPv6 text truncates within its slot instead of moving the layout; the full address
is available for copying. Shared-account scope is beside the routing footer.
Traffic, ping, DNS and login-item controls are in Settings → General. Proxy and
Bypass use distinct icons; there is no duplicate family switch in Proxy.

Healthy service rows show `Healthy(n secs)`. Communication loss is displayed as
unconfirmed communication state, not a claim that the process stopped. Opening,
closing or reconnecting a GUI does not launch an independent protection workflow.

**Stop engine and use Direct** performs full privileged-service cleanup. It drains
Mimo DNS while the TUN exists, removes owned jobs/routes/legacy firewall settings,
restores native networking and verifies cleanup. The app can then be deleted.
Anonymous exit monitoring continues in the GUI; the action becomes **Activate**.
Activate uses the same installation/conflict-consent process and restores all roles.

## What is implemented

| Feature | Behavior |
| --- | --- |
| Native app, menu bar, widgets | Dashboard/Settings aligned with the approved mock: fixed address rows with country flags and family verdict/time, compact equal service rows, Stop/Activate and uninstall controls. Default 1040×660 window; minimum 880×520 keeps routing controls visible. Direct/Allowed/blocked indicators, Event Log, widgets and macOS 26 Control Center entry. |
| Shared state and ownership | Core serializes shared settings, credentials, routing, quotas, service actions and revisions across accounts. GUI clients only request actions and display results. |
| Proxy catalog | Multiple HTTP/SOCKS5 entries; one active or None. Inactive edits save without reload. Active edits reverify protected modes; removal/None restores Direct. |
| Local credentials | Owner-only shared password/token storage; legacy migration/import only uses Keychain. No credentials in public snapshots or artifacts. |
| Modes and family control | Direct, Rule, Global; strict IPv4 and dual stack as described above. Family control appears only on the dashboard. |
| Editable bypass | Add/edit/remove/reorder domain blocks and toggle each block. Apply reloads and verifies Rule; Global/Direct save for future Rule use. |
| Allowlist and verification | Fresh family-specific observations, same-attempt/revision/generation binding, full profile/process/DNS/readiness checks and stale-result rejection. |
| Failure and recovery | Clear exit-rejection/lookup-error messages and provider pause deadlines; relevant settings, retry and explicit Direct actions. Core owns bounded scheduling and cancellation; polling does not retry a failed lookup. Direct does not require an approved exit or working IP provider. |
| Canonical private profiles | Annotated templates and installed profiles from one typed renderer; escaped credentials, stdin syntax checks, private controller reload; credential-free startup profile. |
| Native/private DNS | Core-owned temporary override, search/split-scope preservation, Quad100 policy, private negative answers and no public fallback. Disconnected suffix knowledge is retained without retaining stale resolver addresses. |
| Firewall protection | Flat closed/probe/active guard, exact readback and close epochs; native application fallback denied in protected modes; incoming TCP services use interface-bound states, while outbound grants remain stateless; scoped signed Tailscale transport including pre-interface startup; private Tailnet traffic requires its verified native interface. Direct/cleanup releases filtering. Independent boot/power/session/health handling; no utun provider. |
| Failure recovery | Detected process/profile/DNS/route failures close and reverify. Stopped-service intent and completed release prevent unwanted restart/reblocking. |
| Monitoring | One-hour default, Never disables periodic checks only; manual/startup/event/recovery checks, provider rotation, ten-minute failure cooldown and server Retry-After. |
| Providers and quotas | IPinfo Lite, ipapi.co, IPWho.is, ipapi.is; per-provider daily caps and shared cooldown/budget. Managed IPv4/IPv6 observations each count as actual HTTP requests. |
| Country metadata | Display only; unknown country shows a globe. Country-only changes do not authorize traffic or add a verification cycle. |
| Services and communication | Core-owned bounded health snapshots and uniform ages; cross-account GUI reconnection does not run health repair. |
| Cleanup and coexistence | Full Stop/uninstall removes current and older owned firewall/DNS settings, restores saved IPv6 settings and checks native Tailnet DNS. Unrelated VPNs remain untouched. |
| Installation restoration | Install/reinstall/upgrade/Activate restore all roles, verify health, ask before replacing conflicts, preserve settings and journal rollback. |
| Diagnostics | Shared installation, transition, verification, cleanup and failure events; privacy settings, bounded commands, Copy Diagnostics and persistent machine logs. |
| Maintenance reference | Settings → Maintenance documents active/transition/released firewall rules and offers copyable inspection, release, reinstall and uninstall commands, including when core is disconnected. Commands do not execute from the reference page. |
| Release identity | Distinct monotonically increasing build per publication; matching app, manifest, packages and checksums. Local rebuilds do not advance the published build. |
| Legacy migration | Old names/settings/secrets are migration and cleanup inputs only; old provider runtime code is removed. |

## Profile templates

- [mimo-v3-ipv4-template.yaml](Profiles/mimo-v3-ipv4-template.yaml)
- [mimo-v3-dualstack-template.yaml](Profiles/mimo-v3-dualstack-template.yaml)

These placeholder templates are emitted by the same renderer as the app. Change
only `mode: rule` to `mode: global` to select the other mode. They require the v3
engine and core-owned system DNS. Rules end with `MATCH,Proxy` then `MATCH,REJECT`;
IPv4 also has the explicit IPv6 reject rule plus engine enforcement for Global.
Comments explain capture, family enforcement, private/public DNS, ping handling,
proxy selection and verification listeners. The installed private profile receives
the same annotations; use Settings to change it because core regenerates it.
Comments contain no real credentials, and the installed profile must remain local.
The frozen `mimo-global-ipv6-test.local.yaml` is unchanged historical test input.

Settings → **Maintenance** lists the live firewall policy and copyable CLI commands.
Inspection commands are read-only. Release/uninstall commands affect every account
and remove Mimo's controls; the page describes their effects before copying.
The reference remains available when the GUI cannot reach core.

## Clean uninstall and reinstall

For a Homebrew installation:

```sh
brew uninstall --cask jxz345/tap/mimo
```

On success, this stops all Mimo clients and owned services, unregisters GUI login items, clears their saved login choice, removes Mimo’s PF rules/boot policy and launchd jobs, deletes generated runtime files and the private group/authorization right, removes the Mimo DNS override, and restores saved IPv6 service flags. It removes only Mimo’s protection; unrelated firewall rules and applications are not removed.

The v3 engine is bundled and removed with Mimo’s runtime. Independently installed engines remain. Shared proxy settings, allowlist, service intent, local credentials and logs are deliberately retained for reinstall. Reinstall resets the optional GUI login choice.

**Moving Mimo.app to Trash is not a clean uninstall.** The background services and firewall remain installed. Run the Homebrew command even if the app has already been deleted: the installer retains a sealed, root-owned cleanup copy for this case.

For a copied-app or package installation:

```sh
sudo /Library/PrivilegedHelperTools/mimo-manage uninstall
```

After cleanup succeeds, remove `/Applications/Mimo.app`. The installing account has a narrow grant for this exact removal command. Other accounts or a missing grant may require administrator authentication. The standalone manager leaves Homebrew package ownership alone.

Uninstall verifies cleanup and stops on failures; it does not reset the system-wide login-item database. `brew uninstall --zap` additionally removes the calling account’s presentation preferences, private profile files and logs; it does not erase shared machine settings or local credentials.

Older builds need the current installer to receive the updated cleanup behavior. Existing Homebrew installations should use the reinstall commands above. A direct replacement of an old installation retains a fixed, root-owned old-command bridge only when necessary for its cached uninstall hook; the bridge delegates to `mimo-manage` and is removed during uninstall. Fresh installs have no old-named helper.

### Recover leftover network controls

The updated cleanup enumerates **all descendants of `com.apple/000.mimo`**, including old or unreferenced child anchors. It clears Mimo's filter/NAT rules and tables, verifies the remaining policies are empty, removes the persistent boot entry and resolver, releases only Mimo's recorded PF references, and restores saved IPv6 flags. Final release does not disable PF globally or change another VPN’s rules. Before teardown, the transition guard closes and revokes original outbound PF states so existing outbound connections cannot bypass it. Tracked incoming TCP service connections are retained; cleanup does not globally flush the state table.

After refreshing system DNS caches, cleanup checks the native route to Tailscale's Quad100 resolver and makes a fresh TCP MagicDNS reverse lookup for this Mac's Tailnet address. A connected Tailnet that fails this check prevents a successful completion receipt; logs distinguish that failure from Tailscale being disconnected. This verifies native routing/DNS, not every peer's reachability or access policy.

For a machine already stopped/uninstalled with an older build, [release-network.pl](Sources/MimoDiagnostics/release-network.pl) performs the same final release without building the app. Keep Tailscale connected, stop Mimo first, then run the saved script on the affected Mac:

```sh
sudo /usr/bin/perl ~/Downloads/release-network.pl
```

It refuses to run while any Mimo system job is loaded. If cleanup stops, retain the recovery files and read the failure before retrying. Do not delete the app until full cleanup completes. Recovery for substantially damaged older installations is archived in [legacy recovery](Design/LEGACY_UNINSTALL_RECOVERY.md).

## Current names and storage

| Component | Current name/location |
| --- | --- |
| App / widget identities | `com.mimo`, `com.mimo.widgets` |
| Core / supervisor / engine jobs | `com.mimo.core`, `com.mimo.supervisor`, `com.mimo.mihomo` |
| Independent guard jobs | `com.mimo.pf-boot`, `com.mimo.infrastructure` |
| Executables | `/Library/PrivilegedHelperTools/mimo-core`, `/Library/PrivilegedHelperTools/mimo-manage` |
| Private cleanup copy | `/Library/PrivilegedHelperTools/MimoUninstaller.app` |
| Machine configuration | `/Library/Application Support/Mimo/Service/state.plist` |
| Runtime and service intent | `/Library/Application Support/Mimo/Runtime/` |
| Startup profile / controller | `/Library/Application Support/Mimo/Mihomo/` |
| Saved PF/health material | `/Library/Application Support/Mimo/Guard/` |
| System logs | `/Library/Logs/Mimo/` |
| Personal files / logs | `~/Library/Application Support/Mimo/` |
| Preference domains | `com.mimo`, `group.com.mimo` |
| Private machine settings and credentials | `/Library/Application Support/Mimo/Service/state.plist` (root-owned, mode 0600) |
| DNS ownership key | `State:/Network/Service/com.mimo.dns/DNS` |
| Authorization right / removal grant | `com.mimo.configure`, `/etc/sudoers.d/mimo-service` |

Runtime/profile directories are private, and credentials are stored in the owner-only shared state file. Migration reads the old namespace, verifies new storage, then retires the old machine records. Unexpected user-added files are preserved under `Migrated`; colliding files are retained rather than overwritten. Old strings remain in explicit migration code and historical test evidence. See [naming migration](Design/MIMO_NAMING_MIGRATION.md).

The App Group default remains an unregistered development identifier. Ad-hoc packaging strips App Group entitlements; the widget reads the daemon over XPC. A developer-signed build requires a registered App Group and matching local signing configuration. Mimo does not claim Developer ID signing or notarization.

## Validation and known limits

Current execution is recorded in [the implementation record](Design/MIMO_3_0_IMPLEMENTATION.md)
and [dual-stack results](Design/MIMO_DUALSTACK_TEST_RESULTS.md). Historical template
results do not qualify the installed v3 app. Controlled fixtures test protocol,
family and failure behavior without requiring public IPv6 egress from the user’s
proxy. Physical sleep/login switching, Wi-Fi changes and real remote IPv6 egress
require their own qualification.

The earlier empty-active Release candidate's fault campaign **observed native
fallback attempts after engine termination in all four family/mode combinations**,
and during one injected native-route change. A separate lab containment rule
stopped these test packets; it is not shipped protection. Active Rule/Global's
empty PF policy did not meet a zero-fallback requirement during these
faults. Successful recovery does not erase this finding. See the
[qualification closure record](Design/MIMO_V3_QUALIFICATION_CLOSURE.md) for packet
timing, remaining checks and physical-Mac instructions. That earlier candidate was
not qualified for release. A separate core-stall test remained safely blocked but did
not automatically resume verification after core recovered; that retry path also
required correction. The approved active-guard and recovery revision is tracked
separately in [the new qualification record](Design/MIMO_V3_ACTIVE_GUARD_RESULTS.md):
**68/68 VM checks passed**, including 32 traffic/fault cases with zero native
attempts. Both Direct states were checked at the service/network level: engine
running idle, and full Stop with the app retained. Released GUI IP refresh and
native button appearance have not been visually exercised. Native visual review
and the physical-only scenarios above remain separate from these passing results.

Later live testing found and corrected a VPN startup prerequisite: signed public
transport must be permitted before the native private interface exists. The
corrected candidate passed real Tailscale disconnect/reconnect in dual-stack
Rule and Global, with zero measured native bypass. Sleep/wake was skipped at the
operator's request because the VM did not enter sleep; it remains unqualified.
See [the live lifecycle results](Design/MIMO_V3_LIVE_LIFECYCLE_RESULTS.md).

That testing also found a checksum error in the earlier fault harness's IPv4
echo sender and missing reply correlation. Its historical echo subprobe does not
qualify fault-time ping blocking. A separate
[32-row corrected rerun](Design/MIMO_V3_CORRELATED_FAULT_RESULTS.md) passed all
cases: actual both-family echo attempts during every fault, zero public echo
replies or native bypass, and recovery after all 28 faults. Original VM state and
native Tailnet access were verified after cleanup. These are scoped VM results;
the physical/native-UI and sleep qualifications above remain separate.

The published **3.0 build 9** passed real Homebrew install, uninstall and reinstall,
the bundled Stop/Activate scripts, and app deletion after cleanup. Old Mimo PF
fixtures were removed while an unrelated rule was preserved; the VM was restored
to healthy Direct. Native dashboard and Settings click-through is **partial**:
desktop automation lost access to every host window before the remaining buttons
could be checked. See [the build 9 release checks](Design/MIMO_V3_BUILD9_RELEASE_CHECKS.md)
for exact completed and outstanding controls, evidence and test cleanup.

## Build and test

```sh
xcrun swift test
bash Tests/MimoServiceTests/run.sh
bash Tests/MimoDaemonTests/daemon_test.sh
MIMO_GO=/absolute/path/to/go1.26.11 bash Scripts/build-v3-engine.sh
bash Scripts/generate-xcode-project.sh --force
```

The engine build must match `Configuration/MihomoDependency.plist`. Keep signing
and credentials local. Edit source and generator inputs, not generated XcodeProject
or DerivedData. Full GUI builds need Xcode and the macOS 26 SDK. The default
App Group is a development identifier; developer signing requires a registered
identifier and local signing configuration. No notarization is claimed.

VM tests can use `Scripts/vm-console-admin.py` through Tart's guest agent when a
closed transition intentionally blocks SSH. It uses the same private test-account
configuration as `Scripts/vm-admin.py`; credentials never become command arguments.
For SSH without mDNS, `MIMO_VM_ADDRESS` accepts a literal guest IP address.
Installed recovery distinguishes the guarded engine startup wrapper from a hung
running engine, so Direct restoration does not repeatedly cancel launchd repair.
Family selection is saved by core and shared across accounts. Changing it in
Rule/Global invalidates approval and requires a fresh check; selecting a future
family in Direct preserves native networking and survives supervisor polling.
The isolated private-listener test is `Tests/MihomoRuntimeTests/v3_probe_acl_test.py`;
installed VM recovery/removal and failed-verification tests are
`v3_lifecycle_test.py` and `v3_failure_test.py` in the same directory. These require
the named disposable test VM and are not host cleanup commands.

## Unapproved exit IPs and incoming access

Rule/Global keeps outbound application traffic blocked when the allowlist is empty
or either required exit is unapproved. It never adds the observed address to the
allowlist or silently selects Direct. The dashboard retains separate IPv4/IPv6
observations and offers **Review allowed IPs**, **Change proxy**, **Retry verification**
and **Use Direct**. A successful IP lookup with denied access reports that distinction
in Refresh now and Event Log; it is not a provider failure. The warning does not
activate the app or steal keyboard focus from another app.

Mimo tracks peer-initiated TCP connections on interfaces other than its own TUN or loopback,
so SSH, Screen Sharing and TCP web servers can send replies during a block.
Loopback connections remain stateless so public proxy/DNS sessions cannot bypass closure.
The rule is not `quick`: administrator ingress restrictions still apply. Verified
Tailscale transport is retained in a settled blocked state for incoming Tailnet
connections. This is not a blanket outbound or UDP exemption. Connections already
established before Mimo began tracking them, UDP server protocols and public
asymmetric return routes require separate qualification. See
[the incoming-access regression record](Design/MIMO_V3_INBOUND_ACCESS_FIX.md).

If the proxy or IP provider fails, the dashboard retains the failure reason and
shows the provider pause deadline. Use **Change proxy** or **Check IP provider**
to correct it, then retry when the provider permits. **Use Direct** restores
native networking without an approved exit or a successful lookup, including
when verification is pending. A failed cleanup is shown as an error rather than
claiming Direct is ready. Core owns scheduling and cancellation; opening multiple
dashboards or polling health does not create additional verification loops.

## Runtime diagnostics

Event Log includes `mimo_installation`, `mimo_pf_policy_installed`,
`mimo_gate_closed`, `mimo_exit_ip_rejected`, `mimo_blocked_native_transport_updated`,
`mimo_blocked_native_transport_failed`, `manual_refresh_finished` (including `blocked`), `mimo_private_probe_ready`, `mimo_readiness_passed`,
`mimo_traffic_opened`, `mimo_active_firewall_installed`, `mimo_native_egress_updated` (scope counts only; historically `mimo_transition_firewall_released`),
`mimo_dns_removed_and_drained`, `mimo_direct_network_released`,
`mimo_native_release_checked`, `mimo_native_release_check_failed`,
`mimo_cleanup_step` and deactivation outcomes. `lookup_http_request` records quota
accounting without tokens; `lookup_succeeded`/`lookup_failed` record outcomes.
Communication events distinguish disconnected GUI clients from service failure.

Manual validation must inspect effective profile, DNS, routes and PF, not only the
selected mode or launchd PID. For owned rules:

```sh
sudo pfctl -a com.apple/000.mimo -sr
sudo pfctl -a 'com.apple/000.mimo/*' -sr
scutil --dns
```

All newly generated packet rules have a `mimo:` context label. Active Rule/Global
and Direct should have no owned packet rules. Stop/uninstall must also remove
historical unreferenced child anchors. Do not flush global PF or stop Tailscale to
repair Mimo; use the cleanup procedure above.
