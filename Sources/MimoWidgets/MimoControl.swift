import SwiftUI
import WidgetKit

@available(macOS 26.0, *)
struct MimoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: MimoSurfaceID.control, provider: MimoControlValueProvider()) { entry in
            ControlWidgetButton(action: OpenMimoDashboardIntent(target: .dashboard)) {
                Label([entry.presentation.title, entry.presentation.address].compactMap { $0 }.joined(separator: " · "),
                      systemImage: entry.presentation.symbol)
                    .accessibilityLabel(entry.presentation.accessibilityText)
            }
        }
        .displayName("Mimo")
        .description("Shows shared routing mode, internet access, and the checked or blocking IP.")
    }

}

@available(macOS 26.0, *)
private struct MimoControlValueProvider: ControlValueProvider {
    var previewValue: MimoWidgetEntry { MimoWidgetEntry(date: .now, snapshot: nil, indicators: .init()) }
    func currentValue() async throws -> MimoWidgetEntry { await WidgetServiceState.entry() }
}

@main
struct MimoWidgetBundle: WidgetBundle {
    var body: some Widget {
        MimoStatusWidget()
        if #available(macOS 26.0, *) {
            MimoControl()
        }
    }
}
