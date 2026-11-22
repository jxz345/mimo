# Mimo for macOS

Install **Mimo v2.0 (build 5)** with Homebrew:

```sh
brew trust --formula jxz345/tap/mihomo@1.19.34
brew install --cask jxz345/tap/mimo
open /Applications/Mimo.app
```

The fully qualified install finds the repository automatically. The first command trusts only the pinned mihomo dependency, so Homebrew can install it as a dependency rather than an explicitly requested package. Homebrew 6 and later require trust for non-official packages; the fully qualified cask install trusts Mimo itself. [Homebrew’s trust documentation](https://docs.brew.sh/Tap-Trust).

Requires an **Apple silicon Mac with macOS 14 or later**. Control Center integration requires macOS 26. Installation includes tested **mihomo 1.19.34** and requests administrator authentication for the machine-wide services. Routine routing and settings controls need no administrator password. Full Stop and Activate use administrator authentication. Managed Mimo routing supports IPv4 only; IPv6 is disabled during managed operation and its saved settings are restored by full Stop or uninstall.

The updated [service installer](Sources/MimoDaemon/daemon.sh) handles a running Clash/mihomo engine by listing its executable/PID and any matching launchd service, then asking **Stop and Continue**. In a foreground terminal, answer `y`; Homebrew, package and GUI installs without terminal input show a macOS dialog. Cancel, no response within 60 seconds, or unavailable confirmation leaves the competing engines running. Approval replaces the listed running engines: it disables and unloads their identified launchd jobs, stops standalone processes, verifies exit, then continues setup. Disabled jobs cannot restart automatically at login/reboot. Apps, configuration and startup files are retained. If a proxy restarts its engine, quit that app/service and retry; the installer does not kill unapproved replacement processes. If installation later fails, re-enable the other proxy through its app or service manager if you want to restore it.

To repair a sealed **2.0** app without rebuilding or modifying its bundle, save the linked installer as `install-mimo-services.sh` and run:

```bash
sudo /bin/bash ~/Downloads/install-mimo-services.sh install --app /Applications/Mimo.app
```

For an older 1.0 bundle, use the [version 1 installer](https://github.com/jxz345/mimo/blob/v1.0/Sources/MimoDaemon/daemon.sh), or upgrade the complete app first. Signature, pinned-engine checksum and staging checks run before the stop prompt. `install --non-interactive` explicitly refuses conflicts without asking or stopping anything; it does not authorize stopping another proxy.

[Installer takeover validation](Tests/ReleaseEvidence/mimo-installer-takeover.json) records the standalone script hash, VM confirmation/launchd/repair checks and test limits. Physical Homebrew confirmation remains pending.

Upgrading from version 1? Update the tap and upgrade:

```sh
brew update
brew fetch --force --cask jxz345/tap/mimo
brew upgrade --cask jxz345/tap/mimo
```

[Download v2.0](https://github.com/jxz345/mimo/releases/tag/v2.0) · [What is implemented](#what-is-implemented) · [Event-driven workflows](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) · [Clean uninstall](#clean-uninstall-and-reinstall) · [Protection limits](Design/MIMO_FIREWALL_AND_FAILURE_SCENARIOS.md)

The source on `main` and `v2.0` matches this release. Packages are `Mimo-2.0.zip` and `Mimo-2.0.pkg`. Version 1.0 build 4 remains available under `v1.0`. The installed app is `Mimo.app`; its executables are `mimo-gui` and `mimo-core`.

## First launch

1. Open Mimo. If installation authentication was cancelled, use **Install Service** or **Repair Service** to finish setup.
2. Configure the shared proxy in **Settings → Proxy**. Credentials are stored in the System Keychain.
3. Add approved IPv4 addresses in **Settings → Allowed IPs** before selecting Rule or Global.
4. Select Direct, Rule or Global on the Dashboard. Use **Refresh now** for a manual check.
5. Optionally enable **Open Mimo at login** in Settings → General. This starts only this account’s GUI. The shared services are managed independently by launchd.

The release is ad-hoc signed, not notarized. Homebrew checks the sealed signature and removes quarantine from this app only; it does not disable Gatekeeper. Copied-app/package installations may require macOS’s Open Anyway approval. If macOS parks an approval before startup, lock and unlock the screen, then reopen the app. Use the bundled `diagnose-launch.sh --launch` to collect a bounded startup trace.

Mimo’s required supervisor and PF boot policy run independently of the GUI. Closing the window or quitting Mimo does not stop shared protection. The **Stop engine and use Direct** action removes Mimo’s background installation and network controls while preserving saved settings; ordinary Direct keeps the engine and IPv4 policy.

## Modes and protection

| Mode | Behavior |
| --- | --- |
| **Direct** | Keeps the engine running with unproxied IPv4. IP checks and network/session events do not block internet access or enforce the allowlist. |
| **Rule** | Applies the saved profile’s routing rules. An empty allowlist, invalid configuration or unapproved exit IPv4 keeps public traffic blocked. |
| **Global** | Sends traffic through the proxy, with the same allowlist and verification requirements as Rule. |

Protected transitions show **Blocking → Blocked/Checking → Allowed**. Once allowed, routine background audits do not change the dashboard/menu icon or status; audit failures still block traffic and show their cause. The last observed exit IP remains visible when it caused blocking. Direct shows its current IP and country with the Direct indicator. Menu-bar colors and dashboard status reflect the shared service state.

Country is display metadata. A valid exit IP remains valid when a provider cannot identify its country; the menu bar shows a globe. Country-only changes never request another lookup, confirmation or block/open cycle. The Allowed shield is white. Rule/Global still require the actual IPv4 address to be allowlisted, and real network/system events still trigger protected verification in Rule/Global. AirPort scan/radio status notifications are compared before the early firewall callback. Unchanged values and known telemetry (AutoJoinTimestamp, Busy, signal/noise, channel and scan records) do not start a cycle. The `Setup:` network-location root is also compared before early blocking: an unchanged location with only a `LastUpdated` timestamp change is ignored. Missing location data, a changed location, and unknown root-field changes still trigger verification. Wi-Fi power, association and unknown field changes still trigger protection; public IP, DNS, proxy, route, link and VPN changes retain protection. Private Tailnet connect/disconnect notifications can update in place when the verified proxy uses a separate public interface; exit-node, subnet-router, unknown and public-network changes still require verification. Ordinary network/session/wake events are ignored in Direct; startup, manual/routine IP checks, tailnet integration and PF/launchd health monitoring remain available.

The supervisor closes PF on detected protected-mode changes, prepares restricted private verification access and checks the exit IP before reopening. An unchanged configuration with a valid full-verification baseline may use the agreed optimistic path: essential live checks and an approved IPv4 first, then a fuller background audit. An audit failure or deadline requests blocking and full recovery. This accepts possible exposure before a missed fault is detected.

PF has a saved boot policy and a separate launchd loader/health monitor. **Traffic before that loader runs is outside the protection guarantee.** Detection of network/session events is asynchronous. Mimo does not claim a macOS Always On VPN or a zero-packet boot barrier. See the [current event workflows](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md), [design history](MIMO_PLAN.md) and [failure analysis](Design/MIMO_FIREWALL_AND_FAILURE_SCENARIOS.md).

## Dashboard and Settings

Version 2 builds on **Mimo 1.0 build 4** (`d772840`), which is the reference for the [interactive mockup](https://mimo-dashboard-design-jay.nativebadger32.chatgpt.site). Dashboard / Settings, Refresh now and Direct / Rule / Global remain in the top toolbar. Route details remain inside Proxy configuration. The six background-service rows retain equal 60-point heights, aligned health columns, original controls and configured endpoints. Settings keeps the native sidebar, single-column proxy form, provider quota table, and grouped preferences. The new features are the Rule-only Bypass editor and explicit cleanup/activation action. The footer retains Event Log, version/build and Quit GUI. The short cleanup copy is “Stop the engine and release network controls.” Browser controls outside the app frame only operate the simulation.

Settings contains **Proxy**, **Bypass**, **Allowed IPs**, **Monitoring**, and **General**. Proxy uses a network icon; Bypass uses a branching-route icon. Proxy and bypass drafts survive status updates and tab changes. General contains login launch, appearance and clean-uninstall instructions. Monitoring contains provider choice, quotas, refresh policy and events.

### Stop engine and use Direct

This action runs through the privileged installer to remove all Mimo services, login items and owned network controls while keeping the GUI and saved settings. The confirmed completed state is **Mimo is inactive**, with PF **Released** and launchd/services **Removed**. Only confirmed cleanup makes `/Applications/Mimo.app` safe to delete. Cleanup progress or a communication error must not claim completion.

The same button becomes **Activate Mimo**, which restores all daemons in ordinary Direct. Occupied resources use the installer's identified-conflict **Cancel / Stop and Continue** prompt. Ordinary Direct selection retains build 4 behavior and does not perform full cleanup. Reinstalling or upgrading an inactive app keeps it inactive, even if another engine is running. Failed activation restores inactive networking. Installed cleanup, activation, conflict handling and reboot checks are recorded in the [2.0 release evidence](Tests/ReleaseEvidence/mimo-build-5-v2.json).

### Edit Rule bypass blocks

Open **Settings → Bypass** to add, rename, enable/disable or remove a block, and edit its domains. Choose **Exact** for one hostname or **Suffix** for that domain and its subdomains; enter plain DNS names without schemes, ports or wildcards. New installations and older settings start with the existing website blocks. Removing every block is saved as an explicit empty list and does not restore defaults.

**Apply** validates and saves the machine-wide draft; **Cancel** reloads saved values. If another account changed shared settings, reload before applying rather than overwriting its revision. Applying in Rule starts protected verification with the new rules. Applying in Global or ordinary Direct saves for the next Rule activation without starting the engine or changing current routing. Fully inactive Mimo retains drafts; activate it before applying shared settings. Managed Tailscale, LAN and final routing rules retain their precedence and are not editable as website bypass blocks.

Copy icons briefly show a checkmark after success; Event Log’s Copy All/Copy Diagnostics buttons show “Copied” without moving nearby controls.

All six monitoring rows use the same status-and-age format, for example **Healthy(3 secs)**. The age comes from the last inspection and advances every second; receiving or redrawing a cached reply does not reset it. A running service report older than 35 seconds becomes **Stale(n secs)**. Stopped, suspended, released and failed services retain their actual status, and a missing inspection time appears as **Unavailable(—)**. These labels describe the recorded checks, not a fresh end-to-end connectivity test. [Healthy rows](Previews/mimo-dashboard-health-light.png) · [Stale service reports](Previews/mimo-dashboard-health-stale-dark.png). Included in build 3.

Queued controls and held events appear in Event Log (`mimo_control_queued`, `mimo_control_resumed`, `mimo_cycle_event_deferred`). Provider failures record `provider_failure_paused` with their reason and resume time. Rule/Global remain blocked if all available providers fail; Direct stays open.

## What is implemented

| Feature | Behavior |
| --- | --- |
| **Homebrew distribution** | Mimo v2.0 (build 5), Apple silicon only, with the pinned mihomo 1.19.34 formula, checksum verification, normal install/reinstall/uninstall and standalone ZIP/package installers. The updated service installer asks before stopping conflicting Clash/mihomo engines, verifies their exit and then continues; cancellation preserves them. A standalone repair can use the existing sealed app. |
| **Release build identity** | Each GitHub upload receives a distinct increasing build number while the marketing version may stay 1.0. The dashboard, diagnostics and release manifest identify the exact build. |
| **Consistent Mimo identity** | Mimo app/widget/build names, `com.mimo` app identity, `com.mimo.*` jobs/XPC endpoints, Mimo data/log directories, `mimo-manage` removal command and Mimo archive names. Old names are migration/cleanup inputs, not current branding. |
| **Shared machine state** | One core owns proxy configuration, credentials, allowlist, provider budget and routing state for all accounts; GUI clients and widgets read that shared state. |
| **Three routing modes** | Direct remains unproxied; Rule applies the profile; Global uses the proxy. Protected modes require an approved IPv4 and a nonempty allowlist. |
| **Owned IPv4 policy** | IPv6 is disabled during managed operation, including ordinary Direct. IPv6 observations cannot approve traffic. Explicit engine release and uninstall restore owned per-service IPv6 flags while preserving later changes by another owner. |
| **Private profile delivery** | Exact generated profile bytes are validated through stdin and reloaded through the authenticated controller. Profile Open/Reload actions remain available; a credential-free blocking profile is stored privately for startup. |
| **PF boot policy and repair** | Independent saved blocking rules and loader, PF/launchd health checks every ten seconds, service-intent repair and dashboard check ages. Released intent keeps these checks read-only for network ownership. Boot protection starts when the loader actually runs. |
| **Protected verification** | Closed-gate private probes, approved IPv4, engine/profile binding, generation/revision checks, stale-result cancellation and full readiness checks. Warm optimistic reopening completes a bounded background audit; routine audit progress stays hidden, and failure remains visible. |
| **Concurrent checks and event scheduling** | Preparatory work overlaps PF closure; private probe access is installed under the PF mutation lock. Related route, interface, DNS, VPN, wake and session notifications share one verification cycle and one follow-up. Early callbacks wait for classification before approval: owned tunnel setup is discarded, real external changes retain the follow-up. An armed Direct-to-Rule/Global cycle takes precedence over the old Direct state when recording an external event. |
| **System event coverage** | Network path/configuration/routes, VPN/Tailscale, sleep/wake, display sleep/wake, login/logout, lock/unlock and active-user changes. AirPort telemetry, including timestamp-only AutoJoinTimestamp updates, is filtered before blocking; real connection changes remain monitored. Network-location apply timestamps are also filtered; actual location/unknown-field changes remain monitored. A native DNS selection carrying configd’s interface index is accepted only when it matches the current native interface; wrong indices, changed DNS servers and unknown fields still require verification. Direct ignores ordinary network/session events; routine checks and tailnet controls remain active. |
| **Workflow reference** | [Event-driven workflow documentation](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) maps OS events, user commands, timers, service faults and UI updates to their owners, traffic behavior, cancellation/coalescing rules, diagnostic records and tests. |
| **Lifecycle protection** | Protected service/profile mutations confirm blocking; explicit engine Stop instead leaves protected mode and performs network release. Intent, confirmed cleanup and communication state remain distinct. Unexpected engine failure still closes protected access. |
| **Deactivation and coexistence** | Explicit Stop invokes full privileged cleanup of all Mimo services/login items and network controls. Confirmed completion reports inactive and makes the app safely deletable. Activate Mimo restores all daemons in Direct and uses installation conflict confirmation. Reinstall preserves inactivity; failed activation restores inactive networking. Installed VM round trips and coexistence are tested. |
| **Editable Rule bypass** | Machine-wide named domain blocks with exact/suffix entries, add/edit/delete and per-block enable switches. Validated Apply/Cancel drafts and revision conflicts; existing defaults migrate without changing managed network rules. Global ignores these website bypasses. |
| **Protected DNS** | Rule/Global direct system DNS to mihomo, intercept TUN DNS and restrict ordinary direct DNS. Build 3 permits root-owned TCP Quad100 DNS only through the verified native Tailscale interface, before the generic group-based DNS block; clearing the native policy revokes it. Ordinary applications retain the DNS block. Because Mimo's resolver becomes the system default, it carries the native search domains (MagicDNS first, then the primary service), so short names of peers in your tailnet still expand. Status/heartbeat replies revoke Allowed immediately if the protected resolver entry is missing or changed, independently of the full audit. Restricted runtime/bootstrap exceptions and limitations are described in the failure analysis. |
| **Native Tailscale transport** | Uses the installed official Tailscale network extension, peer verification and relay recovery. Native Tailscale Connect/Disconnect and Mimo’s provider switch update the provider in place. The stable profile needs no reload, and Tailnet-only changes leave approved internet access open when the public proxy path is unchanged. The diagnostic endpoint is prepared when the provider starts; native observations and provider bytes are maintained ahead of verification. A protected profile loads only after the firewall policy and current provider publication have completed. The supervisor publishes mihomo's root-owned provider file only after applying the matching native firewall rules; the core cannot overwrite it with an independent observation. Missing native transport or a stopped provider publishes Reject. The diagnostic HTTP endpoint prefers loopback port 18766 and automatically binds a free loopback port if occupied; the dashboard shows the actual port. Runtime provider delivery remains independent of HTTP ports. The provider starts/restarts when the tailnet is active; an intentionally disconnected tailnet is not reported as a provider failure. |
| **Hostname bootstrap** | Protected bootstrap removes the prior TUN under a closed gate before using restricted resolver access. Successful hostname-proxy coverage remains subject to the recorded qualification limits. |
| **Password-free routine controls** | Installer-pinned GUI identity and separate XPC control endpoints authorize ordinary-account operations. Credentials do not travel in public state; root-only operations remain restricted. |
| **GUI communication** | Background processes own supervision, health inspection and firewall enforcement; the GUI displays their reports. A lost connection shows **Service communication interrupted**, **No connection**, the last reply age and **Reconnect**. A fresh independent supervisor reply can still show process/PF health; a running core process is labeled Running without claiming its connection is healthy. Read-only state probes have a 3-second deadline and coalesce. Account deactivation pauses subscriptions/polling; return recreates the subscription immediately. No lookup or service restart is requested by reconnecting. |
| **Per-account login item** | Cached status and a serialized background worker keep macOS login-item queries and registration off the GUI thread. View construction never synchronously queries Background Task Management. Inactive windows do not reposition or request deferred activation. |
| **Dashboard** | Stable connection/status space, colored country/mode/blocked indicators, service icons and ports, equal-height monitoring rows with uniform `Healthy(n secs)` inspection ages, overdue inspection reporting and separate communication-loss status, the refresh interval alongside IP-check details, Refresh now, profile controls, routing/LAN/Tailscale details inside the proxy section, explicit Stop/Activate controls, Rule bypass summary, app version/build and confirmation on every copy control. |
| **Settings and drafts** | Proxy and Bypass with distinct icons, allowlist, monitoring and general settings; draft validation, empty-allowlist blocking, private credential entry and retained unsaved edits. |
| **Native macOS presentation** | Grayscale styling with Liquid Glass on supported systems, normal-window behavior, Dashboard/Settings tabs, appearance preferences, Finder/Dock icon consistency and keyboard shortcuts. Version 2 retains the build 4 toolbar with navigation, Refresh now and modes together; Settings retains its sidebar, single-column proxy form, provider table and grouped preferences. Uninstall help lives in General. |
| **Menu bar and widgets** | Country or globe fallback plus Direct/white Allowed indicator, colored blocked status, blocked-IP presentation, a status menu with shortcuts, a WidgetKit snapshot and macOS 26 Control Center entry. |
| **Monitoring and quotas** | Startup/manual/routine/event checks, provider rotation/cooldowns, daily budgets and stale/error state. Country is display-only metadata; a valid IP with unknown geography does not retry. Country highlights require an IP change. Failed lookup providers are excluded for eight hours and the next available provider is tried; a longer provider Retry-After is honored. Monitoring shows each pause reason and retry time. The UI shows each provider’s published quota, Mimo cap, usage and remaining allowance. |
| **Providers and credentials** | IPinfo Lite, ipapi.co, IPWho.is and ipapi.is support; shared IPinfo token and proxy password in the System Keychain, with explicit legacy personal-Keychain import support. |
| **Diagnostics** | Event Log merges core, supervisor and GUI records, including specific network/system triggers and audit failures. Native multiline selection, ⌘A/⌘C, Pause, Copy All and Copy Diagnostics preserve readable events and full diagnostic fields. Privacy-conscious runtime records, bounded commands, signature/startup verification, launch heartbeat, optional external launch traces and saved installation evidence. A standalone MagicDNS comparison checks native DNS and installed/fresh Mihomo instances without changing the active configuration. Temporary firewall tests check the Quad100 correction, including repeated fresh queries through the live native policy, and restore their changes with an independent watchdog. A read-only service snapshot compares process/job state, controller/listeners, service intent, gate and resolver when the dashboard conflicts with command output. |
| **Recovery and upgrades** | Revision-fenced Direct recovery, stopped-service retention, staged service repair/rollback, settings/credential migration and retained-data reinstall. |
| **Clean uninstall** | On success, removes owned jobs, PF policy, login registrations/choices, private group/right, staged engine, generated secrets/caches and removal helpers, and restores networking. Settings, credentials and logs are retained. For an interrupted or incomplete version 1 removal, [manual recovery](#manual-recovery-after-an-incomplete-version-1-uninstall) includes a standalone inspection/confirmed-cleanup script that archives installed components and preserves recovery evidence. |
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

### Manual recovery after an incomplete version 1 uninstall

Use this on the **Mac where Mimo was installed**, from a local administrator Terminal, if normal uninstall fails or internet access remains broken after removing the app. Keep the same Terminal window for these steps. This procedure removes Mimo’s network enforcement; it does not require a working GUI or core connection.

Deleting or killing `mimo-core` alone is insufficient. Mimo also installs an engine, two independent guard jobs, a persistent PF boot rule and a DNS override. A guard can reapply blocking after the core exits. Version 1 uninstall can stop on an earlier cleanup error; a partially removed installation can also lack files needed for automatic network restoration. The order below stops those writers before releasing the network.

#### Standalone recovery script

Save [cleanup-mimo-v1.pl](Scripts/cleanup-mimo-v1.pl) to Downloads on the affected Mac. It uses the macOS-supplied Perl and does not need a new Mimo build. Quit every Mimo GUI first, and use a local Terminal. Inspect before applying:

```sh
sudo /usr/bin/perl ~/Downloads/cleanup-mimo-v1.pl --check
sudo /usr/bin/perl ~/Downloads/cleanup-mimo-v1.pl --apply
```

Omitting the argument is equivalent to `--check`: it inspects jobs, processes, Mimo’s PF anchor/resolver and the proposed PF configuration; it changes no services or network settings. `--apply` prints the Mac name and scope, asks you to type `REMOVE MIMO`, and then rechecks before making changes. There is no unattended confirmation bypass.

The script disables/unloads Mimo’s jobs, waits for its workers to exit, reasserts the disable overrides, removes only the exact Mimo boot block and live PF parent rules, removes Mimo’s DNS key, releases identifiable current-boot PF references and restores journaled IPv6 flags. It archives startup files, helpers and generated runtime material under a root-private `/var/root/mimo-recovery.*` directory. It does not call the service manager’s maintenance operation, reload the global firewall, flush unrelated states or kill other engines.

Unexpected PF configuration, uncertain job state or a worker that will not exit stops automation. A missing/broken helper with saved IPv6 settings leaves the helper/journals in place for the manual IPv6 step below; already completed PF/DNS recovery is not rolled back. A missing IPv6 journal is reported as unknown previous settings, not proof of restoration. PF references whose ownership cannot be verified are left for review. Keep the printed backup path and any error. The backup may contain generated credentials and must remain private.

This is **service/network recovery**, not the complete package uninstaller. It retains the app/Homebrew receipt, per-account login entries, private group/authorization right, machine settings, Keychain credentials and logs. After successful recovery, finish the app/login/package/group/right cleanup described in step 5, then verify after reboot as in step 6. Do not run the archive block again after the script has already archived the components.

Validation: `perl -c Scripts/cleanup-mimo-v1.pl` and `perl Tests/MimoDaemonTests/manual_cleanup_test.pl` check syntax and fixture/mocked-command behavior, including unrelated-policy preservation, shutdown order, failed restoration, backup collisions and command deadlines. These checks do not uninstall the app or exercise a real firewall; the script still requires validation on an affected Mac or in the designated runtime VM.

#### 1. Quit the GUI and stop every Mimo system job

Quit Mimo in every logged-in account, and do not reopen it or run an installer during recovery. Remove Mimo from **System Settings → General → Login Items & Extensions → Open at Login** in each account where it was enabled. A leftover login entry can be cleaned up later; do not delay network recovery because another account is unavailable.

Create a private recovery directory, save the network recovery records, then disable all five jobs before unloading any of them, with the independent repair jobs first. A repair already in flight can re-enable a job, so also complete the process and registration checks below. The block accepts an already absent job, but stops on other launchctl errors.

```bash
mimo_recovery="$(sudo /usr/bin/mktemp -d /var/root/mimo-recovery.XXXXXX)"
printf 'Recovery files: %s\n' "$mimo_recovery"
sudo /bin/bash -s -- "$mimo_recovery" <<'MIMO_STOP'
set -eu
recovery=$1
case "$recovery" in /var/root/mimo-recovery.*) ;; *) exit 1 ;; esac
[ -d "$recovery" ]
[ ! -L "$recovery" ]
/bin/cp -p /etc/pf.conf "$recovery/pf.conf"
support='/Library/Application Support/Mimo'
for relative in Runtime/ipv6-original.plist Runtime/ipv6-apply-pending Runtime/pf-reference.json Guard/pf-reference.json; do
    if [ -f "$support/$relative" ]; then
        /bin/mkdir -p "$recovery/$(/usr/bin/dirname "$relative")"
        /bin/cp -p "$support/$relative" "$recovery/$relative"
    fi
done
labels=(com.mimo.infrastructure com.mimo.pf-boot com.mimo.core com.mimo.mihomo com.mimo.supervisor)
for label in "${labels[@]}"; do
    /bin/launchctl disable "system/$label"
done
for label in "${labels[@]}"; do
    status=0
    output=$(/bin/launchctl print "system/$label" 2>&1) || status=$?
    if [ "$status" = 0 ]; then
        /bin/launchctl bootout "system/$label"
    elif [ "$status" = 113 ] && [[ "$output" == *'Could not find service'* ]]; then
        printf 'Already absent: %s\n' "$label"
    else
        printf '%s\n' "$output" >&2
        exit 1
    fi
done
MIMO_STOP
```

Allow up to 45 seconds for stopped workers to exit, then check their full paths:

```sh
/bin/ps -axww -o pid=,uid=,command= | /usr/bin/awk '
    /\/Library\/PrivilegedHelperTools\/(mimo-core|com\.mimo\.core)|\/Library\/Application Support\/Mimo\/(Runtime\/mihomo|Guard\/pf-guard\.pl)/ && !/awk/
'
```

**Continue only when no Mimo worker remains.** If one remains, verify its executable path and PID, send `sudo kill -TERM PID`, and check again. Use `sudo kill -KILL PID` only for that same verified process if it will not exit. Do not use `killall mihomo`: another VPN may own a different engine. Do not proceed past a failed stop or a process that keeps returning.

With the workers gone, reassert the disable overrides and verify all registrations are absent:

```bash
sudo /bin/bash <<'MIMO_VERIFY_STOP'
set -eu
for label in com.mimo.infrastructure com.mimo.pf-boot com.mimo.core com.mimo.mihomo com.mimo.supervisor; do
    /bin/launchctl disable "system/$label"
    status=0
    output=$(/bin/launchctl print "system/$label" 2>&1) || status=$?
    if [ "$status" = 113 ] && [[ "$output" == *'Could not find service'* ]]; then
        printf 'Stopped and disabled: %s\n' "$label"
    else
        printf 'Registration still present or inspection failed: %s\n%s\n' "$label" "$output" >&2
        exit 1
    fi
done
MIMO_VERIFY_STOP
```

If this check fails, repeat the stop and process checks before continuing. For an installation migrated from ExitIPMonitor, also inspect and stop the compatibility jobs `com.example.exitipmonitor.tailscale-verge` and `com.example.exitipmonitor.tailscale-verge-http` if present, using the same disable/unload procedure.

#### 2. Remove Mimo’s persistent and live firewall policy

If the installed guard script is present, its removal operation deletes only Mimo’s marked block in `/etc/pf.conf` and releases its own PF enable reference:

```sh
sudo /usr/bin/perl '/Library/Application Support/Mimo/Guard/pf-guard.pl' --remove
```

If the script is missing or fails, run `sudo /usr/bin/nano /etc/pf.conf` and remove **only** this block if present:

```text
# BEGIN MIMO BOOT GUARD
load anchor "com.apple/000.mimo" from "/etc/pf.anchors/com.mimo.boot"
# END MIMO BOOT GUARD
```

Keep Apple’s `anchor "com.apple/*"` and every other application’s entries. If the markers or contents differ, inspect them before editing; do not delete a range of unrelated rules. Check the edited file without loading it, then empty only Mimo’s live parent anchor:

```sh
sudo /sbin/pfctl -n -f /etc/pf.conf
sudo /sbin/pfctl -a com.apple/000.mimo -F rules
sudo /sbin/pfctl -a com.apple/000.mimo -sr
```

The last command should show no rules. An already absent anchor can report `Invalid argument`; verify that Mimo has no loaded parent rules and its boot block is gone before treating that as harmless. Emptying the parent disconnects its permission, power-guard, native-transport and other child anchors; inert child entries may remain until reboot. Do not use global `pfctl -d`, `pfctl -F all`, a global state flush, or reload all of `/etc/pf.conf` to recover Mimo. Those operations can change another VPN’s protection.

#### 3. Remove the orphaned resolver and restore IPv6

Remove only Mimo’s dynamic-store DNS key, which may otherwise direct lookups to a stopped listener:

```sh
printf 'remove State:/Network/Service/com.mimo.dns/DNS\nquit\n' | sudo /usr/sbin/scutil
printf 'show State:/Network/Service/com.mimo.dns/DNS\nquit\n' | /usr/sbin/scutil
sudo /usr/bin/dscacheutil -flushcache
/usr/sbin/scutil --dns
```

`No such key` is the expected result of the second command. The native network/VPN resolvers should remain. Current Mimo does not overwrite each network service’s saved DNS-server or proxy settings: do not clear all DNS servers, delete Tailscale’s resolver, or reset every proxy. If you separately configured a service to use Mimo’s loopback address, restore that service’s previous setting.

Before deleting the helper or its recovery records, restore the saved per-service IPv6 enabled flags:

```sh
sudo /Library/PrivilegedHelperTools/mimo-core --restore-ipv6-preferences
```

This one-shot operation does not start the core or reinstall the firewall. It reads `Runtime/ipv6-original.plist` and removes that journal after restoration. A missing journal makes it a no-op, so a successful exit alone does not prove IPv6 was restored when recovery data is missing. **Keep the original journal and helper if this step fails.**

If the helper is missing or cannot run, restore the affected services’ previous IPv6 choices in **System Settings → Network → service → Details → TCP/IP** ([Apple’s TCP/IP settings reference](https://support.apple.com/guide/mac-help/change-tcpip-settings-on-mac-mh14129/mac)). For a service that previously used Automatic, `sudo /usr/sbin/networksetup -setv6automatic "Wi-Fi"` restores that choice; replace `Wi-Fi` with the actual service name. Do not apply Automatic to every service or overwrite a deliberate manual/disabled setting. Mimo’s journal records enabled flags by service UUID, not a replacement address/router configuration.

#### 4. Release only Mimo’s remaining PF enable references

PF being enabled is not itself evidence of leftover Mimo blocking: another application or macOS may still need it. Inspect the current boot ID, live references and Mimo’s saved records:

```sh
/usr/sbin/sysctl -n kern.bootsessionuuid
sudo /sbin/pfctl -s References
sudo /bin/cat '/Library/Application Support/Mimo/Runtime/pf-reference.json'
sudo /bin/cat '/Library/Application Support/Mimo/Guard/pf-reference.json'
```

A missing record is normal after successful cleanup. For each remaining JSON record, release its numeric `token` with `sudo /sbin/pfctl -X TOKEN` **only if** its `boot` equals the current boot ID and the same token appears in the live reference list. The guard removal may already have released its token. Do not use an old backup’s token after reboot, guess a token, or release another owner’s reference. If ownership cannot be established, leave the reference alone; an empty Mimo anchor no longer blocks traffic, and the reference does not survive reboot.

#### 5. Remove the installed components after network recovery

First verify ordinary DNS and internet access locally, for example with `dscacheutil -q host -a name example.com` and a browser. Check that the Mimo DNS key is absent, the Mimo parent anchor is empty, and no Mimo worker has returned. Do not use the old GUI’s last “Healthy” report as confirmation.

Use the following fallback **after completing the steps above**. Do not retry the service manager or installer midway through manual recovery: entering maintenance can reapply blocking. The fallback moves Mimo’s startup files, helpers and generated runtime material into the private recovery directory, instead of discarding recovery evidence. Machine settings in `Mimo/Service`, Keychain credentials and logs stay in place; saved service intent moves with `Runtime` into the backup.

Remove the `com.mimo.configure` authorization right with the helper if it is still available:

```sh
sudo /Library/PrivilegedHelperTools/mimo-core --remove-right
```

If the helper is unavailable, the equivalent targeted command is `sudo /usr/bin/security authorizationdb remove com.mimo.configure`. An already absent right requires no further action.

```bash
sudo /bin/bash -s -- "$mimo_recovery" <<'MIMO_ARCHIVE'
set -eu
recovery=$1
case "$recovery" in /var/root/mimo-recovery.*) ;; *) exit 1 ;; esac
[ -d "$recovery" ]
[ ! -L "$recovery" ]
archive() {
    local source=$1 target="$recovery/removed$1"
    [ -e "$source" ] || [ -L "$source" ] || return 0
    if [ -e "$target" ] || [ -L "$target" ]; then
        printf 'Backup already exists; inspect before continuing: %s\n' "$target" >&2
        return 1
    fi
    /bin/mkdir -p "$(/usr/bin/dirname "$target")"
    /bin/mv "$source" "$target"
}
for label in com.mimo.infrastructure com.mimo.pf-boot com.mimo.core com.mimo.mihomo com.mimo.supervisor; do
    archive "/Library/LaunchDaemons/$label.plist"
done
support='/Library/Application Support/Mimo'
for name in LaunchDaemons Guard Runtime Mihomo TailscaleVerge; do
    archive "$support/$name"
done
for name in installed-app app.cdhash command-support.sh cleanup-installation.sh tailscale-verge.sh; do
    archive "$support/$name"
done
for path in /Library/PrivilegedHelperTools/mimo-core /Library/PrivilegedHelperTools/com.mimo.core /Library/PrivilegedHelperTools/mimo-manage /Library/PrivilegedHelperTools/MimoUninstaller.app /etc/pf.anchors/com.mimo.boot /etc/sudoers.d/mimo-service /etc/sudoers.d/mimo-tailscale-verge; do
    archive "$path"
done
printf 'Installed Mimo components moved to %s/removed\n' "$recovery"
MIMO_ARCHIVE
```

The backup can contain generated proxy credentials; keep it root-private. It is not a diagnostics bundle to publish. Do not move these files back wholesale: that would also restore startup and blocking components.

The unused `_mimo` group is not a running service and cannot block networking. Prefer the normal uninstaller’s membership checks to remove it. For manual removal, inspect `dscl . -read /Groups/_mimo`, its `PrimaryGroupID`, `dscl . -list /Users PrimaryGroupID`, `dscl . -list /Groups PrimaryGroupID`, and `ps -axo pid=,gid=,comm=`. Only if it has no members or nested groups, no user/process uses that GID and no other group shares it, remove it with `sudo /usr/sbin/dseditgroup -o delete _mimo`. Do not assume its GID is always `10000`; leaving an uncertain group is harmless to connectivity.

For installations migrated from ExitIPMonitor, archive the two stopped compatibility jobs’ matching `/Library/LaunchDaemons/*.plist` files, `/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage` and `/etc/sudoers.d/exitipmonitor-service` if present and confirmed to belong to this installation. Do not remove similarly named third-party services.

Finally, for Homebrew, run `brew uninstall --cask jxz345/tap/mimo` as your normal user to remove the cask/app receipt; for a copied app, remove `/Applications/Mimo.app`. If Homebrew’s cached hook still refuses, keep its error for package cleanup; do not reinstall services just to recover internet access. Remove any remaining per-account Mimo login entry. Do not uninstall another application’s Homebrew engine dependency as part of this manual procedure.

#### 6. Verify after reboot and before any reinstall

After removing the boot block and startup components, reboot and confirm that the five Mimo system jobs remain absent, the Mimo DNS key does not return and internet access works. Closing the engine should release its TUN routes; a reboot clears orphaned interfaces without guessing a `utun` number or flushing other VPNs’ routes. If a Mimo rule or worker returns, locate the remaining startup owner before deleting anything else.

These emergency steps intentionally leave launchd disable overrides. **Only when deliberately reinstalling Mimo**, after the old components have been removed, re-enable its five labels before running the installer:

```bash
for label in com.mimo.infrastructure com.mimo.pf-boot com.mimo.core com.mimo.mihomo com.mimo.supervisor; do
    sudo /bin/launchctl enable "system/$label"
done
```

This is a documented recovery procedure, not a fix to the version 1 uninstaller. Its commands are based on the installed-resource ownership in [daemon.sh](Sources/MimoDaemon/daemon.sh), [pf-guard.pl](Sources/MimoDaemon/pf-guard.pl), [DNS configuration](Sources/MimoService/MimoDNSConfiguration.swift) and [IPv6 restoration](Sources/MimoService/MimoIPv4Configuration.swift). Actual network restoration must be verified on the affected Mac.

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

**Mimo 2.0 (build 5)** passes 225 shared tests, the native service/app suites, daemon/installer contracts and installed package acceptance in mimo-vm. Full cleanup from all three modes, missing-controller recovery, safe app removal, a second real mihomo serving HTTPS, cancelled/confirmed takeover, inactive reinstall and activation rollback are exercised. Real TLS/HTTP connections prove exact/suffix bypass application and disabling; Global saves retain proxy routing, and MagicDNS remains functional. An actual VM reboot preserves inactivity before explicit activation. See [build 5 release evidence](Tests/ReleaseEvidence/mimo-build-5-v2.json). These checks do not establish universal VPN compatibility or reproduce the earlier physical account-switch freeze.

The current **build 4 UI alignment** passes 104 mockup interaction checks and 12 native app assertion groups in mimo-vm. Browser screenshots cover Dashboard, all Settings sections, inactive/conflict states, dark appearance and a narrow window. All six service rows are 60 points high with aligned health labels; the shortened cleanup description fits one line. See [UI evidence](Tests/ReleaseEvidence/mimo-v2-build4-ui.json), [native Dashboard](Previews/mimo-v2-build4-native-light.png) and [web Dashboard](Previews/mimo-v2-build4-web-light.png).

The earlier **engine-only release candidate** passed 225 shared tests, the focused service and native-app suites, an unsigned app build, and 97 mockup interaction checks. Installed candidate checks in mimo-vm cover release from verified Rule with a missing controller, other PF-owner preservation, port reuse and conflict handling, bypass persistence, independent guard/boot invocations, core/supervisor restart and explicit resumption. Light/dark renders include release progress, confirmed release, cleanup failure and the bypass editor. See [2.0 development evidence](Tests/ReleaseEvidence/mimo-v2-ui-and-release.json). That record predates the full deactivation path released in build 5. The linked build 5 evidence covers an actual VM reboot and coexistence with another real mihomo; physical account switching and the user’s chosen second VPN remain outside that validation.

| Manual check | Expected result |
| --- | --- |
| Full Stop from Rule/Global/Direct | Cleanup progress, then Mimo inactive; all jobs/login items removed, owned networking restored, app safely deletable; Activate Mimo restores all daemons in Direct. |
| Run another VPN after Stop; reopen Mimo or reboot | Other VPN retains networking; all Mimo daemons remain removed until Activate Mimo. Check IPv6 where the network supports it. |
| Activate while another engine or required port is occupied | Named conflict and Cancel / Stop and Continue; cancellation preserves the other service. |
| Add/edit/disable/remove bypass blocks, then Apply in Rule | New connections follow enabled exact/suffix domain rules after verification; managed Tailnet/LAN rules remain intact. |
| Apply in Global or released mode; switch to Rule later | Current routing stays unchanged while saving; next Rule activation uses the saved blocks. |
| Disconnect GUI during cleanup | Missing communication does not prove cleanup. After reopening, a valid completion receipt confirms inactive; otherwise show unavailable/repair. |
| Reboot while inactive, then Activate Mimo | No Mimo interception before activation; all services then start in Direct. VM reboot is tested; physical acceptance remains useful. |

The previous **1.0 (build 2)** passed 210 shared tests, focused native-provider/coordinator/cycle/power checks, and installed-VM Rule tests for both native Tailnet Connect/Disconnect and Mimo provider Start/Stop. Those actions preserve public access without gate closure, exit-IP lookup or profile reload; full-name MagicDNS resolves over UDP/TCP. Two Direct-to-Rule transitions verify native prerequisites before profile preparation and open after one IP pass. Real route changes still block, including an attributed follow-up when a route changes during verification. The revised dashboard is installed in mimo-vm and has native light/dark and [long-message previews](Previews/mimo-dashboard-long-message.png). See [build 2 workflow evidence](Tests/ReleaseEvidence/mimo-build-2-workflows.json). Build 2 reproduced the physical-Mac MagicDNS failure. The subsequent temporary integrated firewall correction passed on that Mac, as recorded below; it is not included in build 2.

Runtime, installation, networking and GUI validation take place **only in mimo-vm**. Delta is used for editing/building and SSH orchestration. The naming update has focused upgrade, credential/settings preservation, new service identity, dashboard-note and uninstall checks; older broad tests remain tied to their original artifact hashes.

Mimo **1.0 (build 4)** includes account-switch hardening, accurate GUI communication status and confirmed takeover of conflicting Clash/mihomo installations. Login-item system calls run off the GUI thread, inactive GUIs pause their subscriptions, and optional WindowServer display queries cannot hold kernel session sampling. [Build 4 evidence](Tests/ReleaseEvidence/mimo-build-4-account-switch.json) records the tests and exact artifacts. The reported physical login-screen freeze has not been reproduced; these changes address blocking paths without claiming its root cause is established.

Mimo **1.0 (build 3)** includes the physically validated scoped MagicDNS correction, native resolver search domains and uniform monitoring ages. It passes **219 shared tests** and installed-package checks in mimo-vm: three fresh engine answers, root TCP Quad100 DNS with group 0, ordinary direct TCP/UDP DNS denial, no root UDP exception, and provider Stop/Start revocation and recovery. Native Tailscale Connect/Disconnect and Mimo provider Start/Stop preserve public access without another gate cycle, IP lookup or profile reload. All six monitoring rows carry current inspection times. Rule/Global full-name system resolution and TCP/UDP listener queries pass, including core restart, native reconnect, occupied diagnostic-port independence and resolver-loss recovery. Settings, credentials, service intent and the original mode are preserved. See [build 3 evidence](Tests/ReleaseEvidence/mimo-build-3-magicdns.json).

The physical Mac passed the preceding integrated candidate from a failing baseline: three fresh engine queries, TCP/UDP local-listener queries and macOS resolution returned the same Tailnet IPv4 answer. Build 3 permanently includes that policy; its packaged app has been installed and tested in mimo-vm, and still needs confirmation after upgrade on that physical Mac. Short-name resolver construction passes unit tests, but the VM has no online peer in its own tailnet, so the installed peer short-name check was explicitly skipped. Custom split-DNS domains outside `.ts.net` remain outside this fix. Focused service tests and light/dark dashboard renders, including stale and unknown ages, also cover the source changes.

The earlier DNS/provider update passed 204 shared tests and 19 focused installed-VM checks: full tailnet names in Rule/Global, UDP/TCP DNS, an occupied diagnostic port, core restart, native tailnet reconnect, resolver-loss recovery and original-settings restoration. Native light/dark dashboard layouts were also checked. The physical-Mac DNS listener recovered after Reload profile, but build 2 still failed full-name MagicDNS: the loaded provider points to the live native interface while mihomo reports `connect: network is down` for TCP Quad100 DNS. Those earlier VM results did not resolve the physical-Mac failure; the later scoped firewall candidate has now passed directly on the affected Mac. A physical Direct-to-Rule trace also contains a `Setup:` event during early preparation that incorrectly leaves an unattributed follow-up; the network-location filter and cycle attribution correction have separate [local-candidate qualification](Tests/ReleaseEvidence/mimo-network-location-candidate.json). That candidate passes 207 shared tests, focused cycle/power tests, and installed-VM transitions with real preference applies. Real route changes still block, and a mid-check route change retains an attributed follow-up. That location-filter record is separate from the subsequent physical MagicDNS correction evidence.

The earlier accepted workflow’s warm route check opened at 3.708 seconds; Tailscale on/off measured 6.547/8.252 seconds. These are observations, not timing guarantees. Actual system sleep/wake, simultaneous GUI sessions, successful hostname-proxy coverage and peer UDP echo remain subject to the existing evidence limits. First-packet traffic before independent PF initialization is outside the guarantee.

- [Earlier MagicDNS/provider recovery evidence](Tests/ReleaseEvidence/mimo-magicdns-recovery.json)
- [Earlier naming-update evidence](Tests/ReleaseEvidence/mimo-naming-migration.json)
- [Previous clean-uninstall evidence](Tests/ReleaseEvidence/mimo-clean-uninstall.json)
- [Previous event scheduling evidence](Tests/ReleaseEvidence/mimo-event-scheduling.json)
- [Earlier full installed-VM coverage](Tests/ReleaseEvidence/MIMO_FINAL_COVERAGE.md)
- [Build 3 release evidence](Tests/ReleaseEvidence/mimo-build-3-magicdns.json)
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

Before publishing a new build, advance `Configuration/BuildNumber.txt` beyond the last GitHub build. Local rebuilds retain that number until publication; never upload different binaries under a previously published build number. Include “Mimo VERSION (build N)” in the release notes and upload `release-build.json` alongside its matching artifacts and checksums.

It stages the package without copying extended attributes; macOS can still add provenance metadata locally, which is inspected alongside sealed-signature verification. It builds arm64, embeds the core and legacy-login removal tool, signs inside-out, validates signatures and emits `Mimo-2.0.zip`, `Mimo-2.0.pkg`, `install.sh`, `release-build.json`, `SHA256SUMS` and `mimo.rb`. Publishing is separate. The cask’s embedded cleanup is kept in sync with:

```sh
python3 Scripts/sync-homebrew-cleanup.py Packaging/mimo.rb.in
```

## Runtime diagnostics

`mimo_network_released` is emitted only after the engine, listeners, protected resolver, owned PF and IPv6 cleanup checks succeed. Pair it with the supervisor’s `networkReleaseRequested`/`networkReleased` fields and service reports; requested intent alone is not proof of cleanup. Failed cleanup remains unavailable with its reason and can be retried.

Use the [event-driven workflow reference](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md) to trace a trigger through classification, preparation, verification and recovery. It distinguishes installed supervisor observation from the shared engine's standalone observer, and actual gate transitions from display/log updates. Its [diagnostic table](Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md#timing-and-diagnostic-reference) lists the records to correlate for each workflow.

`mimo_dns_configuration_lost` records a missing or changed protected resolver detected while publishing active status; traffic is blocked for verification. Provider port conflicts are recorded as `tailscale_provider_port_conflict`; `tailscale_provider_listening` records the actual port and whether fallback was used. Mihomo does not fetch provider data over HTTP, so another process on the preferred port cannot supply its route.

`tailscale_provider_prepared` records diagnostic endpoint readiness when the provider starts, outside the verification cycle. `mimo_native_provider_published` records a changed runtime provider after its native firewall update. `mimo_profile_prerequisites_ready` identifies the verification attempt whose firewall/provider prerequisites completed before profile loading; a failed prerequisite keeps application traffic blocked. Unchanged provider bytes are not rewritten on each native poll. `mimo_tailnet_configuration_updated` records private native configuration changes handled without a public-IP check; supplemental DNS domains are refreshed in place.

Open **Event Log** from the dashboard to view important UTC-stamped events. Drag across multiple lines, or press **⌘A** then **⌘C**. Incoming updates wait while text is selected, and scrolling up no longer snaps back to the bottom. **Pause** freezes the displayed history until **Resume**.

**Copy All** (**⇧⌘C**) copies readable events. For a repeated block/check/open cycle, use **Copy Diagnostics** (**⌥⌘C**): it includes recent full JSON records from the GUI, core and supervisor, including event names, trigger details, audit failures and selected/effective routing modes. Each source retains up to 500 records within a 256 KiB limit; missing or older services are identified explicitly. The usual IP-address redaction setting still applies. **Show Log Files** opens the GUI log folder; the shared service logs are in `/Library/Logs/Mimo`. Diagnostic traces and evidence may include network metadata; review them before sharing.

A GUI-only `mimo_access_presentation_changed` log describes what was displayed, not what triggered a verification cycle. Routine Direct IP checks keep `blocked:false`; Rule/Global cycle diagnosis needs the core/supervisor records. This diagnostic update does not change firewall or event-handling policy.

`Check trigger` identifies configuration keys, route/address/interface changes (interface and originating PID), session events or recovery. Audit failures include their reason. Long messages wrap; Copy All includes the supervisor's records. `lookup_country_unknown` and `location_metadata_changed` explain a globe or country display update without scheduling another check. `mimo_network_changed`, `mimo_verification_audit_failed` and `mimo_liveness_lost` identify real re-verification causes. The notification filters suppress recognized owned tunnel/DNS updates and validated private Tailnet changes that cannot affect the public proxy path; during a protected cycle, external events are merged into one follow-up instead of interrupting the current work. A changed network prevents the current result from opening PF. Owned notifications are discarded. Human controls wait for the cycle and run in arrival order; mode buttons apply to the latest configuration, while full settings edits retain revision conflict checks. No PF/lifecycle lock is held while controls wait.

Focused manual check: keep the exit IP fixed while country data becomes unknown or differs between providers. The icon must update without another confirmation/retry; Rule/Global stay allowed only for an approved IP. Then change a real network setting in Rule/Global and verify that the Event Log names the trigger and protected verification still runs. During that check, queue a mode selection and verify it runs afterward. In Direct, ordinary system/network events must not request a lookup. A failed provider must rotate, retain its eight-hour pause after restart, and show the reason/time in Monitoring.

MagicDNS check: in Rule and Global, resolve an online peer's full tailnet hostname through macOS and through `127.0.0.1:1053` over UDP/TCP. A public name returning `198.18.x.x` confirms mihomo's synthetic DNS response, not MagicDNS. Also resolve the short name of an online peer in your own tailnet (for example, `ping -c1 peer`); `scutil --dns` must list the tailnet domain as resolver #1's search domain, as it does in Direct. Shared nodes require their full tailnet names. If another application owns port 18766, the dashboard must show Mimo's fallback port and tailnet resolution must still work through the private provider file. The DNS listener remains on port 1053; the HTTP fallback does not change it.

**Physical-Mac status:** Build 2 failed full-name MagicDNS in Rule. The installed engine, fresh isolated engines and native `dig` under the runtime group failed; Direct restored resolution without reconnecting Tailscale. The trace identified Mimo's TCP port-53 `group != 10000` block: its packet count rose by three while native-anchor evaluations stayed unchanged, with only resets captured. A matching process group does not establish that PF identified the socket owner as expected; the exact reason for that mismatch remains unknown. The subsequent root-only firewall experiment returned the correct full-name A answer through both the installed engine and local DNS listener, with seven packets matching its temporary pass rule. The broader fallback was not needed. The subsequent integrated candidate test began with the same `network is down` error, then passed three engine queries with the DNS cache cleared each time, both TCP and UDP local-listener queries, and macOS system resolution. Every query returned the same Tailnet IPv4 address. The script reported restoration of its temporary wrapper, leaving the live native policy, permission gate and installed app unchanged. This validates the full-name Rule-mode correction on the affected Mac. Build 3 includes it permanently; the temporary script did not modify build 2. The separate search-domain correction addresses short names only.

For a single comparison on the affected Mac, keep Rule active and run the [MagicDNS diagnostic](Scripts/diagnose-magicdns.pl) with an online peer's full name:

```bash
sudo /usr/bin/perl Scripts/diagnose-magicdns.pl peer.tailnet.ts.net
```

It reports the installed build/engine identity, live provider, native route, actual native UDP/TCP DNS replies under the runtime group, and replies from the running engine and fresh isolated instances of the same binary. The isolated cases compare interface-bound TCP/UDP with TCP using the system route. Only private temporary files and Unix controllers are created; TUN and public listeners remain disabled, and temporary processes/files are removed on completion or interruption. The script does not load the saved proxy profile, change PF, restart services or reconnect Tailscale. Output includes the requested hostname, DNS answer and native interface; review it before sharing. Fresh-instance success alongside installed-engine failure points to running-engine state or configuration; native success alongside failures in both engines requires further socket/process investigation. Neither result alone identifies a fix. An `nc -z` SOCKS success is not DNS qualification.

When native DNS also fails, add `--trace` before the hostname. This mode takes before/after snapshots of the relevant Mimo PF rules and counters around native/installed-engine TCP DNS queries, with a bounded `tcpdump` capture restricted to Quad100 port 53 on the detected native interface. It starts no additional engine and changes no PF rules, counters or network settings. The packet report can contain DNS names and answers observed during that short capture. An empty capture is useful only when its status confirms successful startup and no dropped packets; compare PF counters and rule insertion identities as well, since the native observer can refresh that anchor during observation. The trace was checked in mimo-vm with immediate packet delivery, capturing a complete native TCP DNS exchange.

To test a candidate firewall correction without installing another build, keep Rule active and run:

```sh
sudo /usr/bin/perl Scripts/test-magicdns-firewall.pl peer.tailnet.ts.net
```

The [temporary firewall test](Scripts/test-magicdns-firewall.pl) checks a root-only TCP port-53 exception to `100.100.100.100` on the verified native interface. If that does not produce a real answer with pass-rule packets, it briefly tests the same interface/address/port exception without an owner condition. **That second experiment permits any process to query Quad100 over TCP during the test; it is not a permanent policy or a qualified privacy-preserving app fix.** Both tests clear only the engine's ordinary DNS cache (not fake-IP mappings), query the installed engine and verify its local listener. They leave the permission and power guards in place. On completion/interruption, the script removes only its temporary anchor reference and rules, preserving any newer Mimo policy. A detached watchdog restores after parent death or timeout. A concurrent gate closure aborts the test without reopening it. No app build/install, profile/provider change, service restart or route change is performed. VM validation covers actual replies, both rule branches, interruption, parent termination and watchdog timeout, with original policy/permission readback preserved. The physical root-only branch passed. Build 3 includes the integrated correction; its installed-app checks are recorded separately.

The next [candidate test](Scripts/test-magicdns-candidate.pl) exercises the integrated correction rather than repeating the earlier broad experiment:

```sh
sudo /usr/bin/perl Scripts/test-magicdns-candidate.pl peer.tailnet.ts.net
```

Keep Rule active. It temporarily inserts the root-only TCP Quad100 call before the ordinary DNS group block and delegates through a removable wrapper to Mimo's **live** native anchor. It never copies or pins a native-interface grant, so the existing native writer retains revocation control. There is no owner-independent fallback. Three engine queries and TCP/UDP queries through the local listener each clear the ordinary engine DNS cache first and require a Tailnet IPv4 answer, rejecting synthetic fake-IP results. The script also checks full-name resolution through the macOS system resolver. Automatic cleanup removes only the wrapper/reference, including on interruption, parent death or timeout; failure keeps a nonzero exit status even when cleanup succeeds. The installed app, native policy and permission/power guards are unchanged. These [success and cleanup paths](Tests/MihomoRuntimeTests/magicdns_candidate_script_test.py) pass in mimo-vm. The affected physical Mac also passed all candidate DNS queries and reported successful restoration; no further full-name diagnostic experiment is needed before packaging the correction.

If the dashboard disagrees with launchd or controller commands, collect one [read-only service snapshot](Scripts/diagnose-mimo-services.sh) on that Mac:

```sh
sudo bash Scripts/diagnose-mimo-services.sh
```

It records the machine/time, installed build, Mimo process identities and jobs, saved service intent, gate marker, controller response, DNS/proxy listeners, permission/power guards and protected resolver. Commands are bounded; it does not restart services, load profiles or change firewall/routing settings. It omits proxy profiles, credentials and complete process argument lists. The output includes the Mac's name and resolver domains.

Monitoring-age check: confirm all six rows use `Healthy(n secs)` when their inspections are current. Cached replies must preserve their original time; a running report older than 35 seconds must show `Stale(n secs)`, and a report without an inspection time must not claim Healthy. Intentionally stopped services must still show Stopped. Compare live service observations with the read-only snapshot; an age label alone does not validate DNS or prove a current access approval.

[Scoped MagicDNS candidate evidence](Tests/ReleaseEvidence/mimo-magicdns-scoped-candidate.json) records the tested script hash, physical root-only and integrated-candidate results, VM resolver/cleanup checks and qualification limits.

Live Tailnet check: while Rule is allowed, stop/start the provider in Mimo and disconnect/reconnect native Tailscale. Confirm the private provider changes Reject → Direct, full-name MagicDNS recovers, and no gate closure, exit-IP lookup or profile reload occurs. Enabling an exit node or subnet route must still request verification.

Profile-order check: switch Direct → Rule, then reload the profile. For each attempt, confirm the probe firewall is installed and `mimo_profile_prerequisites_ready` precedes `mimo_final_profile_loaded`/`mimo_final_profile_reused`. The private provider's interface must match the native PF anchor and live Quad100 route. Stop the provider and confirm its private payload becomes Reject; restart it with port 18766 occupied and confirm the fallback endpoint and full-name DNS work before repeating the transition.

| Event family | Meaning |
| --- | --- |
| `mimo_startup_guard_closed`, `mimo_pf_policy_installed` | Startup protection or a PF policy change. |
| `mimo_native_provider_published`, `mimo_profile_prerequisites_ready`, `mimo_tailnet_configuration_updated` | Native firewall/provider publication, profile prerequisite completion and live private Tailnet updates. |
| `mimo_exit_rejected`, `mimo_profile_verified` | Exit/profile verification results; protected traffic stays closed on rejection. |
| `mimo_direct_restored`, `mimo_direct_recovery_saved` | Explicit unproxied IPv4 recovery; IPv6 remains disabled until uninstall. |
| `mimo_installed_app_control_ready`, `mimo_installed_app_control_unavailable` | Installer-pinned GUI control endpoint availability. |
| `daemon_install_started`, `daemon_install_succeeded`, `daemon_install_cancelled`, `daemon_install_failed` | GUI installation outcome and saved installer log. Declining the competing-engine takeover is cancellation. |
| `daemon_client_connecting`, `daemon_client_connected`, `daemon_client_disconnected`, `mimo_session_event` | GUI connection generation, reply timing, interruption source and account activation/deactivation; separate from service health. |
| `login_item_synced`, `keychain_operation` | Per-account login synchronization and credential-operation status, without credential values. |

Installation/removal commands also log bounded steps and explicit failures. Removal does not infer user intent from an app disappearing: only an explicit uninstall restores networking and removes protection.

Installer takeover check: with another Clash/mihomo engine running, cancel the stop prompt and confirm its PID/service and existing Mimo jobs remain unchanged. Retry and approve: the listed launchd job must be disabled and unloaded, its engine must exit, and Mimo service installation must complete. A standalone engine must receive TERM only after consent. Confirm the other application's files/settings remain. Repeat from Homebrew or the GUI to exercise the macOS dialog; a timeout must cancel. A respawning engine must stop installation without killing a new, unapproved PID.

Latest focused qualification: [country, event-cycle and provider-pause evidence](Tests/ReleaseEvidence/mimo-country-events.json). [Monitoring pause example](Previews/mimo-monitoring-provider-pause.png) and [menu fallback examples](Previews/mimo-menu-country-fallback.png) use fixture data.

Event Log update: [focused validation and current investigation limit](Tests/ReleaseEvidence/mimo-event-log.json), with a [native copy-window preview](Previews/mimo-event-log-copy.png).

AirPort regression check: with the same Wi-Fi association, AutoJoinTimestamp-only, timestamp-plus-Busy and scan/radio updates must produce `network_airport_telemetry_ignored` and no block/check/open cycle. A changed SSID/BSSID, power state, removed key, unreadable value or unknown changed field remains conservative and may trigger verification. `network_airport_connection_changed` names the changed fields without recording their values. Actual route changes still close protected traffic. The VM test replays these through real configd notifications; physical Wi-Fi roaming remains a separate acceptance check.

AirPort timestamp correction and dashboard update: [before/after installed-release evidence](Tests/ReleaseEvidence/mimo-airport-timestamp.json). The earlier filter omitted AutoJoinTimestamp; the reported 20-second updates therefore still triggered cycles. Only that named metadata field is newly ignored. Unknown fields and actual association/power changes remain protected.

Network-location regression check: reapply unchanged network preferences during Direct-to-Rule preparation. `network_location_metadata_ignored` must identify only `LastUpdated` or unchanged data, with one exit-IP pass. A real location change or unknown root-field change emits `network_location_changed`; an external event during early preparation must retain its source in `mimo_cycle_event_deferred` and the follow-up. Filtering the root key does not suppress other DNS, IP, proxy, service-order or interface keys in the same notification batch.

Current transition/copy update: [focused installed-release evidence](Tests/ReleaseEvidence/mimo-cycle-classification.json). `mimo_cycle_owned_event_ignored` records an early notification later confirmed as Mimo’s own tunnel/configuration update. Such a notification cannot leave a follow-up flag; unresolved or genuine external notifications still prevent stale approval. To check the UI, compare Allowed during/after a background audit and verify a failed audit still shows blocking; copy an IP, profile path, uninstall command and each Event Log export, checking both contents and feedback.

Account-switch check (build 4): leave a GUI open in two accounts. The inactive account pauses its UI connection; returning reconnects without waiting for a service-changing operation timeout. Verify the GUI heartbeat stays responsive while login-item status is pending, and distinguish a lost connection from an actual stopped process. A known supervisor reply can show `Running(n secs)` for core while its client channel is unavailable. Check **Reconnect** does not restart services, request an exit-IP lookup or mutate PF. Physical fast-user-switch freeze recovery remains unconfirmed.
