# Mimo 2.1 implementation plan

Approved scope, built on 2.0 build 7. Implementation target: 2.1 build 8.

1. Core owns one shared HTTP/SOCKS5 proxy catalog, stable IDs and active selection. All accounts edit with revision checks. Add inactive; inactive changes save only. Active protected changes reload/verify without changing mode. None or active removal restores Direct. Selecting a proxy in Direct keeps Direct. No automatic proxy failover.
2. Keep proxy passwords and the IPinfo token in owner-only local machine storage outside the bundle. Migrate old machine Keychain entries only after durable commit; retry deletion without reimporting stale values. Personal import stays read-only. Never broadcast secrets or include them in logs/releases. IPinfo uses its fixed HTTPS endpoint with Bearer authentication and refuses redirects.
3. Change local provider failure cooldown to ten minutes; retain longer Retry-After and daily budget restrictions. Migrate identifiable old local pauses, preserve ambiguous old server-related deadlines.
4. Set the periodic default to one hour; migrate existing 15-minute settings once, preserve other choices, and allow choosing 15 minutes afterward. Never cancels only periodic checks and periodic staleness; manual/startup/event/recovery/retry behavior remains.
5. Refresh now respects cooldowns. Publish queued/checking/success/deferred/failure across accounts, coalesce requests, advance check time on same-IP success, and retain it on skipped/failed requests.
6. Compact dashboard Proxy configuration without changing service-row heights, controls or fonts. Put active selection in Settings, preserve drafts/conflict handling, and keep operational failures visible.
7. Run portable tests, VM service/GUI tests, installed VM routing and migration checks. Update README, workflow reference and changelog. Package version 2.1 with a new build identity; Homebrew version remains the marketing version.

Current behavior is documented in [event-driven workflows](MIMO_EVENT_DRIVEN_WORKFLOWS.md). Test results and physical-Mac limits belong in release evidence, not assumptions in this plan.
