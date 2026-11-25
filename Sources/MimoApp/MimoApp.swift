import AppKit
import SwiftUI

@MainActor
final class MimoAppDelegate: NSObject, NSApplicationDelegate {
    static let monitor = PublicIPMonitor()
    private var statusItem: StatusItemController?

    var statusItemIsVisible: Bool { statusItem?.isVisible == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchDiagnostics.record("application_did_finish_launching")
        MimoApplicationAppearance.apply(UserDefaults.standard.string(forKey: "mimo.appearance") ?? "system")
        installApplicationMenus()
        statusItem = StatusItemController(monitor: Self.monitor)
        Self.monitor.start()
        LaunchDiagnostics.record("startup_services_ready")
        // The app is menu-bar only, and a crowded menu bar can hide its item, so the very first
        // launch opens the dashboard once to show the app is running.
        let defaults = MimoAppGroup.defaults
        if !defaults.bool(forKey: MimoPreferenceKey.firstLaunchDashboardShown) {
            defaults.set(true, forKey: MimoPreferenceKey.firstLaunchDashboardShown)
            Self.showDashboard()
        }
        SingleInstanceController.didFinishLaunching()
        // Schedule after the launch callback so readiness proves the main queue is servicing work.
        DispatchQueue.main.async {
            LaunchDiagnostics.markReady()
            // The controller dispatches slow Background Task Management calls off the UI thread.
            DispatchQueue.main.async { LoginItemSync.syncAtLaunch() }
        }
    }

    /// Opening the app again while it runs (Finder, Spotlight, Launchpad, `open`) shows the
    /// dashboard instead of doing nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showDashboard()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.monitor.applicationDidBecomeActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        LaunchDiagnostics.stop()
        Self.monitor.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static func showDashboard() {
        MimoSettingsNavigation.shared.tab = .dashboard
        DashboardWindowController.shared.show(monitor: monitor)
    }

    static func showSettings() {
        MimoSettingsNavigation.shared.tab = .settings
        DashboardWindowController.shared.show(monitor: monitor)
    }

    static func showEventLog() {
        EventLogWindowController.shared.show()
    }

    /// Minimizing is not closing. Only the dashboard owns the app's Dock presence.
    static func updateActivationPolicy() {
        NSApp.setActivationPolicy(DashboardWindowController.shared.isOpen ? .regular : .accessory)
        // macOS uses the bundle's app icon for both the Dock and ⌘-Tab, matching Finder.
    }

    @objc private func openDashboard(_ sender: Any?) { Self.showDashboard() }
    @objc private func openSettings(_ sender: Any?) { Self.showSettings() }
    @objc private func openEventLog(_ sender: Any?) { Self.showEventLog() }

    /// ⌘Q from a window means "put it away": the app lives in the menu bar, so its windows close
    /// and monitoring continues. Quitting is the Quit menu item or the dashboard's Quit button;
    /// Quit Apple Events (Homebrew, logout, osascript) are unaffected.
    @objc private func closeWindowsFromShortcut(_ sender: Any?) {
        let windows = [DashboardWindowController.shared.window, EventLogWindowController.shared.window]
            .compactMap { $0 }
            .filter { $0.isVisible || $0.isMiniaturized }
        windows.forEach { $0.close() }
        RuntimeLog.shared.info("windows_closed_by_shortcut", fields: ["count": String(windows.count)])
    }

    private func installApplicationMenus() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            return menu
        }
        let app = submenu("Mimo")
        app.addItem(withTitle: "About Mimo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Mimo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let quit = app.addItem(withTitle: "Quit Mimo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command, .option]
        // ⌘Q closes the windows instead of quitting (the 1.0 dashboard quit the app on ⌘Q).
        let closeWindows = app.addItem(withTitle: "Close Mimo Windows",
                                       action: #selector(closeWindowsFromShortcut(_:)), keyEquivalent: "q")
        closeWindows.target = self
        closeWindows.isHidden = true
        closeWindows.allowsKeyEquivalentWhenHidden = true

        submenu("File").addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                     ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let windows = submenu("Window")
        windows.addItem(withTitle: "Dashboard", action: #selector(openDashboard(_:)), keyEquivalent: "1").target = self
        windows.addItem(withTitle: "Event Log", action: #selector(openEventLog(_:)), keyEquivalent: "").target = self
        windows.addItem(.separator())
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }
}

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()

    private(set) var window: NSWindow?
    private(set) var isOpen = false
    private var screenObserver: NSObjectProtocol?

    override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if MimoAppDelegate.monitor.isSessionActive, let window = self?.window { keepWindowOnScreen(window) }
            }
        }
    }

    func show(monitor: PublicIPMonitor) {
        let window = window ?? makeWindow(monitor: monitor)
        self.window = window

        isOpen = true
        MimoAppDelegate.updateActivationPolicy()
        if window.isMiniaturized { window.deminiaturize(nil) }
        keepWindowOnScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        // Dock/activation changes finish asynchronously. Request focus again after that turn,
        // when the normal window is already ordered on the active Space.
        DispatchQueue.main.async { [weak self, weak window] in
            guard self?.isOpen == true, MimoAppDelegate.monitor.isSessionActive, let window else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            LaunchDiagnostics.record("dashboard_front_requested")
        }
        LaunchDiagnostics.record("dashboard_presented")
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        MimoAppDelegate.updateActivationPolicy()
        LaunchDiagnostics.record("dashboard_closed")
    }

    private func makeWindow(monitor: PublicIPMonitor) -> NSWindow {
        // Content scrolls when needed, while the footer remains available.
        let hostingController = fixedSizeHostingController(
            DashboardView(monitor: monitor)
                .frame(minWidth: 520, minHeight: 380)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("mimo-dashboard")
        window.title = "Mimo"
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.contentMinSize = NSSize(width: 520, height: 380)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.managed, .primary, .participatesInCycle, .fullScreenPrimary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.delegate = self
        let restored = window.setFrameUsingName("MimoDashboard")
        window.setFrameAutosaveName("MimoDashboard")
        if restored {
            keepWindowOnScreen(window)
        } else { placeOnActiveScreen(window) }
        return window
    }
}

/// Keeps the full Clash Verge profile (~/Library/Application Support/Mimo/clash-verge-profile.yaml,
/// mode 0600) current with the explicitly loaded/saved proxy and the app's template. Only the app
/// writes it; no installer deploys it, and nothing is written into Clash Verge. Never logs the settings.
@MainActor
@discardableResult
func maintainClashVergeProfile(_ settings: ClashProxySettings) throws -> ClashVergeProfile.WriteOutcome {
    // An earlier build kept only the provider part here.
    try? FileManager.default.removeItem(at: ClashVergeProfile.legacyPartialFileURL)
    let outcome = try ClashVergeProfile.write(ClashVergeProfile.render(settings), to: ClashVergeProfile.fileURL)
    if outcome == .written {
        RuntimeLog.shared.info("clash_profile_written", fields: ["path": ClashVergeProfile.fileURL.path])
    }
    return outcome
}

/// Copies the profile file to "Mimo <date> (n).yaml", a name no Clash Verge profile has, and
/// shows the copy selected in Finder, ready to drag onto Clash Verge Rev's Profiles page (which adds it as
/// a Local profile with that name). Only Clash Verge's profile names are read; a missing or unreadable
/// `profiles.yaml` counts as none. Nothing is written into Clash Verge.
@MainActor
@discardableResult
func revealClashVergeProfileCopy() throws -> URL {
    let index = try? String(contentsOf: ClashVergeProfileNaming.profilesIndexURL, encoding: .utf8)
    let names = index.map(ClashVergeProfileNaming.names(inProfilesIndex:)) ?? []
    let copy = try ClashVergeProfile.writeCopy(of: ClashVergeProfile.fileURL, existingNames: names, date: Date())
    RuntimeLog.shared.info("clash_profile_copy_written", fields: ["name": copy.lastPathComponent])
    NSWorkspace.shared.activateFileViewerSelecting([copy])
    return copy
}

/// A hosting controller that only enforces the view's minimum size. With the default sizing
/// options, the window hugs the SwiftUI content and collapses to its minimum: the dashboard opened
/// at 520 × 380 (one stacked column to scroll) and the scrolling Settings form as a bare title bar.
@MainActor
func fixedSizeHostingController<Content: View>(_ rootView: Content) -> NSHostingController<Content> {
    let controller = NSHostingController(rootView: rootView)
    controller.sizingOptions = .minSize
    return controller
}

/// Opens a window at the true center of the screen the pointer is on (the one whose menu bar was
/// just clicked); `NSWindow.center()` places it above center. A window larger than that screen's
/// visible area is shrunk to fit, so a small display never gets an off-screen title bar.
@MainActor
func placeOnActiveScreen(_ window: NSWindow) {
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
        window.center()
        return
    }
    // The hosting controller sizes the window during layout; place it with the final size.
    window.layoutIfNeeded()
    let visible = screen.visibleFrame
    let size = NSSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
    window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height), display: false)
}

/// Keep a remembered frame when possible; recover it when a display is removed or resized.
@MainActor
func keepWindowOnScreen(_ window: NSWindow) {
    guard !window.styleMask.contains(.fullScreen) else { return }
    let frame = window.frame
    let screens = NSScreen.screens.map(\.visibleFrame)
    guard let visible = screens.max(by: {
        let a = $0.intersection(frame), b = $1.intersection(frame)
        return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
    }), visible.intersects(frame) else {
        placeOnActiveScreen(window)
        return
    }
    let size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
    let origin = NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                         y: min(max(frame.minY, visible.minY), visible.maxY - size.height))
    let fitted = NSRect(origin: origin, size: size)
    if fitted != frame { window.setFrame(fitted, display: true) }
}
