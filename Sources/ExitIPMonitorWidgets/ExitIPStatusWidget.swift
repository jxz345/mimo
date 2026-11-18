import SwiftUI
import WidgetKit

struct ExitIPWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: ExitIPSnapshot?
    let indicators: MonitorIndicatorState
    var refreshInterval: RefreshInterval = .fifteenMinutes
    var routing = MimoRoutingState()
    var presentation: MimoStatusPresentation {
        MimoStatusPresentation(routing: routing, snapshot: snapshot, preferences: MonitoringPreferences(), date: date)
    }
}

struct ExitIPWidgetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ExitIPWidgetEntry {
        ExitIPWidgetEntry(
            date: .now,
            snapshot: ExitIPSnapshot(
                ipAddress: "203.0.113.8",
                countryCode: "US",
                countryName: "United States",
                city: "Seattle",
                region: "Washington",
                autonomousSystem: "AS64500",
                organization: "Example Network",
                provider: .ipapiCo
            ),
            indicators: MonitorIndicatorState()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ExitIPWidgetEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let reply = WidgetReply(completion)
        Task { reply.finish(await WidgetServiceState.entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ExitIPWidgetEntry>) -> Void) {
        let reply = WidgetReply(completion)
        Task {
            let entry = await WidgetServiceState.entry()
            let refreshAt = entry.date.addingTimeInterval(RefreshPolicy.widgetTimelineRefresh)
            reply.finish(Timeline(entries: [entry], policy: .after(refreshAt)))
        }
    }
}

struct ExitIPStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ExitIPSurfaceID.widget, provider: ExitIPWidgetTimelineProvider()) { entry in
            ExitIPWidgetView(entry: entry)
        }
        .configurationDisplayName("Mimo")
        .description("Shows routing mode, internet access, and the checked or blocking IP address.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ExitIPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExitIPWidgetEntry

    var body: some View {
        let status = entry.presentation
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: status.symbol).foregroundStyle(status.kind == .blocked ? Color.red : .blue)
                if let country = status.country { Text(country) }
                Spacer(minLength: 0)
                Text(status.kind == .unavailable ? "Mimo" : entry.routing.configuration.mode.title).font(.caption.weight(.semibold))
            }
            Text(status.kind == .unavailable ? "Status unavailable" : entry.routing.allowsTraffic ? "Internet allowed" : "Internet blocked")
                .font(.headline)
            if let address = status.address {
                Text(entry.routing.blockingIP == nil ? "Checked IP" : "IP that triggered blocking").font(.caption2).foregroundStyle(.secondary)
                Text(address).font(.system(.caption, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
            }
            if family == .systemMedium { Text(status.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            Spacer(minLength: 0)
            if let check = entry.routing.displayedIP?.checkedAt { Text(check, style: .relative).font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(status.accessibilityText)
        .containerBackground(for: .widget) { Color.clear }
    }

}

/// Each extension fetches the machine state in its own user context. Its cache is only for outages.
enum WidgetServiceState {
    static func entry() async -> ExitIPWidgetEntry {
        do {
            guard let state = try await DaemonRPC.call(DaemonRequest(.state), timeout: 2).state else { throw DaemonFailure.unavailable }
            if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: "daemon.widget-cache") }
            return ExitIPWidgetEntry(date: .now, snapshot: state.presentedSnapshot,
                                     indicators: state.initialized ? state.presentedIndicators : .init(errorMessage: "Set up shared monitoring in Exit IP", suppressLocation: true),
                                     refreshInterval: state.settings.refreshInterval,
                                     routing: state.initialized ? state.routing ?? MimoRoutingState() : MimoRoutingState())
        } catch {
            let cached = UserDefaults.standard.data(forKey: "daemon.widget-cache").flatMap { try? JSONDecoder().decode(DaemonState.self, from: $0) }
            return ExitIPWidgetEntry(date: .now, snapshot: cached?.presentedSnapshot,
                                     indicators: .init(errorMessage: "Background service unavailable; cached data is stale", suppressLocation: true),
                                     refreshInterval: cached?.settings.refreshInterval ?? .fifteenMinutes)
        }
    }
}

/// WidgetKit's legacy callbacks aren't annotated Sendable. Each immutable callback is transferred
/// once to the fetch task and invoked exactly once, never read concurrently by another task.
private struct WidgetReply<Value>: @unchecked Sendable {
    let finish: (Value) -> Void
    init(_ finish: @escaping (Value) -> Void) { self.finish = finish }
}
