import AppKit
import Foundation

@MainActor
enum CopyFeedbackTests {
    static func run() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = MimoCopyFeedback(pasteboard: pasteboard)
        let second = MimoCopyFeedback(pasteboard: pasteboard)
        for text in ["192.0.2.10", MimoRuntime.blockingProfile.path, "brew uninstall --cask jxz345/tap/mimo", "Event one\nEvent two\n"] {
            precondition(first.copy(text) && first.copied)
            precondition(pasteboard.string(forType: .string) == text)
            precondition(!second.copied, "Only the clicked control should confirm copying")
        }
        try await Task.sleep(for: .milliseconds(1100))
        precondition(first.copy("Copied again"))
        try await Task.sleep(for: .milliseconds(1100))
        precondition(first.copied, "Repeated clicks must renew feedback")
        try await Task.sleep(for: .milliseconds(1100))
        precondition(!first.copied, "Feedback must reset after two seconds")
        precondition(pasteboard.string(forType: .string) == "Copied again", "Reset must preserve clipboard contents")
        print("PASS: copy writes exact clipboard text; feedback is per control, renews on click and resets without clearing clipboard")
    }
}
