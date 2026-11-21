# Mimo for macOS

Install **Mimo v1.0 (build 2)** with Homebrew:

```sh
brew trust --formula jxz345/tap/mihomo@1.19.34
brew install --cask jxz345/tap/mimo
open /Applications/Mimo.app
```

The fully qualified install finds the repository automatically. The first command trusts only the pinned mihomo dependency, so Homebrew can install it as a dependency rather than an explicitly requested package. Homebrew 6 and later require trust for non-official packages; the fully qualified cask install trusts Mimo itself. [Homebrew’s trust documentation](https://docs.brew.sh/Tap-Trust).

Requires an **Apple silicon Mac with macOS 14 or later**. Control Center integration requires macOS 26. Installation includes tested **mihomo 1.19.34** and requests administrator authentication for the machine-wide services. Routine controls after installation and proxy setup need no administrator password. Mimo supports IPv4 only; IPv6 is disabled while installed and its saved settings are restored on uninstall.

Already installed an earlier v1.0 build? The version remains 1.0:

```sh
brew update
brew fetch --force --cask jxz345/tap/mimo
brew reinstall --cask jxz345/tap/mimo
```

[Download v1.0](https://github.com/jxz345/mimo/releases/tag/v1.0) · [What is implemented](#what-is-implemented) · [Event-driven workflows](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) · [Clean uninstall](#clean-uninstall-and-reinstall) · [Protection limits](Design/MIMO_FIREWALL_AND_FAILURE_SCENARIOS.md)

The source on `main` and `v1.0` is one latest-source snapshot, without development commits on the published branch. Current packages are `Mimo-1.0.zip` and `Mimo-1.0.pkg`. The installed app is `Mimo.app`; its executables are `mimo-gui` and `mimo-core`.

## First launch

1. Open Mimo. If installation authentication was cancelled, use **Install Service** or **Repair Service** to finish setup.
2. Configure the shared proxy in **Settings → Proxy**. Credentials are stored in the System Keychain.
3. Add approved IPv4 addresses in **Settings → Allowed IPs** before selecting Rule or Global.
4. Select Direct, Rule or Global on the Dashboard. Use **Refresh now** for a manual check.
5. Optionally enable **Open Mimo at login** in Settings → General. This starts only this account’s GUI. The shared services are managed independently by launchd.

The release is ad-hoc signed, not notarized. Homebrew checks the sealed signature and removes quarantine from this app only; it does not disable Gatekeeper. Copied-app/package installations may require macOS’s Open Anyway approval. If macOS parks an approval before startup, lock and unlock the screen, then reopen the app. Use the bundled `diagnose-launch.sh --launch` to collect a bounded startup trace.

Mimo’s required supervisor and PF boot policy run independently of the GUI. Closing the window or quitting Mimo does not stop shared protection. Service Start/Stop choices are explicit actions in the dashboard; there is no separate checkbox to disable required boot protection.

## Modes and protection

| Mode | Behavior |
| --- | --- |
| **Direct** | Unproxied IPv4. IP checks and network/session events do not block internet access or enforce the allowlist. |
| **Rule** | Applies the saved profile’s routing rules. An empty allowlist, invalid configuration or unapproved exit IPv4 keeps public traffic blocked. |
| **Global** | Sends traffic through the proxy, with the same allowlist and verification requirements as Rule. |

Protected transitions show **Blocking → Blocked/Checking → Allowed**. Once allowed, routine background audits do not change the dashboard/menu icon or status; audit failures still block traffic and show their cause. The last observed exit IP remains visible when it caused blocking. Direct shows its current IP and country with the Direct indicator. Menu-bar colors and dashboard status reflect the shared service state.

Country is display metadata. A valid exit IP remains valid when a provider cannot identify its country; the menu bar shows a globe. Country-only changes never request another lookup, confirmation or block/open cycle. The Allowed shield is white. Rule/Global still require the actual IPv4 address to be allowlisted, and real network/system events still trigger protected verification in Rule/Global. AirPort scan/radio status notifications are compared before the early firewall callback. Unchanged values and known telemetry (AutoJoinTimestamp, Busy, signal/noise, channel and scan records) do not start a cycle. The `Setup:` network-location root is also compared before early blocking: an unchanged location with only a `LastUpdated` timestamp change is ignored. Missing location data, a changed location, and unknown root-field changes still trigger verification. Wi-Fi power, association and unknown field changes still trigger protection; public IP, DNS, proxy, route, link and VPN changes retain protection. Private Tailnet connect/disconnect notifications can update in place when the verified proxy uses a separate public interface; exit-node, subnet-router, unknown and public-network changes still require verification. Ordinary network/session/wake events are ignored in Direct; startup, manual/routine IP checks, tailnet integration and PF/launchd health monitoring remain available.

The supervisor closes PF on detected protected-mode changes, prepares restricted private verification access and checks the exit IP before reopening. An unchanged configuration with a valid full-verification baseline may use the agreed optimistic path: essential live checks and an approved IPv4 first, then a fuller background audit. An audit failure or deadline requests blocking and full recovery. This accepts possible exposure before a missed fault is detected.

PF has a saved boot policy and a separate launchd loader/health monitor. **Traffic before that loader runs is outside the protection guarantee.** Detection of network/session events is asynchronous. Mimo does not claim a macOS Always On VPN or a zero-packet boot barrier. See the [current event workflows](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md), [design history](MIMO_PLAN.md) and [failure analysis](Design/MIMO_FIREWALL_AND_FAILURE_SCENARIOS.md).

## Dashboard and Settings

Dashboard and Settings are tabs in one native window. Dashboard cards size to their content, with a consistent height for firewall, launchd and service rows; they do not stretch to fill a taller window. The dashboard contains current connection details, three modes, Refresh now, background-service controls, PF/launchd health and check ages, service ports, private-profile Open/Reload actions, and a clean-uninstall command with a copy button. Navigation, Refresh now and the mode selector share one top row. The refresh interval and its Configure link sit with the IP-check details. The routing summary and LAN/Tailscale note sit below the proxy details, using the spare card space instead of a separate bottom row. The uninstall command and app-deletion note occupy a separate block below the proxy details; the bottom bar retains Event Log, the installed version/build and Quit GUI. [Light appearance](Previews/mimo-dashboard-compact-light.png) · [Dark appearance](Previews/mimo-dashboard-compact-dark.png) (native VM renders with example data).

Settings contains **Proxy**, **Allowed IPs**, **Monitoring**, and **General**. Monitoring includes provider choice, quotas/remaining allowance, refresh policy and a compact event list. Proxy drafts survive status updates and tab changes. General contains GUI login launch and appearance controls. The Dock uses the same icon as Finder; the status menu shows country/mode/protection state and keyboard shortcuts.

Copy icons briefly show a checkmark after success; Event Log’s Copy All/Copy Diagnostics buttons show “Copied” without moving nearby controls.

Queued controls and held events appear in Event Log (`mimo_control_queued`, `mimo_control_resumed`, `mimo_cycle_event_deferred`). Provider failures record `provider_failure_paused` with their reason and resume time. Rule/Global remain blocked if all available providers fail; Direct stays open.

## What is implemented

| Feature | Behavior |
| --- | --- |
| **Homebrew distribution** | Mimo v1.0, Apple silicon only, with the pinned mihomo 1.19.34 formula, checksum verification, normal install/reinstall/uninstall and standalone ZIP/package installers. |
| **Release build identity** | Each GitHub upload receives a distinct increasing build number while the marketing version may stay 1.0. The dashboard, diagnostics and release manifest identify the exact build. |
| **Consistent Mimo identity** | Mimo app/widget/build names, `com.mimo` app identity, `com.mimo.*` jobs/XPC endpoints, Mimo data/log directories, `mimo-manage` removal command and Mimo archive names. Old names are migration/cleanup inputs, not current branding. |
| **Shared machine state** | One core owns proxy configuration, credentials, allowlist, provider budget and routing state for all accounts; GUI clients and widgets read that shared state. |
| **Three routing modes** | Direct remains unproxied; Rule applies the profile; Global uses the proxy. Protected modes require an approved IPv4 and a nonempty allowlist. |
| **Permanent IPv4 policy** | IPv6 is disabled while installed, including Direct. IPv6 observations cannot approve traffic. Uninstall restores saved per-service IPv6 enabled flags. |
| **Private profile delivery** | Exact generated profile bytes are validated through stdin and reloaded through the authenticated controller. Profile Open/Reload actions remain available; a credential-free blocking profile is stored privately for startup. |
| **PF boot policy and repair** | Independent saved blocking rules and loader, PF/launchd health checks every ten seconds, service-intent repair and dashboard check ages. Boot protection starts when the loader actually runs. |
| **Protected verification** | Closed-gate private probes, approved IPv4, engine/profile binding, generation/revision checks, stale-result cancellation and full readiness checks. Warm optimistic reopening completes a bounded background audit; routine audit progress stays hidden, and failure remains visible. |
| **Concurrent checks and event scheduling** | Preparatory work overlaps PF closure; private probe access is installed under the PF mutation lock. Related route, interface, DNS, VPN, wake and session notifications share one verification cycle and one follow-up. Early callbacks wait for classification before approval: owned tunnel setup is discarded, real external changes retain the follow-up. An armed Direct-to-Rule/Global cycle takes precedence over the old Direct state when recording an external event. |
| **System event coverage** | Network path/configuration/routes, VPN/Tailscale, sleep/wake, display sleep/wake, login/logout, lock/unlock and active-user changes. AirPort telemetry, including timestamp-only AutoJoinTimestamp updates, is filtered before blocking; real connection changes remain monitored. Network-location apply timestamps are also filtered; actual location/unknown-field changes remain monitored. Direct ignores ordinary network/session events; routine checks and tailnet controls remain active. |
| **Workflow reference** | [Event-driven workflow documentation](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) maps OS events, user commands, timers, service faults and UI updates to their owners, traffic behavior, cancellation/coalescing rules, diagnostic records and tests. |
| **Lifecycle protection** | Rule/Global service/profile actions request blocking before mutation and show progress. Core/engine Start/Stop/Restart and service status are available; stopped intent is retained. |
| **Protected DNS** | Rule/Global direct system DNS to mihomo, intercept TUN DNS and restrict ordinary direct DNS. Full tailnet names retain the private Tailscale resolver. Status/heartbeat replies revoke Allowed immediately if the protected resolver entry is missing or changed, independently of the full audit. Restricted runtime/bootstrap exceptions and limitations are described in the failure analysis. |
| **Native Tailscale transport** | Uses the installed official Tailscale network extension, peer verification and relay recovery. Native Tailscale Connect/Disconnect and Mimo’s provider switch update the provider in place. The stable profile needs no reload, and Tailnet-only changes leave approved internet access open when the public proxy path is unchanged. The diagnostic endpoint is prepared when the provider starts; native observations and provider bytes are maintained ahead of verification. A protected profile loads only after the firewall policy and current provider publication have completed. The supervisor publishes mihomo's root-owned provider file only after applying the matching native firewall rules; the core cannot overwrite it with an independent observation. Missing native transport or a stopped provider publishes Reject. The diagnostic HTTP endpoint prefers loopback port 18766 and automatically binds a free loopback port if occupied; the dashboard shows the actual port. Runtime provider delivery remains independent of HTTP ports. The provider starts/restarts when the tailnet is active; an intentionally disconnected tailnet is not reported as a provider failure. |
| **Hostname bootstrap** | Protected bootstrap removes the prior TUN under a closed gate before using restricted resolver access. Successful hostname-proxy coverage remains subject to the recorded qualification limits. |
| **Password-free routine controls** | Installer-pinned GUI identity and separate XPC control endpoints authorize ordinary-account operations. Credentials do not travel in public state; root-only operations remain restricted. |
| **Dashboard** | Stable connection/status space, colored country/mode/blocked indicators, service icons, ports, PF/launchd health and relative check ages, the refresh interval alongside IP-check details, Refresh now, profile controls, routing/LAN/Tailscale notes below the proxy details, app version/build, uninstall instructions below proxy details and confirmation on every copy control. |
| **Settings and drafts** | Proxy, allowlist, monitoring and general settings; draft validation, empty-allowlist blocking, private credential entry and retained unsaved edits. |
| **Native macOS presentation** | Grayscale styling with Liquid Glass on supported systems, normal-window behavior, Dashboard/Settings tabs, appearance preferences, Finder/Dock icon consistency and keyboard shortcuts. Navigation, Refresh now and routing modes share one top row; uninstall instructions sit below the proxy details. |
| **Menu bar and widgets** | Country or globe fallback plus Direct/white Allowed indicator, colored blocked status, blocked-IP presentation, a status menu with shortcuts, a WidgetKit snapshot and macOS 26 Control Center entry. |
| **Monitoring and quotas** | Startup/manual/routine/event checks, provider rotation/cooldowns, daily budgets and stale/error state. Country is display-only metadata; a valid IP with unknown geography does not retry. Country highlights require an IP change. Failed lookup providers are excluded for eight hours and the next available provider is tried; a longer provider Retry-After is honored. Monitoring shows each pause reason and retry time. The UI shows each provider’s published quota, Mimo cap, usage and remaining allowance. |
| **Providers and credentials** | IPinfo Lite, ipapi.co, IPWho.is and ipapi.is support; shared IPinfo token and proxy password in the System Keychain, with explicit legacy personal-Keychain import support. |
| **Diagnostics** | Event Log merges core, supervisor and GUI records, including specific network/system triggers and audit failures. Native multiline selection, ⌘A/⌘C, Pause, Copy All and Copy Diagnostics preserve readable events and full diagnostic fields. Privacy-conscious runtime records, bounded commands, signature/startup verification, launch heartbeat, optional external launch traces and saved installation evidence. |
| **Recovery and upgrades** | Revision-fenced Direct recovery, stopped-service retention, staged service repair/rollback, settings/credential migration and retained-data reinstall. |
| **Clean uninstall** | Removes owned jobs, PF policy, login registrations/choices, private group/right, staged engine, generated secrets/caches and removal helpers. Restores networking. Settings, credentials and logs are retained. |
| **Existing-name migration** | Copies and verifies machine settings, service intent and credentials before retiring old records; migrates personal preferences/logs; removes the former login identity. A direct upgrade may retain one fixed compatibility bridge for Homebrew’s cached old uninstall hook. |

## Clean uninstall and reinstall

For a Homebrew installation:

```sh
brew uninstall --cask jxz345/tap/mimo
```

This stops all Mimo clients and owned services, unregisters GUI login items, clears their saved login choice, removes Mimo’s PF rules/boot policy and launchd jobs, deletes generated runtime files and the private group/authorization right, and restores the saved DNS/IPv6 configuration. It removes only Mimo’s protection; unrelated firewall rules and applications are not removed.

Homebrew removes mihomo when it is an unused dependency installed for Mimo. An explicitly installed package or one needed by another application remains. Shared proxy settings, allowlist, service intent, System Keychain credentials and logs are deliberately retained for reinstall. Reinstall resets the optional GUI login choice.

**Moving Mimo.app to Trash is not a clean uninstall.** The background services and firewall remain installed. Run the Homebrew command even if the app has already been deleted: the installer retains a sealed, root-owned cleanup copy for this case.

For a copied-app or package installation:

```sh
sudo /Library/PrivilegedHelperTools/mimo-manage uninstall
```

After cleanup succeeds, remove `/Applications/Mimo.app`. The installing account has a narrow grant for this exact removal command. Other accounts or a missing grant may require administrator authentication. The standalone manager leaves Homebrew package ownership alone.

Uninstall verifies cleanup and stops on failures; it does not reset the system-wide login-item database. `brew uninstall --zap` additionally removes the calling account’s presentation preferences, private profile files and logs; it does not erase shared machine settings or System Keychain credentials.

Older builds need the current installer to receive the updated cleanup behavior. Existing Homebrew installations should use the reinstall commands above. A direct replacement of an old installation retains a fixed, root-owned old-command bridge only when necessary for its cached uninstall hook; the bridge delegates to `mimo-manage` and is removed during uninstall. Fresh installs have no old-named helper.

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
| Live tailnet provider for mihomo | `/Library/Application Support/Mimo/Mihomo/proxy_providers/mimo-tailnet.yaml` (root-owned) |
| Saved PF/health material | `/Library/Application Support/Mimo/Guard/` |
| System logs | `/Library/Logs/Mimo/` |
| Personal files / logs | `~/Library/Application Support/Mimo/` |
| Preference domains | `com.mimo`, `group.com.mimo` |
| Machine Keychain service | `com.mimo.core` |
| DNS ownership key | `State:/Network/Service/com.mimo.dns/DNS` |
| Authorization right / removal grant | `com.mimo.configure`, `/etc/sudoers.d/mimo-service` |

Runtime/profile directories are private, and credentials remain in Keychain. Migration reads the old namespace, verifies new storage, then retires the old machine records. Unexpected user-added files are preserved under `Migrated`; colliding files are retained rather than overwritten. Old strings remain in explicit migration code and historical test evidence. See [naming migration](Design/MIMO_NAMING_MIGRATION.md).

The App Group default remains an unregistered development identifier. Ad-hoc packaging strips App Group entitlements; the widget reads the daemon over XPC. A developer-signed build requires a registered App Group and matching local signing configuration. Mimo does not claim Developer ID signing or notarization.

## Validation and known limits

Mimo **1.0 (build 2)** passes 210 shared tests, focused native-provider/coordinator/cycle/power checks, and installed-VM Rule tests for both native Tailnet Connect/Disconnect and Mimo provider Start/Stop. Those actions preserve public access without gate closure, exit-IP lookup or profile reload; full-name MagicDNS resolves over UDP/TCP. Two Direct-to-Rule transitions verify native prerequisites before profile preparation and open after one IP pass. Real route changes still block, including an attributed follow-up when a route changes during verification. The revised dashboard is installed in mimo-vm and has native light/dark and [long-message previews](Previews/mimo-dashboard-long-message.png). See [build 2 workflow evidence](Tests/ReleaseEvidence/mimo-build-2-workflows.json). Build 2 is available for physical-Mac testing; resolution of the reported MagicDNS failure remains unconfirmed.

Runtime, installation, networking and GUI validation take place **only in mimo-vm**. Delta is used for editing/building and SSH orchestration. The naming update has focused upgrade, credential/settings preservation, new service identity, dashboard-note and uninstall checks; older broad tests remain tied to their original artifact hashes.

The earlier DNS/provider update passed 204 shared tests and 19 focused installed-VM checks: full tailnet names in Rule/Global, UDP/TCP DNS, an occupied diagnostic port, core restart, native tailnet reconnect, resolver-loss recovery and original-settings restoration. Native light/dark dashboard layouts were also checked. The physical-Mac DNS listener recovered after Reload profile, but full-name MagicDNS still fails there: the loaded provider points to the live native interface while mihomo reports `connect: network is down` for TCP Quad100 DNS. The VM results do not qualify that unresolved physical-Mac failure. A physical Direct-to-Rule trace also contains a `Setup:` event during early preparation that incorrectly leaves an unattributed follow-up; the network-location filter and cycle attribution correction have separate [local-candidate qualification](Tests/ReleaseEvidence/mimo-network-location-candidate.json). That candidate passes 207 shared tests, focused cycle/power tests, and installed-VM transitions with real preference applies. Real route changes still block, and a mid-check route change retains an attributed follow-up. It is not published, and the physical-Mac failure is not claimed fixed.

The earlier accepted workflow’s warm route check opened at 3.708 seconds; Tailscale on/off measured 6.547/8.252 seconds. These are observations, not timing guarantees. Actual system sleep/wake, simultaneous GUI sessions, successful hostname-proxy coverage and peer UDP echo remain subject to the existing evidence limits. First-packet traffic before independent PF initialization is outside the guarantee.

- [Earlier MagicDNS/provider recovery evidence](Tests/ReleaseEvidence/mimo-magicdns-recovery.json)
- [Earlier naming-update evidence](Tests/ReleaseEvidence/mimo-naming-migration.json)
- [Previous clean-uninstall evidence](Tests/ReleaseEvidence/mimo-clean-uninstall.json)
- [Previous event scheduling evidence](Tests/ReleaseEvidence/mimo-event-scheduling.json)
- [Earlier full installed-VM coverage](Tests/ReleaseEvidence/MIMO_FINAL_COVERAGE.md)
- [Build 2 release evidence](Tests/ReleaseEvidence/mimo-build-2-workflows.json)

## Build and test

Authoritative source directories are `Sources/MimoShared`, `MimoCore`, `MimoService`, `MimoApp`, `MimoWidgets`, `MimoDaemon`, `MimoDiagnostics` and the small `MimoLegacyLoginCleanup` migration tool. Shared tests are under `Tests/MimoSharedTests`. `XcodeProject`, `.build` and `dist` are generated output.

Full app builds require Xcode and the macOS 26 SDK or newer. From the repository root:

```sh
bash Scripts/check-build-environment.sh --test
xcrun swift test
bash Scripts/generate-xcode-project.sh --force --open
xcodebuild -project XcodeProject/Mimo.xcodeproj -scheme Mimo -destination 'platform=macOS' build
```

For this project’s runtime campaign, run tests in mimo-vm. Do not install or exercise Mimo networking on Delta. The packager can build on Delta without installing services:

```sh
MIMO_RELEASE_REPO=jxz345/mimo bash Scripts/package-release.sh
```

Before publishing a new build, advance `Configuration/BuildNumber.txt` beyond the last GitHub build. Local rebuilds retain that number until publication; never upload different binaries under a previously published build number. Include “Mimo 1.0 (build N)” in the release notes and upload `release-build.json` alongside its matching artifacts and checksums.

It builds arm64, embeds the core and legacy-login removal tool, signs inside-out, validates signatures and emits `Mimo-1.0.zip`, `Mimo-1.0.pkg`, `install.sh`, `release-build.json`, `SHA256SUMS` and `mimo.rb`. Publishing is separate. The cask’s embedded cleanup is kept in sync with:

```sh
python3 Scripts/sync-homebrew-cleanup.py Packaging/mimo.rb.in
```

## Runtime diagnostics

Use the [event-driven workflow reference](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) to trace a trigger through classification, preparation, verification and recovery. It distinguishes installed supervisor observation from the shared engine's standalone observer, and actual gate transitions from display/log updates. Its [diagnostic table](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md#timing-and-diagnostic-reference) lists the records to correlate for each workflow.

`mimo_dns_configuration_lost` records a missing or changed protected resolver detected while publishing active status; traffic is blocked for verification. Provider port conflicts are recorded as `tailscale_provider_port_conflict`; `tailscale_provider_listening` records the actual port and whether fallback was used. Mihomo does not fetch provider data over HTTP, so another process on the preferred port cannot supply its route.

`tailscale_provider_prepared` records diagnostic endpoint readiness when the provider starts, outside the verification cycle. `mimo_native_provider_published` records a changed runtime provider after its native firewall update. `mimo_profile_prerequisites_ready` identifies the verification attempt whose firewall/provider prerequisites completed before profile loading; a failed prerequisite keeps application traffic blocked. Unchanged provider bytes are not rewritten on each native poll. `mimo_tailnet_configuration_updated` records private native configuration changes handled without a public-IP check; supplemental DNS domains are refreshed in place.

Open **Event Log** from the dashboard to view important UTC-stamped events. Drag across multiple lines, or press **⌘A** then **⌘C**. Incoming updates wait while text is selected, and scrolling up no longer snaps back to the bottom. **Pause** freezes the displayed history until **Resume**.

**Copy All** (**⇧⌘C**) copies readable events. For a repeated block/check/open cycle, use **Copy Diagnostics** (**⌥⌘C**): it includes recent full JSON records from the GUI, core and supervisor, including event names, trigger details, audit failures and selected/effective routing modes. Each source retains up to 500 records within a 256 KiB limit; missing or older services are identified explicitly. The usual IP-address redaction setting still applies. **Show Log Files** opens the GUI log folder; the shared service logs are in `/Library/Logs/Mimo`. Diagnostic traces and evidence may include network metadata; review them before sharing.

A GUI-only `mimo_access_presentation_changed` log describes what was displayed, not what triggered a verification cycle. Routine Direct IP checks keep `blocked:false`; Rule/Global cycle diagnosis needs the core/supervisor records. This diagnostic update does not change firewall or event-handling policy.

`Check trigger` identifies configuration keys, route/address/interface changes (interface and originating PID), session events or recovery. Audit failures include their reason. Long messages wrap; Copy All includes the supervisor's records. `lookup_country_unknown` and `location_metadata_changed` explain a globe or country display update without scheduling another check. `mimo_network_changed`, `mimo_verification_audit_failed` and `mimo_liveness_lost` identify real re-verification causes. The notification filters suppress recognized owned tunnel/DNS updates and validated private Tailnet changes that cannot affect the public proxy path; during a protected cycle, external events are merged into one follow-up instead of interrupting the current work. A changed network prevents the current result from opening PF. Owned notifications are discarded. Human controls wait for the cycle and run in arrival order; mode buttons apply to the latest configuration, while full settings edits retain revision conflict checks. No PF/lifecycle lock is held while controls wait.

Focused manual check: keep the exit IP fixed while country data becomes unknown or differs between providers. The icon must update without another confirmation/retry; Rule/Global stay allowed only for an approved IP. Then change a real network setting in Rule/Global and verify that the Event Log names the trigger and protected verification still runs. During that check, queue a mode selection and verify it runs afterward. In Direct, ordinary system/network events must not request a lookup. A failed provider must rotate, retain its eight-hour pause after restart, and show the reason/time in Monitoring.

MagicDNS check: in Rule and Global, resolve an online peer's full tailnet hostname through macOS and through `127.0.0.1:1053` over UDP/TCP. A public name returning `198.18.x.x` confirms mihomo's synthetic DNS response, not MagicDNS. Shared nodes require their full tailnet names. If another application owns port 18766, the dashboard must show Mimo's fallback port and tailnet resolution must still work through the private provider file. The DNS listener remains on port 1053; the HTTP fallback does not change it.

Live Tailnet check: while Rule is allowed, stop/start the provider in Mimo and disconnect/reconnect native Tailscale. Confirm the private provider changes Reject → Direct, full-name MagicDNS recovers, and no gate closure, exit-IP lookup or profile reload occurs. Enabling an exit node or subnet route must still request verification.

Profile-order check: switch Direct → Rule, then reload the profile. For each attempt, confirm the probe firewall is installed and `mimo_profile_prerequisites_ready` precedes `mimo_final_profile_loaded`/`mimo_final_profile_reused`. The private provider's interface must match the native PF anchor and live Quad100 route. Stop the provider and confirm its private payload becomes Reject; restart it with port 18766 occupied and confirm the fallback endpoint and full-name DNS work before repeating the transition.

| Event family | Meaning |
| --- | --- |
| `mimo_startup_guard_closed`, `mimo_pf_policy_installed` | Startup protection or a PF policy change. |
| `mimo_native_provider_published`, `mimo_profile_prerequisites_ready`, `mimo_tailnet_configuration_updated` | Native firewall/provider publication, profile prerequisite completion and live private Tailnet updates. |
| `mimo_exit_rejected`, `mimo_profile_verified` | Exit/profile verification results; protected traffic stays closed on rejection. |
| `mimo_direct_restored`, `mimo_direct_recovery_saved` | Explicit unproxied IPv4 recovery; IPv6 remains disabled until uninstall. |
| `mimo_installed_app_control_ready`, `mimo_installed_app_control_unavailable` | Installer-pinned GUI control endpoint availability. |
| `login_item_synced`, `keychain_operation` | Per-account login synchronization and credential-operation status, without credential values. |

Installation/removal commands also log bounded steps and explicit failures. Removal does not infer user intent from an app disappearing: only an explicit uninstall restores networking and removes protection.

Latest focused qualification: [country, event-cycle and provider-pause evidence](Tests/ReleaseEvidence/mimo-country-events.json). [Monitoring pause example](Previews/mimo-monitoring-provider-pause.png) and [menu fallback examples](Previews/mimo-menu-country-fallback.png) use fixture data.

Event Log update: [focused validation and current investigation limit](Tests/ReleaseEvidence/mimo-event-log.json), with a [native copy-window preview](Previews/mimo-event-log-copy.png).

AirPort regression check: with the same Wi-Fi association, AutoJoinTimestamp-only, timestamp-plus-Busy and scan/radio updates must produce `network_airport_telemetry_ignored` and no block/check/open cycle. A changed SSID/BSSID, power state, removed key, unreadable value or unknown changed field remains conservative and may trigger verification. `network_airport_connection_changed` names the changed fields without recording their values. Actual route changes still close protected traffic. The VM test replays these through real configd notifications; physical Wi-Fi roaming remains a separate acceptance check.

AirPort timestamp correction and dashboard update: [before/after installed-release evidence](Tests/ReleaseEvidence/mimo-airport-timestamp.json). The earlier filter omitted AutoJoinTimestamp; the reported 20-second updates therefore still triggered cycles. Only that named metadata field is newly ignored. Unknown fields and actual association/power changes remain protected.

Network-location regression check: reapply unchanged network preferences during Direct-to-Rule preparation. `network_location_metadata_ignored` must identify only `LastUpdated` or unchanged data, with one exit-IP pass. A real location change or unknown root-field change emits `network_location_changed`; an external event during early preparation must retain its source in `mimo_cycle_event_deferred` and the follow-up. Filtering the root key does not suppress other DNS, IP, proxy, service-order or interface keys in the same notification batch.

Current transition/copy update: [focused installed-release evidence](Tests/ReleaseEvidence/mimo-cycle-classification.json). `mimo_cycle_owned_event_ignored` records an early notification later confirmed as Mimo’s own tunnel/configuration update. Such a notification cannot leave a follow-up flag; unresolved or genuine external notifications still prevent stale approval. To check the UI, compare Allowed during/after a background audit and verify a failed audit still shows blocking; copy an IP, profile path, uninstall command and each Event Log export, checking both contents and feedback.
