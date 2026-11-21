# Signed Network Extension engine evaluation

Updated 2026-11-19. This is an integration experiment, not a release qualification or an approved replacement of Mimo's engine.

## Constraint and candidates

The user confirmed that no Apple Developer account is available. The experiment must use publishers' unchanged, signed releases with normal macOS security enabled. Building our own Network Extension, disabling SIP, and borrowing another application's signing identity are not deployment options.

ProjectClash was dropped at the user's request after reviewing its user-session dependency. Clash Mi's runtime evaluation ended when the user declined Full Disk Access; do not grant it or bypass the permission requirement:

| Candidate | Distribution | Extension packaging | Status |
| --- | --- | --- | --- |
| ProjectClash / Clash | Mac App Store, application ID 6794257189 | Packet-tunnel app extension in the published client source | Dropped by user; no further installation or testing |
| Clash Mi 1.0.32.1803 | Official Homebrew `clash-mi` cask | Packet-tunnel system extension | Extension activated; first connection failed for lack of Full Disk Access. User declined that permission; runtime evaluation ended |

The ProjectClash engine repository and the signed application are different deliverables. Its SDK does not remove the signing requirement for a custom Mimo extension. Its CLI did not resolve the user-session dependency.

## Multiple-user requirement: mandatory acceptance gate

The original project goal remains one machine-wide engine and policy, with per-user Mimo interfaces. A replacement must not depend on a designated account staying logged in. One profile, allowlist, mode, monitoring budget and traffic decision must remain authoritative across accounts. Read-only status is available to local users; shared mutations retain Mimo's administrator authorization and revision checks. GUI quit, fast user switching, logout of the account that started the tunnel, and an empty login window must not stop the shared service or release protected traffic.

ProjectClash's published macOS target is an app extension, not a system extension. Apple documents that app extensions run in a user context and terminate when that user logs out. This is a documented architectural mismatch with Mimo's logout-independent requirement, even though ProjectClash offers a useful CLI. The user dropped this candidate; no further runtime tests are planned. Do not equate system-wide packet routing while connected with a service that is independent of every user session.

Clash Mi's signed system extension is a better structural candidate for a session-independent engine, but its profile ownership, cross-user controls and permissions remain unqualified. A system extension alone does not establish a shared configuration model or protection before it starts.

Any future candidate must demonstrate traffic and control behavior for `jay` and `mimotest`, concurrent account activity, conflicting mode changes, launching the second account's app, initiating-account logout, and reboot with no GUI opened. Failure of this requirement disqualifies the candidate as the replacement, irrespective of single-user proxy or throughput results. These tests were not reached for Clash Mi.

## Isolation and recovery

- Network changes and candidate installation are confined to mimo-vm. Delta's networking is unchanged.
- The VM baseline is Direct, with the saved proxy, one allowlisted address, and all three existing Mimo services enabled.
- A root-only VM backup contains the original settings, service intent, helper, launchd definitions, and a saved credential fingerprint. Credentials and private profiles must not appear in committed evidence.
- Preserve the installed Brew mihomo dependency until replacement compatibility is established.
- Stop the existing engine before candidate activation. Identify or remove Mimo's own enforcement from candidate leak measurements so it cannot mask a candidate failure.
- Restore the original Mimo configuration and service intent after each destructive or failure test. Do not grant a release qualification manifest.
- The user will handle password and system approval prompts. Do not connect a candidate while the manual setup handoff is pending.

## Required runtime checks

| Area | Required evidence |
| --- | --- |
| Installation | Published signature, extension entitlement, successful macOS activation without our own signing |
| Profile delivery | Private local profile import; effective proxy, DNS, rules and overrides compared with Mimo's profile |
| External control | Authenticated local status, mode and proxy selection; profile reload and persistence; unsupported operations identified explicitly |
| Verification gate | Ordinary traffic blocked while a restricted probe observes the exit; empty or incorrect allowlist cannot release traffic |
| Modes | Direct independent of approval; Rule exceptions preserved; Global preserves required LAN/tailnet access |
| Failure handling | Invalid proxy, engine/provider crash, controller disappearance, existing connections and configuration changes |
| Independent operation | GUI quit, Mimo absent, extension restart, logout and boot evaluated separately |
| Multiple users | One authoritative policy/engine; both accounts see consistent state; cross-user traffic and administrator controls; survives initiating-account logout |
| Networking | TCP, UDP, DNS, IPv6 bypass, Tailscale coexistence and interface changes |
| Recovery | Explicit Direct, app stop, restart and uninstall restore expected networking without changing the user's saved configuration |

Physical sleep is unavailable in this Tart guest and must remain a separate qualification item. A system-extension entitlement alone is not evidence of first-packet boot protection.

## Initial observations

- `brew install --cask clash-mi` succeeded under the VM's `jay` account, which owns Homebrew. The existing `mimotest` Brew wrapper could not write that prefix; ownership was not changed.
- The installed Clash Mi application and its `com.nebula.clashmi.clashmiServiceSE` extension pass strict signature verification. Both declare `packet-tunnel-provider-systemextension`.
- Clash Mi source exposes `includeAllNetworks` and `enforceRoutes`. An `auto_connect_at_boot` setting also exists, but the pinned release source labels that setting Android-specific; it must not be presented as proven macOS startup support. These behaviors are not yet qualified.
- ProjectClash documents a bundled `clash-cli` with status and mode control. Its CLI explicitly rejects profile `reload` and `check`; profile operations are owned by the application. This may limit replacement compatibility and must be tested against the shipped app.
- Clash Mi's FAQ also describes dashboard profile reload and core restart as disabled, despite its generic API reference listing reload. Runtime behavior must resolve that discrepancy.
- Computer use can observe the Tart window, but input currently fails with `noWindowsAvailable` or a ScreenCaptureKit capture error. ProjectClash's installation handoff is cancelled. Clash Mi's documented `clash://connect?background=true` control URL successfully brought up its system-extension approval request in the VM. After the user's approval, `systemextensionsctl list` confirms `clashmiServiceSE` is activated and enabled.
- The first connection created a `Clash Mi (system)` VPN configuration but did not connect. `scutil --nc status` records `VpnError:FullDiskAccessPermissionRequired`. The pinned release's English message specifically requests Full Disk Access for `clashmiServiceSE`. The user declined this permission. No candidate traffic-blocking, cross-user, logout or boot pass is claimed.
- The vendor FAQ explains that on some Macs the system extension cannot read Clash Mi's own configuration without Full Disk Access. This is the vendor's explanation for the observed failure, not a general Network Extension requirement. The vendor's promise to use the permission only for configuration does not narrow the access granted by macOS. No supported narrower workaround has been established for this signed build; do not change TCC, weaken permissions, relocate files to evade the denial, or modify the signed extension.
- The pinned release's normal Quit path calls `_quit()` → `Biz.uninit()` → `VPNService.uninit()`, which calls `stop()` on desktop platforms. Closing the window only hides it. This is a source-level concern for a GUI-independent engine, not a measured logout result. Test normal Quit separately from window close and process crash; system-extension packaging alone does not remove this application-controlled shutdown behavior.
- Staged a credential-free test profile with an initially rejecting `MIMO-EVALUATION-GATE` selector. Public traffic can later be released deliberately by changing that selector to `DIRECT`, allowing positive and negative controls without copying the saved proxy credential. The fixture preserves the VM's management subnet and tailnet. Its ordinary mixed port is 27890, its authenticated controller is 19090, and `include_all_networks=true` / `exclude_local_networks=true` are confirmed in the generated service configuration. Automatic connection is disabled.
- Stopped Mimo's GUI/core/supervisor/mihomo and cleared only Mimo's PF anchors before candidate activation. Saved configuration remains unchanged. Ordinary IPv4 HTTPS succeeds from both `jay` and `mimotest` in this baseline. IPv6 network-service preferences are still disabled by Mimo, so a later failed IPv6 probe cannot be attributed to Clash Mi without a separate controlled experiment.

## Restored after permission refusal

Clash Mi's application was moved to the Bin by the user on 2026-11-19, and its Homebrew receipt and disconnected VPN service were removed. There is no running Clash Mi app and `scutil --nc list` contains only Tailscale. **Removal is not yet complete:** after a real VM reboot, macOS still lists `com.nebula.clashmi.clashmiServiceSE` as activated and enabled. Do not report that extension as removed. Full Disk Access was never granted, and SIP remains enabled. The earlier test fixture and generated service files remain archived in root-only VM evidence.

Mimo's original supervisor, core, mihomo and private profile service are running again in Direct mode. Saved settings, proxy credentials, service intent, helper and launchd definitions match the baseline. Mimo's PF rules are restored, Tailscale remains connected, and IPv4 HTTPS succeeds for both `jay` and `mimotest`. The original Mimo GUI has been reopened. Sanitized restoration evidence is in `/var/tmp/mimo-ne-evaluation-69wq5_l5/restoration.json` inside the VM.

## Sources

- [ProjectClash client](https://github.com/ProjectClash/Clash-Client)
- [ProjectClash CLI](https://github.com/ProjectClash/Clash-Client/blob/main/cli/HELP.txt)
- [ProjectClash Mac App Store listing](https://apps.apple.com/us/app/clash-rule-based-proxy/id6794257189?platform=mac)
- [Clash Mi Homebrew cask](https://formulae.brew.sh/cask/clash-mi)
- [Clash Mi FAQ](https://clashmi.app/guide/faq)
- [Clash Mi pinned permission messages](https://github.com/KaringX/clashmi/blob/v1.0.32.1803/lib/i18n/en.i18n.json)
- [Clash Mi pinned application lifecycle](https://github.com/KaringX/clashmi/blob/v1.0.32.1803/lib/my_app.dart)
- [Clash Mi pinned VPN lifecycle](https://github.com/KaringX/clashmi/blob/v1.0.32.1803/lib/app/local_services/vpn_service.dart)
- [Apple Network Extension deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
