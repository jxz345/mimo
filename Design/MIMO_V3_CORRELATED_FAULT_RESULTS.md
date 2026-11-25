# V3 corrected ICMP and fault-traffic rerun

Status: **32/32 passed; original VM state restored; fixture removed**
(2026-11-25).

This reruns four baselines and 28 faults across IPv4/Dual × Rule/Global after
correcting the odd-length IPv4 ICMP checksum and reply correlation in
`Tests/MihomoRuntimeTests/v3_fault_traffic_test.py`. The historical 68-row result
does not qualify that old sender's IPv4 echo coverage. This is new evidence on
the corrected native VPN bootstrap candidate, not a replacement for old results.

Candidate: unpublished Mimo 3.0 build 8, helper SHA-256
`d04b44fe9645512bc1d5e15e09c4ab020f1745d666050872e11c2bd7b8529351`.
Use the existing closed Delta fixture and VM only. Preserve the installed app;
no new build or publication is required. Keep reusable certificate trust.

For each mode/family combination, run a baseline and engine kill, engine stall,
core stall, supervisor stall, both owners stalled, a more-specific native route,
and both owners stalled while killing the engine. Exercise both-family TCP/UDP,
persistent streams, DNS, echo and fake-address targets continuously. A separate
lab rule after Mimo contains and records any native fallback. Direct positive
controls must demonstrate detection for both families first.

Require zero native attempts before/during/after each fault, effective protected
recovery, zero matching public echo replies, and at least one actual echo-send
attempt per family during each fault window. Record send-attempt flags only
after packet/checksum construction, so a sender exception cannot masquerade as
a blocked ping. Reply matching checks source, type/code, identifier, sequence
and payload. Baselines must also show intended family-specific TCP/UDP success.

Retain independent process-resume and campaign recovery watchdogs. Restore the
original settings, proxy catalog/selection and managed Direct; remove temporary
routes, captures, PF lab controls and the fixture afterward. Sleep remains
skipped/unqualified at the operator's request. No physical-Mac or native UI
qualification is implied by this campaign.

Private VM root: `/private/var/tmp/mimo-v3-correlated-faults-1`. The installed
helper and engine, together with the exact script hashes, are recorded in
[the campaign manifest](../Tests/MihomoRuntimeTests/Evidence/v3/correlated-faults/manifest.json).
The Direct detector recorded 80 native attempts spanning both families before
the protected baseline started; these are expected positive controls, not
protected-mode leakage.

## Results

| Case | IPv4 Rule | IPv4 Global | Dual Rule | Dual Global |
|---|---|---|---|---|
| Baseline traffic and silent public echo | PASS | PASS | PASS | PASS |
| Engine terminated | PASS | PASS | PASS | PASS |
| Engine suspended | PASS | PASS | PASS | PASS |
| Core suspended | PASS | PASS | PASS | PASS |
| Supervisor suspended | PASS | PASS | PASS | PASS |
| Core and supervisor suspended | PASS | PASS | PASS | PASS |
| More-specific native routes | PASS | PASS | PASS | PASS |
| Core/supervisor suspended and engine terminated | PASS | PASS | PASS | PASS |

All 28 faults recovered to the confirmed active mode/family. All 32 captures
contained **zero native-bypass packets** and **zero matching public echo replies**.
During the fault windows, the corrected raw sender attempted 535 IPv4 and 533
IPv6 sends, with at least 12 attempts in every fault/family cell. An attempted
send may be rejected by the OS; the count proves execution reached the send
call after checksum construction, rather than failing silently beforehand.

The four baselines met their family-specific TCP/UDP/persistent-stream criteria.
These observations close the historical fault-harness ICMP coverage gap for this
candidate and these scenarios. They do not rewrite earlier results or establish
protection against arbitrary privileged firewall changes, boot-before-loader
traffic, all VPN implementations or all physical network/power conditions.

Evidence: [summary](../Tests/MihomoRuntimeTests/Evidence/v3/correlated-faults/summary.json),
[all 32 rows](../Tests/MihomoRuntimeTests/Evidence/v3/correlated-faults/traffic-results.json),
[positive detector control](../Tests/MihomoRuntimeTests/Evidence/v3/correlated-faults/detector.json).
Private packet captures and per-probe observations remain in the VM root above.

## Restoration and remaining limits

The campaign and independent watchdog finished successfully. Original settings,
proxy catalog/selection and saved family were restored, with managed Direct and
all services healthy. Independent checks confirmed empty Mimo/lab PF, owned DNS
removal, no captures or lab `pflog0`, Tailscale Running, matching native A/AAAA
answers and successful native peer ping/ping6. The installed helper hash remained
unchanged. The Delta fixture process and all six listening service ports were
closed. Reusable VM certificate trust and the host certificate/key were retained.

[Restoration](../Tests/MihomoRuntimeTests/Evidence/v3/correlated-faults/restore-results.json),
[independent native checks](../Tests/MihomoRuntimeTests/Evidence/v3/correlated-faults/final-independent-checks.json),
[host cleanup](../Tests/MihomoRuntimeTests/Evidence/v3/correlated-faults/host-cleanup.json).

Real sleep/wake remains skipped/unqualified at the operator's request; screen
lock was not scored as sleep. Native visual inspection, physical multi-account
and network/power cases, and actual PF kernel-operation failure remain separate
qualification limits. This local candidate was not published.
