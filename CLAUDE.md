# Working on Mimo

Follow [AGENTS.md](AGENTS.md) for repository conventions and [README.md](README.md)
for the current product behavior. [XCODE_ASSEMBLY.md](XCODE_ASSEMBLY.md) documents
build generation. Older release evidence describes the binary tested at that time;
it is not a specification for today's identifiers or behavior.

## Sources and builds

`Sources/MimoShared` contains portable models, persistence and typed XPC contracts.
`Sources/MimoCore` owns monitoring; `Sources/MimoService` owns the machine-wide core,
supervisor and protected networking. `Sources/MimoApp` contains the SwiftUI/AppKit
GUI, and `Sources/MimoWidgets` contains WidgetKit and Control Center targets.
`Sources/MimoDaemon` contains installation and PF scripts. The old optional shell
provider is a reference fixture and is not shipped as the active provider.

Edit authoritative sources and generator inputs, not `XcodeProject/`, `.build/`,
or DerivedData. Generate with `bash Scripts/generate-xcode-project.sh --force`.
Build the `Mimo` scheme in `XcodeProject/Mimo.xcodeproj`. Package with
`MIMO_RELEASE_REPO=jxz345/mimo bash Scripts/package-release.sh`.

For this project, all runtime, network and acceptance tests execute only in
**mimo-vm**. Delta may edit, compile, package and orchestrate SSH. Do not change
Delta's network configuration or install Mimo there for testing. Shared tests are
in `Tests/MimoSharedTests`; relevant service/app/installer tests have Mimo-prefixed
directories. Full Xcode and the macOS 26 SDK are needed for GUI builds.

## Behavior that must be preserved

- One root core shares configuration, credentials, quota and routing across users.
  Quitting a GUI does not stop the core. GUI login launch is a per-user choice.
- Direct is unproxied and never blocks for an allowlist or event check. Rule and
  Global require an approved IPv4 and a nonempty allowlist. IPv6 is disabled while
  installed and restored on uninstall.
- Protected events follow the documented concurrent gate workflow. Preserve the
  PF permission barrier, generation/revision fences, private probe restrictions,
  optimistic receipt checks and bounded background audit.
- Installation establishes the trusted GUI identity. Ordinary controls must not
  ask for an administrator password after installation and proxy setup.
- Secrets stay in the System Keychain and private profile-delivery path. Never log
  or publish actual credentials, proxy endpoints, personal IPs or signing data.
- Provider quotas and cooldowns are enforced. Provider rejection must not trigger
  rate-limit evasion through another vendor. Country-change confirmation uses a
  different provider. Widget reloads follow rendered changes, not clock ticks.
- Uninstall removes owned services, PF/boot policy, login registrations and runtime
  artifacts, restores networking, and retains settings/credentials/logs. Homebrew
  removes the pinned engine only if it is an unused dependency.
- Current names are Mimo, `com.mimo.*`, and `mimo-manage`. Former identifiers belong
  only in explicit migration/cleanup compatibility and historical evidence.

See [MIMO_PLAN.md](MIMO_PLAN.md),
[the failure analysis](Design/MIMO_FIREWALL_AND_FAILURE_SCENARIOS.md), and
[the naming migration](Design/MIMO_NAMING_MIGRATION.md) for boundaries and ordering.
Every feature change must update README's complete **What is implemented** table,
usage steps, affected manual checks and log documentation in the same change.
