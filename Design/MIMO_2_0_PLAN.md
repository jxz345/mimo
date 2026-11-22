# Mimo 2.0 plan

Status: implemented for **2.0 build 5**, with release authorized by the user. Installed qualification is recorded in [build 5 evidence](../Tests/ReleaseEvidence/mimo-build-5-v2.json). Current behavior and test limits are recorded in [README](../README.md) and [event workflows](MIMO_EVENT_DRIVEN_WORKFLOWS.md).

Prepared: 2026-11-22. Baseline: Mimo 1.0 build 4 (`d772840`). The user reports build 4 is working so far; this is not a claim that the rare account-switch freeze has been conclusively resolved.

## Confirmed decisions

1. Add an explicit dashboard action: **Stop engine and use Direct**. Selecting Direct alone keeps its existing behavior. This reflects the user's final choice after considering both alternatives.
2. Let other VPN/proxy software be installed alongside Mimo. When Mimo's engine is intentionally stopped, its networking controls must not interfere with that software. Handle incompatible simultaneous operation with an actionable error.
3. Add named bypass blocks in Settings. Users can add, rename, edit, delete and enable/disable blocks, and add/edit/remove their domain entries.
4. Editable bypass blocks apply in **Rule only**. Global retains its existing public-traffic proxy behavior.
5. Build on the current file structure, service architecture and profile renderer. Do not introduce a replacement application, new daemon architecture, or parallel profile format.
6. Preserve the **version 1 build 4 UI** (`d772840`) as the foundation: same toolbar, cards, typography, Settings forms, service controls and footer. Add 2.0 features within those components; do not redesign existing screens.
7. The original planning request authorized this document only. The later request to synchronize the implementation with the updated mockup authorized implementation. The subsequent release request authorizes GitHub publication after qualification.

## Build 4 baseline (before this implementation)

- `MimoServicePreferences` saves engine/core/profile Start/Stop intent. The supervisor already consults that intent after restarting.
- Stopping mihomo in a protected mode currently closes the traffic gate. It does not also select Direct and release networking.
- Ordinary Direct loads a blocking engine profile with no public proxy/DNS listeners or TUN, removes Mimo's protected DNS, and releases IPv4. It can keep the engine process running and **still disables/blocks IPv6**.
- Mimo's boot guard, supervisor, watchdog and IPv6 policy can act independently of the engine. Killing the engine alone therefore cannot provide reliable coexistence.
- Mimo stages its own private mihomo executable. The installer already asks before stopping/disabling identified competing engines. That behavior needs to respect an intentionally stopped installation in 2.0.
- The profile's website bypasses are hardcoded in `ClashVergeProfile.swift`. `MihomoProfile.swift` derives the managed profile from that template and currently selects some Global rules by array position. Adding editable groups must remove that positional dependency inside the existing renderer.

Sources: [routing/service models](../Sources/MimoShared/MimoRouting.swift), [supervisor](../Sources/MimoService/MimoSupervisor.swift), [runtime](../Sources/MimoService/MimoSystemRuntime.swift), [firewall](../Sources/MimoShared/MimoFirewallPolicy.swift), [IPv6 ownership](../Sources/MimoService/MimoIPv4Configuration.swift), [profile template](../Sources/MimoShared/ClashVergeProfile.swift), [managed profile](../Sources/MimoShared/MihomoProfile.swift), [installer](../Sources/MimoDaemon/daemon.sh).

## 1. Stop engine and use Direct

### Dashboard behavior

Keep the build 4 Dashboard / Settings and Direct / Rule / Global segmented controls in the same top toolbar. Keep route details inside Proxy configuration, equal 60-point background rows and the existing footer. Add Bypass and the explicit cleanup action to the connection card. Use **“Stop the engine and release network controls.”**, on one line at normal window width.

| State | Dashboard presentation | Available action |
| --- | --- | --- |
| Rule / Global or ordinary Direct, services installed | Existing build 4 access presentation | Stop engine and use Direct |
| Cleanup in progress | Restoring system networking…; controls busy | No duplicate transition requests |
| Full cleanup confirmed | **Mimo is inactive.**; PF Released; launchd and services Removed | The same button becomes **Activate Mimo** |
| Activation conflict | Remain inactive; identify the conflicting process/resource | Installer's **Cancel / Stop and Continue** confirmation |
| Cleanup incomplete | Report the failing cleanup stage; do not claim safe deletion | Retry cleanup |

Selecting Direct alone preserves the build 4 behavior. Explicit cleanup removes all Mimo daemons, login items and owned network controls, so `/Applications/Mimo.app` can be deleted safely. Keep saved settings for later activation. The mihomo row keeps its existing Start / Stop / Restart controls; intentional Stop invokes the same full cleanup. An unexpected engine exit in a protected mode still blocks.

### Ownership and ordering

The GUI requests the existing privileged installer, which owns cleanup independently of GUI/window lifetime. It does not poll or supervise network health itself.

1. Authorize `daemon.sh deactivate` through the existing administrator flow; serialize installer work.
2. Remove Mimo's login items across accounts, unload its core, engine, supervisor and boot/guard jobs, and wait for owned processes to exit. Keep the current GUI open to display the result.
3. Restore owned DNS, TUN/routing, PF references/policy and IPv6 settings using the uninstall recovery path. Preserve unrelated applications and newer network settings.
4. Confirm cleanup before creating the root-owned deactivation receipt. The GUI verifies the receipt and absence of the jobs before displaying **Mimo is inactive**. Missing communication alone never proves cleanup.
5. Keep the app and saved settings. No Mimo daemon remains to reclaim networking after login, wake or reboot. Deleting the app now leaves no live Mimo network controls.

The earlier internal engine-only release path remains in the implementation for service recovery, but is not the requested dashboard completion state. Its VM evidence does not qualify full deactivation.

### Activation

**Activate Mimo** runs the existing installer activation path. Preflight known competing engines and required listeners before taking over networking. Reuse the same identified-process confirmation as installation: **Cancel** preserves inactive networking; **Stop and Continue** stops only the confirmed conflict and continues installation. Do not remove the other app or its settings.

Restore all Mimo daemons and intended services, start in ordinary **Direct**, and remove the inactive receipt only after installation succeeds. Rule/Global are chosen after activation and use build 4 verification. This is a full activation, not an engine-only start. Failure remains explicit; the GUI must not infer success from an absent socket or elapsed timer.

## 2. Other installed engines and VPNs

### Contract

Installed software alone is not a conflict. Mimo should not remove another application, its Homebrew package, configuration, or launch job simply because it is installed. In the released state, another application's engine/VPN may run normally.

Mimo cannot guarantee compatibility with every VPN or detect every competing network controller. Report observed conflicts specifically; do not treat every `utun` interface as a conflict. Native Tailscale remains an intentionally supported integration.

| Situation | Proposed result |
| --- | --- |
| Other engine/VPN installed but inactive | Installation succeeds; no takeover prompt solely for installed files |
| Other engine active while Mimo is released | Mimo stays stopped and does not reclaim its resources |
| User starts Mimo while a known incompatible engine or required resource is active | Keep Mimo inactive; use installer Cancel / Stop and Continue for an identified conflict |
| Identified competing launchd/standalone mihomo engine | Use **Stop and Continue**, with the existing explicit confirmation and process identity checks |
| Unknown VPN/network extension or unclear ownership | Ask the user to disconnect it through its own controls; do not kill an arbitrary VPN process |
| Competing service appears during Mimo startup | Abort or recover according to the stage reached; show a resource-specific error, not a generic installation failure |
| Repair/upgrade while Mimo is released and another engine is active | Preserve released/stopped intent and do not request takeover merely to stage Mimo's files |
| Fresh install while another engine is active | Recommend offering **Install with engine stopped** as well as confirmed takeover, rather than forcing a stop to install |

Reuse the current conflict inventory/confirmation logic where applicable. Extend checks to actual listener ownership, engine/controller identity, saved service intent and network ownership. A process basename is a discovery hint, not sufficient permission to stop that process. Bound every check and cancellation path.

Homebrew and package validation must cover co-installed engines, repair, upgrade and removal. Keep Mimo's private staged executable and pinned dependency ownership separate from another application's runtime. Do not use forced Homebrew linking or dependency removal to resolve coexistence.

## 3. Editable bypass blocks

### Settings design

Add **Settings → Bypass** using the current Settings navigation and controls.

- A block has a name, enabled switch and domain count. Expand/select it to edit entries.
- Add, rename and delete blocks; add, edit and remove domain entries. Support pasting several domains as separate entries with per-line validation.
- Each entry has a domain and a match choice: **Exact domain** or **Domain and subdomains**. Preserve the distinction in current defaults.
- Keep edits as a draft. **Apply changes** commits the complete revision once; Cancel discards it. Several edits/toggles should not trigger several network transitions.
- Show saved versus active configuration when a change is pending or application fails. Preserve unsaved edits across incoming status updates, using the existing draft pattern.
- Explain the effect plainly: “Enabled blocks bypass Mimo's selected proxy in Rule mode.” Global ignores these blocks; Direct has no active bypass routing to change.

Migrate the current defaults into enabled blocks without changing routing: **YouTube + CDN**, **Homebrew / GitHub**, **Microsoft CDN**, **Zoom**, and a separate **Tailscale websites** block for the ordinary public-domain bypass entries. Native tailnet addressing, MagicDNS, native-process transport, local-network rules, IPv6 protection and the verification listener remain system-managed rules, not editable website blocks. Make this boundary visible in Settings.

Settings are shared across the Mac, consistent with the proxy and allowlist. Changes from two accounts use existing revision conflict handling; one account must not silently overwrite another's edits. A disabled block retains its entries. Deleting a migrated default remains deleted after future launches/upgrades. Restoring defaults, if included, is an explicit user action.

### Data and validation

Use a small typed model in `Sources/MimoShared` and extend the existing machine settings schema:

| Field | Purpose |
| --- | --- |
| Stable block ID | Rename/edit without losing identity |
| Name | User-facing label |
| Enabled | Include/exclude the block from Rule rendering |
| Domain entries | Normalized domain plus exact/suffix match type |
| Optional default identifier | One-time migration and explicit default restoration |

Normalize case/trailing dots and define internationalized-domain handling explicitly. Reject URLs, paths, ports, wildcards not represented by the match choice, empty/invalid labels, control characters and raw rule/YAML fragments. Enforce reasonable documented size limits. Explain duplicates/overlaps, especially when a disabled block's domain is still included by another enabled block.

Do not add arbitrary proxy targets, scripts, IP/process rules, remote subscriptions or full YAML editing in this scope. Domains compile only into validated `DIRECT` rules. The existing protected DNS policy remains intact: bypassing website traffic does not automatically make its DNS lookup use an unprotected resolver.

### Profile generation and application

Extend `ClashVergeProfile.swift` and `MihomoProfile.swift`; keep the existing trusted profile sections and delivery mechanism. Define named rule sections rather than relying on `prefix(7)`/`suffix(8)` offsets. Preserve system-rule precedence and the final proxy fallback; enabled bypass groups participate only in Rule. Keep the legacy compatibility export consistent where it is still exposed.

Current rule semantics are documented by [mihomo's primary routing-rule reference](https://wiki.metacubex.one/en/config/rules/): matching is ordered, exact-domain and suffix-domain rules differ. Validate against Mimo's pinned engine, not assumptions about a newer engine release.

| Current mode/state | Applying bypass edits |
| --- | --- |
| Direct, engine stopped | Validate and save; no engine start, PF change, profile reload or IP lookup |
| Ordinary Direct | Validate and save for later Rule use; no protected transition |
| Global | Validate and save for later Rule use; effective Global profile is unchanged, so do not reload/reverify solely for bypass edits |
| Rule | Prepare/validate the complete candidate before disrupting traffic; apply one revision through the existing protected workflow |
| Rule apply fails | Validation or revision conflicts preserve the draft and previous saved settings. A later runtime failure retains the saved desired rules, reports blocked/unconfirmed routing, and cannot reopen without verification |

Validation or a no-op edit must not interrupt connectivity. Successful changes must invalidate any cached profile/readiness proof tied to the previous effective rules. If rollback requires reloading/reverifying the previous profile, report that accurately; do not promise uninterrupted hot reload before it is tested.

## Implementation map within the current structure

| Existing area | Planned work |
| --- | --- |
| `Sources/MimoShared/MimoRouting.swift` | Keep internal release intent separate from fully inactive installation state |
| `Sources/MimoShared/DaemonProtocol.swift` | Shared bypass settings, validation/migration and revision-aware commands/state |
| `Sources/MimoShared/ClashVergeProfile.swift`, `MihomoProfile.swift` | Named rule sections and typed bypass rendering; remove positional selection |
| `Sources/MimoShared/MimoFirewallPolicy.swift` | Released networking state distinct from ordinary Direct and protected policies |
| `Sources/MimoService/DaemonService.swift`, `MimoCoordinator.swift` | Serialize transitions/settings and reject stale results; publish backend-owned status |
| `Sources/MimoService/MimoSupervisor.swift`, `MimoSystemRuntime.swift` | Internal release/recovery operations; full deactivation uses the installer |
| `Sources/MimoService/MimoIPv4Configuration.swift`, `MimoDNSConfiguration.swift` | Ownership-aware restoration and re-acquisition without overwriting other software |
| `Sources/MimoDaemon/daemon.sh`, `pf-guard.pl`, startup/service entry points | Full deactivate/activate operations, verified receipt, cleanup and confirmed conflict takeover |
| `Sources/MimoApp/MimoViews.swift`, `PublicIPMonitor.swift`, current draft/navigation helpers | Dashboard action, accurate progress/conflicts, Bypass editor; no GUI-owned supervision |
| `Packaging/Formula`, packaging scripts and tap cask | Dependency/co-install behavior and stopped-intent upgrade checks |
| Existing shared, service, app and installed-runtime test directories | Extend existing harnesses and evidence format; no separate replacement test stack |

Small focused model/view files may be added inside the current modules. Do not reorganize or rename the repository to implement these features.

## Implementation sequence

1. **Ownership and state contract:** settle the suggestions below, enumerate every boot/repair writer, define persisted release intent and crash recovery; add behavior tests for intent and transitions.
2. **Engine release and restart:** implement the combined action, full networking release, persistence, accurate dashboard status and restart preflight. Test with another real engine/VPN in mimo-vm before proceeding.
3. **Installer coexistence:** extend confirmed takeover with inactive installation/repair behavior, and verify Homebrew/package co-install and dependency preservation.
4. **Bypass model and renderer:** migrate existing defaults, add validation and named rule sections, prove unchanged defaults/Global behavior and Rule-only edits.
5. **Bypass settings and application:** implement shared revision-aware drafts, one Apply operation and recovery/error presentation.
6. **Qualification and documentation:** run the release matrix, update README/features/manual checks, changelog and event-driven workflow reference, then package 2.0 only when requested/approved for release.

The dated release evidence distinguishes completed checks from physical-Mac and arbitrary-VPN scenarios that remain outside the tested scope.

## Acceptance criteria

### Release and coexistence

- From Rule, Global and ordinary Direct, the explicit stop action reaches Mimo is inactive with all Mimo jobs, login items, listeners, TUN/DNS/PF/IPv6 ownership removed or restored.
- Repeat after a dead engine, dead controller, partial cleanup, forced GUI quit, supervisor crash and account switch. Report incomplete state honestly and recover deterministically.
- Reboot, wake, repair and upgrade do not start Mimo's engine or install blocking PF when stopped/released was saved.
- Install/start another mihomo-based application while Mimo is released. Verify IPv4, IPv6 where supported, public DNS, the other application's listeners and its VPN routing.
- Starting Mimo against an active conflict produces a specific, cancellable error and does not silently stop the other service or disrupt released networking during preflight.
- A service appearing between preflight and startup is handled without retry loops or an unreported partial takeover.
- Native Tailscale/MagicDNS remains functional in supported combinations. Do not reject it merely for having a tunnel interface.
- Routine core/supervisor monitoring cannot reclaim networking in released mode. Intentional Stop remains distinct from an unexpected protected-engine failure and a GUI communication failure.
- Two accounts can issue conflicting commands without leaving mode, intent, process state and network ownership inconsistent.

### Bypass blocks

- Default migration preserves current Rule routing and current Global routing, including exact-versus-suffix matching and system-rule precedence.
- Enabled/disabled, added/edited/deleted blocks survive restart/upgrade; deleting defaults does not resurrect them.
- Exact/suffix boundaries, normalization, invalid inputs, duplication, disabled overlapping blocks and size limits are covered.
- Applying in ordinary Direct or Global does not start the engine, reload a profile, change PF or request verification. Fully inactive Mimo cannot apply shared edits until activation; drafts may be retained.
- Applying in Rule changes actual routing for a controlled test domain. Check both new connections and the documented handling of existing connections; rendered text alone is insufficient evidence.
- Validation failure leaves current traffic untouched. Runtime failure/rollback cannot display the unconfirmed candidate as active or open unverified protected access.
- Multiple GUI sessions preserve unsaved drafts and handle concurrent revision changes explicitly.

All runtime/installation/network/UI tests run in **mimo-vm**, with original settings and network state preserved/restored. Physical acceptance should include the user's chosen second VPN and fast user switching, while acknowledging that the build-4 freeze report is hard to reproduce. Do not claim universal VPN compatibility from one VM test.

## Current disposition

The approved scope is full deactivation with a reversible **Activate Mimo** action, installer conflict confirmation, Rule-only bypass editing, and the existing file/module structure. Version 2 extends the build 4 interface. The mockup is a simulation with fictional state, not runtime evidence. Full deactivation/reactivation, coexistence, bypass routing and inactive reboot have installed VM coverage. Version 1.0 build 4 remains the preserved baseline release; 2.0 is published separately.
