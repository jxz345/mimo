# Mimo for macOS

Install **Mimo v2.0 (build 6)** with Homebrew:

```sh
brew trust --formula jxz345/tap/mihomo@1.19.34
brew install --cask jxz345/tap/mimo
open /Applications/Mimo.app
```

The fully qualified install finds the repository automatically. The first command trusts only the pinned mihomo dependency, so Homebrew can install it as a dependency rather than an explicitly requested package. Homebrew 6 and later require trust for non-official packages; the fully qualified cask install trusts Mimo itself. [Homebrew’s trust documentation](https://docs.brew.sh/Tap-Trust).

Requires an **Apple silicon Mac with macOS 14 or later**. Control Center integration requires macOS 26. Installation includes tested **mihomo 1.19.34** and requests administrator authentication for the machine-wide services. Routine routing and settings controls need no administrator password. Full Stop and Activate use administrator authentication. Rule/Global capture IPv6 in the TUN and reject it in the profile. Mimo does not disable macOS IPv6; upgrade, Direct, Stop and uninstall restore IPv6 settings saved by older builds.

The updated [service installer](Sources/MimoDaemon/daemon.sh) handles a running Clash/mihomo engine by listing its executable/PID and any matching launchd service, then asking **Stop and Continue**. In a foreground terminal, answer `y`; Homebrew, package and GUI installs without terminal input show a macOS dialog. Cancel, no response within 60 seconds, or unavailable confirmation leaves the competing engines running. Approval replaces the listed running engines: it disables and unloads their identified launchd jobs, stops standalone processes, verifies exit, then continues setup. Disabled jobs cannot restart automatically at login/reboot. Apps, configuration and startup files are retained. If a proxy restarts its engine, quit that app/service and retry; the installer does not kill unapproved replacement processes. If installation later fails, re-enable the other proxy through its app or service manager if you want to restore it.

To repair a current **2.0** app whose bundle includes `release-network.pl`, without modifying its bundle, save the linked installer as `install-mimo-services.sh` and run:

```bash
sudo /bin/bash ~/Downloads/install-mimo-services.sh install --app /Applications/Mimo.app
```

Signature, pinned-engine checksum and staging checks run before the stop prompt. `install --non-interactive` explicitly refuses conflicts without asking or stopping anything; it does not authorize stopping another proxy.

[Installer takeover validation](Tests/ReleaseEvidence/mimo-installer-takeover.json) records the standalone script hash, VM confirmation/launchd/repair checks and test limits. Physical Homebrew confirmation remains pending.

To upgrade, update the tap and install the current release:

```sh
brew update
brew trust --formula jxz345/tap/mihomo@1.19.34
brew fetch --force --cask jxz345/tap/mimo
brew upgrade --cask jxz345/tap/mimo
```

[Download v2.0 build 6](https://github.com/jxz345/mimo/releases/tag/v2.0-build.6) · [What is implemented](#what-is-implemented) · [Event-driven workflows](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) · [Clean uninstall](#clean-uninstall-and-reinstall) · [Protection limits](#modes-and-protection)

The `v2.0-build.6` tag identifies build 6; each build has its own release URL. Homebrew tracks both version and build (`2.0,6`), so `brew upgrade` detects a new build even when the marketing version is unchanged. Packages are `Mimo-2.0.zip` and `Mimo-2.0.pkg`. The installed app is `Mimo.app`; its executables are `mimo-gui` and `mimo-core`.

## First launch

1. Open Mimo. If installation authentication was cancelled, use **Install Service** or **Repair Service** to finish setup.
2. Configure the shared proxy in **Settings → Proxy**. Credentials are stored in the System Keychain.
3. Add approved IPv4 addresses in **Settings → Allowed IPs** before selecting Rule or Global.
4. Select Direct, Rule or Global on the Dashboard. Use **Refresh now** for a manual check.
5. Optionally enable **Open Mimo at login** in Settings → General. This starts only this account’s GUI. The shared services are managed independently by launchd.

The release is ad-hoc signed, not notarized. Homebrew checks the sealed signature and removes quarantine from this app only; it does not disable Gatekeeper. Copied-app/package installations may require macOS’s Open Anyway approval. If macOS parks an approval before startup, lock and unlock the screen, then reopen the app. Use the bundled `diagnose-launch.sh --launch` to collect a bounded startup trace.

Mimo’s required supervisor and PF boot policy run independently of the GUI. Closing the window or quitting Mimo does not stop shared protection. The **Stop engine and use Direct** action removes Mimo’s background installation and network controls while preserving saved settings; ordinary Direct keeps the engine available but releases Mimo’s packet filtering and DNS override.

## Modes and protection

| Mode | Behavior |
| --- | --- |
| **Direct** | Keeps the engine available with native system networking and no Mimo packet filtering. IP checks and network/session events do not block internet access or enforce the allowlist. |
| **Rule** | Applies the saved profile’s routing rules. An empty allowlist, invalid configuration or unapproved exit IPv4 keeps public traffic blocked. |
| **Global** | Sends traffic through the proxy, with the same allowlist and verification requirements as Rule. |

Protected transitions show **Blocking → Blocked/Checking → Allowed**. Once allowed, routine background audits do not change the dashboard/menu icon or status; audit failures still block traffic and show their cause. The last observed exit IP remains visible when it caused blocking. Direct shows its current IP and country with the Direct indicator. Menu-bar colors and dashboard status reflect the shared service state.

Country is display metadata. A valid exit IP remains valid when a provider cannot identify its country; the menu bar shows a globe. Country-only changes never request another lookup, confirmation or block/open cycle. The Allowed shield is white. Rule/Global still require the actual IPv4 address to be allowlisted, and real network/system events still trigger protected verification in Rule/Global. AirPort scan/radio status notifications are compared before the early firewall callback. Unchanged values and known telemetry (AutoJoinTimestamp, Busy, signal/noise, channel and scan records) do not start a cycle. The `Setup:` network-location root is also compared before early blocking: an unchanged location with only a `LastUpdated` timestamp change is ignored. Missing location data, a changed location, and unknown root-field changes still trigger verification. Wi-Fi power, association and unknown field changes still trigger protection; public IP, DNS, proxy, route, link and VPN changes retain protection. Private Tailnet connect/disconnect notifications can update in place when the verified proxy uses a separate public interface; exit-node, subnet-router, unknown and public-network changes still require verification. Ordinary network/session/wake events are ignored in Direct; startup, manual/routine IP checks, tailnet integration and PF/launchd health monitoring remain available.

The supervisor closes PF on detected protected-mode changes, prepares restricted private verification access and checks the exit IP before reopening. An unchanged configuration with a valid full-verification baseline may use the agreed optimistic path: essential live checks and an approved IPv4 first, then a fuller background audit. An audit failure or deadline requests blocking and full recovery. Active PF does not enforce routes or interface-bound traffic: the profile only governs traffic reaching Mihomo. More-specific routes or another VPN can bypass the TUN; fault detection is asynchronous and can leave a window before blocking. This is a transition guard, not a continuous system-wide kill switch.

PF has a saved boot policy and a separate launchd loader/health monitor. **Traffic before that loader runs is outside the protection guarantee.** Detection of network/session events is asynchronous. Mimo does not claim a macOS Always On VPN or a zero-packet boot barrier. See the [current event workflows](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md), [design history](MIMO_PLAN.md) and [failure analysis](Design/MIMO_FIREWALL_AND_FAILURE_SCENARIOS.md).

## Dashboard and Settings

The [interactive mockup](https://mimo-dashboard-design-jay.nativebadger32.chatgpt.site) shows the Dashboard and Settings layout. Dashboard / Settings, Refresh now and Direct / Rule / Global remain in the top toolbar. Route details remain inside Proxy configuration. The six background-service rows retain equal 60-point heights, aligned health columns, original controls and configured endpoints. Settings keeps the native sidebar, single-column proxy form, provider quota table, and grouped preferences. The new features are the Rule-only Bypass editor and explicit cleanup/activation action. The footer retains Event Log, version/build and Quit GUI. The short cleanup copy is “Stop the engine and release network controls.” Browser controls outside the app frame only operate the simulation.

Settings contains **Proxy**, **Bypass**, **Allowed IPs**, **Monitoring**, and **General**. Proxy uses a network icon; Bypass uses a branching-route icon. Proxy and bypass drafts survive status updates and tab changes. General contains login launch, appearance and clean-uninstall instructions. Monitoring contains provider choice, quotas, refresh policy and events.

### Stop engine and use Direct

This action runs through the privileged installer to remove all Mimo services, login items and owned network controls while keeping the GUI and saved settings. The confirmed completed state is **Monitoring only**, with PF **Released** and launchd/services **Removed**. Exit IP monitoring continues in the active account’s open GUI, using anonymous providers and the saved refresh interval. It follows system networking (including another VPN), performs no firewall or routing mutations, and stops when that GUI quits or its account becomes inactive. No daemon or machine credential is retained for monitoring. Only confirmed cleanup makes `/Applications/Mimo.app` safe to delete. Cleanup progress or a communication error must not claim completion.

The same button becomes **Activate Mimo**, which restores all daemons in ordinary Direct. Occupied resources use the installer's identified-conflict **Cancel / Stop and Continue** prompt. Ordinary Direct selection keeps the engine running and does not perform full cleanup. Reinstalling or upgrading an inactive app keeps it inactive, even if another engine is running. Failed activation restores inactive networking. Installed cleanup, activation, conflict handling and reboot checks are recorded in the [2.0 release evidence](Tests/ReleaseEvidence/mimo-build-5-v2.json).

### Edit Rule bypass blocks

Open **Settings → Bypass** to add, rename, enable/disable or remove a block, and edit its domains. Choose **Exact** for one hostname or **Suffix** for that domain and its subdomains; enter plain DNS names without schemes, ports or wildcards. New installations and older settings start with the existing website blocks. Removing every block is saved as an explicit empty list and does not restore defaults.

**Apply** validates and saves the machine-wide draft; **Cancel** reloads saved values. If another account changed shared settings, reload before applying rather than overwriting its revision. Applying in Rule starts protected verification with the new rules. Applying in Global or ordinary Direct saves for the next Rule activation without starting the engine or changing current routing. Fully inactive Mimo retains drafts; activate it before applying shared settings. Managed Tailscale, LAN and final routing rules retain their precedence and are not editable as website bypass blocks.

Copy icons briefly show a checkmark after success; Event Log’s Copy All/Copy Diagnostics buttons show “Copied” without moving nearby controls.

All six monitoring rows use the same status-and-age format, for example **Healthy(3 secs)**. The age comes from the last inspection and advances every second; receiving or redrawing a cached reply does not reset it. A running service report older than 35 seconds becomes **Stale(n secs)**. Stopped, suspended, released and failed services retain their actual status, and a missing inspection time appears as **Unavailable(—)**. These labels describe the recorded checks, not a fresh end-to-end connectivity test. [Healthy rows](Previews/mimo-dashboard-health-light.png) · [Stale service reports](Previews/mimo-dashboard-health-stale-dark.png).

Queued controls and held events appear in Event Log (`mimo_control_queued`, `mimo_control_resumed`, `mimo_cycle_event_deferred`). Provider failures record `provider_failure_paused` with their reason and resume time. Rule/Global remain blocked if all available providers fail; Direct stays open.


## Firewall ownership and manual inspection

All packet rules generated by current Mimo builds have persistent PF labels beginning `mimo:`. Labels describe purpose: `mimo:transition:deny`, `mimo:transition:public-listeners`, `mimo:transition:local-control`, `mimo:transition:dhcp`, `mimo:transition:ipv6-link-control`, `mimo:probe:proxy` and `mimo:probe:bootstrap-doh`. Generated files also contain context comments. PF omits comments on readback, but keeps labels. Inspect only Mimo’s anchor tree:

```sh
sudo pfctl -a 'com.apple/000.mimo' -s Anchors
sudo pfctl -a 'com.apple/000.mimo' -sr
sudo pfctl -a 'com.apple/000.mimo/power-guard' -vvsr
sudo pfctl -a 'com.apple/000.mimo/probe-policy' -vvsr
```

During normal Rule/Global operation, the parent calls only the empty `power-guard` child. Stored probe rules are unreachable. During verification, the barrier blocks application traffic (including the TUN, LAN and native Tailnet), permitting local control, DHCP/IPv6 link control and only the installed runtime group’s TCP verification endpoint. Approval atomically removes that barrier. Closing a transition also clears existing IPv4/IPv6 PF states so old connections cannot escape the barrier; this can interrupt connections belonging to other applications.

The persistent boot entry is the marked `MIMO BOOT GUARD` block in `/etc/pf.conf`, loading `/etc/pf.anchors/com.mimo.boot`. Stop/uninstall remove it, all descendants of `com.apple/000.mimo`, owned PF references, and `State:/Network/Service/com.mimo.dns/DNS`. Cleanup uses exact ownership paths, **not labels**, so older unlabeled rules are included. Use the [network recovery script](#recover-leftover-network-controls) after stopping Mimo services rather than disabling PF globally. An empty anchor name may remain in PF after its rules are removed; that is not an active block.

## What is implemented

| Feature | Behavior |
| --- | --- |
| **Homebrew distribution** | Mimo v2.0 (build 6), Apple silicon only, with the pinned mihomo 1.19.34 formula, checksum verification, normal install/reinstall/uninstall and standalone ZIP/package installers. The updated service installer asks before stopping conflicting Clash/mihomo engines, verifies their exit and then continues; cancellation preserves them. A standalone repair can use the existing sealed app. |
| **Release build identity** | Each GitHub upload receives a distinct increasing build number while the marketing version stays unchanged. The dashboard, diagnostics and release manifest identify the exact build. |
| **Consistent Mimo identity** | Mimo app/widget/build names, `com.mimo` app identity, `com.mimo.*` jobs/XPC endpoints, Mimo data/log directories, `mimo-manage` removal command and Mimo archive names. Old names are migration/cleanup inputs, not current branding. |
| **Shared machine state** | One core owns proxy configuration, credentials, allowlist, provider budget and routing state for all accounts; GUI clients and widgets read that shared state. |
| **Three routing modes** | Direct remains unproxied; Rule applies the profile; Global uses the proxy. Protected modes require an approved IPv4 and a nonempty allowlist. |
| **Profile-owned traffic policy** | Rule/Global routing, website bypass, DNS and IPv6 rejection are implemented by the Mihomo profile. Both address families enter TUN; IPv6 is rejected there, not disabled in macOS. Direct removes Mimo packet restrictions. Upgrade and cleanup restore older saved IPv6 flags. |
| **Private profile delivery** | Exact generated profile bytes are validated through stdin and reloaded through the authenticated controller. Profile Open/Reload actions remain available; a credential-free blocking profile is stored privately for startup. |
| **Transition firewall and boot recovery** | A labeled, default-deny PF barrier covers startup, verification, changes and detected failures. Active Rule/Global retain only an empty emergency anchor; the profile owns normal packet handling. A persistent boot guard and ten-second PF/launchd checks remain until Stop/uninstall. Every generated packet rule has a `mimo:` context label. |
| **Protected verification** | Closed-gate private probes, approved IPv4, engine/profile binding, generation/revision checks, stale-result cancellation and full readiness checks. Warm optimistic reopening completes a bounded background audit; routine audit progress stays hidden, and failure remains visible. |
| **Concurrent checks and event scheduling** | Preparatory work overlaps PF closure; private probe access is installed under the PF mutation lock. Related route, interface, DNS, VPN, wake and session notifications share one verification cycle and one follow-up. Early callbacks wait for classification before approval: owned tunnel setup is discarded, real external changes retain the follow-up. An armed Direct-to-Rule/Global cycle takes precedence over the old Direct state when recording an external event. |
| **System event coverage** | Network path/configuration/routes, VPN/Tailscale, sleep/wake, display sleep/wake, login/logout, lock/unlock and active-user changes. AirPort telemetry, including timestamp-only AutoJoinTimestamp updates, is filtered before blocking; real connection changes remain monitored. Network-location apply timestamps are also filtered; actual location/unknown-field changes remain monitored. A native DNS selection carrying configd’s interface index is accepted only when it matches the current native interface; wrong indices, changed DNS servers and unknown fields still require verification. Direct ignores ordinary network/session events; routine checks and tailnet controls remain active. |
| **Workflow reference** | [Event-driven workflow documentation](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) maps OS events, user commands, timers, service faults and UI updates to their owners, traffic behavior, cancellation/coalescing rules, diagnostic records and tests. |
| **Lifecycle protection** | Protected service/profile mutations confirm blocking; explicit engine Stop instead leaves protected mode and performs network release. Intent, confirmed cleanup and communication state remain distinct. Unexpected engine failure still closes protected access. |
| **Deactivation and coexistence** | Explicit Stop invokes full privileged cleanup of all Mimo services/login items and network controls. Confirmed completion reports Monitoring only and makes the app safely deletable. The open GUI continues anonymous exit IP checks. Stop and uninstall remove previous-version PF policies, refresh system DNS and verify connected native Tailnet DNS; Event Log records verified stages. Activate Mimo restores all daemons in Direct and uses installation conflict confirmation. Reinstall preserves inactivity; failed activation restores inactive networking. Installed VM round trips and coexistence are tested. |
| **Editable Rule bypass** | Machine-wide named domain blocks with exact/suffix entries, add/edit/delete and per-block enable switches. Validated Apply/Cancel drafts and revision conflicts; existing defaults migrate without changing managed network rules. Global ignores these website bypasses. |
| **Protected DNS** | A temporary macOS resolver sends system lookups to `127.0.0.1:1053`; profile DNS sends `.ts.net` through the native provider and public DNS through the proxy. TUN intercepts TCP/UDP DNS. Native search domains are preserved. No steady PF DNS block or Quad100 exception is installed. Direct, Stop and uninstall remove and verify removal of Mimo’s resolver, including older persistent entries. |
| **Native Tailscale transport** | Uses the installed official Tailscale network extension, peer verification and relay recovery. Native Tailscale Connect/Disconnect and Mimo’s provider switch update the provider in place. The stable profile needs no reload, and Tailnet-only changes leave approved internet access open when the public proxy path is unchanged. The diagnostic endpoint is prepared when the provider starts; native observations and provider bytes are maintained ahead of verification. A protected profile loads only after the firewall policy and current provider publication have completed. The supervisor publishes mihomo's root-owned provider file after verifying the native interface; provider updates do not write PF rules. The core cannot overwrite it with an independent observation. Missing native transport or a stopped provider publishes Reject. The diagnostic HTTP endpoint prefers loopback port 18766 and automatically binds a free loopback port if occupied; the dashboard shows the actual port. Runtime provider delivery remains independent of HTTP ports. The provider starts/restarts when the tailnet is active; an intentionally disconnected tailnet is not reported as a provider failure. |
| **Hostname bootstrap** | Protected bootstrap removes the prior TUN under a closed gate before using restricted resolver access. Successful hostname-proxy coverage remains subject to the recorded qualification limits. |
| **Password-free routine controls** | Installer-pinned GUI identity and separate XPC control endpoints authorize ordinary-account operations. Credentials do not travel in public state; root-only operations remain restricted. |
| **GUI communication** | Background processes own supervision, health inspection and firewall enforcement; the GUI displays their reports. A lost connection shows **Service communication interrupted**, **No connection**, the last reply age and **Reconnect**. A fresh independent supervisor reply can still show process/PF health; a running core process is labeled Running without claiming its connection is healthy. Read-only state probes have a 3-second deadline and coalesce. Account deactivation pauses subscriptions/polling; return recreates the subscription immediately. No lookup or service restart is requested by reconnecting. |
| **Per-account login item** | Cached status and a serialized background worker keep macOS login-item queries and registration off the GUI thread. View construction never synchronously queries Background Task Management. Inactive windows do not reposition or request deferred activation. |
| **Dashboard** | Stable connection/status space, colored country/mode/blocked indicators, service icons and ports, equal-height monitoring rows with uniform `Healthy(n secs)` inspection ages, overdue inspection reporting and separate communication-loss status, the refresh interval alongside IP-check details, Refresh now, profile controls, routing/LAN/Tailscale details inside the proxy section, explicit Stop/Activate controls, Rule bypass summary, app version/build and confirmation on every copy control. |
| **Settings and drafts** | Proxy and Bypass with distinct icons, allowlist, monitoring and general settings; draft validation, empty-allowlist blocking, private credential entry and retained unsaved edits. |
| **Native macOS presentation** | Grayscale styling with Liquid Glass on supported systems, normal-window behavior, Dashboard/Settings tabs, appearance preferences, Finder/Dock icon consistency and keyboard shortcuts. The toolbar groups navigation, Refresh now and modes together; Settings retains its sidebar, single-column proxy form, provider table and grouped preferences. Uninstall help lives in General. |
| **Menu bar and widgets** | Country or globe fallback plus Direct/white Allowed indicator, colored blocked status, blocked-IP presentation, a status menu with shortcuts, a WidgetKit snapshot and macOS 26 Control Center entry. |
| **Monitoring and quotas** | Startup/manual/routine/event checks, provider rotation/cooldowns, daily budgets and stale/error state. Country is display-only metadata; a valid IP with unknown geography does not retry. Country highlights require an IP change. Failed lookup providers are excluded for eight hours and the next available provider is tried; a longer provider Retry-After is honored. Monitoring shows each pause reason and retry time. The UI shows each provider’s published quota, Mimo cap, usage and remaining allowance. |
| **Providers and credentials** | IPinfo Lite, ipapi.co, IPWho.is and ipapi.is support; shared IPinfo token and proxy password in the System Keychain, with explicit legacy personal-Keychain import support. |
| **Diagnostics** | Event Log merges core, supervisor and GUI records, including specific network/system triggers and audit failures. Native multiline selection, ⌘A/⌘C, Pause, Copy All and Copy Diagnostics preserve readable events and full diagnostic fields. Privacy-conscious runtime records, bounded commands, signature/startup verification, launch heartbeat, optional external launch traces and saved installation evidence. A standalone MagicDNS comparison checks native DNS and installed/fresh Mihomo instances without changing the active configuration. Temporary firewall tests check the Quad100 correction, including repeated fresh queries through the live native policy, and restore their changes with an independent watchdog. A read-only service snapshot compares process/job state, controller/listeners, service intent, gate and resolver when the dashboard conflicts with command output. |
| **Recovery and upgrades** | Revision-fenced Direct recovery, stopped-service retention, staged service repair/rollback, settings/credential migration and retained-data reinstall. |
| **Clean uninstall** | On success, removes owned jobs, PF policy, login registrations/choices, private group/right, staged engine, generated secrets/caches and removal helpers, and restores networking. Settings, credentials and logs are retained. The [network recovery script](#recover-leftover-network-controls) removes older Mimo firewall policies and verifies native Tailnet DNS after services stop. |
| **Existing-name migration** | Copies and verifies machine settings, service intent and credentials before retiring old records; migrates personal preferences/logs; removes the former login identity. A direct upgrade may retain one fixed compatibility bridge for Homebrew’s cached old uninstall hook. |

## Clean uninstall and reinstall

For a Homebrew installation:

```sh
brew uninstall --cask jxz345/tap/mimo
```

On success, this stops all Mimo clients and owned services, unregisters GUI login items, clears their saved login choice, removes Mimo’s PF rules/boot policy and launchd jobs, deletes generated runtime files and the private group/authorization right, removes the Mimo DNS override, and restores saved IPv6 service flags. It removes only Mimo’s protection; unrelated firewall rules and applications are not removed.

Homebrew removes mihomo when it is an unused dependency installed for Mimo. An explicitly installed package or one needed by another application remains. Shared proxy settings, allowlist, service intent, System Keychain credentials and logs are deliberately retained for reinstall. Reinstall resets the optional GUI login choice.

**Moving Mimo.app to Trash is not a clean uninstall.** The background services and firewall remain installed. Run the Homebrew command even if the app has already been deleted: the installer retains a sealed, root-owned cleanup copy for this case.

For a copied-app or package installation:

```sh
sudo /Library/PrivilegedHelperTools/mimo-manage uninstall
```

After cleanup succeeds, remove `/Applications/Mimo.app`. The installing account has a narrow grant for this exact removal command. Other accounts or a missing grant may require administrator authentication. The standalone manager leaves Homebrew package ownership alone.

Uninstall verifies cleanup and stops on failures; it does not reset the system-wide login-item database. `brew uninstall --zap` additionally removes the calling account’s presentation preferences, private profile files and logs; it does not erase shared machine settings or System Keychain credentials.

Older builds need the current installer to receive the updated cleanup behavior. Existing Homebrew installations should use the reinstall commands above. A direct replacement of an old installation retains a fixed, root-owned old-command bridge only when necessary for its cached uninstall hook; the bridge delegates to `mimo-manage` and is removed during uninstall. Fresh installs have no old-named helper.

### Recover leftover network controls

The updated cleanup enumerates **all descendants of `com.apple/000.mimo`**, including old or unreferenced child anchors. It clears Mimo's filter/NAT rules and tables, verifies the remaining policies are empty, removes the persistent boot entry and resolver, releases only Mimo's recorded PF references, and restores saved IPv6 flags. It does not disable PF globally, flush global connection state, or change another VPN's rules.

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

**Mimo 2.0 (build 6)** passes 227 shared tests, 13 native service groups, 13 native GUI groups, 18 network-cleanup checks, 27 PF-guard checks and the installer/daemon contracts. Installed VM checks cover empty active Rule/Global policies, both TUN address families, actual IPv6 TLS rejection, HTTPS, repeated fresh MagicDNS lookups, warm verification, mode switching and full Stop with old firewall descendants. Legacy-cleanup fixtures restore native Tailnet DNS while preserving unrelated firewall rules, references and DNS settings. Real Homebrew installation preserves inactivity; uninstall from a closed Rule transition removes the app, helpers, all jobs, old PF descendants and DNS controls, then restores native HTTPS and Tailnet DNS. Closed-transition tests reject IPv4/IPv6 HTTPS and public UDP DNS. See [build 6 release evidence](Tests/ReleaseEvidence/mimo-build-6.json) and the monitoring-only [light](Previews/mimo-monitoring-only-light.png) / [dark](Previews/mimo-monitoring-only-dark.png) screenshots.

Some VM runs encountered intermittent exit-IP TLS/timeouts and remained blocked; a complete run passed without changing the app. The cause of that intermittent transport failure is not established. These VM checks do not establish universal VPN compatibility, first-packet boot protection or physical sleep/account-switch behavior.

Runtime, installation, networking and GUI validation take place **only in mimo-vm**. Delta is used for editing/building and SSH orchestration.

| Manual check | Expected result |
| --- | --- |
| Stop from Rule/Global/Direct | Full uninstall completes; all Mimo jobs are absent, old/new PF child policies are empty, saved IPv6 settings restored, DNS refreshed and connected Tailnet DNS verified. |
| Tailnet after Stop or uninstall | Connect by full MagicDNS name and a peer's native address; confirm Event Log's native DNS result. Peer access policies remain Tailscale's responsibility. |
| Keep GUI open after Stop | Current IP/country refresh locally; background services remain Removed; changing another VPN updates the observed exit. |
| Reopen or reboot after Stop | No Mimo network controls return; opening the GUI starts monitoring only. Activate explicitly to restore daemons. |
| Activate with occupied resources | Cancel / Stop and Continue identifies the conflict; cancellation preserves the other service. |
| Edit bypass and Apply in Rule | New connections follow the reloaded rules after verification. Global/ordinary Direct save for the next Rule activation. |
| Cleanup failure | Show incomplete cleanup and retain recovery files; never claim the app is safe to delete. |

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

Before publishing a new build, advance `Configuration/BuildNumber.txt` beyond the last GitHub build. Local rebuilds retain that number until publication; never upload different binaries under a previously published build number. Include “Mimo VERSION (build N)” in the release notes and upload `release-build.json` alongside its matching artifacts and checksums.

It stages the package without copying extended attributes; macOS can still add provenance metadata locally, which is inspected alongside sealed-signature verification. It builds arm64, embeds the core and legacy-login removal tool, signs inside-out, validates signatures and emits `Mimo-2.0.zip`, `Mimo-2.0.pkg`, `install.sh`, `release-build.json`, `SHA256SUMS` and `mimo.rb`. Publishing is separate. Each build uses an immutable tag such as `v2.0-build.6`; the Homebrew cask version includes both the marketing version and build (`2.0,6`). The cask’s embedded cleanup is kept in sync with:

```sh
python3 Scripts/sync-homebrew-cleanup.py Packaging/mimo.rb.in
```

## Runtime diagnostics

`mimo_network_released` is emitted only after the engine, listeners, protected resolver, owned PF and IPv6 cleanup checks succeed. Pair it with the supervisor’s `networkReleaseRequested`/`networkReleased` fields and service reports; requested intent alone is not proof of cleanup. Failed cleanup remains unavailable with its reason and can be retried.

Use the [event-driven workflow reference](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) to trace a trigger through classification, preparation, verification and recovery. It distinguishes installed supervisor observation from the shared engine's standalone observer, and actual gate transitions from display/log updates. Its [diagnostic table](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md#timing-and-diagnostic-reference) lists the records to correlate for each workflow.

`mimo_dns_configuration_lost` records a missing or changed protected resolver detected while publishing active status; traffic is blocked for verification. Provider port conflicts are recorded as `tailscale_provider_port_conflict`; `tailscale_provider_listening` records the actual port and whether fallback was used. Mihomo does not fetch provider data over HTTP, so another process on the preferred port cannot supply its route.

`tailscale_provider_prepared` records diagnostic endpoint readiness when the provider starts, outside the verification cycle. `mimo_native_provider_published` records a changed runtime provider after native interface verification, without a PF update. `mimo_profile_prerequisites_ready` identifies the verification attempt whose firewall/provider prerequisites completed before profile loading; a failed prerequisite keeps application traffic blocked. Unchanged provider bytes are not rewritten on each native poll. `mimo_tailnet_configuration_updated` records private native configuration changes handled without a public-IP check; supplemental DNS domains are refreshed in place.

Open **Event Log** from the dashboard to view important UTC-stamped events. Drag across multiple lines, or press **⌘A** then **⌘C**. Incoming updates wait while text is selected, and scrolling up no longer snaps back to the bottom. **Pause** freezes the displayed history until **Resume**.

**Copy All** (**⇧⌘C**) copies readable events. For a repeated block/check/open cycle, use **Copy Diagnostics** (**⌥⌘C**): it includes recent full JSON records from the GUI, core and supervisor, including event names, trigger details, audit failures and selected/effective routing modes. Each source retains up to 500 records within a 256 KiB limit; missing or older services are identified explicitly. The usual IP-address redaction setting still applies. **Show Log Files** opens the GUI log folder; the shared service logs are in `/Library/Logs/Mimo`. Diagnostic traces and evidence may include network metadata; review them before sharing.

A GUI-only `mimo_access_presentation_changed` log describes what was displayed, not what triggered a verification cycle. Routine Direct IP checks keep `blocked:false`; Rule/Global cycle diagnosis needs the core/supervisor records. This diagnostic update does not change firewall or event-handling policy.

`Check trigger` identifies configuration keys, route/address/interface changes (interface and originating PID), session events or recovery. Audit failures include their reason. Long messages wrap; Copy All includes the supervisor's records. `lookup_country_unknown` and `location_metadata_changed` explain a globe or country display update without scheduling another check. `mimo_network_changed`, `mimo_verification_audit_failed` and `mimo_liveness_lost` identify real re-verification causes. The notification filters suppress recognized owned tunnel/DNS updates and validated private Tailnet changes that cannot affect the public proxy path; during a protected cycle, external events are merged into one follow-up instead of interrupting the current work. A changed network prevents the current result from opening PF. Owned notifications are discarded. Human controls wait for the cycle and run in arrival order; mode buttons apply to the latest configuration, while full settings edits retain revision conflict checks. No PF/lifecycle lock is held while controls wait.

Focused manual check: keep the exit IP fixed while country data becomes unknown or differs between providers. The icon must update without another confirmation/retry; Rule/Global stay allowed only for an approved IP. Then change a real network setting in Rule/Global and verify that the Event Log names the trigger and protected verification still runs. During that check, queue a mode selection and verify it runs afterward. In Direct, ordinary system/network events must not request a lookup. A failed provider must rotate, retain its eight-hour pause after restart, and show the reason/time in Monitoring.

MagicDNS check: in Rule and Global, resolve an online peer's full tailnet hostname through macOS and through `127.0.0.1:1053` over UDP/TCP. A public name returning `198.18.x.x` confirms mihomo's synthetic DNS response, not MagicDNS. Also resolve the short name of an online peer in your own tailnet (for example, `ping -c1 peer`); `scutil --dns` must list the tailnet domain as resolver #1's search domain, as it does in Direct. Shared nodes require their full tailnet names. If another application owns port 18766, the dashboard must show Mimo's fallback port and tailnet resolution must still work through the private provider file. The DNS listener remains on port 1053; the HTTP fallback does not change it.

For a live MagicDNS check, resolve a full peer name and a short name through the macOS resolver, then query the local listener over TCP and UDP while Rule is active. Private Tailnet Connect/Disconnect and provider Start/Stop should update the native provider without a public-IP check or profile reload. Exit-node, subnet-router and public-route changes still require verification. Custom split-DNS domains outside `.ts.net` remain outside current protected DNS support.

For communication or process-health discrepancies, collect the [read-only service snapshot](Scripts/diagnose-mimo-services.sh) on the affected Mac. All six status ages must reflect the actual inspection time; cached replies cannot claim current health.

| Event family | Meaning |
| --- | --- |
| `mimo_startup_guard_closed`, `mimo_pf_policy_installed` | Startup/transition protection or a PF policy change. |
| `mimo_legacy_network_controls_removed`, `mimo_transition_firewall_released`, `mimo_direct_network_released` | Older controls restored at startup, verification barrier withdrawn, or Direct restrictions removed. |
| `mimo_native_provider_published`, `mimo_profile_prerequisites_ready`, `mimo_tailnet_configuration_updated` | Native provider publication, transition-policy/profile prerequisite completion and live private Tailnet updates. |
| `mimo_exit_rejected`, `mimo_profile_verified` | Exit/profile verification results; protected traffic stays closed on rejection. |
| `mimo_direct_restored`, `mimo_direct_recovery_saved` | Explicit native networking recovery; Mimo packet restrictions and resolver are removed, and older saved IPv6 flags are restored. |
| `mimo_installed_app_control_ready`, `mimo_installed_app_control_unavailable` | Installer-pinned GUI control endpoint availability. |
| `daemon_install_started`, `daemon_install_succeeded`, `daemon_install_cancelled`, `daemon_install_failed` | GUI installation outcome and saved installer log. Declining the competing-engine takeover is cancellation. |
| `daemon_client_connecting`, `daemon_client_connected`, `daemon_client_disconnected`, `mimo_session_event` | GUI connection generation, reply timing, interruption source and account activation/deactivation; separate from service health. |
| `mimo_deactivation_started`, `mimo_cleanup_step`, `mimo_deactivation_succeeded`, `mimo_deactivation_failed` | Full uninstall start, verified release stages including native Tailnet DNS, completion or failure. |
| `mimo_local_monitor_started`, `mimo_local_monitor_stopped` | GUI-only monitoring lifecycle after network release. |
| `login_item_synced`, `keychain_operation` | Per-account login synchronization and credential-operation status, without credential values. |

Installation/removal commands also log bounded steps and explicit failures. Removal does not infer user intent from an app disappearing: only an explicit uninstall restores networking and removes protection.

Installer takeover check: with another Clash/mihomo engine running, cancel the stop prompt and confirm its PID/service and existing Mimo jobs remain unchanged. Retry and approve: the listed launchd job must be disabled and unloaded, its engine must exit, and Mimo service installation must complete. A standalone engine must receive TERM only after consent. Confirm the other application's files/settings remain. Repeat from Homebrew or the GUI to exercise the macOS dialog; a timeout must cancel. A respawning engine must stop installation without killing a new, unapproved PID.

For detailed triggers, ordering, timers, cancellation and recovery, see [event-driven workflows](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md). Historical release evidence remains under `Tests/ReleaseEvidence`; it is not a qualification of a newer binary.
