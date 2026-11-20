# Mimo / mihomo workflow design

Updated 2026-11-20. **Status: native implementation working in mimo-vm; release qualification and publication remain in progress.** This is the canonical plan, including the accepted dashboard, Settings, menu-bar scenarios, service controls, and service-port details. The webpage implements the interactive design using sample data. The native dashboard/Settings, machine-wide services, private profiles, three modes, password-free controls and PF/launchd monitoring are implemented. Installed VM tests cover networking, relay recovery, service failures, reboot recovery and Homebrew lifecycle; first-packet boot protection and actual sleep/wake remain unqualified. Later dated evidence supersedes historical pending entries below. See the implementation checkpoint below.

Mimo targets Apple silicon (arm64) Macs only. Intel support and Intel qualification were removed at the user’s request on 2026-11-18.

## 1. Components and access policy

- **mihomo** runs as an independently supervised system service. Every startup loads a blocking profile before the main controller restores access.
- **mimo-core** is the machine-wide daemon. It owns configuration, exit-IP verification, monitoring, and access decisions.
- **mimo-gui** is the menu-bar app and dashboard. Quitting it does not stop monitoring or change routing.
- **Profile hosting** manages private full-profile delivery to mihomo. Its service row does not imply a public HTTP endpoint.
- **Tailnet provider** publishes the local-routing policy through the existing loopback HTTP endpoint. It is distinct from the Tailscale application.
- An independent privileged supervisor owns verified firewall transitions and authorized service lifecycle operations, including recovery when mimo-core is unavailable.
- Separate macOS-tool boot and infrastructure jobs load saved blocking PF without the Mimo helper and actively inspect/repair PF and launchd. The dashboard reports their recent health independently of routing mode.

| Selected mode | Requirement for internet access | Routing |
| --- | --- | --- |
| Direct | No exit-IP verification required | Unproxied IPv4 networking; IPv6 remains disabled |
| Rule | Valid profile and a fresh allowlisted exit IP | The 36-rule IPv4-only adaptation described below, including its intentional direct exceptions |
| Global | Valid profile and a fresh allowlisted exit IP | Public internet through the proxy; preserve LAN and Tailscale access |

The traffic-release condition is **Direct OR (valid Rule/Global configuration AND fresh allowlisted exit IP)**. An empty allowlist blocks Rule and Global. Direct remains the explicit recovery option, including when the proxy or lookup provider is unavailable.

The selected mode and shared settings persist across GUI quit, logout, and reboot. At every boot the independent macOS-tool loader installs saved blocking PF. Supervisor/engine startup synchronizes with that loader before proceeding, then mihomo starts with the credential-free blocking profile. The initial policy grants no runtime-group or native-transport public exception. The supervisor restores saved Direct without an IP check, or keeps Rule/Global closed for fresh validation. If the Mimo helper cannot run, the independent guard continues blocking after it loads. The GUI is not involved.

The implemented guard protects traffic only after its startup firewall is installed. This measured limitation is not an approved narrowing of the boot requirement. Boot acceptance records the startup boundary explicitly. The first active-Global reboot test found traffic during installation validation, so the source now closes a minimal guard before that work and before Keychain access. The historical protected-boot capture has a 4.892-second interval from the first captured ordinary probe to confirmed guarding, with 118 packets before the boundary and zero after it. A first-packet-at-boot guarantee is not established. The full boot boundary remains required; the user explicitly requested fixing it. Release qualification remains closed until a verified implementation enforces it.

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

1. A separate macOS-tool boot job loads a saved blocking PF policy without requiring the Mimo helper. Supervisor/engine entry synchronizes with it; the supervisor then starts the enabled mihomo job with a credential-free blocking profile. Saved service Stop intent is retained.
2. Mimo-core reads shared settings and the saved mode.
3. For Direct, restore unproxied IPv4 networking immediately; IPv6 stays disabled. Start an anonymous IP check even before settings initialization so the dashboard and country indicators show the current connection. IP approval never gates Direct.
4. For Rule/Global, validate the generated candidate through the pinned mihomo binary’s standard input, then send the same bytes as an API payload through its private Unix controller socket. Keep contents and the hash/engine-PID receipt in memory; do not write a credential-bearing candidate YAML or reload JSON.
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

Use macOS PF to enforce blocking independently of the candidate profile and mihomo process. Save the blocking anchor and an owned load block in `/etc/pf.conf`; independent launchd boot/health jobs load and repair them. Preserve unrelated configuration and release only live owned enable references. A ten-second checker and an asynchronous supervisor task inspect PF enable/main-anchor rules and saved/loaded launchd jobs, close before repair, and respect persisted Stop choices. The dashboard shows PF and launchd health with failed/overdue/unknown states.

- Cover IPv4, IPv6, public DNS, ordinary proxy entry points, and existing public connections.
- In approved Rule/Global, allow application internet traffic only through Mimo's verified TUN interface.
- Identify mihomo's outbound TCP/UDP sockets using a dedicated effective group, rather than exempting every root process.
- Keep Global public egress restricted to the proxy endpoint and necessary infrastructure exceptions. Rule permits the validated profile's intentional direct routes.
- Scope LAN and verified native Tailscale transport exceptions explicitly. Do not broadly exempt all VPN/utun interfaces. The current implementation verifies the official native extension and its held root socket ports, scopes HTTPS/STUN to authenticated DERP/control infrastructure, and uses DERP relays for protected peer traffic. Direct peer UDP is not currently exempt. Tailnet-provider Stop removes only the verified inner-tailnet exception; it preserves already verified public access.
- Close existing public sessions when closing the gate; old sessions cannot remain authorized by stale connection state.
- Keep protection effective when mihomo stops. An independent supervisor closes the gate when mimo-core disconnects or misses its five-second heartbeat deadline. Send independent one-second liveness pulses and record their actual XPC receipt time so synchronous profile work or a stalled status request cannot hide them; only the already authenticated core PID/controller and current command sequence may renew that lease. Stopping core revokes it.
- Direct cancels pending checks and restores unproxied IPv4 without requiring a proxy or an IP lookup. Its only remaining traffic restriction is the permanent IPv6 denial.
- Provide an administrator recovery command to select Direct when the GUI is unavailable.

Reclose the gate before applying profile, mode, or allowlist changes in protected modes, and immediately upon detecting an external network configuration change. Reverify before opening it. Routine monitoring may run while the gate is open, but an unapproved address or failed required check closes it. Preserve existing lookup budgets, provider cooldowns, and bounded retries. Lack of a verification opportunity never grants access.

Every real change to Wi-Fi, DNS, routes, interfaces, proxies, or VPN configuration triggers an immediate exit-IP check, independently of the periodic interval. Wake also triggers a check. Close protected traffic before starting that check; Direct keeps normal access while refreshing its IP. If services, budgets, or providers prevent verification, remain blocked or report unavailable as appropriate. Do not wait for the next periodic check or invent a result.

Use configuration and network generation identifiers to invalidate earlier probes, including when another change occurs during verification. A stale completion must never open the gate. Recognize the controller's own expected network mutations to prevent revalidation loops without suppressing external changes. Country-change confirmation remains separate from traffic authorization.

The managed check has a bounded 60-second overall allowance for preparation, the HTTP lookup, and activation. HTTP still has its own 15-second resource deadline. Check cancellation after preparation and after the IP response before submitting approval. Core sends a separate lightweight liveness pulse while status/profile work is pending; a stopped or unauthenticated core cannot renew it. Own DNS/tunnel notifications are compared with the recorded values, and the bounded kernel-route window uses receipt time rather than delayed actor processing time.

### Service controls

The dashboard offers Start / Stop / Restart for mimo-core, mihomo and Tailnet provider. Replace Profile hosting’s lifecycle buttons in the same row with **Open profile** and **Reload**. Open displays the exact delivered profile in a read-only sheet reached through the installer-pinned app connection; Reload regenerates from saved settings and requests fresh verification. The only on-disk profile is the credential-free startup file. Native actions use the signature-checked privileged supervisor without another password; stopping core must not remove the ability to start it again.

| Action | Required behavior |
| --- | --- |
| Start or restart core/mihomo, or Reload profile | Keep protected traffic closed until delivery, profile validation, and a fresh allowlisted exit succeed. Close the gate before stopping a service for restart. |
| Stop mihomo, or profile delivery unavailable | Keep Rule/Global blocked and retain the selected mode. Never switch to Direct implicitly. |
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

Name the product **Mimo.app** and use Mimo in Finder, menus, About, login items and alerts. Use `mimo-core` and `mimo-gui` as executable names. Preserve existing bundle identifiers and storage locations for compatibility. Update packaging, process identity checks, signing verification, and diagnostics for the renamed executables.

Move the active proxy settings to machine-wide storage and credentials to a distinct System Keychain account. Generalize credential handling so the proxy account cannot overwrite the IPinfo account. Offer explicit import through the installed app from a user's legacy Keychain entry. Preserve legacy files until successful migration.

Generate the runtime profile from typed validated settings and trusted templates. Never accept arbitrary client-provided root-loaded YAML, executable paths, or unrestricted controller commands. Never return passwords in status responses or include credentials in logs.

Fresh installations default to Direct. Saving changes in Rule/Global automatically validates and reapplies them. Removing the active proxy leaves those modes blocked. Shared mutations use the installer-pinned app identity and optimistic revision checks; stale edits show the latest state.

## 7. Interfaces

Extend the typed XPC protocol with:

- `ProxyMode`: Direct, Rule, Global.
- Access status: blocked, validating, checking exit IP, active, unavailable.
- Requested and effective modes, block reason, configuration revision, runtime/version health, and last verification metadata.
- Network generation and verification identity; canonical observed IP, check time, and the IP/reason that triggered a block. Keep observed data distinct from access authorization.
- Per-service installation/running/pending/unknown state and configured/runtime endpoints, with transport, address, port when applicable, and whether a binding is confirmed.
- Commands to set the mode, save/import/remove proxy settings, edit the allowlist/monitoring policy, retry verification, and read runtime state. Authorized lifecycle commands go through the independent privileged manager.

Bump protocol compatibility as necessary and reject mismatched clients/services with a clear repair/update message. Read-only status remains available to local accounts; machine-wide changes require the installed app’s signature or the explicit legacy administrator recovery interface.

## 8. Approved native UI design

### Dashboard

Use a compact macOS utility-app window. The complete overview targets a MacBook viewport of at least 1280 × 700 CSS pixels at normal zoom in the prototype, with a maximum mock-window height of 650px. Move long forms and provider budgets into Settings. Narrow windows and enlarged text may scroll so controls remain accessible; do not clip content to meet the desktop target.

- Keep Direct / Rule / Global in one prominent segmented control. Blocked, Validating, Checking exit IP, and Unavailable are statuses, not modes. Show requested versus effective mode during transitions.
- Keep **Refresh now** permanently in the toolbar, with Command-R, and keep Direct available as explicit recovery when core can accept the change. If core is unreachable, report the failed/pending request without claiming connectivity was restored.
- Reserve fixed space for the IP, lookup message, location, profile title, access explanation, recovery/setup action and service rows. Dynamic text cannot move unrelated controls. Truncate long text with full tooltips; narrow windows may scroll.
- The left column contains the observed IP and check time, network details when available, allowlist count, proxy configuration, monitoring interval, and **Open Mimo at login**.
- The right column is **Background services**. Its **Internet access** area owns the decision, explanation, and verification/recovery actions; there is no separate duplicate access section.
- Show aligned status and Start / Stop / Restart controls for all four services. Configured endpoints appear directly below each service, including proxy 7890, DNS 1053 and tailnet 18766; no Ports shortcut or separate service Settings page.
- Keep a compact LAN/Tailscale route summary, Event Log, and Quit GUI. Explain that background services and routing continue after GUI closure.

### Observed IP and blocking reason

For an allowlist mismatch, show the exact address prominently as **IP that triggered blocking**, name it in the access explanation and menu, and provide Copy. Retain that recorded address and check time through retries until a fresh successful verification clears the block or Direct is selected. It is evidence of the blocking decision, not a claim that the IP is still current. Do not replace this with a vague “Historical” or “Last verified” label.

A successful isolated probe may show its checked IP even when an empty allowlist prevents access. With neither a current result nor a recorded blocking IP, show **IP unavailable**, omit unavailable network details and Copy, and use **Checking IP…** during a check. If core is unavailable, do not assert a current address or confirmed protection. Keep the explicit Allowed / Blocked / Unavailable decision separate from the address.

### Settings

Provide a full Settings page with four sidebar sections. General is the default.

| Section | Contents |
| --- | --- |
| Proxy | Shared profile name, type, server, port, optional credentials, Save and apply, and Remove; never reveal a stored password. |
| Allowed IPs | IPv4-only add/remove with validation and duplicate detection. Approval is always explicit; retries never add an address. An empty list always denies Rule/Global. |
| Monitoring | Routine interval, Check now, provider health/budgets, and the mandatory **When network settings change → Immediately** policy. |
| General | **Open Mimo at login**, appearance, and reduced transparency. No duplicated background-service controls. |

The login item is a personal preference synchronized between Dashboard, General, and the menu. It opens the GUI for the current account and does not control boot daemons. Shared configuration changes through the installed app require no administrator password after installation. Background status updates must preserve in-progress Settings edits, focus, selection, and scroll position; explicit saves apply the form. Never persist draft secrets in web storage or return saved secrets from the native service.

Service details use these current source references; they are configured values, not a claim that a service is listening:

| Service | Reference port/transport | Native display requirement |
| --- | --- | --- |
| mimo-core | No TCP port; typed XPC / Mach | Report its local transport and service health. |
| mihomo | 7890 HTTP/SOCKS mixed listener in the current generated template; controller uses a Unix socket | Report actual Mimo runtime bindings. Replace the Verge socket path; finalize the private probe/controller bindings during implementation. Do not invent a controller TCP port. |
| Profile hosting | No TCP port; in-memory payload over a private Unix socket | Open profile / Reload; never expose a credential-bearing HTTP endpoint. |
| Tailnet provider | 127.0.0.1:18766 HTTP | Show its loopback binding, separately from Tailscale itself. |

Show **In memory · Unix socket · No TCP port**, plus the credential-free startup path `/Library/Application Support/Mimo/Mihomo/blocking.yaml` and Copy path in the service row. The socket is `/Library/Application Support/Mimo/Mihomo/controller.sock`. Its enclosing directories are root-only (0700); the supervisor narrows the root-owned socket to 0600 before use because mihomo explicitly creates it as 0666. Open profile reads the in-memory delivered contents and never places them in public state or logs. Successful upgrades remove old generated candidate/config/reload files only after readiness passes; failed upgrades retain rollback data. The left card says **Proxy configuration**, with **No proxy configured** when no upstream proxy is saved; this does not imply the blocking YAML is absent. Keep configured endpoint details visible when stopped, and distinguish configured, confirmed listening, and unknown state. Reference sources are `Sources/ExitIPShared/ClashVergeProfile.swift`, `TailscaleVergeProvider.swift`, `DaemonRPC.swift`, and `Sources/ExitIPService/TailscaleProviderService.swift`.

### Menu bar and appearance

The menu bar, dashboard, and Settings observe the same state. Direct uses a checking clock during an IP lookup and a neutral warning on lookup failure; Direct remains selected and this warning does not claim firewall blocking. Gate status takes precedence in Rule/Global. Render updates on the main queue even while a native menu tracks input, and reload widgets on routing-only changes. Losing network reachability triggers the same immediate check/invalidation path as recovery. The menu offers modes, Refresh now, Open Dashboard, Settings, and the login-item preference. The preview status item stays available when its app window closes; its status continues updating, and its menu can reopen the window. Provide accessible status text, keyboard navigation, and Escape dismissal with focus restoration.

| Scenario | Menu-bar appearance and meaning |
| --- | --- |
| Verified Rule/Global | Exit-country flag; approved exit. |
| Direct | Current IP’s country flag when known, otherwise a Direct arrow; no proxy/IP gate. Checking and failure use neutral status symbols. |
| Startup, validation, IP check | Clock; ordinary internet blocked. |
| Unapproved IP, proxy/lookup failure, empty allowlist, missing profile, stopped mihomo/profile hosting | Stop symbol with last known country flag when available; specific blocking reason, including the triggering IP for a mismatch. |
| Core unavailable or setup incomplete | Neutral information symbol; status unavailable, never a claim of confirmed blocking. |
| Tailnet provider stopped while public access remains verified | Country flag plus warning; protected tailnet routes reject. |

Use a greyscale graphite/neutral-gray palette and frosted “m” icon. Remove blue and green branding, tints and status shades. Country flags retain their semantic colors. Follow Apple's macOS HIG, official UI resources, and Activity Monitor's compact aligned rows. Use native title bars, toolbars, segmented pickers, `NavigationSplitView`, forms, and controls. Adopt Liquid Glass sparingly for navigation and controls on macOS 26, including appropriate glass button styles/custom groups; use availability checks and native fallbacks on macOS 14+. Honor dark appearance, reduced transparency, contrast, and keyboard accessibility.

The browser's CSS material is an approximation. SVG/PNG/ICNS and editable icon layers are design assets, not a compiled dynamic Icon Composer document. The native Dock and Cmd-Tab now use the bundled Mimo app icon shown in Finder; live country/status indicators remain in the menu bar.

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

- Verify all dashboard and menu states, exact triggering-IP retention/clearing, unavailable data, permanent refresh, synchronized login preference, all four Settings sections, and configured ports when stopped.
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

**Apple silicon and IPv4 only; implementation and acceptance are still in progress. Mimo 1.0 is published as a preview in its own repository and tap cask; it is not a qualified protected-routing release.** The current source builds and signs successfully for arm64. The signed IPv4-only Release candidate is installed in the VM. Its installation, engine/profile checks and fresh GUI heartbeat pass. Installed-service integration passed 49 checks. Continuous packet runs passed 32 and 33 checks, but separate repeated runs reproduced peer timeouts; relay consistency remains unresolved. Original uninitialized Direct settings are retained.

### Implemented in source

- Native `mimo-gui` and `mimo-core`, approved icon, compact dashboard, four Settings sections, permanent refresh/login controls, service lifecycle controls, configured ports, exact blocking IP, and shared menu/widget/Control Center presentation, with the bundled app icon in the Dock and Cmd-Tab.
- Revision-aware proxy drafts remain in memory across status updates and Settings navigation. Conflicts preserve edits until explicit reload. Shared credentials remain in separate System Keychain accounts; status never returns secrets.
- The IPv4-only profile derived from the 38-rule legacy baseline, Global IPv4 local/tailnet exceptions, credential-free startup, private authenticated verification, exact profile-byte/engine binding, controller inspection, independent PF guard, flow termination, command ordering and persistent Direct recovery.
- Machine state is committed through a 0600 exclusive temporary file and atomic rename, without login-session file protection. This fixes a reproducible inability to reopen settings while the desktop is locked; credentials remain in System Keychain.
- Independent network/wake observation in the supervisor. Engine PID and route-address metadata recognize its own tunnel mutations; kernel-generated address/link events also require recorded ownership, an unchanged tunnel signature and a bounded reload window. Unchanged global notifications from configd are distinguished from real network changes.
- Verified native Tailscale socket exceptions scoped to authenticated control/DERP infrastructure. IPv4 infrastructure discovery runs independently of socket monitoring, retries ten seconds after each pass, and retains only observations from the last five minutes. IPv6 sockets receive no exception. Unclassified SYNs are dropped so the observer can inspect pending native sockets before any exception is granted. Failed DNS queries add no addresses and do not discard independently authenticated DERP or other DNS results. Protected peer transport uses DERP; arbitrary native diagnostic destinations and public exit-node traffic receive no exception. Tailnet Stop removes the inner-tailnet allowance without invalidating already verified public access.
- Protected system DNS on loopback port 1053, with a temporary supervisor-owned supplemental resolver. Original saved network preferences remain untouched. Direct removes the override; the closed guard blocks the ordinary DNS listener. DNS binding/ownership checks are part of activation and watchdog inspection.
- Pinned arm64 Homebrew formula/manifest, copied-app setup, transactional installation/upgrade rollback, stopped-service persistence, uninstall restoration, old-helper migration, and renamed-process diagnostics.

### Evidence retained on Delta and in the VM

| Acceptance | Result and evidence |
| --- | --- |
| In-memory profile and current controls | 2026-11-19: six installed-engine checks pass for stdin validation/socket reload, exact in-memory snapshot and hash binding, no payload in files/argv, malformed YAML rejection, authorized viewing/public-state redaction and Direct reload. All 19 VM upgrade/rollback/uninstall/reinstall checkpoints pass (`/var/tmp/mimo-upgrade-test-8yiqs7h3`). Live Open profile and Reload pass; Direct obtains an IP before initialization and shows its country in the menu/Dock. Greyscale controls and the Mimo startup path are visible. Evidence: `Tests/ReleaseEvidence/mimo-memory-profile.json` and `mimo-live-ui.json`. These checks do not qualify protected routing. |
| Shared models/policies | 158 tests pass in the current UI revision. The preceding 155-test run also passed with Delta locked. Includes secure atomic storage replacement and budget/cooldown reopening. |
| Service/XPC/authorization/revisions | Pass; `.build/mimo-service-early-startup.log`. Includes heartbeat receipt/expiration, independent pulses, cancellation fencing, secure persistence and non-routing changes preserving approved public access. |
| Native UI/model tests | Pass; `.build/mimo-ui-review-tests.log`. Direct/checking/failure/recovery updates exercise the retained native status item without manual refresh. Dashboard states and four populated Settings sections render in light/dark at 1040 × 570. Shared suite: 158 tests; installation/cleanup suite passes for renamed packaging. Live Tart checks supplement these renders. |
| Full Apple silicon build and ad-hoc signature | Latest source passes; `.build/mimo-ui-review-release.log` and `.build/mimo-ui-review-sign.log`. App bundle: `.build/mimo-current-release/Build/Products/Release/Mimo.app`. The development GUI is installed at `~/Applications/Mimo.app` in the VM. Published 1.0 artifacts are unchanged. |
| Published installation baseline | Mimo **1.0 (build 1)** downloaded from its public release, signature verified and installed in the VM. Core/engine/profile hosting run in Direct with IPv6 off. Fresh main-thread heartbeat after acceptance cleanup: `launch-check-Ue87g0jz`. Public archive `ExitIPMonitor-1.0.zip`, SHA-256 `1bc8b1437c4c27b2d035020348a1712f842478a2638b491401ea173001547706`. All 11 published Homebrew lifecycle checks pass; original state is retained. |
| Live native and browser UI | Pass for the reviewed scope; `Tests/ReleaseEvidence/mimo-live-ui.json`. Tart checks cover service endpoints, private profile filename/path, separate empty proxy state, stable layout, initialization, Direct recovery, blocked Rule/Global, menu updates while open, service controls, login synchronization, draft retention and Dark-to-System appearance. Safari renders the current dashboard and four-section Settings preview. Original Direct settings and production helper are restored; this is not protected-routing qualification. |
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
| Saved active Global reboot | The VM-only helper restores saved Global after a fresh allowlisted check without the GUI, uses the current boot’s PF reference, retains IPv6 denial, and restores the production Direct installation afterward. **Full-boot acceptance fails:** `mimo-installed-boot-t__vgnbe` captures 118 ordinary probe packets before the first confirmed guard and zero afterward. The measured interval is 4.892 seconds; moving the guard ahead of installation/Keychain work does not establish first-packet boot protection. Report: `Tests/ReleaseEvidence/mimo-protected-boot.json`. |
| Installed protected routing | **49 checks pass** in `/var/tmp/mimo-installed-test-4uddgng1`, using the separately signed VM-only helper. Covers real administrator XPC/Keychain configuration, empty and mismatched allowlists, exact blocking IP, Rule/Global TCP/UDP/DNS/HTTPS, IPv6 denial, bad credentials, peer service controls, external network events, core hangs/crashes, engine crashes, profile-byte changes and Direct restoration. Continuous captures confirm no unapproved uplink packets. The production helper, original settings and empty credential were restored; no qualification manifest was written. Public summary: `Tests/ReleaseEvidence/mimo-installed-routing.json`. |
| Continuous relay repeatability | Production-policy runs pass 32 and 33 checks, including another 33-check pass in `kozum5qp`, but repeats fail at Rule relay or Global native reconnect. Latest `uk6ens58` passes peer TCP/UDP in both modes, then fails after native down/up. Ping and actual peer TCP/UDP remain unavailable even after removing the VM TUN, protected DNS and IPv4 gate, and after a guest relay reset. These observations do not identify the original trigger. Separate Direct reconnection baselines pass nine and three cycles; Direct has also timed out transiently. No production firewall exception was widened. [Passing, failing and diagnostic reports](Tests/ReleaseEvidence/mimo-relay-repeatability.json) keep qualification open. |
| Real Homebrew lifecycle | The local Release cask installs its missing pinned mihomo dependency, passes the formula test and retains a stopped core across reinstall. Real uninstall exposed a transient firewall-lock collision; a bounded five-second wait and contention/timeout regression now pass, and the removal hooks succeed. All ten lifecycle checks pass in `.build/mihomo-runtime-tests/evidence/brew-7qkxq3rl`, including automatic removal of an app-only dependency, retention/removal of explicitly installed mihomo, and saved IPv6 restoration. The cleanup rerun also passes all ten checks in `brew-d76d456d`, including verified deletion of generated runtime profiles. The tested ZIP SHA-256 is `91e482516eb413d40a9ccfc7db5dcbda1bd1b97cd1545d901a58218053adfbdc`. Test artifacts remain unpublished. |
| IPv4-only implementation checks | 154 shared tests, service regressions (including bounded firewall-lock contention), daemon tests, native UI/model tests and Release packaging pass. Seventeen real mihomo private-runtime checks pass in guest `run-ca9b6cb1`; nine network-event checks and two installer preflight checks also pass with the IPv4-only policy. Nineteen upgrade/recovery checkpoints pass in `/var/tmp/mimo-upgrade-test-8228mom4`, including network-change re-enforcement with core/engine stopped. All eleven reboot checkpoints pass in `/var/tmp/mimo-boot-test-zlgqtcsy`; IPv6 remains disabled through protected startup and Direct recovery. Two 31-check controlled IPv4-only packet fixtures pass both modes, peer traffic and provider lifecycle; repeated-run relay consistency is still under investigation. |

The VM packet driver now rejects malformed private probe credentials before touching service state, retains native stacks/metrics and exact driver/helper hashes, and preserves every failed ping attempt. Its opt-in layer diagnostic compares ping and peer TCP/UDP after temporary VM-only firewall relaxation, TUN removal and complete Direct IPv4 restoration, including a guest relay reset. These deliberately relaxed intervals cannot pass protected acceptance. A separate optional region diagnostic restores the default guest relay preference, with watchdog cleanup. Four unprivileged regressions cover invalid input, failed-socket worker survival and relay-reset cleanup failures/timeouts. No production firewall exception was widened; tested TCP close/reset exceptions did not fix the intermittent failure and were reverted.

### Remaining acceptance

The VM now sees Delta as its online Tailscale peer; no additional node is currently needed to continue these tests. Direct peer TCP/UDP works over IPv4; IPv6 is now intentionally rejected. Remaining work:

- Resolve the boot guarantee. The current implementation protects traffic after its startup firewall is confirmed; real reboot evidence shows earlier ordinary traffic. Do not mark full-boot protection passed or enable release qualification while this requirement is unresolved.
- Resolve the intermittent relay failure across repeated IPv4-only runs. The latest failure persists in Direct without the Mimo TUN, protected DNS or IPv4 gate, and after a guest relay reset. Compare an independently reachable peer or separately authorized host/client environment next; wider firewall exceptions and repeated unchanged runs have not resolved it. Preserve passing and failing evidence; do not treat isolated passes or this diagnostic as qualification. Delta’s network configuration remains outside VM test scope.
- Complete the remaining installed protected-mode restart and packet acceptance. The 49-check installed run already covers actual allowlist/proxy configuration, both modes, wrong credentials, core hangs/crashes, mihomo crashes, changed profile bytes, network events and service Stop/Start; peer repeatability remains unresolved. A separate `MIMO_VM_ACCEPTANCE` build can exercise the real installed core, supervisor, authorization, Keychain, profile and firewall flow before release qualification; it requires root inside an Apple VirtualMac and release packaging rejects its identifying marker. The fixture restores the production helper, original settings/service intent and empty proxy credential with an independent watchdog. Keep the production qualification guard closed; never manufacture `qualification.json` to bypass missing evidence.
- Run real sleep/wake acceptance in a supported test environment. This VM refuses actual sleep.
- Finish copied-app Homebrew prompts/cancellation and remaining keyboard acceptance. Safari dashboard/Settings visual checks now pass. Tart GUI access is working in jay’s VM session. Live checks covered initialization, Direct recovery, blocked Rule/Global, all four service Start/Stop/Restart controls, invalid IPv4 input, preserved proxy drafts, synchronized login item and appearance. Automated modifier keys/clipboard through Tart were unreliable, so keyboard acceptance is still open. Production helper and original uninitialized Direct state were restored after the test. Offscreen captures are supplemental evidence.

This tailnet returns IPv4 MagicDNS records and successful empty AAAA answers for the tested names. Tests preserve those actual responses; IPv6 tailnet address assignment does not imply an AAAA record exists.

### Test environment and reusable installation image

- Tart inventory: `mimo-test-macos`; guest Bonjour name: `mimo-vm.local`; macOS 27.2.1 (26B131), 4 CPUs, 8 GB RAM, 100 GB disk, 1440 × 900 display, default NAT. No host directories are shared. Clipboard sharing is enabled. Start with `tart run mimo-test-macos --no-audio --no-usb-accessories`.
- `ssh mimo-vm` connects as `jay` using Bonjour, IPv4 and the existing pinned host-key alias. Tart Guest Agent 0.15.0 provides a verified VM-socket command channel independent of IP connectivity. Clipboard round-trip acceptance is outstanding.
- The user-created `mimotest` administrator and `mimo-vm-admin` SSH alias support authorized unattended tests. `Scripts/vm-admin.py` supplies ordinary sudo authentication through stdin using Delta's owner-only credential file outside the repository. No password is printed or committed; the temporary guest setup input is removed.
- The reusable repaired image is `~/Downloads/UniversalMac_27.2.1_26B131_Restore.complete.ipsw`, SHA-256 `233e85a09887579d47d0b195e7db72be7f204261059c6946f719acf6b300814f`. The missing segment, repair record and checksums are retained; the original image is unchanged.
- Firewall/TUN acceptance runs only inside the isolated VM. Delta's firewall and network configuration are not changed. The controlled SOCKS fixture binds only Delta's existing VM NAT interface and allows only the VM plus fixed test destinations. The peer echo fixture binds only Delta's existing tailnet addresses, requires a private nonce, and accepts only the VM; temporary credentials stay outside the repository. Both fixture servers are now stopped and their temporary credentials removed; the user-requested dashboard server remains available.

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

### Saved-proxy acceptance and status indicators (2026-11-19)

The VM now contains the user’s saved SOCKS5 proxy, password and one approved IPv4 address. A separate saved-configuration acceptance runner preserves the password and restores the original configuration in Direct; it must not use the older empty-configuration fixture. Protected production activation remains gated pending qualification. A missing qualification record must explain this limitation rather than report an unsafe installation file.

Direct shows the current country flag in Current connection and pairs it with a white Direct arrow in the menu bar; checking and failure indicators supplement the arrow. Background services shows only the access-status symbol. Direct never evaluates the allowlist or publishes an allowlist warning. Entering Rule/Global waits for a fresh proxy observation; a cached Direct address cannot trigger a protected-mode warning. Rule rejection keeps the last observed IP that triggered blocking visible through retries. The menu bar and dashboard use a red stop sign for blocked traffic, while other controls retain the greyscale theme.

The native dashboard layout now follows the approved preview’s card proportions, service status/control columns, login switch and routing footer at 1040 × 570. Menu symbols use white for Direct, amber for checking/warnings and red for blocked access; country flags retain their full color. General controls remain greyscale.

The saved-proxy acceptance run passes all 60 checks: approved Rule/Global TCP, UDP, DNS and HTTPS; empty/wrong allowlists; existing-flow revocation; bad username and unavailable proxy; in-memory credential matching; service Stop/Start; core hang and core/engine crash recovery; altered controller state; immediate checks on network changes; repeated reloads; IPv6 denial; and continuous packet attribution. Production helper, user configuration and saved password were restored in Direct. Evidence is sanitized in `Tests/ReleaseEvidence/mimo-saved-proxy.json`. Profile reloads have a bounded 10-second budget because cold initialization was too close to the previous 3-second deadline. These checks do not resolve the previously documented boot gap, relay repeatability, real-sleep or copied-app acceptance limitations and do not grant release qualification.

The focused Direct/allowlist regression passes all 13 checks: Direct keeps fresh IPv4 monitoring without evaluating approval or presenting a warning; Rule still rejects a fresh unapproved proxy IP and blocks ordinary HTTPS, mixed-port HTTPS, UDP and IPv6; switching back to Direct immediately clears the rejection. Original settings, credentials and the production helper were restored. Sanitized evidence is in `Tests/ReleaseEvidence/mimo-direct-allowlist.json`.


### 2026-11-19 protection repair work

- Added a dedicated IOKit queue and PF power sub-anchor. Protected sleep closes traffic before acknowledgement; the queue does not wait for main-actor profile work. A synchronized power epoch rejects stale approvals across sleep/wake. Direct remains unproxied and independent of the allowlist. Physical sleep qualification remains separate from injected power-event tests.
- Investigated a persistent empty network location as a boot barrier. In the isolated VM it survived a cold restart, blocked all 89 public TCP attempts and restored the original Automatic location. It is **not a production solution**: Apple's InterfaceNamer can automatically establish configuration for newly discovered interfaces, and applying the working location would introduce another persistence window. No network-location changes remain installed.
- A signed Network Extension packet filter was proposed as the next boot-enforcement candidate. The user has now confirmed there is no Apple Developer account, so a custom extension has no current signed deployment path. Publisher-signed Clash Mi activated successfully but failed to connect without Full Disk Access. The user declined that permission, ending its runtime evaluation without qualification. The user also dropped ProjectClash after reviewing its user-session dependency; multi-user, logout-independent operation remains mandatory. [The evaluation record](Design/MIMO_NETWORK_EXTENSION_EVALUATION.md) distinguishes installation, external control and profile compatibility from measured boot/crash protection. No assumption that a Network Extension automatically proves boot protection is permitted.
- Relay investigation found a version mismatch: Delta runs native Tailscale 1.104.2; the VM runs 1.104.7. Upstream PR 21902 fixes UDP reachability errors in the 1.104.5 line. The official signed/notarized 1.104.7 installer is prepared; a Delta update requires the user's approval because existing network tests were confined to the VM. This is a test hypothesis, not a demonstrated Mimo fix.

The saved-proxy power regression passes **77 checkpoints**, including both modes, pre-acknowledgement blocking, existing-flow closure, suspended-core wake blocking, fresh re-verification, service cycles and crash/network-change recovery. Continuous packet attribution passes. All 161 shared tests, service/daemon/installer suites and the arm64 Release build pass. [Sanitized power evidence](Tests/ReleaseEvidence/mimo-power-guard.json) distinguishes injected messages from real sleep. These results do not qualify early boot or physical sleep/wake.

A new actual sleep request after the repair still returns `0xe00002e2` / exit 71 in the VM, with all kernel sleep/wake counters unchanged at zero. The scheduled wake alarm was removed. [Current capability evidence](Tests/ReleaseEvidence/mimo-power-capability.json) confirms that event injection cannot close the real-sleep qualification item.

The relay repair now discovers Tailscale’s separate built-in DNS bootstrap hostnames through authenticated IPv4 DoH, publishes the live DERP map and successful DNS answers incrementally, and takes the held-socket snapshot after the user/route probe. Control endpoints refresh each pass; bootstrap names refresh once per minute. The five-minute expiry and signed-root-process/socket restrictions remain. VM-only timing events expose observation/apply delays. Repeated saved-configuration relay acceptance is in progress; the failed TCP-state experiment is not part of the implementation.

The initial relay repair passed a 36-check run and a 42-check run, but a further repeat failed. Those results remain in the evidence record. Timing exposed multi-second delays on the supervisor’s main actor. Native CLI probing, infrastructure discovery and socket/PF enforcement now run independently; a five-second interface lease is rechecked against the live route/address. Stop serializes with the last update and fences stale detached results. A regression deliberately blocks the main actor and confirms socket enforcement keeps progressing. The independent-worker candidate still needs repeated VM acceptance.

The independent-worker candidate exposed a lower-level subprocess bug: children inherited other concurrent commands’ open stdin socket ends, delaying EOF for pfctl/mihomo until unrelated network requests exited. An isolated reader plus unrelated sleeping child reproduces status 124 before the fix. BoundedProcess now uses POSIX_SPAWN_CLOEXEC_DEFAULT and explicit stdio actions; the service regression tests concurrent EOF delivery. This repair applies to both power guarding and native transport.

A further repeat passed all five Rule relay resets but failed native down/up. The worker was independent of the main actor but still waited on the parent firewall lock for up to 1.8 seconds. Native PF transactions now have their own cross-process lock; Direct clears the sub-anchor through the same writer. The parent guard and power sub-anchor remain authoritative, and neither Direct nor startup blocking depends on native exceptions. Fresh packet-level acceptance is required for this change.

The final helper (`696c0875c1c44623ccb866b1e34ec5328e3d87342ef413c445a8127c2055b526`) passes **44 relay checkpoints in two consecutive runs**, `mimo-saved-proxy-243jrws1` and `mimo-saved-proxy-9ip3n1tn`. Both include five forced relay reconnects per mode, native down/up, provider Stop/Start/Restart and continuous traffic-boundary checks. This is 20 successful forced reconnects across the two runs, using unchanged host/guest Tailscale versions. Earlier failed candidates are retained in [the repair record](Tests/ReleaseEvidence/mimo-relay-repair.json). No qualification manifest is created; boot and physical sleep remain separate.

Final regression on that same helper passes **77 power/failure checkpoints** (`mimo-saved-proxy-uuba_ryo`): injected sleep/wake in both modes with core suspended, existing/new-flow denial, fresh approval, empty/wrong allowlists, invalid/unavailable proxies, profile reload, service controls, crashes, controller mismatch and network-change recovery. Continuous packet attribution passes. The normal arm64 GUI/helper are installed and match (`e9fb7250195605ab06a67b59fd60535b1e9cc6f395cc80af42e3c520865119b2` helper SHA-256). Independent checks confirm exact saved settings/password/service intent, fresh Direct IP without rejection, responsive GUI heartbeat/menu icon, native Tailscale Running, empty power barrier, and no test residue or qualification manifest. Shared163, service regressions, cleanup fault tests and Release build pass. The preview remains on `0.0.0.0:8347`.

**Still unfinished:** first-packet boot protection remains unproved. The independent loader and repair implementation below reduces reliance on Mimo startup; it does not establish the earliest boot boundary. Neither evaluated third-party app is an accepted replacement: ProjectClash was dropped for its user-session dependency, and Clash Mi's runtime evaluation ended when the user declined its Full Disk Access requirement. No Apple Developer account is available for a custom signed extension. Physical sleep/wake requires a supported physical Mac, and hardware availability remains unanswered. The VM refuses real sleep. Normal Rule/Global remain blocked; no new release archive or tap update is justified by the present evidence.


### 2026-11-19 independent PF startup and health monitoring

The approved change is now implemented in source: a saved credential-free PF anchor, a marked load directive in the existing `/etc/pf.conf`, and separate macOS-tool boot/health launchd jobs. Neither loader requires `mimo-core` or mihomo to execute. Each new boot blocks first; the supervisor restores saved Direct or verifies protected intent. This reduces dependency on Mimo startup but does not guarantee protection before the independent loader runs. The startup-TUN-enabled assumption remains in the failure analysis; the actual generator has not changed.

The independent health job checks every ten seconds. The supervisor also invokes the fixed checker asynchronously. Live main-anchor rules, PF enable-reference ownership, saved PF/launchd assets, registered job arguments/boot properties, disabled overrides and saved Stop intent are checked. Repair closes first, then restores jobs. Shared locking prevents automatic repair racing a saved Stop or manual lifecycle operation. Maintenance and uninstall stop repair safely; unrelated PF configuration and saved user settings are retained. A missing/hung OS, simultaneous monitor loss, running-but-hung processes and arbitrary child-anchor changes remain limits.

Background services now includes separate PF firewall and launchd monitor rows in normal body-size text. Each shows Healthy, Needs repair, Check overdue after 35 seconds, or Unavailable, plus a visible Last check elapsed timer matching the exit-IP check. Both timers use the shared inspection timestamp; missing timestamps show No result, while hover shows the exact check time. Both light and dark dashboards use a 1040 × 640 default window and monochrome healthy state. Older saved wide windows grow to this height when reopened. The independent guard is not exposed as a user-stoppable routing service.

Validation and retained failed attempts are recorded in `Tests/ReleaseEvidence/mimo-infrastructure.json`. This change does not create a protected-routing qualification manifest or publish a new release.


Final independent-infrastructure VM acceptance passes **33 checks** (`mimo-infrastructure-test-c6m8gigk`), including the real missing-helper reboot, dashboard health over XPC, fault repair, uninstall/reinstall, unrelated PF ownership/configuration retention, and exact original settings/service intent restoration. Local shared164, service, app/render, daemon-script/guard and arm64 build checks pass. The normal GUI/helper candidate is installed in the VM; no protected-routing qualification or public release is created. See the sanitized record for previous failures and remaining limits.

### 2026-11-19 actual Release-package acceptance

The user requested realistic tests only in `mimo-vm`, with real sleep attempted last, and approved enabling Rule/Global in the normal release candidate. The obsolete qualification-manifest gate is removed; PF enforcement, verified profiles, private exit-IP checks, allowlist approval, stale-generation fencing and IPv6 denial remain. Tests must use the same packaged executable installed through Homebrew, without swapping a VM-only helper or claiming simulated power events as real sleep. First-packet boot protection remains unproven. Earlier test-helper restrictions and qualification-gate descriptions above are historical, not the current candidate behavior.


### 2026-11-19 — normal Release acceptance in progress

Testing now uses the exact ordinary arm64 Release package installed by Homebrew in `mimo-vm`, with the saved real proxy, password and approved exit list. No helper substitution, simulated sleep, host networking changes or peer echo service is used. A VM-local test tap changes only the download URL; the published 1.0 release remains unchanged.

Completed lifecycle evidence includes cancelled Homebrew authentication followed by the standard authorized administrator setup, real uninstall/network restoration, retained explicit mihomo dependency, automatic installation of a missing pinned dependency, and shared-state/authorization checks from both existing administrators plus a temporary standard account. The standard account had login disabled and was removed. A Direct allowlist regression passed with ordinary traffic and packet capture.

The broad feature run exposed intermittent lost heartbeat replies. A dedicated heartbeat connection was added without changing the five-second expiry. Its first candidate introduced an actor-isolation crash in an XPC error callback; macOS crash stacks identified it, and explicitly Sendable callbacks repaired that crash. A subsequent 75-checkpoint attempt still failed at mihomo Restart. A focused real-provider reproducer and process samples then showed cancelled discovery generations occupying Swift cooperative threads with blocking operation queues and Security checks. Persistent serial dispatch queues now isolate discovery, interface/socket inspection, provider probes and infrastructure checks; cancelled queued work is skipped and stale results remain fenced. The same reproducer recovered three consecutive provider/engine restart cycles. The subsequent full installed Release audit passed all 88 checkpoints, including actual engine suspension and supervisor termination. [Queue-repair evidence](Tests/ReleaseEvidence/mimo-heartbeat-queue-repair.json) and [the current execution record](Tests/ReleaseEvidence/mimo-real-release-status.json) retain both failures and successes.

The current normal Release passes all 88 full-feature checkpoints, 35 infrastructure checks with a real missing-helper reboot, ten saved-Rule and ten saved-Global reboot checks with the GUI unavailable, 41 existing-peer relay checks, 17 engine/supervisor fault checks, 12 Direct/allowlist checks, eight account-access checks and eight final Homebrew lifecycle assertions. Raw evidence remains private in the VM. [The normal Release acceptance report](Tests/ReleaseEvidence/MIMO_NORMAL_RELEASE_ACCEPTANCE.md) records package hashes, scope and limitations. Screen Sharing exercised all four native Settings sections, login on/off, appearance and transparency restoration, and Event Log. A discovered GUI fallback bug now preserves cached proxy/mode during service disconnection; the updated package has the identical tested helper. Verification of that GUI correction, remaining native controls and final restoration checks remain, with real VM sleep last. Computer use subsequently lost access to the VM window; the pending interactions are not counted as tested. Delta only builds artifacts, starts SSH and stores sanitized reports; all runtime tests execute in mimo-vm.

### Approved session authorization and dashboard consistency (2026-11-19)

**Superseded by the password-free controls section below:** the previous GUI kept one private administrator authorization until Quit GUI or logout, without the former five-minute expiry. Closing a window retains it; quitting destroys the rights. The helper still validates every privileged operation, and other clients/accounts do not inherit the authorization. macOS owns password entry; Mimo does not store the password. Native validation must cover reuse after five minutes, quit/relaunch, and separate-account denial. Installer/system prompts remain separate.

Background services uses a 26-point status symbol and a 21-point main message matching Current connection. Direct/approved status is blue, checking/warnings orange, blocked red and unavailable neutral, with the surrounding greyscale theme retained. PF firewall, launchd monitor and the four service names share the same body-size medium-weight font. A fixed status area reserves room for changing messages. Verify the actual VM app without scrolling at its default size.

The earlier native service-outage check passed: saved proxy configuration and Global selection remained visible while live access became unavailable. Login-item registration and on/off controls passed, but actual launch after login remains to be checked before the final manual sleep test.

### Dashboard and Settings share one window (2026-11-19)

The approved design uses two main tabs, Dashboard and Settings. The native app now follows that structure instead of opening a separate Settings window. Settings retains its Proxy, Allowed IPs, Monitoring and General sidebar sections. Every Settings entry point, including Cmd-comma and dashboard Edit/Configure/Allowed IPs links, selects the appropriate tab/section and restores the same main window. Refresh now and the Event Log/Quit GUI footer stay available in both tabs. Both pages retain their view state so tab switching, refreshing and closing/reopening the window preserve unsaved drafts. Switching tabs clears keyboard focus from hidden controls. The default size remains 1040 × 640.

Validation is performed on the actual installed arm64 Release in mimo-vm. The existing authorization-session check has passed reuse after more than five minutes, main-window close/reopen and core Restart; quitting and relaunching requires a fresh native approval, and cancelling leaves Direct/services unchanged. The Settings-tab acceptance record will distinguish the new GUI hash from earlier runtime evidence.

Service-row typography uses explicit sizes to prevent contextual style differences: all six PF/launchd/service titles are 13-point medium, and health values/check timers are 13-point regular. The four service status values no longer use smaller caption text.

Follow-up alignment: PF/launchd health and service status share the same 104-point column with matching five-point bullets. The right-hand 170-point column contains check ages or service controls. At the user’s request, Last check labels/ages now match the 11-point button font; all six names and status values remain 13-point.

Profile hosting places an 11-point Copy path icon directly to the left of the startup file path, with a descriptive accessibility label and tooltip. It no longer floats at the far right of the row.


### 2026-11-19 — Network verification visibility, system events and menu shortcuts

Rule/Global must acknowledge a closed firewall before publishing profile validation, then show the private exit-IP check while ordinary traffic stays blocked. The dashboard keeps a fixed-height status area and shows the completed block → approved-IP → reopened sequence after success. The menu retains its red stop during checks and adds an amber clock; Direct keeps its country and white arrow during lookups. No cosmetic delay controls the firewall. Notifications are asynchronous and cannot prove zero leakage before detection.

Settings → Monitoring lists network interface/address/gateway, DNS/proxy/route, VPN connect/disconnect/configuration, sleep, wake/cancelled sleep, reboot/service recovery, login/user-switch/display-wake, and logout/lock/app-close behavior. Login/session/display events refresh shared state; they do not unnecessarily stop every user's traffic. Remote exit-IP changes require routine/manual lookups when macOS emits no network event. Actual login and real sleep remain independently qualified.

Every actionable status-menu item has a visible native shortcut: ⌘⌥1/2/3 modes, ⌘R refresh, ⌘1 dashboard, ⌘, Settings, ⌘⌥Q quit. Preserve ⌘Q window closing. Verify these changes with the installed normal Release app and real saved proxy in mimo-vm; no Delta runtime tests.

Login controls stay in Dashboard/Settings and are removed from the status popup, including the Login Items Settings link.

Monitoring refinement: move the compact six-row system/network event list below lookup providers. Show provider quota, calls today, Mimo’s 80% cap and remaining budget. Correct anonymous ipapi.is to 30/day (Mimo 24/day), per its current official documentation; IPinfo Lite is unlimited with a token. Counters are machine-local and reset at midnight UTC.

Provider layout: compact four-row table with Provider, Quota/day, Mimo/day, Used today and Remaining columns. Keep shared IPinfo token controls below the table.

Verification card: compact aligned rows for routine interval, network changes, IPv4-only traffic and protected verification. Keep one short Direct/failure note. Remove its duplicate Check now button; the permanent toolbar Refresh now performs the action in both main tabs.

Monitoring navigation: add an inline greyscale **View rules ↓** link beside **Rule / Global** in Verification. It scrolls to the existing **System & network events** card at the bottom of the same page, respects Reduce Motion, and does not change settings or trigger an IP check.

### 2026-11-20 — Direct observation recovery and native extensions

Actual VM testing reproduced a missing Direct IP after firewall repair: the core completed its lookup, but a temporary blocked supervisor reply discarded that observation. Core now owns the last successful Direct observation separately from the supervisor's gate state. Direct recovery reattaches it with its original check time; changing modes clears it. A service reinstall starts a new lookup rather than treating an old observation as fresh.

The ordinary installed Release passes 18 recovery checks: PF disable, missing main-anchor rules, supervisor restart, actual competing firewall-lock contention, bundled service reinstall, ordinary-user HTTPS, fresh startup observation and restoration of the original configuration/password/service intent. The same contention case failed before the fix. [Before](Tests/ReleaseEvidence/mimo-direct-observation-before.json) and [after](Tests/ReleaseEvidence/mimo-direct-observation-after.json) retain separate artifact hashes. This is a display-state repair; it changes no firewall approval requirement.

The same helper subsequently passes [20 real network-transition checks](Tests/ReleaseEvidence/mimo-network-progress-direct-recovery.json) across Rule, Global and Direct, including empty/wrong allowlists and GUI progress, then [seven read-only restoration checks](Tests/ReleaseEvidence/mimo-direct-recovery-restoration.json). The exact package/helper hashes remain in each report. These checks do not qualify actual login or sleep.

Native VM checks confirmed a medium Notification Center widget receives the actual Direct IP and age, updates during Rule/Global verification, and retains the rejected IP during re-verification. The Control Center control was added through the native gallery and opened the dashboard. WidgetKit schedules extension updates; these surfaces are not a synchronous firewall indicator. Actual login launch, physical shortcut execution and real sleep remain separate acceptance items. Sleep stays last.

Service startup remains managed by launchd, with no user-facing launch-at-boot option. Rename the personal login preference to **Show menu-bar app at login**, label the dashboard row **This account · Interface only**, and explain that it changes neither system-service startup nor running state. Show **mimo-core starts at boot and keeps running when you quit Mimo’s interface.** in both Dashboard and Settings. This wording clarification does not alter manual Start/Stop/Restart or saved Stop intent.

### Dock icon consistency — 2026-11-20

Use the bundled Mimo application icon for the Dock and Cmd-Tab, matching Finder. Remove the runtime status-label icon override; country, mode, checking and blocking indicators remain in the menu bar and dashboard. Verify in the installed mimo-vm app, including refresh and reopening the dashboard.

Verified in the installed arm64 Release in mimo-vm: Finder/Dock match, fresh IP refresh, minimize/restore and close/reopen. See `Tests/ReleaseEvidence/mimo-dock-icon-native-ui.json`. Cmd-Tab is not independently observed; the shared bundled icon is used by macOS.

### Mode transition follow-up — 2026-11-20

The real Option-Command-2 check exposed a transient unavailable presentation and a second configuration-driven verification immediately after first activation. Show pending closure as progress without claiming confirmed blocking; preserve already confirmed blocking during the next preparation. Treat a stopped provider as normal only when native Tailscale is off. When native Tailscale is starting/running, stopping its provider is a failure: show a red service row and dashboard/menu warning in every mode, without claiming public traffic is blocked. Trace the external configuration classification before adjusting self-change suppression.

The user chose working network behavior over saved customization. mimo-core follows native Tailscale across logged-in accounts: off means provider off without a warning; Starting/Running means provider on. A native reconnect overrides manual Stop, as does core startup reconciliation. Manual Stop remains effective during the current native connection. Failed observations leave the current setting unchanged and retry. An automatic setting revision during protected verification invalidates that in-flight proof and requests a fresh check; an already approved public connection is preserved. Validate native down/up, manual Stop then reconnect, real provider HTTP responses, protected access and restoration in mimo-vm only.

The duplicate Rule activation was traced to `State:/Network/Global/DNS`: macOS selected the Mimo supplemental resolver after the profile became active. Skip only that resolver’s exact fields and owned configuration identity when every other service DNS value is unchanged. External DNS, routing and interface changes continue to close traffic and verify. Installed VM regression must include real DNS preference changes.

DNS review: ordinary application resolver bypass is restricted, but Rule still inherits direct upstream DNS, including plaintext resolvers. Global uses proxied DoH for public DNS. Direct encrypted bootstrap and private MagicDNS are explicit exceptions. The recommendation to proxy ordinary public DNS in both protected modes is recorded, not implemented as part of the Tailnet lifecycle change. See `Design/MIMO_FIREWALL_AND_FAILURE_SCENARIOS.md`, section 5.

Installed Release verification: 168 shared tests pass in mimo-vm. Eighteen lifecycle/DNS/restoration scenarios pass across the Direct/Rule run and the focused Global/DNS rerun, with the failed overlapping-network assertion retained separately. The same installed helper passes all 20 real route-change, empty/wrong-allowlist, GUI-progress and Direct-restoration checks. See `Tests/ReleaseEvidence/mimo-tailnet-lifecycle-summary.json`, `mimo-real-dns-transition-order.json`, and `mimo-tailnet-aware-network-progress.json`. No host runtime tests, synthetic network notifications or helper replacement were used. Actual remaining mode/Quit keyboard checks and physical sleep remain separate; sleep stays last.

### Tailnet Start without administrator authentication — 2026-11-20

The user requires starting the system-wide Tailnet provider to work without a password. Add a dedicated, idempotent `startTailnetProvider` command available to local accounts. It accepts no settings payload and enables only the current saved provider configuration. Both native GUI Start entry points use it without constructing an administrator authorization. Existing shared-settings authorization remains independently enforced. Reuse the same serialized provider update and protected-verification fencing as automatic native connection changes. Validate with real unauthenticated XPC clients under two existing administrator UIDs and a temporary standard UID in mimo-vm, plus actual provider HTTP and blocked-public-traffic checks.

Password-free Start is installed in mimo-vm and passes all 11 real-account checks, plus 168 shared tests. Both existing administrator accounts and an actual standard UID start the provider without an authorization form. Repeated Start is idempotent; injected settings are rejected; empty-allowlist Rule remains blocked. The temporary account and all test configuration are removed/restored. Evidence: `Tests/ReleaseEvidence/mimo-tailnet-start-without-password.json`.

## Password-free controls after installation — 2026-11-20

Installation authorizes the exact app build once by saving its code-directory hash in root-owned `/Library/Application Support/Mimo/app.cdhash`. Hardened Runtime is enabled on the app. Dedicated core and supervisor XPC control endpoints enforce this identity before accepting each message. App updates replace the identity with the helper and launchd definitions; rollback restores it and uninstall removes it. All local accounts using the installed app may operate its shared controls without a password, including after relaunch and reboot. The UI no longer obtains or caches Authorization Services rights. Existing read-only endpoints remain available to widgets and local readers; generic clients cannot use the new endpoints. Root-only verification/approval and command-generation fences remain unchanged.

If the installed supervisor is temporarily unavailable, recovery reports the failure and relies on the independent launchd/PF monitors; it never starts an authentication dialog. Missing or replaced privileged files require a genuine reinstall. The exact installed app has a read-only `--check-service-access` diagnostic; it never accepts arbitrary commands or returns profiles, settings or secrets. Real VM validation must distinguish this account/signature check from physical dashboard interaction. This replaces the earlier one-password-per-GUI-session design.

## Service transition ordering — 2026-11-20

A Rule-mode mihomo Restart did not immediately show Blocked in the dashboard. This was a display observation, not evidence of continuing traffic. The service handler previously waited until its final reply to deliver state, and its non-throwing close helper could let service mutation proceed after an unconfirmed close. Both paths are changed: core/engine/profile lifecycle actions inspect the saved mode, require strict PF closure without public engine/probe exceptions, then emit confirmed blocked progress over the same XPC connection before changing service flags or launchd jobs. Failure aborts the action, retains existing service intent, and reports unavailable protection. No unconfirmed closure is labeled Blocked.

The initiating GUI shows Blocking on click, receives Blocked separately from the final response, and ignores cached Allowed snapshots until new verification/progress or an explicitly newer mode selection arrives. This applies to its menu bar as well as the dashboard. Stop retains protected denial; Start/Restart/Reload need a fresh valid profile and allowlisted exit. Direct continues unproxied IPv4. Native Tailnet provider lifecycle has its own route-exception boundary; stopping it does not invalidate an otherwise verified public proxy. Real VM checks cover all lifecycle operations, actual ordinary-user HTTPS and actual kernel-lock contention. Physical GUI ordering is recorded separately from transport checks.

Service recovery refinement: the confirmed service-change barrier is the strict startup PF policy, with no public engine/probe exception. Publish Blocked immediately after PF succeeds, then try controller flow cleanup. A missing/unresponsive controller does not prevent safely stopping/restarting its engine. Ordinary verification closes strictly first, deletes old controller flows, and only then restores the bounded probe/endpoint exceptions; failed cleanup cannot resume buffered old engine traffic through those exceptions. Existing LAN policy exceptions remain. The Tailnet Stop test checks removal of the inner `100.64.0.0/10` interface permission; it must not incorrectly require removal of the constrained native control/DERP socket rules that intentionally keep Tailscale connected.

Validation: the full 45-case real service lifecycle matrix passes in mimo-vm, including Rule/Global denial while services are stopped, Direct recovery, native Tailnet controls and PF-lock contention. After the display-only lost-supervisor fallback, the final installed build passes a focused 7-case Rule/mihomo rerun (including a missing controller), 13 account/signature checks, 7 restoration checks and 173 shared tests. Settings, proxy credentials, Direct/native-off/provider-off state and the explicit mihomo dependency are restored. The user confirmed password-free native controls. The user subsequently confirmed the requested Rule/mihomo Restart dashboard/menu sequence and return to Direct; see `mimo-service-progress-user-confirmation.json`. Evidence and build identities: `Tests/ReleaseEvidence/MIMO_NORMAL_RELEASE_ACCEPTANCE.md`. Sleep/first-packet boot qualification is not claimed by these checks.

### Direct selection and event behavior (2026-11-20)

Explicit Direct selection cancels stale verification without sending a close command. After saving Direct, the supervisor releases protected IPv4 restrictions before removing TUN/DNS interception; IPv6 denial remains. The interface reports Switching to Direct until restoration succeeds, then checks the current IP without allowlist approval. Normal network/VPN, login/session, wake and refresh events while Direct is selected do not close IPv4. This does not remove independent boot/infrastructure repair policy or claim that changing routes preserves every existing TCP connection. Installed VM validation is recorded in the acceptance evidence.

Validation: 14 installed Release Direct transition/event checks pass in mimo-vm, including real VPN reconnect/disconnect and route changes with an empty allowlist. All 174 shared tests pass. Original Direct/native-off settings are restored; the final native dashboard and menu state were visually confirmed. See `Tests/ReleaseEvidence/mimo-direct-transition.json`.

### Protected public DNS (2026-11-20)

Both Rule and Global now send public DNS through `https://1.1.1.1/dns-query#Proxy`. Rule keeps its intentional website-routing exceptions, but those exceptions no longer send DNS to the old direct/unencrypted upstreams. Private ts.net names retain MagicDNS through TS-DIRECT. Proxy endpoint bootstrap uses a separate fixed encrypted resolver and never resolves the proxy through itself. This supersedes the earlier recorded DNS limitation. All 175 shared tests and 15 installed DNS/packet/restoration checks pass in mimo-vm. The latter covers UDP/TCP and uncached public lookups in both modes, ordinary HTTPS, physical-interface process attribution with a Direct positive control, and MagicDNS after native VPN connection and fresh verification. See `Tests/ReleaseEvidence/mimo-protected-dns.json`. Encrypted bootstrap and intentional Rule website routes remain documented exceptions.


Current-candidate completion checkpoint (2026-11-20): the same protected-DNS package passes 88 installed feature checks, seven real Homebrew lifecycle assertions, ten checks after each saved Rule/Global reboot, and seven final restoration assertions. The exact GUI can access its permitted services/profile as jay without a password. Original Direct/native-off state and credentials are retained. Remaining manual shortcuts, native user switching and actual sleep are not marked passed; peer UDP requires an existing service. First-packet protection before the independent PF loader remains a design limitation. Public Homebrew v1.0 is unchanged; source and evidence are preserved in the current-candidate branch.
