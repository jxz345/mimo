import SwiftUI
import WidgetKit

struct MimoWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: MimoSnapshot?
    let indicators: MonitorIndicatorState
    var refreshInterval: RefreshInterval = .sixtyMinutes
    var routing = MimoRoutingState()
    var monitoringStatus: MonitoringStatus = .ready
    var presentation: MimoStatusPresentation {
        MimoStatusPresentation(routing: routing, snapshot: snapshot, preferences: MonitoringPreferences(), date: date, monitoringStatus: monitoringStatus, lookupError: indicators.errorMessage)
    }
}

struct MimoWidgetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MimoWidgetEntry {
        MimoWidgetEntry(
            date: .now,
            snapshot: MimoSnapshot(
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

    func getSnapshot(in context: Context, completion: @escaping (MimoWidgetEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let reply = WidgetReply(completion)
        Task { reply.finish(await WidgetServiceState.entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MimoWidgetEntry>) -> Void) {
        let reply = WidgetReply(completion)
        Task {
            let entry = await WidgetServiceState.entry()
            let refreshAt = entry.date.addingTimeInterval(RefreshPolicy.widgetTimelineRefresh)
            reply.finish(Timeline(entries: [entry], policy: .after(refreshAt)))
        }
    }
}

struct MimoStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MimoSurfaceID.widget, provider: MimoWidgetTimelineProvider()) { entry in
            MimoWidgetView(entry: entry)
        }
        .configurationDisplayName("Mimo")
        .description("Shows routing mode, internet access, and the checked or blocking IP address.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct MimoWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MimoWidgetEntry

    var body: some View {
        let status = entry.presentation
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: status.symbol).foregroundStyle(Color.primary)
                if let country = status.country { Text(country) }
                Spacer(minLength: 0)
                Text(status.kind == .unavailable ? "Mimo" : entry.routing.configuration.mode.title).font(.caption.weight(.semibold))
            }
            Text(status.kind == .unavailable ? "Status unavailable" : status.kind == .directWarning ? "IP check unavailable" : status.kind == .checking ? "Checking exit IP" : entry.routing.allowsTraffic ? "Internet allowed" : "Internet blocked")
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
    static func entry() async -> MimoWidgetEntry {
        do {
            guard let state = try await DaemonRPC.call(DaemonRequest(.state), timeout: 2).state else { throw DaemonFailure.unavailable }
            if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: "daemon.widget-cache") }
            return MimoWidgetEntry(date: .now, snapshot: state.presentedSnapshot,
                                     indicators: state.initialized ? state.presentedIndicators : .init(errorMessage: "Set up shared monitoring in Mimo", suppressLocation: true),
                                     refreshInterval: state.settings.refreshInterval,
                                     routing: state.initialized ? state.routing ?? MimoRoutingState() : MimoRoutingState(),
                                     monitoringStatus: state.status)
        } catch {
            let cached = UserDefaults.standard.data(forKey: "daemon.widget-cache").flatMap { try? JSONDecoder().decode(DaemonState.self, from: $0) }
            return MimoWidgetEntry(date: .now, snapshot: cached?.presentedSnapshot,
                                     indicators: .init(errorMessage: "Background service unavailable; cached data is stale", suppressLocation: true),
                                     refreshInterval: cached?.settings.refreshInterval ?? .sixtyMinutes)
        }
    }
}

/// WidgetKit's legacy callbacks aren't annotated Sendable. Each immutable callback is transferred
/// once to the fetch task and invoked exactly once, never read concurrently by another task.
private struct WidgetReply<Value>: @unchecked Sendable {
    let finish: (Value) -> Void
    init(_ finish: @escaping (Value) -> Void) { self.finish = finish }
}
