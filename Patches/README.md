# Mimo engine patches

## Current managed v3 engine

`mihomo-1.19.34-v3.patch` combines silent captured echo, strict IPv4 enforcement
in both modes, the private verification ACL and native overlay route selection.
`v1.19.34-mimo-v3.2` leaves CGNAT/Tailnet ULA sockets unbound on macOS so the
native host route chooses the tunnel. Interface address-prefix matching cannot
select Quad100 from a /32 Tailnet interface and previously bound it to the physical
default. Mimo's active PF policy independently blocks those destinations on a
wrong interface. This change does not add a utun provider or an interface name
to the profile. Core requires the `native-dns-route-v1` engine capability.

Use `Scripts/build-v3-engine.sh` with Go 1.26.11. Source/patch/binary hashes and
required capabilities are pinned in `Configuration/MihomoDependency.plist`.
The script also tests native-route selection, destination family and probe ACLs.
Packet and installed-app qualification are recorded separately in
`Design/MIMO_V3_ACTIVE_GUARD_RESULTS.md`; compilation alone does not qualify them.

## Historical standalone no-ping engine

This is a **standalone test engine**, not an app release. It accompanies
[`mimo-global-ipv6-test.yaml`](../Profiles/mimo-global-ipv6-test.yaml).

Stock Mihomo v1.19.34 cannot provide the requested behavior using
`disable-icmp-forwarding` alone: that flag selects synthetic echo replies.
Ordinary Global/Rule TCP/UDP proxy selection does not apply to ICMP. Changing
only the listener's preparation result also misses the gVisor handler's
own-address reply shortcut.

The patches add an explicit `gvisor-no-ping` stack selection. It uses the
ordinary gVisor TCP/UDP stack, but consumes captured ICMPv4 echo requests and
ICMPv6 echo requests before direct forwarding or reply generation. No ICMP
unreachable or synthetic echo is returned. Other ICMP types retain normal
handling, including IPv6 Packet Too Big and neighbor/router messages.

Native connected LAN and Tailnet routes stay outside TUN, so real ping to those
addresses remains available. This does not claim to block traffic that an
application deliberately sends outside the TUN using a different interface.

The distinct stack name is deliberate: **stock Mihomo rejects this profile**.
It cannot silently ignore an unknown YAML option and return fake ping success.
Existing `gvisor`, `system` and `mixed` behavior is unchanged by this opt-in
patch. Do not change the profile back to `gvisor` while claiming ping is blocked.

## Pinned sources and build

- Mihomo v1.19.34: commit `0455d0d28c4526937380505153e65a843d8612e8`.
- sing-tun v0.4.29: module sum `h1:KIULEuW0iFXxLegOgrW8orq5Sx4TCBBhwo6j8+CIFBs=`.
- Go 1.26.11; `CGO_ENABLED=0`; `with_gvisor`; darwin/arm64 qualification.
- Version: `v1.19.34-mimo-no-ping.1`.
- [Mihomo patch](mihomo-1.19.34-no-ping.patch): stack parsing, handler policy and parser tests.
- [sing-tun patch](sing-tun-0.4.29-no-ping.patch): packet drop and packet/control-message tests.

Run from the repository with Go 1.26.11 available:

```bash
MIMO_GO=/absolute/path/to/go bash Scripts/build-no-ping-test-engine.sh
```

The script fetches the pinned source, checks the module checksum, applies both
patches, runs their focused tests, and writes `.build/no-ping-repro/mihomo-no-ping`.
It refuses to overwrite an existing source directory. Set
`MIMO_NO_PING_BUILD_ROOT` to a fresh directory for another build. It never starts
an engine or changes host network settings. Record the printed checksum when
copying the binary into `mimo-vm`; the VM tests require that exact checksum.
The checked build identity is in [the manifest](no-ping-test-engine.json).

## Validation and limits

Parser tests verify that the policy survives config/controller serialization
and unknown stacks fail. Packet tests fail if an echo request reaches either
forwarding or synthetic-reply code; ICMPv6 control/error packets remain on the
normal handling path.

[VM packet tests](../Tests/MihomoRuntimeTests/no_ping_profile_test.py) check six
captured destinations with two requests each, zero echo replies, no native
forwarding, and real LAN/Tailnet IPv4/IPv6 ping before, during and after the test.
The Global/DNS and real Delta IPv6 HTTPS/UDP suites exercise this same engine.
See [profile instructions and evidence](../Profiles/README.md).

No app bundle, production engine pin, installer, PF rule, provider workflow or
release number is changed. Installed-app lifecycle integration remains separate
work. Upstream source retains its original licenses; the build downloads it
rather than copying a vendored engine into this repository.
