import AppKit
import Combine
import SwiftUI

/// Retained independently of all windows. Native actions control shared routing.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: PublicIPMonitor
    private var observation: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var hostingView: StatusLabelHostingView?
    private let statusMenu: MimoStatusMenu
    private var loginObservation: AnyCancellable?

    var isVisible: Bool { item.isVisible }

    init(monitor: PublicIPMonitor) {
        self.monitor = monitor
        statusMenu = MimoStatusMenu(monitor: monitor)
        super.init()
        item.autosaveName = "ExitIPMonitorStatusItem"
        item.isVisible = true
        item.menu = statusMenu.menu
        item.button?.setAccessibilityIdentifier("exit-ip-menu-bar")
        update()
        // objectWillChange is sent before the properties change; render on the next main turn.
        observation = monitor.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        loginObservation = NotificationCenter.default.publisher(for: LoginItemSync.changed).receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.statusMenu.update() }
        }
        // The Dock follows the system appearance (the menu bar may differ with the wallpaper), so
        // the monochrome text and stop symbol of the Dock copy are re-colored when it changes.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }
        RuntimeLog.shared.info("status_item_created")
    }

    private func update() {
        guard let button = item.button else { return }
        statusMenu.update()
        let label = MimoMenuBarLabel(presentation: statusMenu.presentation)
        let host = hostingView ?? StatusLabelHostingView(rootView: label)
        host.rootView = label
        if hostingView == nil {
            host.sizingOptions = .intrinsicContentSize
            host.setAccessibilityElement(false)
            button.addSubview(host)
            hostingView = host
        }
        let size = host.fittingSize
        item.length = ceil(size.width) + 12
        host.frame = NSRect(x: 6, y: (button.bounds.height - size.height) / 2,
                            width: ceil(size.width), height: size.height)
        button.setAccessibilityLabel(label.presentation.accessibilityText)
        button.toolTip = label.presentation.accessibilityText + " — Open Mimo menu"
        // The Dock and ⌘-Tab icon is the same label, redrawn at the same moment, colored for the
        // Dock's (system) appearance so monochrome text and symbols stay legible there.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        DockIconController.shared.update(label: label, darkAppearance: dark)
    }
}

/// The native status button owns mouse and keyboard interaction, including its pressed highlight.
private final class StatusLabelHostingView: NSHostingView<MimoMenuBarLabel> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
