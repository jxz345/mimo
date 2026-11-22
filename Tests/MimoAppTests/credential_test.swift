import AppKit
import Darwin
import SwiftUI

/// Native integration checks compile the real app with a separate entry point and isolated defaults.
/// No real Keychain operations, network calls, visible windows, or provider installation occur.
@main
enum CredentialAppTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let defaults = MimoAppGroup.defaults
        defer { defaults.removePersistentDomain(forName: MimoAppGroup.identifier) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--released-only") {
            try await ReleasedMonitorTests.run(output: output)
            return
        }
        if CommandLine.arguments.contains("--installed-event-log") {
            try await EventLogTests.installedExport(output: output)
            return
        }
        if CommandLine.arguments.contains("--event-log-only") {
            try EventLogTests.run(output: output)
            return
        }
        if CommandLine.arguments.contains("--provider-pause-only") {
            try MimoCountryTests.renderProviderPause(output: output)
            return
        }
        if CommandLine.arguments.contains("--country-regression") {
            try await MimoCountryTests.run()
            try await MimoMenuTests.run(output: output)
            return
        }
        if CommandLine.arguments.contains("--dashboard-only") {
            try MimoDashboardTests.run(output: output)
            return
        }
        if CommandLine.arguments.contains("--connection-only") {
            try await ClientConnectionTests.run(output: output)
            try await LoginItemControllerTests.run()
            return
        }
        if CommandLine.arguments.contains("--copy-feedback-only") {
            try await CopyFeedbackTests.run()
            return
        }

        try await ReleasedMonitorTests.run(output: output)

        require(SingleInstanceController.isCurrentUserProcess(getpid()), "The current user's process must match")
        require(!SingleInstanceController.isCurrentUserProcess(-1), "An unknown process must not block this user")
        if getuid() != 0 {
            require(!SingleInstanceController.isCurrentUserProcess(1), "Another user's process must not block this user")
        }
        let bundleID = "com.mimo"
        require(SingleInstanceController.reopenObject(bundleID: bundleID) ==
                SingleInstanceController.reopenObject(bundleID: bundleID, userID: getuid()),
                "Reopen requests must target the current user")
        require(SingleInstanceController.reopenObject(bundleID: bundleID, userID: 501) !=
                SingleInstanceController.reopenObject(bundleID: bundleID, userID: 502),
                "Different users must have separate reopen notifications")
        print("PASS: duplicate process checks and reopen notifications are scoped to the current user")

        defaults.removePersistentDomain(forName: MimoAppGroup.identifier)
        MonitoringPreferences(provider: .ipinfoLite, providerPool: [.ipinfoLite]).save()
        let oldSnapshot = snapshot(.ipWhois)
        SnapshotStore().save(oldSnapshot)
        let backend = MemoryCredentials()
        let credentials = CredentialSession(service: CredentialService(backend: backend), account: "token")
        let client = RecordingClient()
        let monitor = MonitoringEngine(observeSystem: false, client: client, ipinfoCredentials: credentials)
        monitor.start()
        try await settle()
        require(monitor.status == .waitingForIPinfoToken, "IPinfo-only startup must wait for an explicit load")
        require(monitor.snapshot == oldSnapshot, "Waiting must preserve the snapshot")
        require(await client.calls.isEmpty, "Startup must spend no IPinfo request")
        require(monitor.lookupBudget.callsToday(for: .ipinfoLite) == 0, "Startup must spend no quota")
        for _ in 0..<10 { _ = monitor.ipinfoCredentialStatus; _ = monitor.isIPinfoTokenUnavailable }
        monitor.applicationDidBecomeActive()
        await monitor.refresh(force: true, trigger: .periodic)
        await monitor.testProvider(.ipinfoLite)

        let profileBackend = MemoryCredentials()
        let profile = CredentialSession(service: CredentialService(backend: profileBackend), account: "profile")
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            try render(DashboardView(monitor: PublicIPMonitor(readDeactivation: { false })),
                       size: NSSize(width: 1040, height: 690), dark: dark,
                       to: output.appendingPathComponent("mimo-dashboard-\(mode).png"))
            for section in MimoSettingsSection.allCases {
                MimoSettingsNavigation.shared.section = section
                try render(SettingsView(monitor: PublicIPMonitor(readDeactivation: { false })),
                           size: NSSize(width: 880, height: 620), dark: dark,
                           to: output.appendingPathComponent("mimo-settings-\(section.symbol)-\(mode).png"))
            }
            MimoSettingsNavigation.shared.section = .general
            try render(ClashVergeProfileSection(providerInstalled: false, credentials: profile),
                       size: NSSize(width: 500, height: 640), dark: dark,
                       to: output.appendingPathComponent("profile-\(mode).png"))
            try render(SettingsView(monitor: PublicIPMonitor(readDeactivation: { false })), size: NSSize(width: 560, height: 1300), dark: dark,
                       to: output.appendingPathComponent("settings-\(mode).png"))
            try render(BackgroundServiceSection(monitor: PublicIPMonitor(readDeactivation: { false }), installer: DaemonInstallationModel()),
                       size: NSSize(width: 640, height: 270), dark: dark,
                       to: output.appendingPathComponent("service-\(mode).png"))
        }
        try await settle()
        require(backend.calls.isEmpty, "Rendering Settings and the dashboard must not read the IPinfo token")
        require(profileBackend.calls.count <= 1 && profileBackend.calls.allSatisfy { $0 == "read" },
                "Opening the profile view may read the proxy info once, and only read it")
        require(await client.calls.isEmpty, "Refresh and Test must not load credentials implicitly")
        print("PASS: startup, status, activation, refresh and Test make no Keychain calls; the profile view reads the proxy info at most once; IPinfo waits without quota use")

        try profileButtonRowChecks()
        try menuBarLabelChecks(output: output)
        try await MimoMenuTests.run(output: output)
        try MimoDraftTests.run()
        try MimoDashboardTests.run(output: output)
        try await ClientConnectionTests.run(output: output)
        try await LoginItemControllerTests.run()

        let pausedUntil = Date().addingTimeInterval(300)
        ProviderCooldownStore().save(retryNotBefore: pausedUntil, for: .ipinfoLite)
        require(await monitor.loadIPinfoToken(), "Explicit Load should succeed")
        try await settle()
        require(backend.calls == ["read"], "Load should read exactly once")
        require(ProviderCooldownStore().retryNotBefore(for: .ipinfoLite) == pausedUntil, "Load must preserve the provider pause")
        require(await client.calls.isEmpty, "Load must not bypass a provider pause")
        ProviderCooldownStore().clear(for: .ipinfoLite)
        await monitor.refresh(force: true)
        let loadedCalls = await client.calls
        require(!loadedCalls.isEmpty && loadedCalls.allSatisfy { $0.provider == .ipinfoLite && $0.ipinfoToken == "test-token" },
                "Automatic monitoring must use the loaded token")
        let manualAttempt = Date()
        RefreshAttemptStore().recordAttempt(for: .ipinfoLite, at: manualAttempt)
        await monitor.refresh(force: true, bypassMinimumInterval: true, trigger: .manual)
        require(await client.calls.count == loadedCalls.count + 1, "Refresh now must call a single provider immediately inside its gap")
        require(monitor.status == .ready && (monitor.snapshot?.checkedAt ?? .distantPast) >= manualAttempt,
                "Refresh now must publish the fresh result")
        print("PASS: Refresh now calls the provider and updates the snapshot immediately inside the five-second gap")
        let manualCalls = await client.calls.count
        await monitor.testProvider(.ipinfoLite)
        require(backend.calls == ["read"], "Subsequent lookup must use memory")
        require(await client.calls.count > manualCalls, "Provider Test must use the loaded token")

        let countBeforeRemoval = await client.calls.count
        require(await monitor.removeIPinfoToken(), "Explicit Remove should succeed")
        await monitor.refresh(force: true)
        require(await client.calls.count == countBeforeRemoval, "Remove and a tokenless refresh must spend no lookup")
        require(monitor.ipinfoToken == nil && monitor.status == .waitingForIPinfoToken, "Remove must clear the cached token")
        require(monitor.snapshot != nil, "Remove must preserve the last result")
        require(backend.calls == ["read", "delete"], "Only explicit actions may access storage")
        ProviderCooldownStore().save(retryNotBefore: pausedUntil, for: .ipinfoLite)
        require(await monitor.saveIPinfoToken("  replacement-token  "), "Explicit Save should succeed")
        require(ProviderCooldownStore().retryNotBefore(for: .ipinfoLite) == nil, "Save must clear the old credential's pause")
        try await settle()
        await monitor.testProvider(.ipinfoLite)
        require(await client.calls.last?.ipinfoToken == "replacement-token", "Save must update the token used for lookup")
        require(backend.calls == ["read", "delete", "save"], "Save must not reread Keychain")
        monitor.stop()
        print("PASS: explicit Load/Save enables cached IPinfo use; Remove clears the cache without a request")

        defaults.removePersistentDomain(forName: MimoAppGroup.identifier)
        MonitoringPreferences(provider: .ipinfoLite, providerPool: [.ipinfoLite, .ipWhois]).save()
        let mixedBackend = MemoryCredentials()
        let mixedClient = RecordingClient()
        let mixed = MonitoringEngine(observeSystem: false, client: mixedClient, ipinfoCredentials:
            CredentialSession(service: CredentialService(backend: mixedBackend), account: "token"))
        mixed.start()
        try await settle()
        let mixedCalls = await mixedClient.calls
        require(!mixedCalls.isEmpty && mixedCalls.allSatisfy { $0.provider == .ipWhois && $0.ipinfoToken == nil },
                "A mixed pool must use its anonymous provider while IPinfo is not loaded")
        require(mixedBackend.calls.isEmpty, "Mixed rotation must not query Keychain")
        mixed.stop()
        print("PASS: mixed pools continue anonymous monitoring without reading the saved IPinfo token")
    }

    /// Load proxy info, Save and Remove form one row (an HStack with no fallback) that fits the
    /// profile form's narrowest value column: about 472 pt column − GroupBox insets − 110 pt label
    /// − 12 pt spacing ≈ 326 pt. 320 pt leaves a margin.
    @MainActor
    static func profileButtonRowChecks() throws {
        let host = NSHostingView(rootView: ProxyInfoActionRow(load: {}, save: {}, remove: {}))
        let size = host.fittingSize
        require(size.width > 200 && size.width <= 320,
                "The proxy-info button row must fit the 320 pt value column in one row (needs \(size.width) pt)")
        require(size.height < 40, "The proxy-info buttons must share one row (height \(size.height) pt)")
        print("PASS: Load proxy info, Save and Remove share one \(Int(size.width)) pt row, within the narrowest value column")
    }

    /// Render the menu-bar labels and retain error/allowlist presentation coverage.
    @MainActor
    static func menuBarLabelChecks(output: URL) throws {
        let now = Date()
        let singapore = MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore",
                                       provider: .ipWhois, checkedAt: now)
        let japan = MimoSnapshot(ipAddress: "198.51.100.7", countryCode: "JP", countryName: "Japan",
                                   provider: .ipWhois, checkedAt: now)
        let changed = MimoSnapshot(ipAddress: "198.51.100.7", countryCode: "JP", countryName: "Japan",
                                     provider: .ipWhois, checkedAt: now,
                                     countryChange: CountryChange(previousCode: "SG", previousName: "Singapore",
                                                                  changedAt: now, highlightUntil: now.addingTimeInterval(600)))
        let stale = MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore",
                                   provider: .ipWhois, checkedAt: now.addingTimeInterval(-7_200))
        func label(_ snapshot: MimoSnapshot?, _ style: MenuBarDisplayStyle = .flag,
                   error: Bool = false, outside: Bool = false) -> MenuBarCountryLabel {
            MenuBarCountryLabel(snapshot: snapshot, displayStyle: style, refreshInterval: .fifteenMinutes,
                                indicators: MonitorIndicatorState(errorMessage: error ? "Lookup failed" : nil,
                                                                  suppressLocation: error),
                                outsideAllowlist: outside, date: now)
        }
        func redCoverage(_ image: CGImage, sampleStride: Int) -> (opaque: Int, red: Int) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            var opaque = 0
            var red = 0
            for x in stride(from: 0, to: image.width, by: sampleStride) {
                for y in stride(from: 0, to: image.height, by: sampleStride) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                    opaque += 1
                    if color.redComponent > 0.7 && color.greenComponent < 0.4 && color.blueComponent < 0.4 { red += 1 }
                }
            }
            return (opaque, red)
        }
        let errorLabel = label(singapore, error: true)
        let states: [(String, MenuBarCountryLabel, Bool)] = [
            ("flag-sg", label(singapore), true), ("flag-jp", label(japan), true),
            ("changed", label(changed), true), ("error", errorLabel, true),
            ("stale", label(stale), true), ("locating", label(nil), true),
            ("code", label(singapore, .code), true), ("name-dark", label(singapore, .name), false),
            ("outside-allowlist", label(singapore, outside: true), true),
            ("outside-allowlist-name-dark", label(singapore, .name, outside: true), false),
        ]
        for (name, menuBar, light) in states {
            let renderer = ImageRenderer(content: menuBar.fixedSize().environment(\.colorScheme, light ? .light : .dark))
            renderer.scale = 4
            if let small = renderer.cgImage,
               let data = NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:]) {
                try data.write(to: output.appendingPathComponent("menubar-\(name).png"))
            }
        }
        let errorRenderer = ImageRenderer(content: errorLabel.fixedSize().environment(\.colorScheme, .light))
        guard let errorMenuBarImage = errorRenderer.cgImage else { fatalError("No menu-bar error image") }
        let menuBarErrorCoverage = redCoverage(errorMenuBarImage, sampleStride: 1)
        require(menuBarErrorCoverage.opaque > 3 && menuBarErrorCoverage.red * 10 >= menuBarErrorCoverage.opaque * 9,
                "The menu-bar lookup error icon must be red (\(menuBarErrorCoverage.red) of \(menuBarErrorCoverage.opaque) red)")
        // Outside the allowlist, the menu bar keeps the flag and adds a red stop sign.
        func width(_ view: MenuBarCountryLabel) -> Int { ImageRenderer(content: view.fixedSize()).cgImage?.width ?? 0 }
        require(width(label(singapore, outside: true)) > width(label(singapore)),
                "Outside the allowlist the menu bar must show the flag and the stop sign")
        require(label(singapore, outside: true).accessibilityText(at: now) == "Exit IP country: Singapore, not on the allowlist",
                "The menu-bar label must say the exit IP is not on the allowlist")
        require(label(singapore, error: true, outside: true).visualKey == label(singapore, error: true).visualKey,
                "After a failed lookup the error stop sign replaces the flag, without the red one")
        print("PASS: menu-bar labels retain their error, country-change and allowlist presentation")
    }

    static func snapshot(_ provider: ProviderID) -> MimoSnapshot {
        MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: provider)
    }

    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    @MainActor
    static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to path: URL, padding: CGFloat = 16) throws {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view
            .padding(padding)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        window.appearance!.performAsCurrentDrawingAppearance {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        guard let flattened = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: bitmap.pixelsWide * 4, bitsPerPixel: 32), let context = NSGraphicsContext(bitmapImageRep: flattened) else { fatalError("No opaque bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: dark ? 0.12 : 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
        bitmap.draw(in: NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = flattened.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try data.write(to: path)
    }
}

private actor RecordingClient: PublicIPLookupClientProtocol {
    private(set) var calls: [LookupConfiguration] = []
    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        calls.append(configuration)
        return CredentialAppTests.snapshot(configuration.provider)
    }
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot {
        CredentialAppTests.snapshot(.ipWhois)
    }
}

private final class MemoryCredentials: CredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [String] = []
    private var value: String? = "test-token"
    var calls: [String] { lock.withLock { operations } }
    func read(account: String) throws -> String? { lock.withLock { operations.append("read"); return value } }
    func save(_ value: String, account: String) throws { lock.withLock { operations.append("save"); self.value = value } }
    func delete(account: String) throws { lock.withLock { operations.append("delete"); value = nil } }
}
