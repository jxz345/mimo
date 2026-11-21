import AppKit
import SwiftUI

@MainActor
final class MimoCopyFeedback: ObservableObject {
    @Published private(set) var copied = false
    private let pasteboard: NSPasteboard
    private var resetTask: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    @discardableResult
    func copy(_ text: String) -> Bool {
        reset()
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        copied = true
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
        return true
    }

    func reset() {
        resetTask?.cancel(); resetTask = nil
        copied = false
    }
}

struct MimoCopyButton: View {
    let text: String
    let label: String
    var iconOnly = true
    @StateObject private var feedback = MimoCopyFeedback()

    var body: some View {
        Button {
            if !feedback.copy(text) { NSSound.beep() }
        } label: {
            if iconOnly {
                Image(systemName: feedback.copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 14, height: 14)
            } else {
                // Reserve both labels so success feedback never shifts nearby controls.
                ZStack {
                    Text(label).opacity(feedback.copied ? 0 : 1)
                    Label("Copied", systemImage: "checkmark").opacity(feedback.copied ? 1 : 0)
                }.fixedSize()
            }
        }
        .help(feedback.copied ? "Copied to clipboard" : label)
        .accessibilityLabel(feedback.copied ? "Copied to clipboard. \(label)" : label)
        .onDisappear { feedback.reset() }
    }
}
