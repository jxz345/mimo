# Boot protection repair

The required behavior is unchanged: a saved Rule/Global selection must not allow ordinary public traffic before fresh proxy and allowlist verification. Starting a launch daemon sooner is not sufficient evidence of protection from the beginning of boot.

## Findings on 2026-11-19

The existing PF guard still starts after networking. An experimental empty network location can be committed to disk without applying it to the running system. A cold VM start using that location had no configured services or primary IPv4 interface; all 89 public TCP attempts failed. The test restored the original location and removed its temporary boot job. See [the experiment record](../Tests/ReleaseEvidence/mimo-boot-barrier-experiment.json).

That experiment is not suitable for production. Apple's InterfaceNamer can add default configuration for newly discovered interfaces. Restoring the normal persistent location during startup would also introduce another crash/reboot window before isolation was re-armed. Writing a replacement live `Setup:/Network` tree would take over macOS network configuration and is not a justified workaround for these problems.

## Next implementation candidate

Evaluate a signed Network Extension packet filter as a persistent startup barrier. Keep mihomo's existing IPv4 tunnel and the supervisor's PF enforcement. A data-flow filter alone is insufficient for a requirement that includes initial packets; the experiment must use packet filtering and capture actual traffic.

The packet barrier must start closed, permit only the explicitly supported local bootstrap traffic, and remain closed if the supervisor is absent. The supervisor may release that barrier only after its PF startup guard is independently confirmed. Rule/Global then follow the existing private probe and allowlist verification. A stale pre-reboot acknowledgement or expired lease cannot grant access. Direct recovery and uninstall must explicitly restore ordinary IPv4 access.

This is a candidate, not a claim that Network Extension automatically guarantees first-packet protection. Before integrating it into the normal build, measure:

1. Cold boot with a protected selection and a deliberately delayed/missing supervisor.
2. New network hardware present at boot; Wi-Fi/Ethernet changes after boot.
3. Extension crash/restart, supervisor crash, and stale acknowledgements.
4. Failed proxy, empty/wrong allowlist, successful private probe and approved opening.
5. Direct recovery, repair, upgrade and uninstall, including cancellation.
6. Actual physical sleep/wake with packet capture and kernel sleep/wake counters.

Delta currently reports no valid code-signing identity, no installed provisioning profiles, and no stored Xcode developer accounts. A Developer ID identity and provisioning for the Network Extension must be available before installation can be tested with normal macOS protections enabled. Do not disable SIP or weaken macOS security to make the experiment pass.

## Separate repairs already in progress

The existing supervisor now has a dedicated IOKit power queue and a PF power sub-anchor. It closes protected traffic before sleep acknowledgement, invalidates old approvals, and requires fresh verification on wake. VM event injection tests exercise the real PF path; they are explicitly not physical sleep evidence.

The relay investigation also found different native Tailscale versions: Delta 1.104.2 and VM 1.104.7. Upstream [PR 21902](https://github.com/tailscale/tailscale/pull/21902) addresses UDP reachability errors, and the maintainers identify fixes in 1.104.5. The final Mimo bootstrap/socket/locking repair now passes two consecutive 44-check runs against those original versions. Matching versions is no longer necessary for reproducing those passing results. The signed/notarized official 1.104.7 package is prepared locally. Updating Delta requires approval because previous network mutations were confined to the VM. Version mismatch is a hypothesis, not a demonstrated cause of the relay failures.

## Platform references

- [Apple: Network Extension entitlements](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.developer.networking.networkextension) specifies Developer ID provisioning for an independently distributed content-filter system extension.
- [Apple: packet filter provider identifier](https://developer.apple.com/documentation/networkextension/nefilterproviderconfiguration/filterpacketproviderbundleidentifier) requires a system extension for packet filtering on macOS.
- [Apple: configuring Network Extensions](https://developer.apple.com/documentation/xcode/configuring-network-extensions/) describes the capability and provisioning setup. These documents establish the supported packaging path; they do not replace measured boot/crash acceptance.
