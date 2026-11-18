import AppKit
import ServiceManagement

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
    private(set) var loginItem: NSMenuItem!
    private let loginStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var loginError: String?

    init(monitor: PublicIPMonitor) {
        self.monitor = monitor
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for row in [titleItem, detailItem, addressItem] { row.isEnabled = false; menu.addItem(row) }
        menu.addItem(.separator())
        for mode in ProxyMode.allCases {
            let row = add(mode.title, action: #selector(selectMode(_:)))
            row.representedObject = mode.rawValue
            modeItems[mode] = row
        }
        menu.addItem(.separator())
        refreshItem = add("Refresh now", action: #selector(refresh(_:)), key: "r")
        _ = add("Open Dashboard", action: #selector(openDashboard(_:)))
        _ = add("Settings…", action: #selector(openSettings(_:)), key: ",")
        menu.addItem(.separator())
        loginItem = add("Open Mimo at login", action: #selector(toggleLogin(_:)))
        loginStatusItem.isEnabled = false
        menu.addItem(loginStatusItem)
        _ = add("Login Items Settings…", action: #selector(openLoginSettings(_:)))
        menu.addItem(.separator())
        _ = add("Quit GUI", action: #selector(quit(_:)))
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
        loginItem.state = LoginItemSync.status == .enabled ? .on : .off
        let message = loginError ?? (LoginItemSync.status == .requiresApproval ? "Approve Mimo in Login Items Settings." : nil)
        loginStatusItem.title = message ?? ""
        loginStatusItem.isHidden = message == nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        update()
        RuntimeLog.shared.info("status_menu_opened")
    }

    private func add(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let row = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
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
    @objc private func openLoginSettings(_ sender: Any?) { SMAppService.openSystemSettingsLoginItems() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
    @objc private func toggleLogin(_ sender: Any?) {
        do { try LoginItemSync.setEnabled(LoginItemSync.status != .enabled); loginError = nil }
        catch { loginError = error.localizedDescription }
        update()
    }
}
