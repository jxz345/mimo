# Incoming services while an exit IP is rejected

Release: [v3.0 build 10](https://github.com/jxz345/mimo/releases/tag/v3.0-build.10),
installed in `mimo-vm`. The final tested package is published unchanged; earlier
local candidate identities remain attached to their respective measurements.

## Observed failure and corrected behavior

Build 9 had a healthy Screen Sharing listener, running core/engine and an empty
Allowed IP list. It correctly rejected the public exit, but its outbound deny
also dropped the TCP server's replies. Packet capture showed incoming SYNs on
`en0` without returned SYN-ACKs. Both host SSH and Screen Sharing timed out.
The old global PF state purge also destroyed unrelated incoming sessions.

The corrected policy distinguishes connection initiation from packet direction:

```pf
pass in on ! utun239 proto tcp all flags S/SA keep state (if-bound) label "mimo:inbound:tcp"
pass in on lo0 all no state label "mimo:inbound:loopback"
```

This appears in closed, probe and active policies, including boot and standalone
cleanup. It creates state only from a peer's initial SYN, on an interface other
than Mimo's TUN or loopback. The second, last-match rule keeps loopback stateless:
a local proxy/DNS client must not retain a state across public-listener closure.
Replies for a peer-initiated connection can pass the outbound deny. The rule is
not `quick`, so later administrator inbound restrictions retain their veto.
It does not use broad `flags any` recovery. Outbound grants remain stateless.
Direct still releases Mimo's rules rather than retaining an ingress policy.

Closure installs denial first, then inspects `pfctl -ss`. Only source addresses
of original outbound (`->`) states are passed to Apple's `pfctl -k`; original
incoming (`<-`) states survive. Unknown/truncated state output fails closure,
never falling back to a global purge. Core performs this itself: using an older
installed helper during an upgrade is not safe. Independent boot/repair and
standalone cleanup implement the same selective rule. A staged-upgrade test
caught and corrected the old-helper dependency before installation passed.

A settled blocked state retains scoped transport of the signed native Tailscale
extension, using the existing socket/identity probe and watchdog. Updates require
the same close epoch, exact current policy and mutation lock. This does not grant
new outbound application connections or open the gate. Physical Tailnet incoming
reachability must be measured separately from local LAN TCP service access.

## Rejection presentation

Both required family observations remain in their own dashboard slots. An empty
allowlist or IPv6-only rejection is reflected in core's authorization result,
not just in a GUI label. The dashboard offers Review allowed IPs, Change proxy,
Retry verification and Use Direct. Nothing automatically approves an observed IP
or switches to Direct. The warning does not activate the app or steal focus.
Refresh now reports that the exit was checked but access remains blocked, while
the provider lookup itself remains successful. Event Log records
`mimo_exit_ip_rejected`, blocked manual-refresh outcomes and blocked native
transport updates/failures. Settings → Maintenance explains the new state rules.

## Validation

- Shared model tests: 219 passed, including inbound/outbound state selection,
  IPv6 rejection, paired observations and the empty-list recovery message.
- Service tests: passed, including 60 exception/recovery simulations, real XPC
  transport and concurrent/revision controls. Every exception row also polls
  without retriggering a lookup, restores Direct while the fault still exists,
  then repairs and verifies again. Four additional cases hold an HTTP lookup
  pending across Direct (Rule/Global × IPv4/dual-stack): Direct returns before
  the held response, and its late completion cannot reopen protected traffic.
  Daemon/cleanup/guard tests passed.
- Native app tests: passed for dashboard/Settings renders, retained pause errors,
  Direct availability, refresh outcomes, bounded/coalesced GUI probes and
  off-main login-item work. These complement, rather than replace, installed
  core responsiveness measurements.
- Installed upgrade: passed after correcting the staged-helper dependency;
  500 incoming IPv4/IPv6 echoes survived the upgrade with no disconnect.
- Installed incoming matrix: 23 scenario rows passed, plus settings restoration.
  Both families and Rule/Global cover active access, listener closure, empty and
  rejected allowlists, checked-but-rejected refresh, and IPv6-only rejection.
  Each row checks fresh HTTP4/HTTP6, SSH/RFB and existing streams. A separate
  foreign-state positive control confirmed outbound states are revoked while
  incoming states survive.
- Installed fault regression: 16/16 rows passed (four baselines plus engine
  crash, native-route change and simultaneous owner stalls/engine crash in each
  mode/family). Zero measured native bypass or public echo replies; actual echo
  sends occurred in both families. All 12 faults recovered. The downstream lab
  detector's Direct positive control detected both families (72 attempts).
- Installed proxy/provider/allowlist exception campaign: 22/22 passed across
  Direct→Rule/Global and IPv4/dual-stack. Refused SOCKS endpoints, authentication
  rejection, provider HTTP 503, empty/wrong IPv4 allowlists and IPv6-only rejection
  retained a failure cause, selected mode and blocked state. Each row preserved
  fresh SSH/RFB access, observed 12 settled seconds without a new lookup/open
  event, restored native IPv4/IPv6 HTTP while the fault persisted, then repaired
  and verified again. The 564 state queries, including Tart overhead, took at
  most 1.597 seconds. Direct restored PF/DNS and access in 9.903–12.492 seconds.
  Fixture credential replacement resets provider cooldown for the repair step;
  ordinary Retry retains provider budgets/cooldowns. The disposable token is
  removed before Direct, so pending-HTTP cancellation is qualified separately
  by the four coordinator cases above.

Sanitized records and candidate/harness identities are in
[the evidence directory](../Tests/MihomoRuntimeTests/Evidence/v3/inbound/README.md).

The final UI package was installed successfully after the campaigns. Its core
and engine hashes match the installed exception candidate; its final GUI hash
and package/ZIP hashes are recorded separately. Original settings, proxy catalog
and routing are restored exactly, with no disposable credential remaining. The
original Rule/IPv4 configuration has an empty allowlist, so it correctly settles
to "No exit IPs are approved". Core, supervisor and engine are running; controller
and signature checks pass. Fresh SSH and Screen Sharing banners still pass over
both LAN address families. Temporary lab rules and fixture processes are removed;
the reusable test certificate and trust are retained at the user's request.

## Dashboard and failure contract

The native dashboard now follows the approved mock's plain, fixed-height address
rows, country flags, per-family verdict/time, compact service rows, proxy summary,
and horizontal Stop action. Uninstall and its adjacent copy icon stay on the
dashboard. Its firewall health text remains truthful to the current persistent
fallback guard, rather than copying historical "no filtering" mock text.
The default window is 1040×660 with an 880×520 minimum, keeping routing and
recovery controls visible. Recovery actions wrap at the supported minimum width.
Native light/dark and failure renders are retained under `Previews/`; desktop
automation was unavailable, so these do not claim a complete installed click-through.

Clear feedback, bounded scheduling, responsive state/control, repair, and explicit
Direct escape are required under every tested failure. Provider pauses show a
deadline and recovery choices instead of hiding behind a generic configuration
message. See [the acceptance contract](MIMO_DUALSTACK_TEST_PLAN.md#current-failurerecovery-acceptance-contract-26-november).

## Limits

The new permission covers incoming TCP, including SSH, Screen Sharing and TCP
web servers. It does not claim general UDP-server support. A TCP connection that
was established before this rule existed has no corresponding state and may
need reconnecting. Direct→protected preservation of untracked preexisting
sessions and public asymmetric return routes remain unqualified. An upstream
firewall, macOS application firewall, Tailscale ACL or service listener can still
deny a connection. These limits are separate from the observed LAN reply-drop
regression. No physical sleep/wake or new public release is claimed here.
