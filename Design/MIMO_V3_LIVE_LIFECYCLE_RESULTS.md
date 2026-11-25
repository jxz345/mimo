# V3 live Tailscale and sleep/wake continuation

Status: **corrected candidate passed Rule and Global dual-stack reconnect and
measured containment; sleep skipped/unqualified**
(2026-11-25).

This follows the 68 passing installed VM cases in
[the active-guard report](MIMO_V3_ACTIVE_GUARD_RESULTS.md). It adds real Tailscale
disconnect/reconnect and human-requested macOS sleep/wake. It does not replace
physical-Mac login, power or hardware qualification.

## Setup and acceptance

- Installed candidate: Mimo 3.0 build 8 in `mimo-vm`, with the pinned v3.2 engine.
- Reuse the previously trusted, retained test certificate and closed Delta
  fixture. Save and restore the original settings, proxy catalog and selection.
- Start with dual-stack Rule. Compare three fresh engine A/AAAA queries with
  native Quad100 answers; check local TCP/UDP DNS and ordinary native peer
  ping/ping6. Tailscale's own ping is not the connectivity criterion.
- While the operator disconnects and reconnects Tailscale, continuously exercise
  both families of TCP/UDP, streams, DNS, echo and fake-address probes. A lower lab
  containment rule records any public native-bypass attempts after Mimo; positive
  controls must demonstrate detection for both families.
- Disconnected private A queries must not return a fresh peer answer or be sent
  to public DoH. After reconnect, repeat cold queries and native connectivity;
  inspect live scope removal/replacement and recovery events.
- Only after the first cycle passes, repeat in Global as appropriate and proceed
  to real sleep/wake in protected mode and managed Direct. Record OS sleep/wake
  counters, preparation/wake events, fresh protected approval and recovered
  connectivity. Locking the screen or pausing Tart is not a sleep result.
- Record unsupported VM sleep as NOT QUALIFIED. A VM pass still does not qualify
  the earlier physical login-screen freeze.

The operator receives one action at a time, after a confirmed baseline. No
Tailscale toggle, power event, engine kill or route fault is automated by this
observer. Its existing independent recovery watchdog bounds the session; raw
captures, peer identities and local fixture configuration remain private.

## Preparation observations

The first baseline found three valid A answers and native IPv4/IPv6 ping success.
It incorrectly expected a peer AAAA record. A direct Quad100 comparison showed
`NOERROR` with zero AAAA answers. That is a test expectation error, not a Mimo
failure. The initial observer restored the original settings and configuration;
its evidence is retained separately. The corrected observer compares against
the actual native A and AAAA answers, including legitimate AAAA NODATA.

Observer: [v3_live_lifecycle_test.py](../Tests/MihomoRuntimeTests/v3_live_lifecycle_test.py).
First-round private VM evidence: `/private/var/tmp/mimo-v3-live-lifecycle-2`.
Repeat private VM evidence: `/private/var/tmp/mimo-v3-live-lifecycle-3`.
Corrected candidate private VM evidence: `/private/var/tmp/mimo-v3-live-lifecycle-4`.
Initial expectation-error evidence: `/private/var/tmp/mimo-v3-live-lifecycle`.

## Results

The corrected connected baseline passed all ten checks: three cold A queries,
three AAAA queries matching native NODATA, local TCP/UDP A queries and ordinary
native IPv4/IPv6 peer pings.

After the operator disconnected Tailscale:

- Tailscale reported `Stopped`. The first sampled stopped state was closing,
  with both native Tailnet passes and all observed native transport grants
  removed. Rule/dual-stack reached active again about 12.3 seconds after that
  first stopped sample; this is sampled recovery timing, not exact click timing.
- All three cold A and three cold AAAA checks stopped matching the connected
  baseline; neither local DNS protocol returned the peer A address. Ordinary
  native IPv4/IPv6 peer pings failed as expected while disconnected.
- The active fallback guard remained installed. The ongoing lower-trap capture
  contained zero native-bypass packets at this checkpoint. The host fixture
  recorded zero `.ts.net` queries sent to public DoH or through its proxy.
- Both-family public fixture traffic continued through the proxy, with temporary
  interruption during revalidation expected. Raw observations are retained for
  final per-phase analysis.

These observations qualify the disconnected checkpoint only; no completed
reconnect cycle or sleep/wake pass is claimed yet.

The first operator-reported reconnect checkpoint (`reconnected-1.json`) still
showed backend `Stopped`; a read-only preference query showed `WantRunning=false`.
Private DNS and peer connectivity therefore remained unavailable. This is not a
completed reconnect test or evidence of a Mimo reconnect defect. Await the
operator's VM menu confirmation and an observed backend start before scoring it.

### First round ended; restart required according to the operator

The 40-minute watchdog expired and restored the original managed Direct
configuration. The finalized capture recorded **zero native attempts in either
family**; saved settings and routing configuration were restored. During the
five-minute focused Connect recorder, the backend stayed `Stopped` with
`WantRunning=false`. The operator subsequently reported that restarting
Tailscale was necessary to connect. The next backend check found it Running,
but after the test had already restored Direct. The reconnect is therefore
**inconclusive**, not PASS; this timing does not identify the cause of the
operator's connection failure. [Sanitized first-round evidence](../Tests/MihomoRuntimeTests/Evidence/v3/live-lifecycle/round1.json).

At the operator's request, repeat the actual disconnect/reconnect sequence under
protected mode. The human-operated observer now has a bounded two-hour recovery
window, records `WantRunning` along with backend state on each sample, and keeps
private DNS responses for diagnosis. The automated campaigns retain their
40-minute default. No application or firewall implementation changed for this
repeat. Do not proceed to sleep until the reconnect outcome is understood.

### Repeat: disconnected checkpoint

The repeated connected baseline passed all ten checks. The operator then
disconnected Tailscale: backend `Stopped`, `WantRunning=false`, and all ten
connected DNS/ping comparisons failed as expected. The live active guard had
zero Tailnet passes and zero native VPN transport grants, with both wrong-path
denials retained. The ongoing capture had zero native-bypass packets and the
public DoH fixture had received zero `.ts.net` queries. A separate 30-minute
Connect recorder is armed for the next operator action, with a 128 MiB raw system
log limit and half-second backend/preference samples. Reconnect is still pending.

### Repeat: startup failure and interface prerequisite

The next Connect action changed `WantRunning` to true and the backend to
`Starting`, where it remained. Health reports named a failed control-key request.
Mimo stayed active Rule/dual with no native interface passes and no native public
transport grants. The official root-owned system extension passed code-signature
validation. Its bounded socket observation contained two unconnected UDP sockets
and fifteen candidate HTTPS sockets in `SYN_SENT`; these were being excluded by
the three `nativeInterfaces.isEmpty` guards in cached preparation, fresh
preparation and active audit. That created a circular startup prerequisite.

An eight-second VM-only attribution probe inserted thirteen root-owned transport
scopes from the signed extension, after fake/private wrong-path denials and before
the engine permission. The existing active fallback guard and lower lab trap
remained. Core/supervisor were briefly suspended to keep the trial policy stable,
then resumed; an independent recovery process bounded the mutation. One temporary
HTTPS rule carried ten packets. Tailscale did not become Running within those
eight seconds, so the probe alone does not qualify a complete fix. The exact
original policy was restored. The observer subsequently restored the original
managed Direct settings; Tailscale then reached Running without another restart.
The complete repeated-round capture recorded zero native public-bypass attempts
in both families, including the attribution window. Settings/configuration
restoration passed. The reconnect itself is a **FAIL**, not a passed leak test.

Correction: always collect verified held public transport sockets, even before
a native interface exists. Private Tailnet passes still require an observed
interface and wrong-path denials remain earlier than any transport grant. No
provider, profile reload or broad root permission was added. The README, v3
plan, current event workflow, firewall reference and Settings Maintenance text
describe the distinction. All **215 shared tests** and the service suite pass;
this includes the no-interface bootstrap/wrong-path/revocation policy regression.
The corrected local 3.0 build 8 package installed successfully in the VM. Its
installed helper hash matches the packaged helper; managed Direct and all
reported roles were healthy before starting the repeat baseline. This build
number remains an unpublished local candidate. Package SHA-256:
`f97dbabbd4e96e9c4dd4a1a369d31a4952a4f412e82f380eb04d6e8d100bf19a`.
Live reconnect qualification remains pending. The historical
68-row result belongs to its recorded pre-correction package and is unchanged.

[Failed second round](../Tests/MihomoRuntimeTests/Evidence/v3/live-lifecycle/round2.json),
[corrected package identity and local tests](../Tests/MihomoRuntimeTests/Evidence/v3/live-lifecycle/bootstrap-candidate.json).

Probe source: [v3_native_bootstrap_probe.py](../Tests/MihomoRuntimeTests/v3_native_bootstrap_probe.py).

### Corrected candidate: disconnected checkpoint

The new connected baseline passed all ten DNS/ping checks. After the operator
disconnected, the backend reported `Stopped` and `WantRunning=false`. All six
cold engine queries returned errors, both local DNS protocols stopped returning
the peer address, and ordinary IPv4/IPv6 peer pings failed as expected. No native
Tailnet interface passes remained; both private wrong-path denials remained.
Four public transport scopes backed by the signed extension's socket observation
were still present, which is now independent of the private interface lifecycle.
The ongoing public-bypass capture contained zero packets, and the fixture had
received no `.ts.net` query over public DoH. The Connect recorder is armed; the
corrected candidate's actual reconnect is still pending.

### Corrected candidate: reconnect passed; ping instrumentation corrected

The operator connected Tailscale without a restart. The backend became Running
with `WantRunning=true`, Mimo returned to active Rule/dual, and all ten cold
DNS/native-ping comparisons passed. Finalizing the reconnect capture found zero
native public-bypass packets; both families had successful proxied TCP, UDP and
persistent-stream payloads. No private `.ts.net` name reached public fixture DNS.
[Scoped reconnect evidence](../Tests/MihomoRuntimeTests/Evidence/v3/live-lifecycle/corrected-rule-reconnect.json).

The old raw echo probe produced one uncorrelated IPv6 reply indication while
ordinary native ping was being tested. It did not record the reply's source or
identifier, so that indication cannot establish a public/synthetic response.
Investigation also found that its IPv4 checksum unpack failed on the odd-length
payload before sending. This invalidates that harness's historical IPv4 echo
subprobe, not the recorded TCP/UDP/DNS probes or separate system-ping tests.

The harness now zero-pads only the checksum calculation and matches reply source,
type, code, identifier, sequence and payload. Twelve packet-matching assertions
passed. A focused live rerun made eight public echo attempts per family, observed
zero matching public replies and zero native bypass, and successfully matched
real native Tailnet replies with the same matcher in both families. Keep the
earlier measurement and its limitation; do not backfill historical fault-time
IPv4 echo coverage. The corrected independent traffic observer is now used for
the actual Rule/dual sleep attempt. Global reconnect and real sleep/wake are
still pending.

### First power attempt was screen lock, not sleep

The operator confirmed using Lock Screen, followed by the display darkening.
The records contain `screen_locked` and `screen_unlocked`, no sleep/wake guard
events, and no OS sleep/wake counter increase. Rule/dual remained active after
unlock; the corrected traffic capture recorded zero native bypass in both
families. This is **NOT A SLEEP TEST** and does not qualify sleep recovery.
[Screen-lock evidence](../Tests/MihomoRuntimeTests/Evidence/v3/live-lifecycle/rule-screen-lock.json).

Preserve that attempt's `protected-sleep-*` files. A separate `menu-sleep-*`
baseline/capture was prepared for Apple menu → Sleep inside the VM. Neither Tart
pause nor a lock event substitutes for OS sleep/wake counters and power callbacks.

### Apple-menu attempt skipped; Global baseline ready

The operator reported that the VM would not sleep and requested skipping this
test. The capture was finalized; all three OS sleep/wake counters remained zero,
with no sleep/wake events in the observation window. Mimo remained active
Rule/dual and the measured capture had zero native-bypass packets. This is
**NOT QUALIFIED / SKIPPED**, not a sleep/wake pass or a diagnosis of why the VM
would not sleep. No further power operation is requested. Protected and managed
Direct sleep/wake qualification remain open.
[Skipped-attempt evidence](../Tests/MihomoRuntimeTests/Evidence/v3/live-lifecycle/rule-menu-sleep-skipped.json).

The continuation has switched to active Global/dual. Tailscale is Running and all
ten baseline DNS/native-ping comparisons passed. A separate corrected traffic
observer and backend/Connect recorder are running, with bounded deadlines and
the existing independent recovery watchdog. The next operator action is a real
disconnect, followed by a separately requested reconnect. This is a baseline,
not a completed Global reconnect result.
[Global baseline evidence](../Tests/MihomoRuntimeTests/Evidence/v3/live-lifecycle/global-reconnect-baseline.json).

### Global/dual: disconnected checkpoint

After the operator disconnected, Tailscale reported `Stopped` with
`WantRunning=false`. Mimo remained active Global/dual. All six uncached private
A/AAAA queries returned error responses, both local DNS checks stopped returning
the peer address, and native IPv4/IPv6 peer pings failed as expected. The live
policy had zero private Tailnet passes, both wrong-path denials and four signed
public transport scopes, preserving the pre-tunnel reconnect path.

The ongoing corrected capture contained zero native-bypass packets in either
family at this checkpoint. The closed fixture recorded successful Global-labelled
TCP/UDP service requests in both families and zero `.ts.net` queries among all
1,719 public DNS fixture records so far. These counts are an interim snapshot;
the capture remains open through the next reconnect. No completed Global
reconnect or final traffic qualification is claimed yet.
[Disconnected evidence](../Tests/MihomoRuntimeTests/Evidence/v3/live-lifecycle/global-disconnected.json).

### Global/dual reconnect passed; manual setup restored

The operator connected Tailscale; the backend returned to Running with
`WantRunning=true`. All ten fresh DNS/native-ping comparisons passed in active
Global/dual. The finalized corrected capture recorded zero native-bypass packets
and zero matched public echo replies across 1,523 echo probes per family. Both
families had successful TCP, UDP and persistent-stream payloads. No `.ts.net`
query appeared in the 1,857 public DNS fixture records accumulated by this point.
[Completed Global evidence](../Tests/MihomoRuntimeTests/Evidence/v3/live-lifecycle/corrected-global-reconnect.json).

The manual observer and its independent watchdog completed. Saved settings and
routing configuration were restored exactly; managed Direct was active with all
three reported services running, empty Mimo PF and no owned resolver. All manual
packet captures stopped. The host fixture is retained temporarily for the
separate corrected fault-traffic rerun below; its certificate remains reusable.

The historical echo gap was addressed by a new **32/32 passing** campaign (four
baselines, 28 faults across IPv4/Dual × Rule/Global) using the same corrected
installed candidate. The harness records actual raw-send attempts after checksum
construction and required both-family attempts during every fault, plus zero
matching public replies. All captures had zero native bypass, and every fault
recovered. These new results do not retroactively validate the historical sender.
See [the correlated fault rerun](MIMO_V3_CORRELATED_FAULT_RESULTS.md).

After that rerun, original VM settings/catalog/selection and managed Direct were
restored again. Independent native A/AAAA and peer ping/ping6 checks passed;
Tailscale was Running. All temporary captures, routes and lab controls were
removed, and the Delta fixture was stopped. The reusable certificate/key remain.
