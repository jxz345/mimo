import AppKit
import SwiftUI

/// Warning for a fresh Rule/Global observation that the supervisor has actually rejected.
/// Direct never opens this panel; selecting Direct or losing confirmed blocked state dismisses it.
@MainActor
final class AllowlistWarningWindowController: NSObject, NSWindowDelegate {
    static let shared = AllowlistWarningWindowController()

    private var window: NSPanel?
    private(set) var isPresented = false

    func show(address: String) {
        let panel = window ?? makePanel()
        window = panel
        isPresented = true
        panel.contentViewController = NSHostingController(
            rootView: AllowlistWarningView(address: address) { [weak self] in
                self?.dismiss()
            }
        )
        panel.center()
        panel.orderFront(nil)
    }

    func dismiss() {
        isPresented = false
        window?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("mimo-allowlist-warning")
        panel.title = "Exit IP Not Allowed"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}

private struct AllowlistWarningView: View {
    let address: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Exit IP is not on the allowlist", systemImage: "exclamationmark.triangle.fill")
                .font(.title.weight(.bold))
                .foregroundStyle(.orange)
            Text(address)
                .font(.title2.monospaced())
                .textSelection(.enabled)
            Text("Outbound access is blocked because this exit IP is not approved. Review the allowed list or select another proxy. Direct bypasses exit-IP approval.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Review allowed IPs") {
                    dismiss()
                    MimoSettingsNavigation.open(.allowedIPs)
                }
                Spacer()
                Button("Close", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 320)
    }
}
