import AppKit
import SwiftUI

/// Readable events and full, already-redacted records from all three processes.
@MainActor
final class EventLogModel: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var diagnosticsText = ""
    @Published private(set) var sourceStatus = "Connecting to background logs…"
    @Published var isPaused = false {
        didSet { if !isPaused { updateLines() } }
    }
    private var observer: NSObjectProtocol?
    private var serviceEvents: [String] = []
    private var supervisorEvents: [String] = []
    private var serviceRecords: [String]?
    private var supervisorRecords: [String]?
    private var coreStatus = "not yet received"
    private var supervisorStatus = "not yet received"
    private var polling: Task<Void, Never>?

    var copyText: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    func start() {
        guard observer == nil else { return }
        isPaused = false
        updateLines()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                if MimoDeactivation.isConfirmed() {
                    self?.coreStatus = "removed; monitoring in GUI"
                    self?.supervisorStatus = "removed; network controls released"
                    self?.updateLines()
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                var request = DaemonRequest(.supervisor)
                var message = MimoSupervisorRequest(.state)
                message.includeEvents = true
                request.supervisor = message
                async let core = try? DaemonRPC.call(DaemonRequest(.events), timeout: 2)
                async let supervisor = try? DaemonRPC.call(request, timeout: 2, serviceLabel: MimoRuntime.supervisorLabel)
                let (coreResponse, supervisorResponse) = await (core, supervisor)
                guard !Task.isCancelled else { return }
                if let events = coreResponse?.events {
                    self?.serviceEvents = events
                    self?.serviceRecords = coreResponse?.diagnosticEvents
                    self?.coreStatus = coreResponse?.diagnosticEvents == nil ? "readable events only; update service for full records" : "connected"
                } else { self?.coreStatus = "unavailable; showing last received records" }
                if let events = supervisorResponse?.events {
                    self?.supervisorEvents = events
                    self?.supervisorRecords = supervisorResponse?.diagnosticEvents
                    self?.supervisorStatus = supervisorResponse?.diagnosticEvents == nil ? "readable events only; update service for full records" : "connected"
                } else { self?.supervisorStatus = "unavailable; showing last received records" }
                self?.updateLines()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        observer = NotificationCenter.default.addObserver(forName: RuntimeLog.recordWritten, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLines() }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func updateLines() {
        guard !isPaused else { return }
        let next = Array(Set(serviceEvents + supervisorEvents + RuntimeLog.shared.recentLines()).sorted().suffix(500))
        if lines != next { lines = next }
        let status = "Core: \(coreStatus) · Supervisor: \(supervisorStatus)"
        if sourceStatus != status { sourceStatus = status }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let report = "Mimo \(version) (build \(build)) · recent diagnostic records · UTC\n" +
            "IP-address visibility follows Settings → General → Diagnostics.\n\n" +
            "=== GUI ===\n" + RuntimeLog.shared.recentDiagnosticRecords().joined(separator: "\n") +
            "\n\n=== Core (\(coreStatus)) ===\n" + (serviceRecords ?? serviceEvents).joined(separator: "\n") +
            "\n\n=== Supervisor (\(supervisorStatus)) ===\n" + (supervisorRecords ?? supervisorEvents).joined(separator: "\n") + "\n"
        if diagnosticsText != report { diagnosticsText = report }
    }
}

/// One native text document supports multi-line selection, Select All, Copy and
/// the standard context menu. Incoming updates cannot replace selected text.
struct EventLogText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? EventLogTextView)?.display(text)
    }

    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = EventLogTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textColor = .labelColor
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = view
        view.setAccessibilityIdentifier("mimo-event-log-text")
        view.setAccessibilityLabel("Event log. Select text to copy; updates wait while text is selected.")
        scroll.documentView = view
        return scroll
    }
}

final class EventLogTextView: NSTextView, NSTextViewDelegate {
    private var pendingText = ""
    private var applying = false

    func display(_ text: String) {
        pendingText = text
        applyPendingText()
    }

    private func applyPendingText() {
        guard !applying, string != pendingText,
              !selectedRanges.contains(where: { $0.rangeValue.length > 0 }) else { return }
        let wasEmpty = string.isEmpty
        let scroll = enclosingScrollView
        let origin = scroll?.contentView.bounds.origin ?? .zero
        let wasAtBottom = wasEmpty || visibleRect.maxY >= bounds.maxY - 4
        let caret = selectedRange().location
        applying = true
        string = pendingText
        setSelectedRange(NSRange(location: min(caret, (string as NSString).length), length: 0))
        applying = false
        if wasAtBottom { scrollToEndOfDocument(nil) }
        else if let scroll {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        applyPendingText()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command {
            if event.charactersIgnoringModifiers == "a" { selectAll(nil); return true }
            if event.charactersIgnoringModifiers == "c" { copy(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct EventLogView: View {
    @ObservedObject var model: EventLogModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(model.isPaused ? "Resume" : "Pause") { model.isPaused.toggle() }
                    .frame(minWidth: 65)
                Spacer()
                MimoCopyButton(text: model.copyText, label: "Copy All", iconOnly: false)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy all readable events (⇧⌘C). Select text and press ⌘C to copy part of the log.")
                MimoCopyButton(text: model.diagnosticsText, label: "Copy Diagnostics", iconOnly: false)
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .help("Copy full recent GUI, core and supervisor records, including verification triggers (⌥⌘C).")
                Button("Show Log Files") {
                    NSWorkspace.shared.activateFileViewerSelecting([RuntimeLog.shared.directory])
                }
            }.padding(12)
            Divider()
            EventLogText(text: model.copyText)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.lines.count) events · UTC · \(model.isPaused ? "Updates paused" : "Select text to copy; updates wait while selected")")
                Text(model.sourceStatus)
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}

/// A retained AppKit window, like the dashboard and Settings.
@MainActor
final class EventLogWindowController: NSObject, NSWindowDelegate {
    static let shared = EventLogWindowController()

    let model = EventLogModel()
    private(set) var window: NSWindow?

    func show() {
        model.start()
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        keepWindowOnScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        if let text = findTextView(in: window.contentView) { window.makeFirstResponder(text) }
    }

    private func findTextView(in view: NSView?) -> EventLogTextView? {
        if let text = view as? EventLogTextView { return text }
        return view?.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    func windowWillClose(_ notification: Notification) { model.stop() }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("mimo-event-log")
        window.title = "Mimo Event Log"
        window.contentViewController = fixedSizeHostingController(
            EventLogView(model: model).frame(minWidth: 520, minHeight: 240)
        )
        window.setContentSize(NSSize(width: 820, height: 520))
        window.contentMinSize = NSSize(width: 520, height: 240)
        window.isReleasedWhenClosed = false
        window.delegate = self
        placeOnActiveScreen(window)
        return window
    }
}
