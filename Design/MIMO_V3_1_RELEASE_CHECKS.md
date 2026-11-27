# Mimo 3.1 build 12 release checks

Release identity: **3.1 / 12**, immutable tag `v3.1-build.12`. Homebrew uses the
marketing version `3.1`; the download URL and checksum identify build 12.
Earlier releases and their artifacts remain unchanged.

Published **27 November 2026 at 23:57 UTC**:
[Mimo 3.1 (build 12)](https://github.com/jxz345/mimo/releases/tag/v3.1-build.12).
Source commit: `565016a8888a43fa927b18c8c4d6b0de3a8e7a77`. Homebrew tap commit:
`f6afe69205be4a083b53bab5ae25ca4addcde893`.

All five uploaded digests match the built artifacts; see
[distribution evidence](../Tests/ReleaseEvidence/v3.1-build12/distribution.json).
Post-publication Homebrew lifecycle qualification is in progress on the pinned
primary VM (`mimo-vm`); no result is claimed in advance.

## Included behavior

- Approved-path observations keep traffic open while checking. A disallowed IPv4
  closes outbound access; actual path changes still block before verification.
- Coalesced refresh and mode requests, current-generation approval ownership,
  bounded queues and explicit superseded outcomes prevent obsolete work from
  changing a newer routing decision or pausing a healthy provider.
- Serialized infrastructure and release workers keep status delivery responsive.
  Native-policy contention defers without an unrelated exit check, and health
  receipts describe completed readback rather than optimistic publication.
- Core infrastructure/peer roles replace Perl launch jobs, expose bounded logs,
  and report service health through the shared backend.
- Literal local IPv4/IPv6 destinations provide incoming TCP tracking in ordinary
  Direct. Address-only maintenance does not close traffic or reload profile/DNS.
  Full Stop and uninstall remove all owned network controls.

## Candidate validation and provenance

The [remaining-failure report](MIMO_REMAINING_FAILURE_INVESTIGATION.md) records
**24/24 distinct VM cases** (the requested 16 plus eight relevant additions) and
**7/7 new local Direct maintenance controls**. The earlier failed attempts are
preserved, not relabelled. Shared routing (27), guard (45), the 84-source Swift 6
typecheck and signed packaging checks also passed in that campaign. Previously
successful unrelated suites were not rerun.

The final pre-release candidate core SHA-256 was
`1942a60ab1b5f635f1eb61b4de25140e1b1d83c15eb7fbf3b732b56e5706395e`.
Before release metadata changes, all 141 production/configuration/build inputs
matched its saved source manifest. The 3.1 build changes the marketing version,
build number and matching GUI/core version-handshake strings. Candidate results
remain attributed to their tested binary; final distribution checks are separate.

The installed candidate supplement tested real incoming SSH through rejected-exit
blocking (109/109 echoes), full Stop/Activate backends and IPv4/IPv6 local-address
inventory changes. Four settled windows lasted at least 35 seconds with no
unexplained gate changes, exit checks or health failures. These were RPC/backend
and packet tests, not a new native button-click audit.

## Distribution and Homebrew qualification

Release checks passed: sealed arm64 app, 3.1/build-12 identities, six nested/core
signature checks, five matching GitHub asset digests, generated cask Ruby syntax
and cleanup-source consistency. The ZIP is free of AppleDouble entries. The PKG
contains 51 AppleDouble records, all inspected as only macOS provenance with
empty resource forks; no private attributes were found. The installer is unsigned
and the app is ad-hoc signed, as documented. The two bundled core copies have
identical code/data; signature blobs and their size fields explain their different
hashes. See the [artifact audit](../Tests/ReleaseEvidence/v3.1-build12/artifact-audit.json)
and [source provenance](../Tests/ReleaseEvidence/v3.1-build12/source-provenance.json).

Published ZIP SHA-256:
`53af2899718a80a956baff03c97e77f65e8f01d62e1e55a815fee531c5946d57`.
Installed core target SHA-256:
`49e2f183814021f35d7fcbfccc44386bbbdd26cced49fbb86b6fbf231ab6495f`.

Four actual Homebrew lifecycle steps on `mimo-vm`:

1. Uninstall the existing cask and verify network/service cleanup.
2. Install published 3.1; verify artifact identity, all three jobs and healthy Direct.
3. Uninstall 3.1; verify app/jobs/PF references/DNS/TUN removal and native connectivity.
4. Install 3.1 again and leave all services healthy with original settings retained.

Observe service/event behavior, preserve private configuration and trusted test
certificates, and keep raw logs outside Git. Ordinary Direct's incoming tracking
is expected while installed; full uninstall must remove it. Record failures and
repairs before claiming completion.

## Qualification limits

This release does not newly qualify physical sleep/wake, simultaneous two-account
native UI interaction, or incoming IPv6 TCP/UDP and route migration. The local
address test establishes inventory reconciliation, not all inbound transports.
A session created before tracking is installed may need to reconnect. The
Homebrew lifecycle checks do not repeat the complete protected traffic matrix.
