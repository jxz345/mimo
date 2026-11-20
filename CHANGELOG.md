# Mimo changelog

## Unreleased — current VM candidate

- Recover automatically from native Tailscale firewall-update failures only after a successful native update and fresh protected verification; keep the final opening blocked while native-rule health is failed.

- Generate and syntax-check immutable restricted PF rules on a background worker, then install them immediately after blocking is confirmed. Keep the private-probe barrier closed through profile preparation and connection cleanup; release it as the last privileged preparation action before the IP request. Record generation, validation, installation and permission spans separately.

- Run connection cleanup, profile reuse checks and runtime inspection alongside PF closure and probe-policy preparation. Use two explicit joins before IP probing and final opening; fence cancelled controller work, retain the atomic final check, and skip unchanged DNS mutation bookkeeping.

- Retry protected verification after controller startup/cleanup failure once the infrastructure check is healthy; keep traffic blocked and require a fresh IP approval.

- Run PF closure concurrently with local preparation and installation inspection; share the event/prepare closure and fence cancellation under the firewall lock. Reuse unchanged profiles in the same engine process while still requiring fresh runtime and exit-IP checks. Manual Reload and engine changes force loading. Record monotonic spans to show concurrency.

- Load changed protected profiles once behind PF and reuse unchanged profiles in the same engine process; overlap exit-IP verification with mandatory installation/profile/TUN/DNS checks. Use a small blocking barrier before one probe-policy installation, retain old-flow cleanup, fence late results, and show approved-IP/readiness progress without opening early. Keep watchdog inspection off the supervisor's main executor. Exact-build VM qualification is tracked separately.

- Reduce redundant protected recheck work: prepare streams confirmed blocking, supervisor events avoid a second core close request, and unchanged protected DNS is retained. Add per-stage timing while keeping fresh verification and stale-approval protection.

- Detect lock/unlock, login/logout, user switching and display sleep/wake in the root supervisor, independently of the GUI. Revoke old protected approvals and close PF before rechecking; keep Direct open. Re-establish the barrier on wake/cancelled sleep and preserve the sleep hold across session events.

- Enable Rule/Global through real profile validation, private exit-IP verification and the saved allowlist. Empty or mismatched allowlists remain blocked.
- Load an independent saved PF boot policy and monitor PF, launchd registrations and IPv6 policy; show their health and last-check timers on the dashboard.
- Permit installed-app controls without administrator prompts after setup, using the installer-pinned app signature. Keep root-only traffic approval separate.
- Require confirmed PF closure before protected service actions, show progress immediately, and reject stale Allowed displays. Direct selection releases IPv4 before TUN/DNS teardown; normal Direct events check the IP without blocking or allowlist approval.
- Use proxied encrypted public DNS in both Rule and Global, while retaining private MagicDNS and explicit encrypted bootstrap.
- Follow native Tailscale connectivity automatically, repair relay recovery, and report a stopped provider as a failure only when the tailnet is expected.
- Use Dashboard/Settings tabs, stable layout, consistent service typography, compact Monitoring controls, menu shortcuts and the Finder app icon in the Dock. Retain the colored live menu indicators and triggering blocked IP.
- Record exact-build installed tests in [VM acceptance evidence](Tests/ReleaseEvidence/MIMO_NORMAL_RELEASE_ACCEPTANCE.md). Early traffic before the independent PF loader, actual macOS sleep/wake, peer UDP and simultaneous logged-in GUI sessions are not qualified. The user confirms physical mode/Quit shortcuts and sequential account sign-in checks. The public 1.0 preview below is unchanged.

## 1.0 — 2026-11-18 (preview)

First Mimo release, with a new source repository and release history.

- Apple silicon and IPv4-only networking; IPv6 stays disabled while installed and its saved service flags are restored on uninstall.
- Compact native dashboard, Settings, menu-bar routing state, login-item control, Refresh now and background-service lifecycle controls.
- Pinned mihomo 1.19.34 dependency, independent supervisor, private profile delivery, exit-IP validation and fail-closed preparation.
- Separate `jxz345/tap/mimo` cask with checksum/signature checks, runtime cleanup and retained settings/Keychain credentials.
- **Preview:** Direct works; Rule/Global activation remains blocked pending protected-routing qualification. Intermittent relay, real sleep/wake and live UI acceptance remain outstanding.

The earlier Exit IP Monitor history remains in https://github.com/jxz345/exit-ip-widget.
