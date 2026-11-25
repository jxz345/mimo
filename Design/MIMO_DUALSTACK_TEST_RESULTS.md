# Dual-stack and installed-app test results

## Latest installed Release qualification — 2026-11-25

**V3 is not release-qualified.** The additional 54-scenario closure plan executed
42 automated scenarios: **33 passed, nine failed**. Six native UI and six physical
Mac scenarios remain unexecuted. These counts are separate from the historical
profile matrices and earlier assertion suites below.

- All four active traffic baselines passed. Engine termination admitted native
  attempts in all four family/mode combinations; one native-route injection also
  admitted attempts. A separate lab containment rule prevented the test packets
  leaving the VM. Captured classes include public test DNS datagrams/TCP, service
  TCP and IPv6 ICMP. Successful recovery does not pass the leakage objective.
- All four corrected core-stall tests remained safely blocked, but automatic
  reapproval did not occur within 100 seconds after resumption. Initial harness
  assertions against cached Active state were corrected and retained separately.
- Both PF failure-reporting cases, four live IPv6 control cases and eight local
  Release package/coexistence cases passed. Live PTB injection reduced subsequent
  IPv6 TCP packets from 3113 to 1252 bytes while preserving exact payloads.
- Original VM preferences/proxies were restored in healthy Direct; test services,
  routes, captures and rules were removed. The reusable trusted certificate/key
  remain local for future tests. Native UI control timed out in Screen Sharing;
  no Mimo visual or physical login/sleep result is claimed.

See [detailed closure results and manual steps](MIMO_V3_QUALIFICATION_CLOSURE.md)
and [sanitized accounting](../Tests/MihomoRuntimeTests/Evidence/v3/closure/summary.json).
The tested local Release artifacts are version 3.0 build 8, with
[recorded package hashes](../Tests/MihomoRuntimeTests/Evidence/v3/closure/release-build.json).
Nothing was published. Actual PF kernel-operation failure, public Internet IPv6
service qualification and the named manual checks remain outside the passed scope.

## Historical final-template campaign — 2026-11-24

**The final Rule/Global template campaign completed 3,620 cases: 3,610 met
expectations and ten failed. The dual-stack template is not deployment-ready.**
All 24 core matrix cells passed; the failures concern native short-name DNS in
both dual-stack modes. The IPv4-oriented template passed all its scheduled cases.
Shutdown also exposed a DNS transition boundary described below.

Neither template nor any of the four frozen working-profile files was changed
by this campaign. No app build, installation, release or host network change was
made. The historical 6,240-case Global/zero-rule experiment remains separate below.

## Final template results

The exact public sources were [mimo-ipv4-template.yaml](../Profiles/mimo-ipv4-template.yaml)
and [mimo-dualstack-template.yaml](../Profiles/mimo-dualstack-template.yaml), with
`tun.dns-mode: native`. Global variants changed only `mode`. The declared lab
overlay supplied controlled Delta proxy/DoH endpoints, a temporary CA, an isolated
controller and test TUN. Runtime reports retain the public-source and rendered
profile hashes. The pinned engine was `v1.19.34-mimo-no-ping.1`, SHA256
`ff21dbbad799783de14f4a13684b35531b455beff0335dc2e9d468e5bcbe52bd`.

| Template / mode | Matrix cases meeting expectations | Focused cases meeting expectations | Failed | Total |
| --- | ---: | ---: | ---: | ---: |
| IPv4-oriented / Rule (T4R) | 780 | 125 | 0 | 905 |
| IPv4-oriented / Global (T4G) | 780 | 125 | 0 | 905 |
| Dual-stack / Rule (T6R) | 780 | 120 | 5 | 905 |
| Dual-stack / Global (T6G) | 780 | 120 | 5 | 905 |
| **Total** | **3,120** | **490** | **10** | **3,620** |

The matrix contains 810 successful service exchanges, 342 expected denials with
no native test-flow egress, 288 expected AAAA suppressions and 1,680 DNS assertions.
These outcomes are distinct: suppression and expected failure are not successful
IPv6 connections. All 332 main focused checks, 52 additional transport/cache
checks, 12 startup/ownership faults, 40 system-DNS/browser/crash checks and 16
UDP-disabled-proxy checks passed. Native DNS lifecycle checks passed 38/48.
Four exact-file parser checks are additional to the behavioral count.

Evidence: [runtime summary](../Tests/MihomoRuntimeTests/Evidence/templates/runtime-summary.json),
[matrix reports](../Tests/MihomoRuntimeTests/Evidence/templates/matrix.json),
[focused reports](../Tests/MihomoRuntimeTests/Evidence/templates/focused.json),
[retained preliminary runs](../Tests/MihomoRuntimeTests/Evidence/templates/preliminary-runs.json),
and [independent final checks](../Tests/MihomoRuntimeTests/Evidence/templates/final-checks.json).
The [preparation record](../Tests/MihomoRuntimeTests/Evidence/templates/preparation.json)
is a historical parser-only snapshot; its zero-runtime count does not describe
this completed campaign. Earlier disabled-DNS preparation remains preserved too.

### Deployment blocker: fake IPv6 answers for short names

Both dual-stack modes reproducibly failed these five assertions:

| Case | Observed failure |
| --- | --- |
| D02 LAN short name | Correct native IPv4 answer plus an unwanted fake IPv6 answer. |
| D04 Tailnet short name | Same extra fake IPv6 answer; the fully qualified name remained correct. |
| D07 Short name after Tailscale reconnect | Reconnect restored the FQDN, but the extra fake AAAA remained for the short name. |
| D09 Mode reload | Public DNS and the single owned resolver were correct; short-name answer equivalence failed. |
| D10 Native DNS/search change | New suffix was present, but the new LAN short name acquired the same extra fake AAAA. |

This is **not a lost search list or complete resolution failure**. `getaddrinfo`
returned one real native IPv4 address and one address from
`fdfe:dcba:9876:1::/64`. Before engine startup and after shutdown, the same short
names returned only their correct native IPv4 address. Full Tailnet names and
scoped non-`.ts.net` names remained correct. The IPv4-oriented template, which
suppresses AAAA, did not exhibit the extra answer.

[Packet correlation](../Tests/MihomoRuntimeTests/Evidence/templates/short-name-dns-proof.json)
matched five unqualified AAAA questions to five fake-IPv6 replies on the test TUN.
The native search expansion can therefore succeed for A while the engine also
synthesizes AAAA for the unqualified name. A native address plus a fake address is
not acceptable preservation of native resolution. These findings reproduce in
Rule and Global, including a repeat run with address-family instrumentation.

The next correction must prevent fake answers for unqualified/native names while
preserving native scope/search behavior and public IPv6 DNS. Merely seeing the
right A answer, disabling Tailscale DNS, or turning off dual-stack DNS does not
qualify this template. No candidate fix was silently applied during testing.

### Shutdown finding and active-traffic results

The first native-DNS run stopped on a packet assertion. Capture inspection found
a macOS PTR query to the former TUN DNS endpoint, `198.18.0.2:53`, on `en0`
during shutdown. Instrumented reruns in all four configurations each recorded
one such request **after teardown began**, with zero native fake-address packets
while protection was active. The original failed assertion remains in preliminary
evidence; the final reports retain both whole-capture and phase-specific counts.

The owned resolver and TUN were removed, native DNS returned, and no orphaned
registration remained. However, removal propagates asynchronously: a queued OS
DNS request can use the native route during shutdown. The standalone templates
are not a transition kill switch. Deployment requiring zero DNS exposure during
teardown needs ordering/enforcement in the sole lifecycle owner; this test does
not provide that guarantee. The templates have not been changed to hide it.

Active matrix/focused captures observed no native test-flow TCP/UDP or NAT64
bypass. Captured ping/ping6 were silently dropped without synthetic replies;
native LAN/Tailnet IPv4/IPv6 pings remained real. In the declared `udp: false`
checks, Rule rejected UDP while Global still completed actual proxied UDP in the
pinned adapter. All TCP controls passed. This is a measured mode difference, not
native fallback. Global ignores the terminal Rule rejection.

### Scope, preliminary corrections and cleanup

- Native short-name checks used the VM's own Tailscale name because it has no
  peer in its own tailnet. A shared peer in another tailnet supplied separate F11
  full-name and real IPv4/IPv6 ping checks. Own-node DNS is not proof of another
  peer's short-name reachability.
- D10 used session-owned default/supplemental DNS and search-list changes. It did
  **not** switch the physical primary network or edit saved Wi-Fi preferences.
  D11 killed a fresh engine immediately after registration; it did not inject an
  internal initialization exception. These substitutions and remaining limits
  are explicit in the plan and evidence.
- Four initial native-DNS attempts stopped before behavioral cases: the fixture
  first needed native forwarding, then the shared-device short-name expectation
  proved invalid for this VM's search suffix. Cleanup readback also needed a
  bounded resolver-settling wait. None was counted as a template pass or failure.
- Seven earlier runs are retained: those four preconditions, the initial shutdown
  packet assertion, and both initial dual-stack failure runs. Repeats do not add
  to the 3,620 unique-case total. A final process scan initially matched its own
  inline command; the corrected anchored scan passed, with the earlier check
  [retained](../Tests/MihomoRuntimeTests/Evidence/templates/final-checks-preliminary.json).
- Independent final verification passed all 24 checks: four frozen files retained
  bytes/mode/mtime; template hashes matched preparation; temporary engines,
  helpers, listeners, private keys, routes, DNS entries, TUN and browser tabs were
  removed; Tailscale was Running and real native LAN/Tailnet IPv4/IPv6 pings passed.
- VM packet capture plus Delta service/socket records support the transport
  conclusions. Host BPF capture, crafted ICMPv6 Packet Too Big, physical network
  switching, public NAT64 translation, the supplied remote proxy's IPv6 service
  and installed-app integration remain unqualified.

### Reproduce the final-template campaign

From Delta with the existing private VM admin setup and pinned engine:

```bash
python3 Tests/MihomoRuntimeTests/dualstack_lab.py \
  --templates --root .build/template-campaign --cells all --scope matrix
```

For each of `T4R:S00,T4G:S00,T6R:S00,T6G:S00`, run scopes `focus-main`,
`focus-extra`, `focus-system`, `focus-native-dns`, `focus-udp-disabled`,
`focus-invalid-engine`, `focus-occupied` and `watchdog`. Run only one VM engine
at a time. `--continue-functional` retains assertion failures and permits other
independent cells; infrastructure, cleanup or active packet failures still stop
the command. Native-DNS tests temporarily disconnect/reconnect VM Tailscale with
a restoration journal and independent watchdog. They do not change host Tailscale.

Export sanitized evidence using:

```bash
python3 Tests/MihomoRuntimeTests/template_evidence.py \
  .build/template-campaign Tests/MihomoRuntimeTests/Evidence/templates
```

Raw captures, private native names and fixture inputs remain in ignored local
storage. Generated `mimo-template-*.local.yaml` files are ephemeral lab inputs,
not deployable configurations. Keep actual proxy settings in a private local copy.

## Original Global/zero-rule experiment

The following results concern P00–P10, not the final Rule/Global templates.
P07 qualified the controlled standalone Global/zero-rule transport experiment:
48 cells and 6,240 cases met expectations. The optional `redir-host` diagnostic
retained one functional difference. The frozen working IPv4-oriented baseline
and separate dual-stack candidate retain `dns-mode: disabled`.

## The candidate's exact changes

| Setting | Working profile / P00 | New candidate / P07 |
| --- | --- | --- |
| `dns.ipv6` | `false` | `true` |
| `dns.fake-ip-range6` | Omitted | `fdfe:dcba:9876:1::/64` |
| SOCKS5 node `ip-version` | `ipv4` | `dual` |

Those are the only semantic differences in the private candidate. Its existing
proxy address, credentials, DNS upstreams, Global/zero-rule selection, static
Tailnet exclusions, no-ping stack and default IPv6 TUN address are preserved.
The proxy listener remains IPv4-addressed. Lab fixture addresses, temporary CA
and controller paths are **not** copied into this candidate.

Both files require the existing patched test engine
`v1.19.34-mimo-no-ping.1`, SHA256
`ff21dbbad799783de14f4a13684b35531b455beff0335dc2e9d468e5bcbe52bd`.
Stock Mihomo rejects `gvisor-no-ping`; this is not an installed-app profile upgrade.

## Matrix results

The [plan](MIMO_DUALSTACK_TEST_PLAN.md) and
[machine-readable matrix](MIMO_DUALSTACK_TEST_MATRIX.json) define every axis.
All eight core variants were tested against six proxy capability modes, using
actual Delta IPv4/IPv6 HTTP, TLS-verified HTTPS and UDP services. DNS tests covered
explicit local-listener queries, intercepted IPv4/IPv6 UDP/TCP DNS and the real
resolver API. Both cold and warm application cases used fresh connections.

| Result class | Cases | Interpretation |
| --- | ---: | --- |
| Successful real service exchanges | 1,430 | Correct nonce/payload, certificate where applicable, and actual upstream address family. |
| Expected transport/resolution denials | 586 | Expected failure with zero native test-flow egress; fixtures remained healthy. |
| Expected client AAAA suppression | 864 | No client IPv6 address for these variants; these are not successful connection tests. |
| DNS expectations met | 3,360 | 2,880 listener/interception cases and 480 real resolver queries, including valid empty answers and nonexistent names. |
| **Total** | **6,240** | **48/48 cells matched expectations and passed cleanup.** |

The fully capable P07/S00 cell passed all 60 application cases and all 70 DNS
cases. IPv6-refusing/stalling/dropping modes produced the specified failures with
no direct fallback. The IPv4-oriented P00 baseline was included in every proxy
mode; it was not replaced by a dual-stack-only test.

Sanitized evidence: [summary and cell checks](../Tests/MihomoRuntimeTests/Evidence/dualstack/summary.json),
[all matrix cases](../Tests/MihomoRuntimeTests/Evidence/dualstack/matrix-cases.jsonl),
[focused runs](../Tests/MihomoRuntimeTests/Evidence/dualstack/focused.json), and
[preliminary runs](../Tests/MihomoRuntimeTests/Evidence/dualstack/preliminary-runs.json).
Raw captures, original runner copies and private inputs remain in ignored,
owner-only local run directories. Temporary certificate private keys were removed.

## What the experiments established

1. **An IPv4 proxy address can carry real IPv6 traffic.** The fixture listened
   only on IPv4 and opened real IPv6 sockets to Delta's IPv6-only service sockets.
   TCP/TLS and UDP payloads passed. A client fake-IPv6 answer alone was never
   counted as proof of IPv6 upstream access.
2. **Enabling `dns.ipv6` alone is insufficient in fake-IP mode.** P04/P05 still
   suppressed client AAAA without a fake IPv6 pool. P02/P03 confirmed that adding
   a pool while leaving IPv6 DNS disabled is also insufficient.
3. **`ip-version: ipv4` constrains UDP hostname resolution.** P06 could return
   fake IPv6 addresses but could not complete IPv6-only UDP hostname exchanges.
   P07's `dual` setting fixed those cases. TCP hostname resolution happens at the
   SOCKS proxy, so AAAA suppression does not force every TCP upstream to IPv4.
4. **IPv6 DNS records and IPv6 DNS transport are separate capabilities.** DoH
   over IPv4 returned AAAA records even when the proxy refused IPv6 application
   destinations. DoH sent to an IPv6 endpoint failed when IPv6 forwarding was
   refused, with no native/public bootstrap fallback observed in those tests.
5. **Unsupported IPv6 fails safely, but automatic IPv4 recovery is not assured.**
   The automatic dual-address curl probe ended in TLS failure or timeout for the
   tested refusal/stall modes. The TUN can accept the local TCP connection before
   the proxy's upstream failure becomes visible, so connection racing alone need
   not retry IPv4. Explicit IPv4 retries succeeded through the selected proxy.
6. **A cached answer can survive an upstream DNS failure.** The expiry test
   observed a retained answer while the local DoH fixture returned SERVFAIL.
   Fresh-name recovery was checked separately. An answer from cache does not
   prove that the resolver or proxy is currently healthy.

## Focused checks and the diagnostic difference

The final focused records contain **148 successful assertions and one retained
functional difference**, across P07, P08, P09, P10 and startup/parent-loss tests.
Assertions are separate from the 6,240 matrix cases.

| Area | Result |
| --- | --- |
| DNS NODATA/SERVFAIL/NXDOMAIN/timeout, expired cache and recovery | Passed the declared response/failure expectations; cached success distinguished from fresh resolution. |
| Untrusted DoH TLS certificate | Resolution failed; restoring trust recovered it. No OS trust-store changes. |
| SOCKS errors, unsupported domain addressing, bad/correct password, auth-method refusal | Expected failures and recovery; no native test-flow fallback. |
| UDP ASSOCIATE refusal, dropped/unavailable relay, control-channel closure | Expected failures. A separate relay-revocation probe received one reply before closure and none afterward. |
| Proxy unavailable, connection reset, warm-DNS capability withdrawal/restoration | Expected failures and recovery through the proxy. |
| Actual IPv4/IPv6 HTTPS body and UDP payloads of 96/1,232/8,224 bytes | Passed payload/family checks. This does not by itself qualify every IPv6 PMTU condition. |
| Captured echo requests | Fourteen requests across seven destinations entered TUN; zero synthetic replies and zero native echo forwarding. |
| Native LAN/Tailnet ping | Real IPv4/IPv6 requests and replies remained outside TUN. |
| MagicDNS | Engine answers matched native Quad100. This peer had an A answer but **no native AAAA answer**, despite having a Tailnet IPv6 address. |
| NAT64 ranges | TCP/UDP destinations remained captured and preserved through SOCKS; the labeled fixture mapping reached real services. This is not a public NAT64 translator test. |
| P08, `ipv6-prefer` | The four UDP hostname classes chose the expected upstream family; not needed for the P07 candidate. |
| P09, `redir-host` | Real DNS responses passed. One mixed-listener IPv4-literal TCP case reached IPv6 after reverse hostname restoration; see below. |
| P07 mixed SOCKS listener | IPv4/IPv6 literal and hostname TLS/UDP cases passed with the expected upstream family. |
| P10, native macOS DNS registration | System resolution, normal HTTPS clients and an actual Safari fetch of the IPv6 service passed. The owned resolver disappeared after forced engine termination. |
| Profile reloads | P00/P07 setting cycles retained route/selector invariants and expected AAAA behavior. |
| Wrong engine and occupied port | Rejected before engine startup; native access remained available. Stock parser rejection was also checked. |
| Lost test-runner process | Detached watchdog stopped the engine/captures, removed its routes, restored DNS and rechecked native IPv4/IPv6 HTTPS. |
| Engine crash | TUN/resolver cleanup passed. Native access resumes after exit; this profile is not an independent kill switch. |

In P09, preceding DNS queries mapped the shared IPv4 service address to a
dual-stack hostname whose fixture proxy preferred IPv6. A later SOCKS request
for the **IPv4 literal** was restored to that hostname, sent with SOCKS domain
ATYP, and reached the IPv6 service. Host socket/service logs confirmed it.
The pinned engine's [metadata preprocessing](https://github.com/MetaCubeX/mihomo/blob/0455d0d28c4526937380505153e65a843d8612e8/tunnel/tunnel.go)
restores names from its DNS mapping, which explains the observation.

The connection stayed inside the proxy, so this was not native leakage. It did
violate the literal-family expectation in this diagnostic case. **Keep P07's
fake-IP design; do not substitute P09 as a behavior-preserving replacement.**

## Test corrections retained in the evidence

The preliminary runs were not silently discarded:

- An initial broad fake-IP filter counted pre-existing VM QUIC traffic. Final
  verdicts use exact fixture ports and retain unrelated packet totals separately.
- A very fast cell finished before tcpdump delivered its buffered TUN packets.
  Immediate capture mode fixed the evidence collection; the cell was rerun.
- The NAT64 fixture initially replied using its mapped service address rather
  than the requested virtual address. That broke the UDP return flow; correcting
  the fixture preserved the original SOCKS address and made the exchange pass.
- MagicDNS expectations now compare with native Quad100, rather than assuming
  every address in Tailscale status has a published DNS record.
- Intentional Tailscale transport to Delta's LAN address was separated from
  fixture service traffic by exact ports.
- Safari fetched the service but the first automation could not close its
  document reference. The owned test tab was removed, and a stable window-ID
  close passed on rerun.
- One subsequent startup encountered a transient port-in-use condition after
  mixed-listener tests. The preflight now uses TCP address reuse consistently
  with the engine, while a fresh live-listener conflict still fails preflight.

These corrections changed the harness and its assertions, not the frozen profile.
P09's address-family difference remains a real diagnostic result.

## Qualification boundaries

- The supplied remote proxy's IPv6 egress remains unqualified. The new private
  candidate keeps its original proxy; successful local fixture tests cannot
  guarantee that remote server's IPv6 capability.
- P07 retains `tun.dns-mode: disabled`. Use its own DNS listener/captured DNS
  paths. The separate P10 experiment qualified native system-DNS registration;
  that setting is not silently added to the candidate.
- Packet captures were taken on VM TUN/native interfaces. Delta's BPF devices
  require unavailable root access; actual Delta socket-family/service records
  supplement the VM captures. No host permissions or networking were changed.
- No crafted ICMPv6 Packet Too Big injection was run. Existing patched-engine
  unit tests cover preserving non-echo control/error handling, and this campaign
  exercised real application payloads; full PMTU qualification remains separate.
- Deliberately native LAN/Tailnet routes, interface-bound traffic outside TUN,
  engine exit, public Internet reachability, public NAT64 translation and installed
  Mimo lifecycle are not converted into guarantees by this profile test.

## Reproduction and ownership

The new [orchestrator](../Tests/MihomoRuntimeTests/dualstack_lab.py),
[Delta fixture](../Tests/MihomoRuntimeTests/dualstack_fixture.py),
[VM runner](../Tests/MihomoRuntimeTests/dualstack_profile_test.py), and
[sanitized evidence exporter](../Tests/MihomoRuntimeTests/dualstack_evidence.py)
implement the plan. With the pinned test binary and existing private VM admin
setup, run from Delta:

```bash
python3 Tests/MihomoRuntimeTests/dualstack_lab.py \
  --root .build/dualstack-campaign --cells all --scope matrix
```

Focused scopes are `focused`, `focus-extra`, `focus-invalid-engine`,
`focus-occupied` and `watchdog`, with explicit `--cells P07:S00` or a diagnostic
profile such as `P10:S00`. The P09 diagnostic intentionally records the observed
literal-family difference as a failed assertion and stops that command.

Generated `mimo-dualstack-p00.local.yaml` through `p10` are private **lab files**:
their temporary endpoint/controller/certificate references belong to their run.
Regenerate them with a live fixture rather than loading stale endpoints. The
separate `mimo-global-dualstack-test.local.yaml` uses the original proxy and DNS
settings, has no lab overlay, and remains Git-ignored with mode 0600.

The [final independent checks](../Tests/MihomoRuntimeTests/Evidence/dualstack/final-checks.json)
passed: the exact public candidate parsed with the qualified engine; the private
candidate had only the three intended setting changes; and the working file's
fingerprint still matched all 15 campaign baselines. No fixture processes, TCP
listeners, temporary private keys, VM test directories, test engine/captures,
test TUN, DNS registration or lab browser tabs remained. Native IPv4/IPv6 routes
were restored, and real native LAN and Tailnet IPv4/IPv6 pings succeeded.

## V3 canonical profiles — 2026-11-25

The v3 canonical renderer and pinned v3 engine passed **3,620/3,620** isolated VM
checks: 3,120 matrix plus 500 focused. [Machine-readable evidence](../Tests/MihomoRuntimeTests/Evidence/v3/runtime-summary.json)
contains 812 application successes, 340 capture-verified denials, 288 expected
DNS suppressions, 1,680 DNS expectations and 500 focused passes. Preliminary
runs are retained separately; two warm-capability expectations were corrected
for the newly strict IPv4 policy before the final passing run.

This is new evidence, not reuse of the historical templates. Both actual Rule
and Global enforce strict IPv4, including proxy-resolved hostnames. Dual-stack
supports both proxied families; unsupported IPv6 and UDP fail without native
fallback. Native Tailnet ping/lookup supplements are included for the first
three configurations whose initial focused runs omitted the peer fixture.

System/native DNS scopes run the production `MimoDNSConfiguration` in an isolated
VM harness because `dns-mode` is disabled in the managed templates. Short-name
expansion, private scoped resolution, Tailnet disconnect/reconnect and teardown
all pass in IPv4 and dual stack. Those runs do not substitute for the installed
app's PF/launchd integration, which is tracked in [the v3 implementation record](MIMO_3_0_IMPLEMENTATION.md).

### Installed v3 and private ingress

The installed candidate passed **38 lifecycle checks**, including all eight
core/supervisor/engine presence combinations, full Stop, uninstall, reinstall,
removal of an injected legacy child policy/table, DNS and TUN release, and native
post-release verification. [Lifecycle evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-lifecycle.json).
These are additional installed checks, not additions to the 3,620-case profile
matrix. A controller-version-qualified role repetition passed **9/9** baseline
and role-combination observations in the final candidate.
[Recovery evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-recovery.json).

The pinned engine also passed **36 private-listener checks** across both families
and modes. Exact allowed host/port and family-pinned requests succeeded; wrong
host, suffix spoof, wrong port, wrong/no credentials and literal destinations did
not reach the fixture SOCKS server. [Private ingress evidence](../Tests/MihomoRuntimeTests/Evidence/v3/probe-acl.json).

The initially untrusted HTTPS fixture correctly failed closed. After the user
trusted its temporary certificate, **44/44 installed HTTPS assertions passed**
across IPv4/dual-stack and Rule/Global, including fresh observations, real engine
configuration, family-specific service access, manual Refresh and Direct cleanup.
No production TLS validation was disabled.
[HTTPS evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-https.json).

This run caught and fixed core discarding the requested network family and
supervisor polls overwriting the saved Direct selection. Regression tests pass;
the corrected app was rebuilt, installed and passed the complete rerun. A separate
initial harness error misclassified Mihomo's built-in inline `Compatible` provider
as the removed native provider. Both preliminary outcomes are preserved.
[Preliminary evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-https-preliminary.json).

**13/13 active recovery assertions passed**, including all eight daemon-presence
combinations from approved dual-stack Global, fresh paired reapproval after role
removal, live family/mode changes and Direct cleanup. Observed role recovery was
16.295–36.543 seconds, not a packet-exposure bound.
[Active recovery](../Tests/MihomoRuntimeTests/Evidence/v3/installed-active-recovery.json).

**9/9 paired-failure assertions passed**. IPv6 proxy refusal or an IPv6 address
outside the allowlist kept both public listeners closed despite IPv4 success.
Correcting the allowlist recovered approval. Transport refusal retained cooldown;
selecting another eligible fixture provider recovered without bypassing it. The
first harness incorrectly expected manual Refresh to bypass this cooldown; that
failed expectation remains documented separately.
[Paired failures](../Tests/MihomoRuntimeTests/Evidence/v3/installed-paired-failure.json),
[preliminary expectation](../Tests/MihomoRuntimeTests/Evidence/v3/installed-paired-failure-preliminary.json).

The leakage objective is public traffic through the selected proxy or failure,
with no silent native fallback. The profile matrix includes public IPv4/IPv6
TCP/UDP, public DNS and suppressed captured echo. LAN/Tailnet/native private DNS
are intentional scoped exceptions. Physical login/sleep, Wi-Fi hardware, native
GUI visual inspection, arbitrary remote proxy IPv6 support and an instantaneous
engine-crash containment guarantee remain outside the passing results.

The installed failed-verification campaign passed **27/27** checks: both families
and modes retain denial with blocked public listeners, all eight role combinations
recover while closed, removal of Mimo's closed rules is repaired, and Direct
restores cleanly. [Failure evidence](../Tests/MihomoRuntimeTests/Evidence/v3/installed-failure.json).
These durations measure observed recovery, not fault-to-packet-denial bounds.

The fixture servers were stopped and the temporary CA key was deleted. At the
user's subsequent request, the certificate was restored to the System keychain
with its existing SSL trust retained and verified. Trust removal is no longer
requested. Its private key had already been deleted, so future HTTPS testing
requires a replacement certificate/key. Original settings and proxy selection
were restored. The final
installed VM is healthy Direct, with empty Mimo PF, no owned DNS override/TUN
and the pinned engine. [Cleanup status](../Tests/MihomoRuntimeTests/Evidence/v3/installed-cleanup.json).
[Final state](../Tests/MihomoRuntimeTests/Evidence/v3/installed-final-state.json).
