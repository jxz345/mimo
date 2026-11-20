# Installed VM regression coverage — 20 November 2026

Status: the available installed-VM checks are complete and passed. Actual system sleep remains unverified: macOS refused the request with exit 71 and kernel sleep/wake counters stayed at zero. Original Rule, settings, credentials, service intent and native Tailscale Stopped are restored; the GUI remains running. No acceptance driver, capture, test job or scheduled wake alarm remains.

All runtime, traffic, Homebrew and reboot tests execute in **mimo-vm** using the ordinary installed arm64 Release, the saved real proxy/password and existing allowlist. Delta only edits/builds packages, orchestrates SSH and stores sanitized reports. Existing peer SSH, ICMP and Tailscale TSMP services are probed from the VM; no peer commands, new listeners or Delta network changes are used.

## Broad run before the hostname correction

The following **206 checks** passed on source `e958b4e`, package `fcaff59daff60fc7ddfabeb526c1fe31fc88da335cedbd6393da2304daf8fe58`, helper `40b4d4c538851d506a4ab75be3105be14840b51f1f3f0e6ab46802b559758006`. Counts include each driver's restoration assertions. Wrapper restoration checks are additional and are not included in 206.

| Coverage | Checks | Evidence |
| --- | ---: | --- |
| Rule/Global allowlists, ordinary TCP/UDP/DNS, IPv6 denial, route changes, Reload, engine crash and Direct | 20 | [Runtime](mimo-final-coverage-runtime.json) |
| Real SystemConfiguration preference changes in all modes; actual TUN disappearance | 5 | [Events](mimo-final-coverage-events.json) |
| Audit stall/deadline, controller drift, Direct cancellation and missing permission/policy | 8 | [Background audit](mimo-final-coverage-audit.json) |
| In-flight Direct/network races, stalled controller, early callback closure and full PF fallback | 13 | [Races](mimo-final-coverage-races.json), [controller](mimo-final-coverage-controller.json), [early closure](mimo-final-coverage-early.json), [fallback](mimo-final-coverage-fallback.json) |
| Exact installed-app control authentication and real admin/standard UID access | 21 | [Signature/control access](mimo-final-coverage-accounts-1.json), [cross-account state](mimo-final-coverage-accounts-2.json) |
| Protected system DNS, public DNS/DoH, uncached and negative queries, MagicDNS and attributed packet capture | 15 | [DNS privacy](mimo-final-coverage-dns-1.json) |
| Live peer SSH, ten forced DERP reconnects, native down/up, provider controls, public traffic, native TSMP and ordinary ICMP | 44 | [Relay](mimo-final-coverage-relay-1.json), [native/ICMP](mimo-final-coverage-relay-2.json) |
| Core/mihomo/profile/provider Start/Stop/Restart across modes, real denial timeout and missing controller | 45 | [Service lifecycle](mimo-final-coverage-services-1.json) |
| PF/launchd/files/IPv6 repair, installer cleanup and real reboot with the main helper absent | 35 | [Infrastructure](mimo-final-coverage-infrastructure.json) |

The service driver initially treated a safe Blocked → Closing transition after Stop as a failure, and held the old administrative lock for a PF-denial contention case. The corrected driver requires no effective mode, denied permission and failed ordinary HTTPS throughout that transition, then settled Blocked; it holds the actual `pf-mutation.lock` for denial timeout. [Direct Stop observation](mimo-final-coverage-stop-observation.json) and the [initial](mimo-final-coverage-services-initial.json)/[lock-attempt](mimo-final-coverage-services-lock-attempt.json) reports retain the evidence. No production change was needed for these two test assumptions.

## Hostname defect and current installed build

Testing found a real availability defect: an existing TUN intercepted the bootstrap HTTPS DNS request, while the restricted PF policy could not reach the previous proxy endpoint. The same resolver succeeded in normal Rule/Direct and with an explicitly bound physical interface during bootstrap. The default route timed out. See [resolver controls](mimo-final-coverage-hostname-controls.json), [route diagnosis](mimo-final-coverage-hostname-route.json), and [failed initial regression](mimo-final-coverage-hostname-initial.json).

Source **`30c295c`** loads and verifies the credential-free blocking profile while PF is closed, confirms the old TUN is absent, then permits restricted bootstrap DNS. Literal-IP endpoints retain their existing path. N1–N3 and the scanner-contention correction remain intact.

Current package: `036b680a9d5e395e6c3ba303c0367d3370994922caaee58a5b6168531b1a80e4`.
Current helper: `df548d9a92665906584de4375dc9d685942879754f9afcbf42f0b62b399d3eec`.
Current GUI: `71c84e6d3feba21eb3084c0ac04b103d2157bca615802e828d79f73ca2229f4a`.

| Current-build coverage | Result | Evidence |
| --- | --- | --- |
| Actual reserved invalid hostname, restricted resolver response, ordinary HTTPS denial, password retention and original proxy restoration | 4 passed | [Hostname regression](mimo-final-hostname-fixed.json) |
| Literal-IP Rule/Global/Direct packet/fault matrix | 20 passed | [Runtime regression](mimo-final-hostname-runtime.json) |
| Real network-preference changes and actual TUN loss | 5 passed | [Event regression](mimo-final-hostname-events.json) |
| Real Homebrew install/uninstall, automatic versus explicit mihomo ownership, settings/password/signature/IPv6/network restoration | 12 detailed checks and both dependency cases passed | [Homebrew](mimo-final-coverage-brew.json) |
| Saved Rule/Global real reboots with GUI executable unavailable | 10 passed per mode | [Rule](mimo-final-coverage-boot-rule.json), [Global](mimo-final-coverage-boot-global.json) |
| Human lock/unlock in the original Rule mode | 4 passed | [Session events](mimo-final-coverage-session.json) |
| Actual sleep request, last | Unsupported/incomplete: exit 71; sleep/wake counters unchanged | [Sleep](mimo-final-coverage-sleep.json), [original Rule restoration](mimo-final-coverage-sleep-restoration.json) |
| Final original-state and cleanup inspection | 7 restoration checks and 2 process/marker checks passed | [Restoration](mimo-final-coverage-restoration.json), [cleanup](mimo-final-coverage-cleanup.json) |

Homebrew 6 refused a fresh dependency install until the pinned formula had item-level trust. The tapped formula matched the repository SHA256 before granting trust only to `jxz345/tap/mihomo@1.19.34`; trust enforcement remained enabled. The formula was still installed automatically as a dependency. [Trust attempt](mimo-final-coverage-brew-trust-attempt.json). The lifecycle checker also needed decoded-value comparison: only JSON key order and the conflict revision changed, while configuration values stayed equal. It now checks configuration values, a nondecreasing revision, the separate password digest and service intent. [Checker attempt](mimo-final-coverage-brew-checker-attempt.json).

## Current timing

Four real warm route changes on the current build passed the full runtime run. Times begin at the actual route request. These observations do not establish a latency guarantee.

| Trial | PF open | Allowed observed | Audit complete |
| --- | ---: | ---: | ---: |
| Rule: route added | 3.367 s | 3.488 s | 5.008 s |
| Rule: route removed | 3.534 s | 3.653 s | 4.646 s |
| Global: route added | 3.573 s | 3.773 s | 4.759 s |
| Global: route removed | 2.865 s | 3.259 s | 4.194 s |

[Monotonic stage data](mimo-final-coverage-timeline.json). One trial opened within three seconds; three did not. These are literal-IP route events, not hostname, unlock or sleep timing.

The human session run also recorded real display sleep/wake. Event detection to PF opening was approximately 3 s for lock, 4 s for display sleep, 3 s for display wake and 2 s for unlock. These use whole-second UTC log timestamps; they are separate observations, not an additive timeline or system-sleep proof.

## Limits

- Actual system sleep/wake is not qualified. The final real `pmset sleepnow` request was refused; no synthetic notification or Tart pause was used.

- A successful hostname-proxy connection needs a user-approved hostname for the actual server. The reserved invalid hostname checks resolution failure and safe recovery without sending saved credentials to another endpoint.
- Boot capture starts with its launchd worker. Neither this test nor the independent PF loader proves protection before that loader runs.
- Optimistic opening intentionally allows traffic before the thorough audit finishes. Later blocking cannot undo packets; the audit deadline is not a guaranteed effective-block bound.
- Simultaneous logged-in GUI sessions remain unavailable in this VM. Real cross-account XPC/UID checks are separate evidence.
- No existing peer UDP echo service was available. Public UDP and DNS were tested; peer UDP was not.
- Native visual rendering is not newly qualified by these automated results. Lock/unlock is not a substitute for actual system sleep.
- The public release and tap binaries are unchanged. This candidate uses a VM-local acceptance cask.

Raw settings, profiles, captures and detailed logs remain private inside the VM. Only sanitized evidence is stored here.
