# Repository Guidelines

## Project Structure & Module Organization

`Sources/MimoShared/` contains portable models, provider clients, App Group storage, allowlist validation, and Keychain helpers. `Sources/MimoApp/` contains the SwiftUI menu-bar app, monitor, dashboard, and allowlist warning window; `Sources/MimoWidgets/` contains the WidgetKit and Control Center targets. Shared-core tests live in `Tests/MimoSharedTests/`. Entitlements and Info.plists are in `Configuration/`. `XcodeProject/` is generated output; edit the source kit and generator inputs, not copied files or `DerivedData/`. `Previews/` contains reference screenshots, while `Scripts/` contains environment, project-generation, runtime-log verification, and optional toolchain helpers.

## Build, Test, and Development Commands

Run commands from the repository root:

```bash
bash Scripts/check-build-environment.sh --test
xcrun swift test --verbose
bash Scripts/generate-xcode-project.sh --force --open
xcodebuild -project XcodeProject/Mimo.xcodeproj -scheme Mimo -destination 'platform=macOS' build
```

The first command validates the macOS/Xcode setup and runs shared tests. `xcrun swift test` tests only `MimoShared`; the generator creates the Xcode project, tests, and performs an unsigned build. Full app builds require full Xcode and the macOS 26 SDK.

## Coding Style & Naming Conventions

Use four-space indentation, standard Swift formatting, explicit access control for shared APIs, and early exits with `guard`. Types and protocols use `UpperCamelCase`; methods, properties, enum cases, and test methods use `lowerCamelCase`. Keep provider-specific behavior in shared-core abstractions and preserve `Sendable`/`Codable` annotations where applicable. No formatter or linter configuration is committed, so match neighboring code. Shell scripts should remain Bash-compatible and executable.

## Testing Guidelines

Add XCTest cases under `Tests/MimoSharedTests/` with names beginning `test` and behavior-focused descriptions. Cover persistence, refresh policy, provider error handling, and snapshot changes when modifying shared logic. There is no recorded coverage threshold; run the portable suite before app builds and report the first actionable compiler error from `swift-test.log`.

## Documentation

Every feature change (added, changed, or removed behavior) must update `README.md` in the same change. The **What is implemented** table must always list the complete set of features. Also update any affected usage steps, manual-check rows, and runtime-log event entries.

Keep `Design/MIMO_EVENT_DRIVEN_WORKFLOWS.md` synchronized when changing event triggers, ownership, firewall behavior, ordering, coalescing, cancellation, recovery or diagnostics. Document both protected-mode and Direct behavior and link the relevant source and validation. Distinguish current implementation from historical design and unqualified scenarios.

## Commit & Pull Request Guidelines

`XcodeProject/`, `.build/`, and `swift-test.log` are generated output and are git-ignored; commit only the authoritative sources. Use a concise imperative subject (for example, `fix: preserve country-change confirmation`) and keep unrelated changes separate. Pull requests should describe behavior and affected targets, list validation commands, link an issue when applicable, and include screenshots or a short recording for menu-bar, dashboard, widget, or accessibility changes.

## Security & Configuration

Never commit provider tokens or personal signing data. Store IPinfo credentials through the app's Keychain flow. Replace the placeholder App Group only with a registered identifier in both entitlements and shared storage configuration; keep signing/team changes local unless the task explicitly requires them.

## Release build identity

Every new build uploaded to GitHub must have a distinct, monotonically increasing build number, even when the marketing version stays `1.0`. Keep the current number in `Configuration/BuildNumber.txt`; advance it once for each new published build, not each local rebuild. Include the version/build in GitHub release notes and upload the generated `release-build.json` with the matching ZIP, package and checksums. Dashboard and diagnostic build values must match the packaged app. Do not reuse a published build number for different binaries.
