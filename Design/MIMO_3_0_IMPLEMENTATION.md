# Mimo 3.0 implementation record

Authorized 2026-11-25: implement `MIMO_3_0_PLAN.md`, install a local candidate in
`mimo-vm`, and execute the relevant dual-stack and installed-app campaigns.
GitHub publication is outside this instruction. Existing evidence and frozen
working profiles remain historical inputs, not v3 test results.

## Work sequence

1. Shared family settings, paired verification models and migration.
2. Pinned engine family enforcement and private-probe ACL; canonical profile
   renderer with private DNS policies and silent captured echo suppression.
3. Core-owned DNS, provider removal, flat firewall, guarded cleanup and recovery.
4. Native UI, installer, dependency identity and documentation.
5. VM recovery snapshot, local installation, standalone profile campaign and
   installed-app regressions; record physical-only/unavailable checks separately.

## Current state

Implemented and installed locally. The persistent active guard and recovery retry
correction passed **68/68 VM qualification rows**, including 32 traffic/fault rows
with zero native attempts and successful recovery. Both managed Direct with its
engine running and released Direct with the app retained passed service/network
checks. The earlier empty-active policy's five bypass and four core-resume failures
remain historical evidence. Native GUI and physical-Mac qualification are still
incomplete; this is not a blanket release qualification.
See [the active-guard results](MIMO_V3_ACTIVE_GUARD_RESULTS.md) and preserve the
[earlier closure evidence](MIMO_V3_QUALIFICATION_CLOSURE.md). No GitHub publication
requested or performed.

- Removed native utun provider service/models/UI/control commands, provider files,
  publication/observer code and the legacy dashboard exporter. Only explicit old-version
  migration and cleanup paths remain. No provider port or fallback exists in v3.
- Canonical profiles use core-owned system DNS, static native exclusions, the
  default engine IPv6 TUN address, public DoH through Proxy and private negative
  policy. Strict IPv4 enforcement works before and after hostname restoration in
  both engine modes. Private verification ingress has an engine-enforced ACL.
- Dual-stack approval requires two fresh family-pinned, allowlisted observations
  from the same generation/revision/attempt. No optimistic opening remains.
- Flat closed/probe/active PF, revocation epoch, readback, DNS drain-before-TUN teardown,
  old-policy cleanup and post-release native checks are implemented.
- Approved native dashboard layout implemented; visual inspection remains pending.
- VM recovery clone: `mimo-pre-v3-20261125`; qualification runs only on `mimo-test-macos`.

## Executed validation

The following records the earlier v3 campaigns. The subsequent active-guard
campaign, current engine/package identity and restored state are documented in
[the active-guard results](MIMO_V3_ACTIVE_GUARD_RESULTS.md).

- Shared Swift suite: **209 tests, zero failures**.
- Service suite: all assertions passed, including XPC, revision/concurrent-control,
  power/session fencing, shared proxy credentials, installation and cleanup models.
- Patched engine Go suites passed. A fresh source/patch rebuild reproduced SHA256
  `9103954f5cb48c2e93826ba1f61e6c2677d9363680eecdf00b09b94c3a4253d8` exactly.
- Native app compiles and its ad-hoc bundle signature verifies.
- **3,620/3,620 isolated v3 campaign checks passed**: 3,120 matrix and 500 focused.
  Both families × Rule/Global × six proxy capabilities were exercised. Native DNS
  uses the production core DNS owner. Short names/reconnect/restoration pass in
  both families; no captured native fallback or synthetic ping reply was observed.
  [Sanitized evidence](../Tests/MihomoRuntimeTests/Evidence/v3/runtime-summary.json).
- First installed-app attempt rolled back because the Debug login-cleanup helper
  used a separate dylib rejected under hardened ad-hoc signing. The unsigned local
  build now uses `ENABLE_DEBUG_DYLIB=NO`. Subsequent installation verified every role.
- Installed scans exposed an empty-file bug in the independent guard: an empty
  expected policy was treated as missing. Corrected and covered by real-file
  regression tests. Direct now remains open across repeated guard scans.
- All eight core/supervisor/engine presence combinations recovered in the VM.
  A stronger repetition passed **9/9** observations (baseline and eight role
  combinations) requiring the versioned engine controller, rather than treating
  a running launchd wrapper as sufficient engine readiness.
  [Controller-qualified evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-recovery.json).
- Full Stop exposed lifecycle lock contention during native DNS verification.
  Native checks now run outside that lock; maintenance uses short PF revocation,
  and an old Direct release cannot override a newer maintenance/close epoch.
  The next run exposed a wrapper/recovery race: failed controller reload during
  guarded startup could stop the wrapper on every recovery attempt. Direct now
  preserves that guarded wrapper when no TUN exists, while still stopping an
  unresponsive actual engine or a surviving tunnel.
- **38/38 installed lifecycle checks passed**: all role-presence combinations,
  full Stop, legacy child filter/NAT/table removal, DNS/TUN/boot-guard removal,
  native release checks, uninstall and two reinstalls. The final state is an
  installed, healthy managed Direct session.
  [Evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-lifecycle.json).
- **36/36 real-engine private-probe checks passed** over isolated loopback:
  both families and both modes, exact host/port admission, family pinning,
  wrong/no credentials, suffix spoofing and literal-address rejection. Accepted
  connections exchanged a nonce; a CONNECT response alone was not success.
  [Evidence](../Tests/MihomoRuntimeTests/Evidence/v3/probe-acl.json).
- Installed HTTPS verification correctly stayed blocked against the initially
  untrusted local fixture. After the user trusted the temporary certificate,
  **44/44 installed HTTPS checks passed** across IPv4/dual-stack and Rule/Global:
  fresh family-pinned observations, actual engine configuration, empty active PF,
  owned DNS, external-provider absence, IPv4/IPv6 service access, Refresh freshness
  and Direct cleanup. No TLS bypass was added to production.
  [HTTPS evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-https.json).
- That campaign found a real configuration bug: core discarded the requested
  network family, and supervisor polling could overwrite the selection in Direct.
  Core now persists the family, requires fresh approval when it changes in a
  protected mode, and preserves the future selection in Direct without a lookup.
  Shared multi-account and coordinator-poll regression tests pass; the rebuilt
  candidate passed the complete HTTPS rerun. A separate preliminary failure was
  a harness error: Mihomo's built-in `Compatible` provider represents inline
  proxies and is not the removed native provider.
  [Preliminary outcomes](../Tests/MihomoRuntimeTests/Evidence/v3/installed-https-preliminary.json).
- **13/13 active recovery checks passed**: dual-stack Global baseline, all eight
  core/supervisor/engine presence combinations, live IPv4/dual-stack and Rule/Global
  changes, and Direct cleanup. Removed roles recovered automatically with a new
  paired approval; the all-present control retains its existing valid approval.
  Recovery elapsed times are observations, not packet-denial deadlines.
  [Active recovery evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-active-recovery.json).
- **9/9 paired-failure checks passed**: IPv6 proxy refusal and an IPv6 address
  absent from the allowlist both retain denial, even when IPv4 succeeds; public
  proxy/DNS listeners stay closed. Correcting the allowlist restores paired
  approval. Transport refusal retains the provider cooldown; selecting another
  eligible fixture provider restores approval without bypassing that cooldown.
  The initial harness wrongly expected Refresh to ignore cooldown, and its failed
  expectation is retained separately.
  [Paired failures](../Tests/MihomoRuntimeTests/Evidence/v3/installed-paired-failure.json),
  [preliminary expectation](../Tests/MihomoRuntimeTests/Evidence/v3/installed-paired-failure-preliminary.json).
- **27/27 installed failure checks passed** across IPv4/dual-stack and Rule/Global:
  failed verification retains denial, public proxy/DNS listeners remain blocked,
  the parent remains flat, Direct recovers, all eight role combinations recover
  while closed, and removal of Mimo's closed parent is repaired.
  [Evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-failure.json).
- Before the user-approved HTTPS continuation, restored the original VM settings and proxy selection, removed the fixture
  proxy and temporary System-keychain certificate, stopped the Delta fixture and
  browser bridge, and deleted the temporary CA key. The VM remains installed in
  healthy Direct with the pinned controller, empty PF and no owned DNS override.
  [Final state](../Tests/MihomoRuntimeTests/Evidence/v3/installed-final-state.json),
  [settings restoration](../Tests/MihomoRuntimeTests/Evidence/v3/installed-restore-results.json).

## Remaining qualification

The subsequent active-guard revision, including native transport compatibility,
is tracked in [MIMO_V3_ACTIVE_GUARD_RESULTS.md](MIMO_V3_ACTIVE_GUARD_RESULTS.md).
It uses engine `v1.19.34-mimo-v3.2`, not the earlier engine in the historical
campaigns below. Its local shared suite has 214 passing tests; the service suite,
31 independent PF assertions, Release package and four annotated-template parser
checks pass. Canonical YAML comments now accompany both templates and private
runtime delivery. Settings → Maintenance documents the current PF policies and
copyable inspect/release/install/uninstall commands without adding a GUI owner.
Native visual inspection of that page has not been completed.

The full candidate is installed in mimo-vm. Successful production HTTPS family
approval is now qualified against the closed local fixture. Native GUI visual
inspection remains separate from the profile, private-ingress, recovery and
cleanup campaigns above. The fixture does not qualify an arbitrary remote proxy's
IPv6 support.
Physical account-switch/login freezes, forced sleep and Wi-Fi hardware transitions
cannot be qualified by model tests or by this VM alone.

### User-approved HTTPS continuation — 2026-11-25

A fresh test certificate and instructions were staged **inside mimo-vm**
at `/Users/Shared/Mimo-v3-Test/`. The user reported trusting it before the resumed
campaign; root's SSL verification for `ipwho.is` succeeded. Certificate name:
`Mimo v3 temporary HTTPS test (2026-11-25)`. It expires
`2026-11-27 01:02:22 UTC`; SHA-256:
`5F:7B:36:63:F1:CE:DE:F3:E9:67:FE:C7:F1:1D:7D:87:8B:75:58:28:50:C3:43:54:35:68:66:A7:92:52:88:34`.

The certificate was trusted for SSL in the VM's System keychain only. The closed
Delta fixture serves the production provider/DoH destinations locally; no public
forwarding or disabled TLS validation is used. Its private key stays owner-only
under ignored `.build/v3-user-approval/` during the campaign. Original VM settings
and proxy selection are now restored; the fixture proxy was removed, the fixture
listeners stopped, and its temporary key deleted. The user subsequently requested
keeping the certificate for future testing. Its System-keychain entry was restored
and its existing SSL trust verified; trust removal is no longer requested.
The public certificate remains at the staged path above. The private server key
had already been deleted before that instruction, so this certificate cannot
serve a new HTTPS fixture: a replacement certificate/key will be needed for a
future campaign. [Cleanup status](../Tests/MihomoRuntimeTests/Evidence/v3/installed-cleanup.json).

The final candidate is healthy managed Direct with no Mimo PF rules, owned DNS
override or TUN. Screen Sharing's controls stopped responding during native
visual inspection; no GUI visual pass is claimed. The console remained usable
for all installed checks and final-state verification.

## Failure-scenario coverage and remaining limits

These rows distinguish code/model validation from installed observations. A
passing profile matrix does not imply instantaneous host-wide crash protection.

| Case | Executed evidence / qualification limit |
| --- | --- |
| T01 initial guard absent | Boot/wrapper construction is tested by the daemon suite. No v3 capture from before the first boot guard; pre-loader traffic remains outside the guarantee. |
| T02 bypassed/missing wrapper | Installer identity, pinned engine/capability and launchd definitions are checked. Arbitrary administrator launch outside the wrapper is not packet-qualified. |
| T03 failed/partial close | PF exact readback, rejection of copied-label extra passes, cleanup readback failure and lock/epoch ordering pass unit/service tests. Injected kernel PF load/state-revocation failures under existing live traffic remain unqualified. |
| T04 missing roles | Installed Direct, closed and active dual-stack Global recovery cover all eight core/supervisor/engine combinations. Active recovery requires actual family/profile readback and fresh paired approval after role removal. Hung rather than terminated actors remain unqualified. |
| T05 detection/reaction | Recovery durations are test observations, not maximum packet leakage windows. No stress-bound fault-to-packet-denial measurement is claimed. |
| T06 incorrect running engine | Exact profile/DNS/route/capability checks and stale receipt tests pass; profile experiments cover engine behavior. Arbitrary undetected drift remains a limit. |
| T07 exit changes | Paired family, revision/generation and fresh-request models pass. Installed HTTPS approval, manual Refresh, and live family/mode reapproval pass against the trusted fixture; checks do not attest every future packet. |
| T08 route/network changes | Isolated native-DNS scopes, reconnect, route/capture scenarios and event/coalescing models pass. Physical Wi-Fi/interface switching is not qualified. |
| T09 sleep/session | Independent callback, stale open rejection and epoch tests pass. Physical forced sleep, login-window freezes and two live account GUIs are not VM-model passes. |
| T10 old native grants | Provider runtime is deleted. Installed Stop/uninstall remove injected legacy child filter/NAT/table material and boot controls. Only historical log formatting and bounded migration/cleanup remain. |
| T11 PF tampering | Historical closed/empty-active checks passed; the active guard now requires its own exact readback and repair qualification. Installed removal of Mimo's closed parent recovered; globally disabled PF and hostile foreign state/rules remain unqualified. |
| T12 native relay | LAN/Tailnet exclusions are intentional. A native relay can carry other traffic; v3 does not claim to prevent it. |
| T13 TUN dependency | Standalone capture, missing capability, process-loss DNS cleanup and installed release are exercised. The earlier empty PF admitted native fallback; the persistent-guard campaign passed all 32 traffic/fault rows with zero native attempts, plus private-DNS wrong-path denial. |
| T14 optimistic opening | Removed. Both model and real private-listener tests enforce scoped verification; installed HTTPS release requires fresh observations for every enabled family and passes the trusted-fixture campaign. |

No GitHub release has been produced. The local candidate uses marketing version
3.0/build 8; a future publication must allocate a new build number if 8 has already
been published. See `Evidence/v3/installed-build.json` for the exact local ZIP.
