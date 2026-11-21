import AppKit
import Combine
import SwiftUI

/// Retained independently of all windows. Native actions control shared routing.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor: PublicIPMonitor
    private var observation: AnyCancellable?
    private var hostingView: StatusLabelHostingView?
    private let statusMenu: MimoStatusMenu

    var isVisible: Bool { item.isVisible }
    private(set) var displayedPresentation: MimoStatusPresentation?

    init(monitor: PublicIPMonitor) {
        self.monitor = monitor
        statusMenu = MimoStatusMenu(monitor: monitor)
        super.init()
        item.autosaveName = "MimoStatusItem"
        item.isVisible = true
        item.menu = statusMenu.menu
        item.button?.setAccessibilityIdentifier("mimo-menu-bar")
        update()
        // Publish after all properties are assigned. DispatchQueue also runs while an NSMenu
        // tracks events; RunLoop.main's default mode can leave the icon stale until it closes.
        observation = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
        RuntimeLog.shared.info("status_item_created")
    }

    private func update() {
        guard let button = item.button else { return }
        statusMenu.update()
        let label = MimoMenuBarLabel(presentation: statusMenu.presentation)
        let statusChanged = displayedPresentation?.visualKey != label.presentation.visualKey
        displayedPresentation = label.presentation
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
        if statusChanged {
            RuntimeLog.shared.info("mimo_access_presentation_changed", fields: [
                "kind": label.presentation.kind.rawValue,
                "blocked": String(label.presentation.trafficIsBlocked),
                "validating": String(label.presentation.isValidating),
                "direct": String(label.presentation.isDirect),
                "selectedMode": monitor.routingState.configuration.mode.rawValue,
                "effectiveMode": monitor.routingState.effectiveMode?.rawValue ?? "none",
                "phase": monitor.routingState.phase.rawValue,
                "reason": monitor.routingState.reason
            ])
        }
    }
}

/// The native status button owns mouse and keyboard interaction, including its pressed highlight.
private final class StatusLabelHostingView: NSHostingView<MimoMenuBarLabel> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
