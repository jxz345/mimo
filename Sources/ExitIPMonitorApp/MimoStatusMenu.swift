import AppKit

/// Keep the same native menu items while status changes, preserving keyboard focus.
@MainActor
final class MimoStatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Mimo")
    private let monitor: PublicIPMonitor
    private let titleItem = NSMenuItem(title: "Mimo", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let addressItem = NSMenuItem(title: "IP unavailable", action: nil, keyEquivalent: "")
    private(set) var modeItems: [ProxyMode: NSMenuItem] = [:]
    private(set) var refreshItem: NSMenuItem!

    init(monitor: PublicIPMonitor) {
        self.monitor = monitor
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for row in [titleItem, detailItem, addressItem] { row.isEnabled = false; menu.addItem(row) }
        menu.addItem(.separator())
        for (mode, key) in [(ProxyMode.direct, "1"), (.rule, "2"), (.global, "3")] {
            let row = add(mode.title, action: #selector(selectMode(_:)), key: key, modifiers: [.command, .option])
            row.representedObject = mode.rawValue
            modeItems[mode] = row
        }
        menu.addItem(.separator())
        refreshItem = add("Refresh now", action: #selector(refresh(_:)), key: "r")
        _ = add("Open Dashboard", action: #selector(openDashboard(_:)), key: "1")
        _ = add("Settings…", action: #selector(openSettings(_:)), key: ",")
        menu.addItem(.separator())
        _ = add("Quit GUI", action: #selector(quit(_:)), key: "q", modifiers: [.command, .option])
        update()
    }

    var presentation: MimoMenuPresentation {
        monitor.statusPresentation
    }

    func update() {
        let presentation = presentation
        titleItem.title = presentation.title
        detailItem.title = presentation.detail.count > 100 ? String(presentation.detail.prefix(97)) + "…" : presentation.detail
        detailItem.toolTip = presentation.detail
        addressItem.title = presentation.address.map { "IP address · \($0)" } ?? "IP unavailable"
        let ready = monitor.canChangeSharedSettings
        for (mode, row) in modeItems {
            row.state = monitor.routingState.configuration.mode == mode ? .on : .off
            row.isEnabled = ready
        }
        refreshItem.isEnabled = monitor.canRefresh
    }

    func menuWillOpen(_ menu: NSMenu) {
        update()
        RuntimeLog.shared.info("status_menu_opened")
    }

    private func add(_ title: String, action: Selector, key: String,
                     modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let row = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        row.keyEquivalentModifierMask = modifiers
        row.target = self
        row.isEnabled = true
        return row
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ProxyMode(rawValue: raw) else { return }
        monitor.setMode(mode)
    }
    @objc private func refresh(_ sender: Any?) { Task { await monitor.refresh() } }
    @objc private func openDashboard(_ sender: Any?) { ExitIPAppDelegate.showDashboard() }
    @objc private func openSettings(_ sender: Any?) { ExitIPAppDelegate.showSettings() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
