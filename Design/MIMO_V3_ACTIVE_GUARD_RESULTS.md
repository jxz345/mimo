# V3 active guard qualification

Status: **68/68 active-guard VM qualification rows passed**, plus a repeated
17-row compatibility preflight. Local candidate only; not published. Native
visual and physical-Mac qualification remain outside these results.

Later harness correction: live reconnect testing found an odd-length checksum
error in `v3_fault_traffic_test.py` that prevented its IPv4 echo subprobe from
sending, plus missing reply-source/identifier correlation. The 68 recorded row
outcomes remain historical evidence, but do **not** qualify that IPv4 echo fault
coverage. TCP/UDP/DNS observations and separate system-ping checks are unaffected.
The corrected live echo controls and new candidate scope are recorded in
[the lifecycle continuation](MIMO_V3_LIVE_LIFECYCLE_RESULTS.md).
The subsequent [corrected fault rerun](MIMO_V3_CORRELATED_FAULT_RESULTS.md) passed
32/32 on the VPN-bootstrap-corrected candidate, including actual both-family
echo-send attempts during all 28 faults, zero matched public replies and zero
native bypass. It supplies separate coverage; the historical 68 rows and their
candidate identity remain unchanged.

The user approved the active guard after five measured native-bypass failures in
[the previous closure campaign](MIMO_V3_QUALIFICATION_CLOSURE.md). Those results
remain historical evidence and are not overwritten.

Implementation uses a flat persistent active guard, exact live readback, no-state
permissions, explicit native destinations and fake-address rejection outside TUN.
Direct/Stop/uninstall still release filtering. Liveness loss now schedules fresh
verification after core returns. The first VM activation caught a PF normalization
mismatch (`from any to any` canonicalizes to `all`) and stayed blocked; corrected
before packet qualification. No permissive readback fallback was added.

Local checks: shared suite **214 tests passed**; service suite passed; independent
PF guard suite **31 assertions passed**. Release build/signature/package passed.
The four annotated v3 template combinations (IPv4/Dual × Rule/Global) pass the
pinned engine's configuration parser. Settings → Maintenance compiles with the
firewall reference and copyable maintenance commands; native visual inspection
is separate and not claimed here.

## Candidate revisions and failures retained

1. The initial active guard passed all 32 traffic rows, including all four
   core-resume cases, with zero native attempts. Compatibility testing then found
   real Tailnet peer ping blocked in every protected cell. Running the same
   peer checks against the earlier empty-active candidate passed. Native DNS
   alone was insufficient to qualify the native VPN's outer transport.
2. A bounded temporary-rule experiment restored peer ping with signed native
   UDP/HTTPS transport scopes. Its original short wait was inconclusive; the
   successful retry is preserved as diagnostic evidence, not release acceptance.
3. Scoping Tailnet destinations to their native tunnel exposed the pinned
   engine's physical-interface binding of Quad100. The engine now leaves native
   overlay sockets unbound for the macOS host route. Separately, a 64 KiB socket
   capture limit rejected a valid 387,268-byte NetworkExtension observation;
   collection now has an explicit 1 MiB bound and 1.5-second timeout.
4. A local package initially retained the previous engine version in its runtime
   check. Installation refused it and rolled back services. The shared pin is
   corrected and a cross-file regression test covers this mismatch. The corrected
   package installed successfully before the current campaign.

The fixture also had a hostname stream-forwarding omission affecting the
Dual/Global payload check in both old and new app comparisons. That fixture bug
was corrected before the current 17-row compatibility preflight, which passed
all rows. A missing Python fixture dependency stopped the first test launch
before any traffic cases; after staging it, the current campaign began normally.

## Current local candidate

- Marketing/build identity: **3.0 / 8**, local only; not a published new build.
- Engine: `v1.19.34-mimo-v3.2` with `native-dns-route-v1` in addition to the
  strict-family, probe-ACL and silent-echo capabilities.
- Engine SHA-256: `6925603de8a31decb3919c607a97cee2845afc5ea70aa4c2797620e775f143ca`.
- Engine patch SHA-256: `8970c459f41901788ebade6afb9edf989e81afb066bcc6c24c5b808ece087d78`.
- A fresh dependency clone with the pinned toolchain reproduced the engine hash;
  native-route, tunnel, config, adapter and constant Go tests passed.

VM raw evidence remains private under the separate `mimo-v3-active-guard`,
`mimo-v3-empty-active-comparison`, `mimo-v3-guard-final`, `mimo-v3-native-guard`
and `mimo-v3-guard-qualified` directories in `/private/var/tmp`. Directory names
are not qualification claims. Only sanitized summaries will be exported. The
reusable TLS certificate and key are retained. Final accounting and restoration
are recorded below.

## Final results

| Suite | Passed | Evidence |
| --- | ---: | --- |
| Traffic baselines and process/route faults | 32/32 | [Traffic results](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/traffic-results.json) |
| Rule bypass/Global selection, peer ping, native and engine DNS | 17/17 | [Compatibility](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/compat-results.json) |
| Physical-interface private DNS denial, with Direct detector control | 5/5 | [Wrong-path results](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/native-wrong-path-results.json) |
| Live IPv6 Packet Too Big, native control and proxied payload | 4/4 | [IPv6 control](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/ipv6-control-results.json) |
| PF mutation contention and real parser rejection | 2/2 | [PF failure checks](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/firewall-failure-results.json) |
| Package, release, conflict consent, uninstall and reinstall | 8/8 | [Package checks](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/package-results.json) |

The 28 fault rows cover seven scenarios in each family/mode cell: engine kill,
engine stall, core stall, supervisor stall, both control roles stalled, a
more-specific native route, and engine kill while both control roles are stalled.
All recovered. Four normal-traffic baselines also passed. **Zero native attempts**
were observed before or during these faults; the lower lab trap had a positive
Direct control in both families. Permitted payloads succeeded and public echo
received no synthetic reply. [Summary and counts](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/summary.json).

Private DNS initially produced only two PF deny hits: macOS returned
`EHOSTUNREACH` for both IPv6 sockets before PF. That run was marked unqualified
for PF attribution, despite zero escapes, and is [retained separately](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/native-wrong-path-route-rejection.json).
The final harness adds one temporary interface-scoped IPv6 test host route,
with independent cleanup, without replacing native VPN routes. Each of the
four engine-owned TCP/UDP requests then hit Mimo's wrong-path deny in every
protected cell; the lower trap remained at zero. UDP `sent: true` means the local
send syscall accepted data, not that a remote server received it. All temporary
routes were removed. An intermediate diagnostic retry stopped on Python enum
argument formatting before protected probes; that harness error was corrected.

Native compatibility passed both before and after the faults. Actual PF counters
show engine-group traffic and signed native UDP/HTTPS transport matches, rather
than relying only on process listings. Active audit scope-update events occurred
during the run. [Scope counters](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/native-scope-counters.json),
[update events](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/native-update-events.json).
This qualifies the observed official Tailscale system extension and current peer
path, not every VPN distribution, peer topology or reconnect sequence.

### The two Direct states

| State | Service/network checks | UI/monitoring qualification |
| --- | --- | --- |
| Managed Direct, engine retained and running idle | Healthy core/supervisor/engine, responding pinned controller, no owned TUN/DNS, empty Mimo PF. Reinstalls and final restoration reached this state. | Native visual review is not claimed. |
| Released Direct after Stop engine, app still installed | `daemon.sh deactivate` removed owned jobs/runtime controls, TUN, DNS, current and legacy PF. Native verification passed, foreign rules survived, and explicit reactivation restored all roles. This was tested separately from `uninstall`. | The GUI button appearance and continuing monitoring-only exit-IP refresh were not visually exercised. |

The second state is full network/service release, not merely a paused engine
with all daemons retained. `Mimo.app` remains installed. These checks invoke the
shared lifecycle commands used by the UI; they do not claim a native button click.

## Restoration and remaining limits

The VM is back in **managed Direct with its engine running**. Original settings,
proxy catalog/selection and saved family match the pre-test snapshot. Owned DNS
and PF are empty; lab rules, captures, `pflog0` and test routes are gone. The host
fixture stopped. The reusable trusted certificate and owner-only private key
remain, as requested. The frozen working profile's SHA-256 is unchanged.
[VM restoration](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/restore-results.json),
[route/certificate checks](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/restoration-extra.json),
[host cleanup](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/host-cleanup.json),
[source and engine manifest](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/manifest.json),
[package hashes](../Tests/MihomoRuntimeTests/Evidence/v3/active-guard/release-build.json).

These results close the measured active-fallback and core-resume failures for the
tested VM scenarios. They do not qualify the pre-loader boot window, actual kernel
PF ioctl/state-flush failure, disabled or externally replaced upstream PF rules,
physical sleep/login/Wi-Fi transitions, arbitrary remote proxy IPv6 support, or
native GUI visual behavior. Native LAN/Tailnet and trusted signed VPN transport
remain intentional exceptions; malicious root or a compromised trusted VPN is
outside the containment boundary. No GitHub release was made.
