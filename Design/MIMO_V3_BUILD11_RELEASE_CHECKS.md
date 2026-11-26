# Mimo 3.0 build 11 release checks

Release identity: **3.0 / 11**, immutable tag `v3.0-build.11`. Homebrew keeps the
marketing version `3.0` and selects this build through its URL and checksum.
Build 10 is retained as a separate release; none of its assets are replaced.

Published on **26 November 2026 at 08:15 UTC**:
[Mimo 3.0 (build 11)](https://github.com/jxz345/mimo/releases/tag/v3.0-build.11).
The [distribution evidence](../Tests/ReleaseEvidence/v3-build11/distribution.json)
records source commit `7fe4b7c2caf21b33724db1001e203cc1a4f0ce0c`, the Homebrew
cask/documentation commits and all uploaded SHA-256 digests. All five GitHub
asset digests matched the tested local files before publication.

After publication, mimo-vm fetched the public ZIP through the updated Homebrew
cask. Its SHA-256, sealed signature, 3.0/build-11 identity and GUI/core hashes
matched the installed package. Homebrew's marketing version remains `3.0`;
existing 3.0 installations use `brew update` followed by
`brew reinstall --cask jxz345/tap/mimo`. This distribution check did not repeat
the earlier Homebrew uninstall/reinstall lifecycle campaign.

## Included behavior

- One fresh IPv4 approval receipt for both IPv4 and Dual-stack traffic, with no
  IPv6 allowlist. Preserve rejected IPv4 and labelled last-known observations.
- Explicit retry after local failures, continued provider health monitoring,
  settled rejection without audit-triggered loops, and fresh checks for effective
  user routing edits. Preserve server rate limits and Retry-After.
- Reduce redundant navigation/menu work and family-change closures; keep normal
  page navigation free of network verification.
- Align dashboard column bottoms and compact service rows while reserving space
  for dynamic status and recovery controls.
- Rotate and expire runtime/service logs with bounded disk queues and per-directory
  budgets. Report cleanup and dropped records without network checks.

## Validation scope

The following completed candidate campaigns retain their exact tested hashes;
they are not relabelled as fresh tests of the final distribution ZIP:

- [IPv4 approval and lifecycle campaign](MIMO_IPV4_APPROVAL_RESULTS.md): four
  mode/family cells, 16 active fault/recovery cases, four server-restriction checks,
  and 22 Direct/Stop/Start assertions.
- [Blocked retry reproduction](MIMO_BLOCKED_VERIFICATION_RECOVERY.md): failing
  build-10 reproduction and passing corrected Rule/Global × IPv4/Dual-stack checks.
- [Navigation recovery](MIMO_NAVIGATION_RESPONSIVENESS.md) and
  [event audit](MIMO_EVENT_TRIGGER_AUDIT.md): native navigation, settled failures,
  approved family edits, and event correlation across GUI/core/supervisor.
- [Log storage](MIMO_LOG_RETENTION.md): reproduced unbounded growth, 11 filesystem
  tests, five integration cases, multi-process contention and real timer expiry.

Final source checks passed: 238 shared tests; the app suite, including all-six-tab
navigation, released monitoring and dashboard renders; the service suite,
including 60 exception/recovery simulations and four pending-lookup cancellation
cases; all five log integration cases; and the Release app/embedded-daemon build.

The final ad-hoc-signed package installed successfully in mimo-vm. Its
[14 smoke assertions](../Tests/ReleaseEvidence/v3-build11/installed-smoke.json)
passed, including matching installed/bundled core, service/controller/infrastructure
health, preserved IPv4 Direct, advancing supervisor health, empty owned PF and
absent DNS override. A 40-second settled observation produced no unexpected
lookup, gate change, error or log-storage failure. Runtime segments were within
the new size cap. This smoke did not repeat the protected-mode matrix or native
button clicks; those candidate campaigns remain separately identified above.

Final ZIP SHA-256:
`15bda33947f44a8abcb9bba2bfa810a978b8d04e91ac7104f4d51c67f51a9414`.
The [release manifest](../Tests/ReleaseEvidence/v3-build11/release-build.json)
and [checksums](../Tests/ReleaseEvidence/v3-build11/SHA256SUMS) identify the exact
ZIP, package, installer script and manifest. Packaging verified arm64 binaries,
sealed signatures, version/build and the absence of AppleDouble entries. The
generated Homebrew cask passed Ruby syntax validation; its only changes from
build 10 are the ZIP checksum, download tag and release-note tag.

## Remaining limits

The event audit retains a protected-startup preparation failure recovered by
explicit Refresh and two source-audit trigger gaps. The intermittent multi-second
display delay was not reproduced, and passing selection timings do not qualify
Screen Sharing latency. Physical sleep, login-screen freezes and simultaneous
two-account GUI interaction are not newly qualified by this release.

Runtime log writes have a hard segment limit; external launchd output is bounded
by periodic maintenance and may overshoot between sweeps. Copy/truncate can lose
concurrent stdout/stderr bytes. See the log-policy record for the full limits.
