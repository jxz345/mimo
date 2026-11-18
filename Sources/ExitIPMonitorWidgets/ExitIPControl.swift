import SwiftUI
import WidgetKit

@available(macOS 26.0, *)
struct ExitIPControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ExitIPSurfaceID.control, provider: ExitIPControlValueProvider()) { entry in
            ControlWidgetButton(action: OpenExitIPDashboardIntent(target: .dashboard)) {
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
private struct ExitIPControlValueProvider: ControlValueProvider {
    var previewValue: ExitIPWidgetEntry { ExitIPWidgetEntry(date: .now, snapshot: nil, indicators: .init()) }
    func currentValue() async throws -> ExitIPWidgetEntry { await WidgetServiceState.entry() }
}

@main
struct ExitIPMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        ExitIPStatusWidget()
        if #available(macOS 26.0, *) {
            ExitIPControl()
        }
    }
}
