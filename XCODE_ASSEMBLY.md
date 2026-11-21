# Build Mimo with Xcode

The authoritative sources are in `Sources/`, `Configuration/`, and `Scripts/`.
The generator copies them into the ignored `XcodeProject/` directory. Edit the
originals, then regenerate; never edit generated sources or DerivedData.

## Requirements

Use an Apple silicon Mac with full Xcode and the macOS 26 SDK. The app supports
macOS 14 and later; its Control Center integration requires macOS 26. Intel builds
are not supported. XcodeGen must be available to the generator.

## Generate and build

From the repository root:

```sh
bash Scripts/check-build-environment.sh --test
bash Scripts/generate-xcode-project.sh --force --open
xcodebuild -project XcodeProject/Mimo.xcodeproj -scheme Mimo -destination 'platform=macOS' build
```

The generator normally runs shared tests and builds an ad-hoc-signed app. Use
`--skip-tests` when tests run separately, or `--generate-only` to generate without
building. `xcrun swift build --build-tests` compiles tests without executing them.
For this project's acceptance work, execute tests and all runtime/network checks
only in **mimo-vm**; Delta may compile and package.

The generated targets are Mimo, MimoWidgets, MimoDaemon and the narrowly scoped
MimoLegacyLoginCleanup helper. The last helper carries the former bundle identity
solely to remove an old login registration during migration. See
[the naming migration](Design/MIMO_NAMING_MIGRATION.md).

App output:

```text
XcodeProject/DerivedData/Build/Products/Debug/Mimo.app
```

The GUI executable is `Contents/MacOS/mimo-gui`; the bundled service executable is
`Contents/MacOS/mimo-core`. The system installer stages the core outside the app.
Deleting the app bundle alone does not remove that service or its firewall policy.

## Signing and distribution

Local release builds use ad-hoc signatures. The default bundle ID is `com.mimo`
and App Group is `group.com.mimo`. These are not a Developer ID registration or a
Network Extension entitlement. For a separately signed build, use the generator's
`--signed-build --team ID --app-group REGISTERED_ID` options; keep team credentials
local. Configure app and widget entitlements consistently.

```sh
MIMO_RELEASE_REPO=jxz345/mimo bash Scripts/package-release.sh
```

This produces `dist/Mimo-1.0.zip`, `dist/Mimo-1.0.pkg`, `dist/install.sh`,
`dist/SHA256SUMS`, and the rendered cask. It does not publish. The ordinary user
installation and clean-uninstall commands are at the top of [README.md](README.md).

If compilation fails, inspect the first actionable compiler error in the build
log. SwiftPM tests cover MimoShared, not the full SwiftUI, WidgetKit or root service
runtime. Use the real VM acceptance checks for installation, Keychain, login,
launchd and PF behavior; fixture tests do not establish those guarantees.
