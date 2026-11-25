# Incoming access and failure recovery evidence

These measurements cover local v3.0 build-10 candidates and the final tested
package selected for release. The installer/package and installed-binary hashes
distinguish local revisions; earlier candidate binaries are not published. See
`Design/MIMO_V3_INBOUND_ACCESS_FIX.md` for outcomes and limits.

| Files | Scope |
| --- | --- |
| `incoming-results.json` | 23 installed scenario rows plus restoration: fresh HTTP4/6, SSH/RFB banners and existing TCP streams during active/rejected/closed states; local SOCKS closure and selective outbound-state revocation |
| `upgrade-incoming.json` | 500 successful incoming TCP echoes through the installed upgrade |
| `traffic-results.json`, `detector.json` | Four protected baselines plus 12 engine/route/stalled-owner faults; actual TCP/UDP/DNS/echo attempts and downstream native-bypass detection, including both-family Direct positive controls |
| `installed-identity.json`, `release-build.json`, `harness-sources.json` | Candidate and harness used for the incoming/traffic campaign |
| `exception-installed-identity.json`, `exception-release-build.json`, `exception-harness-sources.json` | Later candidate with dashboard/pause-message corrections and the closed exception fixture |
| `exception-results.json`, `exception-responsiveness.json` | 22 Direct→protected failure/repair cases: retained error, no extra lookup/open during 12 settled seconds, incoming SSH/RFB, native HTTP4/6 after Direct and fresh verified recovery; 564 bounded state queries |
| `final-release-build.json`, `final-restored-identity.json`, `final-incoming.json` | Final UI package, installed hashes/signature, exact original-settings/catalog/routing restoration, credential removal, healthy daemons/controller, empty temporary lab policy and fresh SSH/RFB over both LAN families |

The later presentation changes do not alter firewall behavior. Keep the original
candidate identity with its measurements instead of silently attributing an old
campaign to a newly rebuilt binary. Each final campaign records its own identity.
The final package's core and engine are byte-identical to the exception-tested
candidate; the final GUI adds responsive recovery controls and the supported
window-size bounds. `final-release-build.json` identifies the unchanged package
published as `v3.0-build.10`; the other manifests remain historical test inputs.

Raw captures, fixture authentication, original settings/catalog and administrative
credentials remain in owner-only local storage and are not included here. Test
addresses are documentation ranges; these records contain no real proxy secret
or IPinfo token. The reusable test certificate/key remain available locally at
the user's request. SSH/RFB banners establish service reachability, not complete
authenticated desktop interaction. General UDP-server and asymmetric-route
behavior are not qualified by the incoming TCP tests.

The exception fixture removes its disposable token before Direct; it does not
measure cancellation during a pending HTTP observation. Four coordinator cases
cover that separately. Repair replaces the disposable token to clear its provider
cooldown, while the ordinary Retry action still respects cooldown and budget.
