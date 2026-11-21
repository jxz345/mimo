import AppKit
import SwiftUI

@MainActor
enum EventLogTests {
    static func installedExport(output: URL) async throws {
        let model = EventLogModel()
        model.start()
        defer { model.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while model.sourceStatus != "Core: connected · Supervisor: connected", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        CredentialAppTests.require(model.sourceStatus == "Core: connected · Supervisor: connected",
                                   "Ordinary account must receive full records from both installed services")
        let report = model.diagnosticsText
        for source in ["=== GUI ===", "=== Core (connected) ===", "=== Supervisor (connected) ==="] {
            CredentialAppTests.require(report.contains(source), "Export must identify every process")
        }
        CredentialAppTests.require(report.contains("mimo_") && report.contains("\"fields\""),
                                   "Installed export must preserve JSON events and fields")
        model.isPaused = true
        try await Task.sleep(for: .seconds(3))
        CredentialAppTests.require(model.diagnosticsText == report, "Pause must freeze the copied diagnostics")
        try report.write(to: output.appendingPathComponent("installed-diagnostics.txt"), atomically: true, encoding: .utf8)
        print("PASS: ordinary-account GUI model copies installed core/supervisor JSON records and Pause freezes the report")
    }

    static func run(output: URL) throws {
        let scroll = EventLogText.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 760, height: 320)
        let view = scroll.documentView as! EventLogTextView
        let original = "First event 🌐\nSecond event\nThird event\n"
        view.display(original)
        let selection = (original as NSString).range(of: "event 🌐\nSecond event")
        view.setSelectedRange(selection)
        view.display(original + "Fourth event\n")
        CredentialAppTests.require(view.string == original && view.selectedRange() == selection,
                                   "Live updates must preserve a multiline selection")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        CredentialAppTests.require(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes),
                                   "Native text copy must succeed")
        CredentialAppTests.require(pasteboard.string(forType: .string) == "event 🌐\nSecond event",
                                   "Copy must preserve newlines and Unicode")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        CredentialAppTests.require(view.string == original + "Fourth event\n", "Clearing the selection applies pending updates")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        CredentialAppTests.require(view.performKeyEquivalent(with: event), "Command-A must be handled")
        CredentialAppTests.require(view.selectedRange().length == (view.string as NSString).length,
                                   "Command-A must select every line")
        view.display("Trimmed history\n")
        CredentialAppTests.require(view.string.hasPrefix(original), "History trimming cannot destroy the selection")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        CredentialAppTests.require(view.string == "Trimmed history\n", "New history appears after selection ends")

        let model = EventLogModel()
        model.isPaused = true
        RuntimeLog.shared.info("mimo_network_changed", fields: ["source": "route", "detail": "route added on en0", "generation": "7"])
        CredentialAppTests.require(model.lines.isEmpty, "Paused view must not update")
        model.isPaused = false
        CredentialAppTests.require(model.copyText.contains("route added on en0"), "Copy All must include readable triggers")
        CredentialAppTests.require(model.diagnosticsText.contains("mimo_network_changed") &&
                                   model.diagnosticsText.contains("=== Supervisor"),
                                   "Diagnostics must preserve raw names and identify missing sources")
        try CredentialAppTests.render(EventLogView(model: model), size: NSSize(width: 820, height: 520), dark: true,
                                      to: output.appendingPathComponent("mimo-event-log.png"))
        print("PASS: native multiline copy, Unicode, Command-A, stable selection during live updates, paused history and diagnostic export")
    }
}
