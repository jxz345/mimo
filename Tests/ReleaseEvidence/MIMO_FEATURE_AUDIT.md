# Mimo feature audit — 2026-11-19

The reported immediate Rule error is the production qualification gate: **“Protected routing is not qualified on this build. Direct remains available.”** The saved proxy, password and approved IPv4 are present. This rejection occurs before testing the proxy. Normal Rule/Global remain unavailable; isolated tests use a separately compiled VM-only helper. Passing those tests does not enable protected routing in the normal app.

All network mutations and packet captures were confined to `mimo-vm`. Delta's networking was not changed. Saved settings and credentials are backed up privately, compared on restoration, and never included in published evidence. No observed IP is automatically approved and no qualification manifest is created.

## Findings and changes

1. The dashboard/menu could replace the useful failure with a generic gate-close reason. They now retain the actual failed-verification message, alongside any recorded IP that triggered blocking. An unavailable firewall state still takes precedence over an older lookup error.
2. Repeated service testing exposed a real mihomo Start race: launchd returned a PID before the Unix controller accepted connections. The immediately following verification failed with curl connection error 7 and stayed blocked. Start and Restart now confirm the blocking profile through the controller before acknowledging completion. Protected traffic remains closed until the subsequent exit-IP approval.
3. Native Settings sidebar/default-button accents still inherited blue. A named greyscale accent asset now covers these native controls in both appearances.
4. Recovery buttons needed more space above the service table. The reserved status area now includes that gap while keeping the dashboard at 1040 × 570.
5. The audit driver now waits for core's XPC readiness after deployment. An intermediate attempt sent its first mode command during deployment startup and failed; this is retained separately from the product readiness bug. Cleanup also now confirms Direct through both live services before disarming its watchdog, rather than trusting the previous gate-state file.

## Coverage matrix

| Area | Evidence and scope |
| --- | --- |
| Normal Direct | Current IP and country; no allowlist approval requirement; explicit Direct recovery; core/engine/profile Stop, Start and Restart. |
| Normal Rule/Global | Both must report the qualification failure and remain blocked. Returning to Direct must recover. |
| Protected Rule/Global | VM-only helper: saved SOCKS5 proxy, approved exit, TCP/UDP/DNS/HTTPS, Rule public-domain exceptions, Global proxy routing and IPv6 denial. |
| Allowlist | Empty/wrong lists block; exact rejected IP remains visible; restoring the original list allows fresh verification; revocation closes an existing HTTPS connection. Shared tests cover normalization, validation and IPv6 rejection. |
| Proxy configuration | Saved metadata and Keychain password preserved; wrong username/unavailable proxy block; restoration recovers. Native model tests cover drafts, concurrent revision conflicts and secret handling. |
| Profiles | Authorized snapshot matches the blocking profile in Direct; protected snapshots match saved credentials without writing runtime credentials to disk; manual and repeated reloads close traffic and reverify. |
| Services | Core, mihomo and profile lifecycle; repeated engine Stop/Start and Restart; core hang/resume, core crash and engine crash; altered controller configuration. |
| Tailnet provider | Start → Stop → Start, loopback provider availability and public-access preservation in Direct/Global. This checks the provider service, not peer relay reliability. |
| Monitoring | Immediate network-change invalidation and IP check; manual refresh, provider selection/budgets/cooldowns, deferred work and country confirmation covered by shared/core suites. Settings shows the mandatory immediate-check and IPv4 policies. Live Refresh now updates the dashboard, menu and Dock through checking back to Direct with a fresh result. |
| Dashboard/menu | Eleven native dashboard states rendered in light/dark, compact stable layout, country flag only in Current connection, white Direct arrow, red blocking symbol, specific error and rejected-IP presentation; native scenario tests plus live Tart inspection. The normal-build qualification failure is confirmed in both the live menu and main dashboard. |
| Shared-setting authorization | Use Direct invokes the native administrator prompt. Cancelling leaves Rule blocked and shows an authorization message; the already-authorized administrator API restores Direct. No GUI credential prompt was bypassed. |
| Settings/login | All four sections inspected live. Login on/off synchronization between General and menu; Dark → System and reduced transparency on/off; original personal preferences restored. |
| GUI independence | Quit GUI exercised live; the process exits and the supervisor continues in active Global during the VM-only run. Subsequent lifecycle/packet checks run without the GUI. |
| Event Log | Live native Event Log opens, lists events and redacts IP values. Automated logging tests cover formatting and redaction. |
| Widgets/Control Center | Shared presentation/content-change tests and arm64 extension build. Widget placement and Control Center interaction were not repeated live in this audit. |
| Installer/Homebrew | Installer and daemon regression suites rerun. Previously published 11-check real Brew lifecycle evidence remains valid for its recorded archive; destructive install/uninstall was not repeated against the user's configured proxy VM. |
| Startup/upgrade/sleep | Existing reboot/upgrade evidence reviewed. Full-boot protection and real sleep remain incomplete as detailed below. |

Fixture-only native renders: [qualification error, light](../../Previews/26-mimo-qualification-error-light.png), [dark](../../Previews/27-mimo-qualification-error-dark.png). Live screenshots containing personal configuration are not published.

## Remaining acceptance

- Full-boot blocking is not established: the recorded reboot has a 4.892-second interval and 118 ordinary packets before the guard is confirmed, with zero afterward. See [boot evidence](mimo-protected-boot.json).
- Native Tailscale relay repeatability remains unresolved, including failures observed in Direct baselines. Provider lifecycle success is not peer connectivity qualification. See [relay evidence](mimo-relay-repeatability.json).
- The VM refuses real sleep; actual sleep/wake requires a supported environment.
- Copied-app Homebrew setup prompts, cancellation/keyboard paths, and live widget/Control Center acceptance are not completed by this run.
- The public 1.0 archive and tap checksum are unchanged. These fixes are development source/VM changes, not a newly qualified release.

## Local validation

Shared suite: **160 tests passed**. Native app/render, service, daemon, installer and packet-driver regression suites passed; the preview passed **74 DOM checks**. The arm64 Release app and widget extension build and ad-hoc signature verification passed.

The expanded saved-proxy run passed **88 checkpoints**, including repeated mihomo Stop/Start and Restart, all captured traffic boundaries, and Direct restoration (`mimo-saved-proxy-yg_zbcm_`). After tightening cleanup readiness, the focused Direct/allowlist run passed **14 checkpoints** (`mimo-saved-proxy-f1zdyx5v`). An immediate independent verification then passed: current GUI/helper match, exact backed-up settings/service intent and password are preserved, both services confirm Direct, a current IP exists with no rejection event, temporary captures/routes are removed, and no qualification manifest exists.

The initial readiness failure and intermediate driver failure remain in the [machine-readable audit](mimo-feature-audit.json), alongside both successful runs. The full 88-check run used the same runtime source; the later change strengthens the test driver's cleanup. Private packet captures, personal settings and credential fingerprints remain root-only in the VM.

## Subsequent protection repair

The follow-up adds a dedicated IOKit queue and a PF power sub-anchor, with stale-approval fencing across sleep/wake. The [77-check power regression](mimo-power-guard.json) uses the real firewall but injected power events; [an actual VM sleep request](mimo-power-capability.json) is still refused. The current shared suite passes 163 tests. Service, cleanup fault tests and the arm64 Release build pass.

The [boot investigation](../../Design/MIMO_BOOT_PROTECTION.md) rejects the network-location workaround after a cold-start experiment; it is not shipped as protection. A signed packet-filter candidate still requires provisioning and measured boot/crash acceptance.

The native relay repair adds authenticated discovery of Tailscale’s separate bootstrap hostname set, incremental infrastructure publication, and a fresh socket snapshot after the user/route probe. [All relay repair attempts](mimo-relay-repair.json), including failed experiments and the corrected lifecycle test-driver error, are retained separately from the earlier audit.

Further repeated relay testing exposed two concurrency defects: native socket enforcement was waiting behind main-actor work, and concurrent helper children inherited unrelated stdin descriptors, delaying EOF for firewall/profile commands. The worker now enforces independently and fences stopped sessions; subprocess spawning closes all descriptors except explicitly assigned stdio. The isolated EOF regression changes from timeout 124 to successful delivery of 300,000 bytes while the unrelated child is still running. Live repeatability remains tracked by the relay repair record rather than inferred from this unit test.

The final candidate passes **44 relay checkpoints in each of two consecutive runs**, including ten forced DERP reconnects, both native down/up cycles, and peer Stop/Start/Restart with verified public access preserved. The fix also separates native sub-anchor transactions from the parent firewall lock; delayed parent transactions had still made socket observations obsolete. A native restart must reach a stable verified public baseline before the separate provider-control assertions begin. The driver retains tracebacks and private supervisor state for failures. The two runs retain exact helper hashes and packet-boundary results in the relay repair record. Full power/failure regression results are recorded separately.

Final regression on the same repaired helper passes **77/77 power and failure checks**, with continuous packet attribution. The matching normal GUI/helper are installed in the VM; exact configuration/password/service intent and fresh Direct IP without rejection were independently verified. The GUI heartbeat advances, its menu icon is present, native Tailscale is Running, and the temporary test state is removed. Normal Rule/Global remain blocked: early boot is not fixed and real sleep is not qualified. The signed packet-filter candidate and physical-Mac test still need implementation/validation and the pending signing/hardware information.
