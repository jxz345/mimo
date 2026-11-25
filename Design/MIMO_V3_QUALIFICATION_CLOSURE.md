# V3 qualification closure campaign

Authorized 2026-11-25: run the remaining tests and provide step-by-step physical
Mac instructions. No publication or host networking changes are authorized by
this campaign. Preserve the frozen working profile and original VM settings.

## Recorded cases before execution

Counts below are scenario records, not individual assertions. Preserve failures
and reruns; do not add these numbers to the historical profile matrix.

| Group | Cases | Scope |
| --- | ---: | --- |
| Installed traffic baseline | 4 | IPv4/dual × Rule/Global; literal TCP/UDP, DNS, long-lived and fresh connections. |
| Installed fault traffic | 24 | The same four configurations × engine kill, engine stall, core stall, supervisor stall, core+supervisor stall, more-specific native route. |
| Firewall failure | 2 | Blocked mutation lock during close; invalid independent guard input during repair. Existing traffic and confirmation must be observed, not inferred from intent. |
| IPv6 control | 4 | Rule/Global × Packet Too Big handling and neighbor/control traffic plus large payload exchange. State exact injection/path coverage. |
| Final package/coexistence | 8 | Package identity, install/upgrade, reinstall after release, uninstall, occupied port refusal, explicitly approved fixture takeover, foreign-rule preservation, final healthy restoration. |
| Native UI | 6 | Dashboard sizing/IPv6/flags, family controls, service ages, communication uncertainty, settings layout, two GUI client state consistency. |
| Physical Mac | 6 | Sleep/wake, Wi-Fi changes, logout/login, fast account switching with two GUIs, reboot, native Tailnet after release. User operates the Mac. |
| Total planned | 54 | Each row must be PASS, FAIL, NOT RUN or an explicitly described architectural limit. |

## Packet evidence and containment

Use closed Delta services, fixture-only SOCKS forwarding and reserved test
destinations. Capture VM TUN/native traffic and record fixture admissions and
service exchanges. No real credentials or private names enter the fixtures.

Where testing fallback to a reserved destination, install an independent,
temporary lab containment anchor *after* Mimo's anchor. It blocks only the
test destination/ports on the VM's native interface. Its rule counters/logs are
evidence that a packet reached native egress past Mimo; it prevents that test
packet from leaving the VM. It is not part of Mimo or a proposed production fix.
Calibrate the detector in Direct, verify zero hits during normal protected
traffic, distinguish native attempts from completed service connections, and
remove only the lab-owned rules afterward. Record limitations if packet logging
or capture cannot observe a stage. Do not claim a universal zero-leakage bound.

Timestamp the injected fault, observed health/phase, actual Mimo rule change,
native-attempt counters, proxy admissions and recovery independently. A healthy
launchd job or restored GUI status alone does not pass a packet test. Resume
stalled processes using an independent watchdog and restore Direct on abort.

Actual PF kernel failures that cannot be safely induced in the unmodified
candidate remain unqualified; do not substitute a parser-only check for them.

## Reusable TLS fixture

The user approved SSL trust for `Mimo reusable qualification TLS` in mimo-vm.
Expiry: 2027-02-23 03:51:45 UTC. SHA-256:
`2B:5C:84:4E:10:ED:53:F1:AA:21:65:97:B0:5A:82:05:A6:8D:35:74:83:BF:D9:A0:34:E4:1A:20:76:C9:4D:3F`.
Certificate and key are retained in owner-only local storage outside the
repository at `~/.config/mimo-vm/qualification-tls/`. Do not delete them at
campaign cleanup or publish them. Servers, temporary proxy entries, routes,
captures and lab firewall material still require normal cleanup.

## Results

Automated execution completed. **The candidate is not release-qualified.** Normal traffic
baselines passed in all four configurations, but the installed Release candidate
admitted native attempts after every engine-kill injection and one native-route
injection. Lab containment stopped them before they left the VM. This is a measured
active-policy limitation, not a provider/TLS failure or a completed remote leak.

| Fault case | Native attempts | First attempt after injection | First sampled closed PF | Recovered |
| --- | ---: | ---: | ---: | --- |
| IPv4 / Rule, engine kill | 2 | 33.7 ms | 96.7 ms | Yes |
| IPv4 / Global, engine kill | 3 | 37.9 ms | 423.8 ms | Yes |
| Dual / Rule, engine kill | 1 | 55.5 ms | 371.4 ms | Yes |
| Dual / Global, engine kill | 4 | 21.8 ms | 165.8 ms | Yes |
| IPv4 / Global, more-specific native route | 2 | 99.4 ms | 504.6 ms | Yes |

PF sampling is periodic, so the sampled timestamp is not the exact kernel denial
instant or a worst-case bound. Packet captures include IPv6 TCP SYNs to the test
DNS destination and service. All test destinations are reserved fixture addresses.
The observation does not depend on interpreting an IP-monitor success as proof of
traffic routing. [Initial evidence](../Tests/MihomoRuntimeTests/Evidence/v3/closure/fault-traffic-initial.json).
Observed packet classes include IPv4/IPv6 DNS, IPv4/IPv6 service TCP and one IPv6
ICMP attempt. [Sanitized protocol counts](../Tests/MihomoRuntimeTests/Evidence/v3/closure/native-packet-types.json).
The IPv4-only profile still rejected IPv6 while its engine was active; that
profile cannot enforce rejection after the process/TUN disappears.

Four initial core-stall records prematurely asserted empty PF against a cached
Active snapshot immediately after core resumed. Those are preserved harness
failures; corrected polling waits for the full engine/PF/observation state and
reruns the four cases. The earlier statement that core exceeded its recovery
deadline was incorrect: the initial assertion aborted before that deadline.

All four corrected core-stall reruns subsequently **reached the full
100-second deadline**. They remained confirmed Blocked with “The core heartbeat
expired. Verification is required.” and recorded zero native attempts. Source
inspection identifies a distinct recovery gap: the liveness-loss branch closes
without setting `verificationRecoveryPending`, whereas audit failure sets it for
the infrastructure monitor's recheck.
[Corrected recovery evidence](../Tests/MihomoRuntimeTests/Evidence/v3/closure/core-resume-results.json).
This is an availability/retry failure, separate from the engine-crash exposure.

All **four IPv6 control cases passed**. In both Rule and Global, one injected
ICMPv6 Packet Too Big message quoted actual TCP output from the installed TUN
stack, advertised MTU 1280, and reduced subsequent IPv6 TCP packet size from a
maximum of 3113 to 1252 bytes on the same connection. Repeated payload exchange
remained exact. Native IPv6 ping and an authenticated 262144-byte proxied TLS
payload also passed in each mode. This qualifies that live PTB/PMTU path and
ordinary native neighbor reachability; it is not a crafted Neighbor Advertisement
attack test or an external Internet path qualification.
[IPv6 control evidence](../Tests/MihomoRuntimeTests/Evidence/v3/closure/ipv6-control-results.json).

Two earlier harness preconditions are retained privately: promiscuous capture
changed interface flags and correctly triggered revalidation (fixed with `-p`),
and the SOCKS fixture returned a mapped UDP source instead of the requested
virtual source (corrected in the fixture). Neither is counted as a production
failure or a successful baseline.

The final local Release ZIP/PKG identify version 3.0, build 8; the pinned engine
SHA-256 is `9103954f5cb48c2e93826ba1f61e6c2677d9363680eecdf00b09b94c3a4253d8`.
[Package hashes](../Tests/MihomoRuntimeTests/Evidence/v3/closure/release-build.json).
No GitHub/tap publication has occurred.

### Final accounting and restoration

| Group | PASS | FAIL | NOT RUN | Notes |
| --- | ---: | ---: | ---: | --- |
| Normal installed traffic | 4 | 0 | 0 | Both families × both modes. |
| Fault traffic and recovery | 15 | 9 | 0 | Five native-bypass findings; four corrected core-resume timeouts. |
| PF failure reporting | 2 | 0 | 0 | Bounded mutation-lock hold and real invalid-input parser rejection. |
| IPv6 control | 4 | 0 | 0 | Live PTB and native control/large TLS exchange in each mode. |
| Final package/coexistence | 8 | 0 | 0 | Local Release package; real CLI consent for a test-owned conflicting process. |
| Native UI | 0 | 0 | 6 | Screen Sharing AX action and subsequent observation timed out; no Mimo UI behavior is inferred. |
| Physical Mac | 0 | 0 | 6 | Requires user execution; procedure below. |
| Total planned scenarios | 33 | 9 | 12 | 42 automated scenarios executed, 54 planned. Reruns do not inflate counts. |

[Machine-readable final accounting](../Tests/MihomoRuntimeTests/Evidence/v3/closure/summary.json).

Holding the actual PF mutation lock for eight seconds delayed the operation,
without falsely confirming closure or admitting native test packets; release of
the lock permitted verified Global activation. The invalid independent guard
input caused real `pfctl` parser rejection, health `failed`, gate `pending`, and
no false claim of an installed deny. The existing proxy still carried traffic;
restoring valid input recovered protection. This is **not** qualification of an
actual failed kernel ruleset load or state flush. The first parser assertion
mistakenly expected the guard to expose `pfctl` stderr; `required()` deliberately
reports only command/status. Its harness failure is retained, and the rerun
checked both that status and the invalid installed file's real parser rejection.
[Initial PF evidence](../Tests/MihomoRuntimeTests/Evidence/v3/closure/firewall-initial.json),
[corrected parser evidence](../Tests/MihomoRuntimeTests/Evidence/v3/closure/firewall-failure-results.json).

The final Release package passed identity/signature, upgrade, Stop/legacy cleanup
with unrelated-rule preservation, occupied-port refusal without consent, real
terminal confirmation followed by termination of exactly the test-owned listener,
service restoration after Stop, uninstall, and final reinstall/healthy Direct.
These are installed package/service tests, **not a new Homebrew or native dialog
UI qualification**. [Package evidence](../Tests/MihomoRuntimeTests/Evidence/v3/closure/package-results.json).

Original VM settings, full proxy catalog, active proxy selection and saved family
were restored. Managed Direct is healthy, Mimo's active root is empty, the owned
resolver is absent, both lab anchors are empty, temporary routes/capture processes
are removed and the campaign-created `pflog0` was destroyed. Delta fixture servers
stopped, and their TCP listeners are absent. The reusable certificate and owner-only
key are retained as requested. The frozen working profile's SHA-256 remains
`75f18599e9a7bf333915c6a0341bf7b36e482cccf87541295afb09c9e303ef8a`.
[Restoration evidence](../Tests/MihomoRuntimeTests/Evidence/v3/closure/restore-results.json).

### Native UI procedure when the display is available

The automation timeout occurred in Screen Sharing, so it does not establish that
Mimo's GUI froze. Reopen the `mimo-vm` Screen Sharing connection manually, then:

1. Open Mimo → Dashboard. Check both address slots, country flags, equal service
   row heights and readable controls at the normal window size.
2. Select IPv4, then dual stack, with a suitable test proxy. Check that the family
   selection persists and the IPv6 address does not resize either column.
3. Observe service ages for ten seconds. Values must use `Healthy(n secs)` and
   correspond to real core inspection times; navigation alone cannot renew them.
4. For communication-loss presentation, coordinate a contained VM core-stall test
   with the operator; check that unavailable communication is distinguished from
   a proved stopped service. Do not repeat the engine-crash test on a physical Mac.
5. Open Settings. Check distinct Proxy/Bypass icons, traffic-policy placement,
   proxy list controls, monitoring interval including Never, and no duplicate
   family selector under Proxy.
6. Check the same shared selection in two signed-in accounts, using physical
   procedure step 5 below. Record both GUIs' observed states and responsiveness.

These six outcomes are not yet recorded. Address the automated blockers before
using physical-Mac testing as a release gate.

## Physical Mac procedure — pending user execution

These six checks measure native integration and responsiveness; they cannot
override the failed packet-fault cases above. Do not infer that a successful
website load proves no bypass. Keep deliberate engine-crash/route injection in
the contained VM. Run this sequence on a test Mac after the candidate decision,
not as a request to replace a working primary-Mac installation now.

1. **Preparation.** Save work in both macOS accounts. Install the supplied local
   `dist/Mimo-3.0.pkg`; verify Dashboard reports 3.0 (8). Keep the installer and
   `/Applications/Mimo.app` available. Record the UTC start time with `date -u`.
   Select the intended real proxy, IPv4 or dual stack, then Rule. Wait for fresh
   approval and record the selected family, mode and service status. Do not copy
   proxy passwords or provider tokens into the report.
2. **Sleep/wake.** With Dashboard open, use Apple menu → Sleep. Wait 30 seconds,
   wake and unlock. Record whether the login screen responds, the displayed
   transition and time to a fresh exit observation. Repeat once in Direct;
   Direct must remain usable without an approval barrier.
3. **Wi-Fi change.** In Rule, switch between two available networks (or turn
   Wi-Fi off for ten seconds and back on). Record the transition and time to
   recovery. Repeat in Direct. This tests physical networking; a VM resolver-key
   change is not a substitute.
4. **Logout/login.** In Rule, log out normally and log back in. Open Dashboard.
   Record responsiveness, the initial communication status and when current core
   results arrive. A disconnected GUI must not claim a new health measurement.
5. **Two accounts.** Leave Mimo open in account A. Use fast user switching to B
   and open Mimo there. Change Rule → Global in B, wait for approval, then return
   to A. Both GUIs must converge on the same shared selection and fresh result.
   Repeat B → A once. Record any login-window freeze or prolonged delay; do not
   repeatedly force switching through an unresponsive login screen.
6. **Reboot.** Save work, select Rule and reboot normally. Record whether login
   responds and Mimo reaches a fresh approved state. Repeat once starting from
   Direct. GUI startup is not required for core-owned routing to work.
7. **Release and Tailnet.** In Dashboard choose “Stop engine and use Direct”.
   Wait for completion and its Event Log entry. Use ordinary `ping` to a known
   Tailnet IPv4 address and `ssh` to its fully qualified Tailnet name; compare
   with the same tests before release. If available, also use `ping6` to that
   peer's Tailnet IPv6 address. A `tailscale ping` alone is insufficient. Verify
   another VPN can start, then stop it before activating Mimo again. Activation
   must restore all intended daemons or show a specific conflict for confirmation.

Report each case as PASS/FAIL/NOT RUN, with Mac model/macOS version, mode/family,
UTC time, observed delay and the relevant Event Log interval. If UI/network access
does not recover, the installed independent cleanup path is:

```sh
sudo /bin/bash /Applications/Mimo.app/Contents/Resources/daemon.sh deactivate
```

Retain the complete output if cleanup fails; do not delete the app while cleanup
is incomplete. This command intentionally releases Mimo, so run it only as the
recovery/cleanup step, not during a protected-mode leakage measurement.
