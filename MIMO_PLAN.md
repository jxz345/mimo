# Mimo / mihomo workflow design

Updated 2026-11-18. **Status: workflow and UI design approved; native implementation in progress.** This is the canonical plan, including the accepted dashboard, Settings, menu-bar scenarios, service controls, and service-port details. The webpage implements the interactive design using sample data. Native foundations and the first dashboard/Settings implementation are in the working tree; installation, networking acceptance, migration, and release qualification are incomplete. See the implementation checkpoint below.

Mimo targets Apple silicon (arm64) Macs only. Intel support and Intel qualification were removed at the user’s request on 2026-11-18.

## 1. Components and access policy

- **mihomo** runs as an independently supervised system service. Every startup loads a blocking profile before the main controller restores access.
- **mimo-core** is the machine-wide daemon. It owns configuration, exit-IP verification, monitoring, and access decisions.
- **mimo-gui** is the menu-bar app and dashboard. Quitting it does not stop monitoring or change routing.
- **Profile hosting** manages private full-profile delivery to mihomo. Its service row does not imply a public HTTP endpoint.
- **Tailnet provider** publishes the local-routing policy through the existing loopback HTTP endpoint. It is distinct from the Tailscale application.
- An independent privileged supervisor owns the firewall guard and authorized service lifecycle operations, including recovery when mimo-core is unavailable.

| Selected mode | Requirement for internet access | Routing |
| --- | --- | --- |
| Direct | No exit-IP verification required | Normal networking without Mimo's proxy interception or blocking |
| Rule | Valid profile and a fresh allowlisted exit IP | The existing 38-rule profile, including its intentional direct exceptions |
| Global | Valid profile and a fresh allowlisted exit IP | Public internet through the proxy; preserve LAN and Tailscale access |

The traffic-release condition is **Direct OR (valid Rule/Global configuration AND fresh allowlisted exit IP)**. An empty allowlist blocks Rule and Global. Direct remains the explicit recovery option, including when the proxy or lookup provider is unavailable.

The selected mode and shared settings persist across GUI quit, logout, and reboot. At every boot mihomo starts blocked. Mimo-core restores saved Direct without an IP check, or validates saved Rule/Global before opening access. The GUI is not involved in that startup sequence.

The boot guarantee begins when macOS launches these services. It does not cover traffic before macOS starts them.

## 2. Profile compatibility

The current generated profile is the baseline, not the older `clash-verge 5.yaml` reference with 17 rules.

The local comparison found that the generated profile and the profile selected in Clash Verge have matching credentials, all 38 routing rules, TUN settings, and DNS policy. They are not byte-identical: the generated profile explicitly enables UDP for the proxy and provider fallback; Clash Verge's runtime also adds `fake-ip-range6: 2001:2::0/64`.

The permanent IPv4-only requirement approved on 2026-11-18 supersedes the original IPv6 behavior. Preserve the baseline's 35 IPv4/domain/process rules, proxy configuration, Tailscale provider, MagicDNS A handling, and explicit UDP settings. Remove the three IPv6 routing exceptions and IPv6 fake-IP range; prepend `IP-CIDR6,::/0,REJECT,no-resolve`, giving Mimo Rule 36 rules. Both mihomo and its DNS resolver use `ipv6: false`. Replace Verge-specific controller paths, CORS settings, and generated instructions with Mimo-owned settings.

Implement Global using local/tailnet and native Tailscale process exceptions followed by `MATCH,Proxy`; ordinary requests to public `tailscale.com` and `tailscale.io` sites also use the proxy. Keep the original public-domain exceptions only in Rule. Raw mihomo Global mode would bypass the requested exceptions. Public DNS in Global must use the proxy, with only narrowly scoped bootstrap resolution for the proxy endpoint. The active profile provides `127.0.0.1:1053`; a temporary supervisor-owned supplemental resolver routes system and native-VPN DNS through that profile. Preserve MagicDNS domain routing, block this ordinary listener while the gate is closed, verify engine ownership of its TCP/UDP bindings, and remove the override in Direct without editing saved network preferences.

Deliver profiles through private files and mihomo's controller API. Never expose a credential-bearing full profile through the existing public provider endpoint. Remove drag-copy generation and manual Clash Verge activation.

### Permanent IPv4-only scope

Mimo supports IPv4 only in Direct, Rule and Global. Installation saves each network service's IPv6 enabled flag in a root-only journal before disabling it through SystemConfiguration. Network changes apply the same policy to newly added services. IPv6 stays disabled across GUI quit, service Stop/Start, repair and reboot. Direct removes proxy interception but retains the IPv6 firewall denial. Uninstall restores the saved flags, preserving existing address/router settings, releases Mimo's firewall reference, and deletes the staged engine and generated credential-bearing runtime profiles. Saved settings and Keychain credentials remain. Homebrew removes mihomo automatically only when it is an unneeded dependency; explicitly installed mihomo remains until separately uninstalled. Failed installation restores the previous IPv6 policy along with the previous services.

The IPv6 firewall denial precedes TUN, native-transport and LAN exceptions. Native Tailscale infrastructure discovery uses A records/IPv4 addresses only, and only IPv4 tailnet packets receive an exception. New IPv6 proxy/allowlist inputs are rejected; retained legacy IPv6 allowlist entries cannot approve traffic. An IPv6 lookup result remains blocked and visible as the triggering address. Settings → Monitoring explicitly displays **IPv4 only**. There is no IPv6 enable switch.

This change applies to machines running Mimo. Delta's host networking is not changed during VM testing. The isolated relay diagnostic `/var/tmp/mimo-relay-test-4mqtavr9` proved that disabling Ethernet IPv6 allows a fresh relay connection behind the closed guard; IPv6 Automatic was restored after that diagnostic. The permanent implementation now passes real Brew install/uninstall, upgrade and reboot acceptance. Active peer consistency is still being verified separately.

## 3. Startup and private verification

1. The privileged supervisor installs the independent firewall guard before starting the supervised mihomo job with a credential-free blocking profile.
2. Mimo-core reads shared settings and the saved mode.
3. For Direct, restore unproxied IPv4 networking without checking the exit IP; IPv6 stays disabled.
4. For Rule/Global, validate a staged candidate with the pinned mihomo binary.
5. Expose only a dedicated, authenticated loopback probe listener. Ordinary proxy listeners remain disabled or rejecting traffic.
6. Probe the configured HTTPS IP-check provider through the candidate proxy, while ordinary application traffic stays blocked.
7. Require a fresh, canonical IP matching the allowlist. Cached snapshots never authorize access.
8. Activate the validated policy behind the still-closed application gate, verify its effective runtime configuration, then open access.

```text
mimo-core -> authenticated local probe -> configured proxy -> IP-check provider
ordinary application traffic -> BLOCKED until approval
direct fallback to the IP-check provider -> BLOCKED
```

The exception must not be a blanket grant of networking to mimo-core or mihomo. During verification, permit mihomo to reach only the configured proxy endpoint plus narrowly scoped DNS required to resolve it. The listener accepts only core-held credentials and configured lookup-provider destinations. The probe transport has no automatic Direct fallback.

Do not activate an unrestricted candidate configuration just to test it. The independent firewall gate covers ordinary TUN traffic, normal proxy listeners, IPv6, DNS bypasses, and existing connections throughout validation and activation. Confirm that the proxy, DNS, and routing policy activated are the validated policy. A configuration/network generation change invalidates earlier results.

| Failure | Required behavior |
| --- | --- |
| Wrong proxy address, port, or credentials | Probe fails; ordinary internet stays blocked |
| Working proxy with an unapproved exit IP | Check fails; ordinary internet stays blocked |
| Probe attempts Direct fallback | Firewall blocks it |
| Another process accesses the probe listener | Authentication rejects it |
| Empty allowlist, missing credentials, invalid profile, unavailable provider, exhausted lookup budget | Remain blocked with an actionable reason |
| Runtime configuration differs from the validated policy | Remain blocked |
| Mihomo exits | Independent firewall remains blocking |

A passing probe verifies that probe's path at that time; it does not prove every IPv6, UDP, DNS, or application connection is safe. Those paths require enforcement and separate acceptance testing.

## 4. Firewall guard and lifecycle

Use macOS PF to enforce blocking independently of the candidate profile and mihomo process. Manage only Mimo's rules and PF enable reference; preserve unrelated firewall configuration.

- Cover IPv4, IPv6, public DNS, ordinary proxy entry points, and existing public connections.
- In approved Rule/Global, allow application internet traffic only through Mimo's verified TUN interface.
- Identify mihomo's outbound TCP/UDP sockets using a dedicated effective group, rather than exempting every root process.
- Keep Global public egress restricted to the proxy endpoint and necessary infrastructure exceptions. Rule permits the validated profile's intentional direct routes.
- Scope LAN and verified native Tailscale transport exceptions explicitly. Do not broadly exempt all VPN/utun interfaces. The current implementation verifies the official native extension and its held root socket ports, scopes HTTPS/STUN to authenticated DERP/control infrastructure, and uses DERP relays for protected peer traffic. Direct peer UDP is not currently exempt. Tailnet-provider Stop removes only the verified inner-tailnet exception; it preserves already verified public access.
- Close existing public sessions when closing the gate; old sessions cannot remain authorized by stale connection state.
- Keep protection effective when mihomo stops. An independent supervisor closes the gate when mimo-core disconnects or misses its five-second heartbeat deadline.
- Direct cancels pending checks and restores unproxied IPv4 without requiring a proxy or an IP lookup. Its only remaining traffic restriction is the permanent IPv6 denial.
- Provide an administrator recovery command to select Direct when the GUI is unavailable.

Reclose the gate before applying profile, mode, or allowlist changes in protected modes, and immediately upon detecting an external network configuration change. Reverify before opening it. Routine monitoring may run while the gate is open, but an unapproved address or failed required check closes it. Preserve existing lookup budgets, provider cooldowns, and bounded retries. Lack of a verification opportunity never grants access.

Every real change to Wi-Fi, DNS, routes, interfaces, proxies, or VPN configuration triggers an immediate exit-IP check, independently of the periodic interval. Wake also triggers a check. Close protected traffic before starting that check; Direct keeps normal access while refreshing its IP. If services, budgets, or providers prevent verification, remain blocked or report unavailable as appropriate. Do not wait for the next periodic check or invent a result.

Use configuration and network generation identifiers to invalidate earlier probes, including when another change occurs during verification. A stale completion must never open the gate. Recognize the controller's own expected network mutations to prevent revalidation loops without suppressing external changes. Country-change confirmation remains separate from traffic authorization.

### Service controls

The dashboard offers Start / Stop / Restart for mimo-core, mihomo, Profile hosting, and Tailnet provider. Native actions require administrator authorization through the privileged supervisor; stopping core must not remove the ability to start it again.

| Action | Required behavior |
| --- | --- |
| Start or restart core, mihomo, or profile hosting | Keep protected traffic closed until delivery, profile validation, and a fresh allowlisted exit succeed. Close the gate before stopping a service for restart. |
| Stop mihomo or profile hosting | Keep Rule/Global blocked and retain the selected mode. Never switch to Direct implicitly. |
| Stop mimo-core | The independent supervisor closes the protected gate. Show unavailable/unknown until the GUI can confirm current state. |
| Stop/restart Tailnet provider | Publish fail-closed REJECT policy for protected tailnet routes; an already verified public connection may remain active. This does not stop Tailscale itself. |
| Stop a service in Direct | Preserve Direct networking. Losing core still prevents confirmed status and mode changes through core. |
| Conflicting or repeated lifecycle action | Disable conflicting actions while pending; expose completion or an actionable failure. |

A stop must suppress immediate automatic respawn until Start or explicit recovery; merely killing a KeepAlive process is insufficient. Do not stop the independent firewall/safety supervisor. Quitting the GUI or disabling its login item never stops machine-wide services.

## 5. Homebrew and service installation

Qualify **mihomo v1.19.34** as the initial dependency candidate. It is not considered tested until the acceptance suite passes. Publish an immutable versioned formula in `jxz345/tap` with pinned arm64 checksums and add it as a dependency of the app cask. Upgrade that dependency only through a newly qualified app release.

If Homebrew is absent, setup runs the official Homebrew installer as the installing user with necessary administrator prompts, then installs the pinned dependency. Package and copied-app installation use the same workflow. Unattended installs without an installing account stay explicitly incomplete. Cancellation/failure leaves a visible and retryable Setup incomplete state.

Verify the installed dependency and stage a root-owned runtime copy before privileged execution. Mimo's launchd jobs own lifecycle; do not use `brew services` for its engine. Detect existing Clash/mihomo conflicts and report them without terminating unrelated services automatically.

Stage and verify dependencies before interrupting a working installation. Keep blocking in place through protected-mode upgrades, repair, and replacement. Explicit uninstall restores normal networking and removes Mimo's services and guard, while retaining saved data and leaving Homebrew available.

## 6. Shared configuration and migration

Use `mimo-core` and `mimo-gui` as executable names. Preserve existing bundle identifiers and storage locations for compatibility. Update packaging, process identity checks, signing verification, and diagnostics for the renamed executables.

Move the active proxy settings to machine-wide storage and credentials to a distinct System Keychain account. Generalize credential handling so the proxy account cannot overwrite the IPinfo account. Offer explicit administrator-authorized import from a user's legacy Keychain entry. Preserve legacy files until successful migration.

Generate the runtime profile from typed validated settings and trusted templates. Never accept arbitrary client-provided root-loaded YAML, executable paths, or unrestricted controller commands. Never return passwords in status responses or include credentials in logs.

Fresh installations default to Direct. Saving changes in Rule/Global automatically validates and reapplies them. Removing the active proxy leaves those modes blocked. Shared mutations use administrator authorization and optimistic revision checks; stale edits show the latest state.

## 7. Interfaces

Extend the typed XPC protocol with:

- `ProxyMode`: Direct, Rule, Global.
- Access status: blocked, validating, checking exit IP, active, unavailable.
- Requested and effective modes, block reason, configuration revision, runtime/version health, and last verification metadata.
- Network generation and verification identity; canonical observed IP, check time, and the IP/reason that triggered a block. Keep observed data distinct from access authorization.
- Per-service installation/running/pending/unknown state and configured/runtime endpoints, with transport, address, port when applicable, and whether a binding is confirmed.
- Commands to set the mode, save/import/remove proxy settings, edit the allowlist/monitoring policy, retry verification, and read runtime state. Authorized lifecycle commands go through the independent privileged manager.

Bump protocol compatibility as necessary and reject mismatched clients/services with a clear repair/update message. Read-only status remains available to local accounts; machine-wide changes require existing administrator authorization.

## 8. Approved native UI design

### Dashboard

Use a compact macOS utility-app window. The complete overview targets a MacBook viewport of at least 1280 × 700 CSS pixels at normal zoom in the prototype, with a maximum mock-window height of 650px. Move long forms and provider budgets into Settings. Narrow windows and enlarged text may scroll so controls remain accessible; do not clip content to meet the desktop target.

- Keep Direct / Rule / Global in one prominent segmented control. Blocked, Validating, Checking exit IP, and Unavailable are statuses, not modes. Show requested versus effective mode during transitions.
- Keep **Refresh now** permanently in the toolbar, with Command-R, and keep Direct available as explicit recovery when core can accept the change. If core is unreachable, report the failed/pending request without claiming connectivity was restored.
- The left column contains the observed IP and check time, network details when available, allowlist count, selected profile, monitoring interval, and **Open Mimo at login**.
- The right column is **Background services**. Its **Internet access** area owns the decision, explanation, and verification/recovery actions; there is no separate duplicate access section.
- Show aligned status and Start / Stop / Restart controls for all four services. A **Ports** shortcut opens Settings → Background services.
- Keep a compact LAN/Tailscale route summary, Event Log, and Quit GUI. Explain that background services and routing continue after GUI closure.

### Observed IP and blocking reason

For an allowlist mismatch, show the exact address prominently as **IP that triggered blocking**, name it in the access explanation and menu, and provide Copy. Retain that recorded address and check time through retries until a fresh successful verification clears the block or Direct is selected. It is evidence of the blocking decision, not a claim that the IP is still current. Do not replace this with a vague “Historical” or “Last verified” label.

A successful isolated probe may show its checked IP even when an empty allowlist prevents access. With neither a current result nor a recorded blocking IP, show **IP unavailable**, omit unavailable network details and Copy, and use **Checking IP…** during a check. If core is unavailable, do not assert a current address or confirmed protection. Keep the explicit Allowed / Blocked / Unavailable decision separate from the address.

### Settings

Provide a full Settings page with five sidebar sections. General is the default.

| Section | Contents |
| --- | --- |
| Proxy | Shared profile name, type, server, port, optional credentials, Save and apply, and Remove; never reveal a stored password. |
| Allowed IPs | IPv4-only add/remove with validation and duplicate detection. Approval is always explicit; retries never add an address. An empty list always denies Rule/Global. |
| Monitoring | Routine interval, Check now, provider health/budgets, and the mandatory **When network settings change → Immediately** policy. |
| Background services | Read-only service ports/transports, with a shortcut to dashboard lifecycle controls. |
| General | **Open Mimo at login**, appearance, and reduced transparency. No duplicated background-service controls. |

The login item is a personal preference synchronized between Dashboard, General, and the menu. It opens the GUI for the current account and does not control boot daemons. Shared configuration changes require administrator authorization. Background status updates must preserve in-progress Settings edits, focus, selection, and scroll position; explicit saves apply the form. Never persist draft secrets in web storage or return saved secrets from the native service.

Service details use these current source references; they are configured values, not a claim that a service is listening:

| Service | Reference port/transport | Native display requirement |
| --- | --- | --- |
| mimo-core | No TCP port; typed XPC / Mach | Report its local transport and service health. |
| mihomo | 7890 HTTP/SOCKS mixed listener in the current generated template; controller uses a Unix socket | Report actual Mimo runtime bindings. Replace the Verge socket path; finalize the private probe/controller bindings during implementation. Do not invent a controller TCP port. |
| Profile hosting | No separate TCP port; private-file/controller delivery | Do not expose a credential-bearing HTTP profile endpoint. |
| Tailnet provider | 127.0.0.1:18766 HTTP | Show its loopback binding, separately from Tailscale itself. |

Keep configured endpoint details visible when stopped, and distinguish configured, confirmed listening, and unknown state. Reference sources are `Sources/ExitIPShared/ClashVergeProfile.swift`, `TailscaleVergeProvider.swift`, `DaemonRPC.swift`, and `Sources/ExitIPService/TailscaleProviderService.swift`.

### Menu bar and appearance

The menu bar, dashboard, and Settings observe the same state. The menu offers modes, Refresh now, Open Dashboard, Settings, and the login-item preference. The preview status item stays available when its app window closes; its status continues updating, and its menu can reopen the window. Provide accessible status text, keyboard navigation, and Escape dismissal with focus restoration.

| Scenario | Menu-bar appearance and meaning |
| --- | --- |
| Verified Rule/Global | Exit-country flag; approved exit. |
| Direct | Direct arrow; no proxy/IP gate. |
| Startup, validation, IP check | Clock; ordinary internet blocked. |
| Unapproved IP, proxy/lookup failure, empty allowlist, missing profile, stopped mihomo/profile hosting | Stop symbol with last known country flag when available; specific blocking reason, including the triggering IP for a mismatch. |
| Core unavailable or setup incomplete | Neutral information symbol; status unavailable, never a claim of confirmed blocking. |
| Tailnet provider stopped while public access remains verified | Country flag plus warning; protected tailnet routes reject. |

Use the approved graphite/neutral-gray palette with macOS blue accents and the graphite-blue frosted “m” icon. Avoid green branding. Follow Apple's macOS HIG, official UI resources, and Activity Monitor's compact aligned rows. Use native title bars, toolbars, segmented pickers, `NavigationSplitView`, forms, and controls. Adopt Liquid Glass sparingly for navigation and controls on macOS 26, including appropriate glass button styles/custom groups; use availability checks and native fallbacks on macOS 14+. Honor dark appearance, reduced transparency, contrast, and keyboard accessibility.

The browser's CSS material is an approximation. SVG/PNG/ICNS and editable icon layers are design assets, not a compiled dynamic Icon Composer document. Existing native country/status Dock behavior remains until integration is implemented and reviewed.

## 9. Dashboard design webpage

The approved interactive review Site has **Dashboard**, **Settings**, **App icon**, and **Full plan** tabs. Use browser-only HTML/CSS/JavaScript, fictional addresses and credentials, and no connection to the real daemon, Keychain, Homebrew, or IP-check providers. Changes are in memory and reset on reload.

Keep prototype controls outside the app window: scenario, light/dark appearance, desktop/narrow size, **Network change**, and Reset. Demonstrate Direct, startup block, verification, approved Rule/Global, unapproved IP, proxy/lookup failure, missing profile, empty allowlist, all four service states, and dependency setup. Support sample mode changes, proxy/allowlist edits, lifecycle commands, retry, event log, GUI-close simulation, and the live menu-bar mapping above. Reset/scenario changes are explicit sample-state resets; ordinary status refreshes must not reset Settings drafts.

Keep the Sites publication owner-private at [Mimo design preview](https://mimo-dashboard-design-jay.nativebadger32.chatgpt.site). Also retain the user-requested static server on Delta's `0.0.0.0:8347`, reachable at `http://delta.local:8347` or `http://100.123.84.71:8347`. Serve only the static prototype directory. This preview server is unrelated to the app's planned private profile delivery.

Generate the Full plan HTML and Markdown download from this canonical file so the hosted and repository versions agree. Keep supplemental UI/design-source documents consistent. The webpage does not implement native network enforcement.

## 10. Validation and release acceptance

### Automated checks

- Sanitized golden profiles compare the unchanged 38-rule legacy source with the 36-rule Mimo profile: all 35 IPv4/domain/process rules remain, the three IPv6 exceptions are removed, and an IPv6 reject rule is added. DNS AAAA and IPv6 fake-IP are disabled.
- Every generated profile passes validation using the pinned mihomo binary.
- Gate tests cover Direct bypass, approved/unapproved IPs, empty allowlists, missing credentials, stale responses, simultaneous edits, and network/configuration changes during verification.
- Cover last-IP removal, retries/restarts with an empty allowlist, immediate repeated network changes, stale completion fencing, and failed or budget-exhausted checks.
- Cover authorized service lifecycle, restart conflicts, stopped-job persistence, independent recovery, private profile delivery failure, and tailnet rejection without disrupting already verified public access.
- Verify budgets, cooldowns, retries, authorization, secret isolation, protocol compatibility, migration, and installer rollback.
- Run shared, service, installer, and app-render tests, then the full app build.

### UI and prototype acceptance

- Verify all dashboard and menu states, exact triggering-IP retention/clearing, unavailable data, permanent refresh, synchronized login preference, all five Settings sections, and configured ports when stopped.
- Verify background checks preserve Settings drafts and keyboard focus, errors remain actionable, and closed-window status tracks the same live state.
- Check the full dashboard without scrolling at 1280 × 700, 1440 × 800, and 1512 × 982 CSS pixels; inspect all failure/recovery actions and the footer. Check narrow layout, 200% zoom, long IP/profile text, dark appearance, reduced transparency, and keyboard use. Long Settings sections may scroll.
- Keep the hosted Markdown byte-identical to this file, check rendered contents/navigation and static assets, and record browser verification limits separately from DOM-simulation checks.

All 73 prototype interaction checks pass, including IPv4-only Monitoring text and rejection of IPv6 proxy/allowlist input. Browser visual/no-scroll verification remains pending because the browser access host is unavailable. Native tests below remain release requirements, not completed evidence.

### Live acceptance on isolated Macs/VMs

- Packet captures show no ordinary public traffic escaping startup or verification, including with deliberately broken proxy configurations.
- Other processes cannot use the private probe; Direct fallback is blocked.
- Exercise IPv4 tunnel/traffic, TCP, UDP, DNS, old connections, Rule exceptions, Global routing, LAN, and Tailscale reconnection. Verify no IPv6 tunnel address, empty AAAA responses, and rejection of IPv6 via TUN and local proxy entry points.
- Test boot without the GUI, delayed/unavailable mimo-core, mihomo/core crashes, invalid reloads, sleep/wake, interface changes, and Direct recovery.
- Test Apple silicon installs, absent Homebrew, cancellation, wrong version/checksum, conflicting services, upgrade/reinstall rollback, and uninstall cleanup.

Do not label the dependency/networking behavior qualified until these checks pass. Retain test results, dashboard screenshots, and packet-level evidence.

## 11. Documentation and delivery

Update README's complete What is implemented table for native feature changes, plus usage, migration, recovery, manual-check rows, and runtime-log events. Clearly distinguish the hosted prototype from shipped application behavior.

The workflow is saved and the UI prototype is approved and published. Keep the prototype and plan synchronized while resolving review issues. Continue acceptance of the implemented dependency/supervision/private-probe/firewall behavior, migration/XPC and native UI; qualify and release only after the remaining checks pass. Updating this plan or approving the mockup does not mark native features implemented or mihomo v1.19.34 qualified.

## 12. Implementation checkpoint — 2026-11-18

**Apple silicon and IPv4 only; implementation and acceptance are still in progress. Mimo 1.0 is published as a preview in its own repository and tap cask; it is not a qualified protected-routing release.** The current source builds and signs successfully for arm64. The signed IPv4-only Release candidate is installed in the VM. Its installation, engine/profile checks and fresh GUI heartbeat pass. Two controlled IPv4-only packet runs pass, while earlier relay timeouts remain recorded as an unresolved acceptance concern. Original uninitialized Direct settings are retained.

### Implemented in source

- Native `mimo-gui` and `mimo-core`, approved icon, compact dashboard, five Settings sections, permanent refresh/login controls, service lifecycle controls, configured ports, exact blocking IP, and shared menu/Dock/widget/Control Center presentation.
- Revision-aware proxy drafts remain in memory across status updates and Settings navigation. Conflicts preserve edits until explicit reload. Shared credentials remain in separate System Keychain accounts; status never returns secrets.
- The IPv4-only profile derived from the 38-rule legacy baseline, Global IPv4 local/tailnet exceptions, credential-free startup, private authenticated verification, exact profile-byte/engine binding, controller inspection, independent PF guard, flow termination, command ordering and persistent Direct recovery.
- Independent network/wake observation in the supervisor. Engine PID and route-address metadata recognize its own tunnel mutations; kernel-generated address/link events also require recorded ownership, an unchanged tunnel signature and a bounded reload window. Unchanged global notifications from configd are distinguished from real network changes.
- Verified native Tailscale socket exceptions scoped to authenticated control/DERP infrastructure. IPv4 infrastructure discovery runs independently of socket monitoring, retries ten seconds after each pass, and retains only observations from the last five minutes. IPv6 sockets receive no exception. Unclassified SYNs are dropped so the observer can inspect pending native sockets before any exception is granted. Failed DNS queries add no addresses and do not discard independently authenticated DERP or other DNS results. Protected peer transport uses DERP; arbitrary native diagnostic destinations and public exit-node traffic receive no exception. Tailnet Stop removes the inner-tailnet allowance without invalidating already verified public access.
- Protected system DNS on loopback port 1053, with a temporary supervisor-owned supplemental resolver. Original saved network preferences remain untouched. Direct removes the override; the closed guard blocks the ordinary DNS listener. DNS binding/ownership checks are part of activation and watchdog inspection.
- Pinned arm64 Homebrew formula/manifest, copied-app setup, transactional installation/upgrade rollback, stopped-service persistence, uninstall restoration, old-helper migration, and renamed-process diagnostics.

### Evidence retained on Delta and in the VM

| Acceptance | Result and evidence |
| --- | --- |
| Shared models/policies | 154 tests pass; `.build/mimo-ipv4-shared-tests.log`. |
| Service/XPC/authorization/revisions | Pass; `.build/mimo-peer-service-tests.log`. Includes non-routing changes preserving approved public access. |
| Native UI/model tests | Pass; `.build/mimo-native-app-tests.log`. Dashboard and populated Settings scenarios render in light/dark, but offscreen native material rendering is not complete live visual acceptance. |
| Full Apple silicon build and ad-hoc signature | Pass; `.build/mimo-ipv4-final-package.log`. App bundle: `XcodeProject/DerivedData-Release/Build/Products/Release/ExitIPMonitor.app`. |
| Latest installation and GUI launch | Mimo **1.0 (build 1)** downloaded from its public release, signature verified and installed in the VM. Core/engine/profile hosting run in Direct with IPv6 off. Fresh main-thread heartbeat: `launch-check-pZkqKub5`. Public archive `ExitIPMonitor-1.0.zip`, SHA-256 `1bc8b1437c4c27b2d035020348a1712f842478a2638b491401ea173001547706`. All 11 published Homebrew lifecycle checks pass; original state is retained. |
| Pinned engine/controller fixture | 17 checks pass; `.build/mihomo-runtime-tests/evidence/run-ac38327c`. |
| Initial closed-gate IPv4 smoke | 4 checks pass; `firewall-z17qjx4j` under the evidence directory. |
| Fresh install and service lifecycle | 10 checks pass; `installation-ebjdruxr`. |
| Upgrade/recovery/rollback | 18 checks pass; `upgrade-ff4jd2fx`. Both injected final-readiness failures restore the previous Direct or blocked protected state. |
| Independent network observation | 9 checks pass with IPv6 off; `/var/tmp/mimo-network-test-gpz4ucn2`. Route/DNS changes request immediate checks, including observation with core stopped. |
| Installer preflight rejection | 2 checks pass on the final UI bundle; `/var/tmp/mimo-preflight-test-kuw21e33`. Wrong checksum and competing engine preserve installed binaries, job PIDs, settings and Direct. |
| Real VM sleep/wake | Incomplete; `sleep-yg3q7o4f`. macOS refuses `pmset sleepnow` with error `0xe00002e2` / exit 71; sleep and wake counts remain zero. The test removes its alarm, restores original settings/services, and confirms Direct. |
| Direct reboot without GUI | Pass; `direct-boot`. |
| Blocked protected boot and recovery | 11 checks pass; `boot-lnigma04`. Temporary boot job removed and original Direct settings restored. |
| Controlled active packet fixture | **21 checks pass on the earlier candidate** in guest `/var/tmp/mimo-packet-test-akzee5xn`, copied to `packet-akzee5xn`. Covers ordinary DNS/HTTPS, local MagicDNS A/AAAA parity, TCP/UDP IPv4/IPv6, existing-flow closure, wrong credentials, private probe/no Direct fallback, native Tailscale reconnect, own TUN/DNS changes, engine crash and Direct restoration. Global public Tailscale websites use the proxy. Raw captures are retained; any native-transport exclusions are exact verified socket tuples, never whole hosts. Both final Global HTTPS captures contain zero direct packets. This is a separate production-profile fixture, not end-to-end installed protected-mode qualification. |
| IPv4-only protected peer fixture | **31 checks pass in each of two runs**, `/var/tmp/mimo-packet-test-5b7tvkop` and `/var/tmp/mimo-packet-test-ety1eihg`, including Rule/Global IPv4 TCP/UDP, peer relay/MagicDNS, provider Stop/Start with public access preserved, IPv6 rejection through TUN and local CONNECT, an IPv4-only tunnel, private probe, gate closure, engine crash and Direct restoration. The first run includes an extra closed-gate peer ping; the second passes without it. Earlier runs showed relay timeouts; consistency remains unqualified. Raw PKTAP captures and actual loaded firewall rules are retained. |
| Real Homebrew lifecycle | The local Release cask installs its missing pinned mihomo dependency, passes the formula test and retains a stopped core across reinstall. Real uninstall exposed a transient firewall-lock collision; a bounded five-second wait and contention/timeout regression now pass, and the removal hooks succeed. All ten lifecycle checks pass in `.build/mihomo-runtime-tests/evidence/brew-7qkxq3rl`, including automatic removal of an app-only dependency, retention/removal of explicitly installed mihomo, and saved IPv6 restoration. The cleanup rerun also passes all ten checks in `brew-d76d456d`, including verified deletion of generated runtime profiles. The tested ZIP SHA-256 is `91e482516eb413d40a9ccfc7db5dcbda1bd1b97cd1545d901a58218053adfbdc`. Test artifacts remain unpublished. |
| IPv4-only implementation checks | 154 shared tests, service regressions (including bounded firewall-lock contention), daemon tests, native UI/model tests and Release packaging pass. Seventeen real mihomo private-runtime checks pass in guest `run-ca9b6cb1`; nine network-event checks and two installer preflight checks also pass with the IPv4-only policy. Nineteen upgrade/recovery checkpoints pass in `/var/tmp/mimo-upgrade-test-8228mom4`, including network-change re-enforcement with core/engine stopped. All eleven reboot checkpoints pass in `/var/tmp/mimo-boot-test-zlgqtcsy`; IPv6 remains disabled through protected startup and Direct recovery. Two 31-check controlled IPv4-only packet fixtures pass both modes, peer traffic and provider lifecycle; repeated-run relay consistency is still under investigation. |

### Remaining acceptance

The VM now sees Delta as its online Tailscale peer; no additional node is currently needed to continue these tests. Direct peer TCP/UDP works over IPv4; IPv6 is now intentionally rejected. Remaining work:

- Resolve the intermittent relay failure across repeated IPv4-only runs. Two full Rule/Global peer/MagicDNS/provider Stop/Start fixtures pass with IPv6 denial and no-leak assertions, but other runs time out; do not treat a single pass as qualification.
- Complete full installed protected-mode packet/lifecycle acceptance after the peer path is qualified. Keep the qualification guard closed; never manufacture `qualification.json` to bypass missing evidence.
- Run real sleep/wake acceptance in a supported test environment. This VM refuses actual sleep.
- Complete live GUI/browser interaction and copied-app Homebrew prompts/cancellation. Screen Sharing and Tart screenshots are available, but coordinate actions fail with `noWindowsAvailable`; the browser access host remains unavailable. Offscreen captures cannot validate native vibrancy compositing.

This tailnet returns IPv4 MagicDNS records and successful empty AAAA answers for the tested names. Tests preserve those actual responses; IPv6 tailnet address assignment does not imply an AAAA record exists.

### Test environment and reusable installation image

- Tart inventory: `mimo-test-macos`; guest Bonjour name: `mimo-vm.local`; macOS 27.2.1 (26B131), 4 CPUs, 8 GB RAM, 100 GB disk, 1440 × 900 display, default NAT. No host directories are shared. Clipboard sharing is enabled. Start with `tart run mimo-test-macos --no-audio --no-usb-accessories`.
- `ssh mimo-vm` connects as `jay` using Bonjour, IPv4 and the existing pinned host-key alias. Tart Guest Agent 0.15.0 provides a verified VM-socket command channel independent of IP connectivity. Clipboard round-trip acceptance is outstanding.
- The user-created `mimotest` administrator and `mimo-vm-admin` SSH alias support authorized unattended tests. `Scripts/vm-admin.py` supplies ordinary sudo authentication through stdin using Delta's owner-only credential file outside the repository. No password is printed or committed; the temporary guest setup input is removed.
- The reusable repaired image is `~/Downloads/UniversalMac_27.2.1_26B131_Restore.complete.ipsw`, SHA-256 `233e85a09887579d47d0b195e7db72be7f204261059c6946f719acf6b300814f`. The missing segment, repair record and checksums are retained; the original image is unchanged.
- Firewall/TUN acceptance runs only inside the isolated VM. Delta's firewall and network configuration are not changed. The controlled SOCKS fixture binds only Delta's existing VM NAT interface and allows only the VM plus fixed test destinations. The peer echo fixture binds only Delta's existing tailnet addresses, requires a private nonce, and accepts only the VM; temporary credentials stay outside the repository. Both fixture servers are now stopped and its temporary credentials removed; the user-requested dashboard server remains available.

## References

- [mihomo v1.19.34 release](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34)
- [mihomo controller API](https://wiki.metacubex.one/en/api/)
- [Listener routing](https://wiki.metacubex.one/en/config/inbound/listeners/)
- [Listener authentication](https://wiki.metacubex.one/en/config/inbound/listeners/mixed/)
- [Homebrew versioned formulae](https://docs.brew.sh/Versions)
- [Apple HIG: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Apple HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Apple Design Resources: macOS](https://developer.apple.com/design/resources/#macos-apps)
- [Activity Monitor for macOS](https://support.apple.com/guide/activity-monitor/welcome/10.14/mac/26)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

### Mimo 1.0 publication

The user requested a new GitHub repository and a fresh version history. Current sources were published as the initial commit of `jxz345/mimo`, version **1.0 (build 1)**, with a preview release and a new `jxz345/tap/mimo` cask. Keep the legacy `exit-ip-monitor` release and cask unchanged. The new cask conflicts with the legacy one, pins `mihomo@1.19.34`, and states that Rule/Global activation is still disabled pending qualification. Public source contains no VM credentials or generated test evidence.

The real lifecycle suite passes all **11 checks** against published tap commit `db2cc4d3c81b5ea764f5a232024ea634f3477df5` and the GitHub release URL, including automatic dependency installation/removal, explicit dependency retention, reinstall with stopped core, runtime-profile cleanup, IPv6 restoration, and saved settings. The VM's manual Direct installation was restored after acceptance. The published ZIP SHA-256 is `1bc8b1437c4c27b2d035020348a1712f842478a2638b491401ea173001547706`; source tag `v1.0` points to initial commit `173c8cc10a7c4e074ee099cd0ac26aa69afb6a87`. Results are saved in `Tests/ReleaseEvidence/mimo-1.0-brew.json`.
