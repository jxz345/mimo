import AppKit
import ServiceManagement
import SwiftUI

enum MimoMainTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", settings = "Settings"
    var id: String { rawValue }
}

enum MimoSettingsSection: String, CaseIterable, Identifiable {
    case proxy = "Proxy", bypass = "Bypass", allowedIPs = "Allowed IPs", monitoring = "Monitoring", general = "General", maintenance = "Maintenance"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .proxy: "network"; case .bypass: "arrow.triangle.branch"; case .allowedIPs: "checkmark.shield"; case .monitoring: "clock"; case .general: "gear"; case .maintenance: "wrench.and.screwdriver" }
    }
}

@MainActor
final class MimoSettingsNavigation: ObservableObject {
    static let shared = MimoSettingsNavigation()
    @Published var tab: MimoMainTab = .dashboard
    @Published var section: MimoSettingsSection = .general
    static func open(_ section: MimoSettingsSection) { shared.section = section; MimoAppDelegate.showSettings() }
}

struct DashboardView: View {
    @ObservedObject var monitor: PublicIPMonitor
    @ObservedObject private var navigation = MimoSettingsNavigation.shared
    @StateObject private var installer = DaemonInstallationModel()
    @State private var openedProfile: String?
    private static let versionLabel: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) · Build \(build)"
    }()
    private let primaryTextSize: CGFloat = 16
    private let primaryIconSize: CGFloat = 24
    private let primaryIconWidth: CGFloat = 34
    private let serviceTitleFont = Font.system(size: 13, weight: .medium)
    private let serviceStatusFont = Font.system(size: 13)
    private let serviceControlFont = Font.system(size: 13)
    private let serviceStatusWidth: CGFloat = 134
    private let serviceAccessoryWidth: CGFloat = 190
    private let serviceRowHeight: CGFloat = 48
    private var routing: MimoRoutingState { monitor.routingState }
    private var presentation: MimoStatusPresentation { monitor.statusPresentation }
    private var location: MimoSnapshot? { monitor.snapshot.flatMap { $0.ipAddress == routing.displayedIP?.address ? $0 : nil } }
    private var savedSettingsKnown: Bool { monitor.daemonState != nil }
    private var proxyTitle: String {
        routing.configuration.proxy.map { "\($0.name) · \($0.type.displayName)" } ?? (savedSettingsKnown ? "None · Direct only" : "Configuration unavailable")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Main tab", selection: $navigation.tab) {
                    ForEach(MimoMainTab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Button { Task { await monitor.refresh() } } label: { Label("Refresh now", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).disabled(!monitor.canRefresh).mimoGlassButton()
                Spacer()
                Picker("Routing mode", selection: Binding(get: { routing.configuration.mode }, set: monitor.setMode)) {
                    ForEach(ProxyMode.allCases) { Text($0.title).tag($0).disabled($0.requiresVerification && routing.configuration.proxy == nil) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 280).disabled(!monitor.canChangeSharedSettings || installer.isInstalling)
                    .help("Direct: no proxy. Rule: apply the saved profile. Global: proxy all public internet traffic.")
            }.padding(.horizontal, 18).padding(.vertical, 10).modifier(MimoBarBackground())
            Divider()
            // Keep both tabs alive so navigation never discards an unsaved settings draft.
            ZStack {
                overview
                    .opacity(navigation.tab == .dashboard ? 1 : 0)
                    .allowsHitTesting(navigation.tab == .dashboard)
                    .accessibilityHidden(navigation.tab != .dashboard)
                    .disabled(navigation.tab != .dashboard)
                SettingsView(monitor: monitor)
                    .opacity(navigation.tab == .settings ? 1 : 0)
                    .allowsHitTesting(navigation.tab == .settings)
                    .accessibilityHidden(navigation.tab != .settings)
                    .disabled(navigation.tab != .settings)
            }
            .onChange(of: navigation.tab) { _, _ in
                // A hidden text field must not retain keyboard focus in the other tab.
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            Divider()
            HStack {
                Button { MimoAppDelegate.showEventLog() } label: { Label("Event Log", systemImage: "list.bullet") }
                Text(Self.versionLabel).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.leading, 12)
                Spacer()
                Text(monitor.installationInactive ? "Monitoring in this app. Safe to delete Mimo.app." : routing.networkReleased == true ? "Engine stays stopped until you start it." : "Shared across this Mac · Routing continues when this window closes.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit GUI", systemImage: "power") }
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 10).modifier(MimoBarBackground())
        }.tint(.gray).modifier(MimoAppearance())
        .sheet(isPresented: Binding(get: { openedProfile != nil }, set: { if !$0 { openedProfile = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Runtime profile").font(.headline); Spacer(); Button("Close") { openedProfile = nil }.keyboardShortcut(.cancelAction) }
                Text("Read-only snapshot · Delivered in memory · May contain proxy credentials").font(.caption).foregroundStyle(.secondary)
                ScrollView([.vertical, .horizontal]) {
                    Text(openedProfile ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).privacySensitive().frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(width: 720, height: 500).tint(.gray)
        }
    }

    private var overview: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let wide = geometry.size.width >= 840
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
                    layout {
                        connection.frame(width: wide ? max(320, (geometry.size.width - 48) * 0.36) : nil)
                        services.frame(maxWidth: .infinity)
                    }.frame(minHeight: wide ? max(568, geometry.size.height - 32) : nil)
                }.padding(16)
            }
        }
    }

    private var connection: some View {
        dashboardCard("Current connection", detail: "") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Traffic family", selection: Binding(get: { routing.configuration.networkFamily }, set: monitor.setNetworkFamily)) {
                    ForEach(MimoNetworkFamily.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                    .disabled(!monitor.canChangeSharedSettings || installer.isInstalling)
                    .help("Applies to Rule and Global. Changing family requires fresh exit-IP verification.")
                VStack(spacing: 8) {
                    addressSlot(.ipv4)
                    addressSlot(.ipv6)
                }
                VStack(spacing: 10) {
                    HStack { Text("Network").foregroundStyle(.secondary); Spacer(); Text(location?.organization ?? location?.locationSummary ?? "Unavailable").lineLimit(1).help(location?.locationSummary ?? "Location unavailable") }
                    HStack { Text("IP check").foregroundStyle(.secondary); Spacer(); if let date = routing.displayedIP?.checkedAt { Text(date, style: .relative) } else { Text("No result") } }
                    HStack {
                        Text("Allowed IPs").foregroundStyle(.secondary); Spacer()
                        Button { MimoSettingsNavigation.open(.allowedIPs) } label: {
                            Text(savedSettingsKnown ? "\(monitor.allowedIPList.addresses.count) addresses" : "Unavailable")
                            Image(systemName: "arrow.right")
                        }.buttonStyle(.plain)
                    }
                }.font(.system(size: 13))
                Spacer(minLength: 6)
                HStack {
                    Label(monitor.preferences.refreshInterval.displayName, systemImage: "clock").lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Configure") { MimoSettingsNavigation.open(.monitoring) }.buttonStyle(.plain)
                }.font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text("Proxy configuration").foregroundStyle(.secondary); Spacer(); Button { MimoSettingsNavigation.open(.proxy) } label: { Text("Edit"); Image(systemName: "arrow.right") }.buttonStyle(.plain) }
                    Text(proxyTitle).font(.system(size: 14, weight: .medium)).lineLimit(1).help(proxyTitle)
                }.font(.system(size: 13))
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Bypass blocks").foregroundStyle(.secondary)
                        Text("\(monitor.daemonState?.settings.effectiveBypassBlocks.filter(\.enabled).count ?? 0) enabled · Rule only")
                    }
                    Spacer()
                    Button("Edit blocks") { MimoSettingsNavigation.open(.bypass) }.buttonStyle(.plain)
                }.font(.system(size: 13))
            }.padding(16)
        }
    }

    private func addressSlot(_ family: MimoAddressFamily) -> some View {
        let ipv6 = family == .ipv6
        let observation = ipv6 ? routing.ipv6Observation : routing.displayedIP
        let snapshot = ipv6 ? routing.exitObservations?.ipv6 : location
        let selected = !ipv6 || routing.configuration.networkFamily == .dual
        let address = observation.flatMap { family.accepts($0.address) ? $0.address : nil }
        return HStack(spacing: 10) {
            Group { if let snapshot { Text(snapshot.countryFlag) } else { Image(systemName: "globe") } }
                .font(.system(size: 24)).frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(ipv6 ? "IPv6" : "IPv4").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(address ?? (selected ? (monitor.status == .refreshing ? "Checking…" : "No result") : "Not selected"))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help(address ?? (selected ? "No current observation" : "IPv6 is rejected for managed traffic"))
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let address { MimoCopyButton(text: address, label: "Copy \(family.rawValue) address").buttonStyle(.borderless) }
        }.padding(.horizontal, 12).frame(height: 78)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var networkReleaseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(monitor.installationInactive ? "Monitoring only" : "Using another VPN?").font(.system(size: 14, weight: .medium))
            Text(monitor.installationInactive ? "Network controls released. IP monitoring continues while this app is open." : "Stop the engine and release network controls.")
                .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(installer.isInstalling ? "Working…" : monitor.installationInactive ? "Activate Mimo" : installer.hasError ? "Retry cleanup" : "Stop engine and use Direct") {
                if monitor.installationInactive { installer.install(activating: true) } else { installer.deactivate() }
            }.font(.system(size: 13)).buttonStyle(.borderedProminent)
                .disabled(installer.isInstalling || (monitor.connected && (monitor.serviceOperation != nil || monitor.isChangingSettings)))
            if let message = installer.message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var uninstallControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Clean uninstall").font(.system(size: 14, weight: .medium))
            HStack(spacing: 6) {
                Text("brew uninstall --cask jxz345/tap/mimo").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                MimoCopyButton(text: "brew uninstall --cask jxz345/tap/mimo", label: "Copy uninstall command").buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            Text("Or stop the engine above, wait for cleanup, quit Mimo, then delete Mimo.app.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var services: some View {
        dashboardCard("Background services", detail: monitor.installationInactive ? "Removed · monitoring in this app" : monitor.connected ? "Health & configured endpoints" : monitor.connection.rowTitle) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: presentation.symbol).font(.system(size: primaryIconSize))
                        .foregroundStyle(accessColor)
                        .frame(width: primaryIconWidth, height: 47).accessibilityLabel(presentation.accessibilityText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Internet access").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(accessHeading).font(.system(size: primaryTextSize, weight: .medium))
                            .lineLimit(1).help(accessHeading)
                        Text(installer.isInstalling ? "Updating background installation…" : presentation.detail).font(.system(size: 14)).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(presentation.detail)
                        accessActions.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 14).padding(.vertical, 12)
                Divider()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 0) {
                        infrastructureStatus(at: context.date)
                        Divider()
                        VStack(spacing: 0) { ForEach(MimoServiceID.allCases) { service in serviceRow(service, at: context.date) } }
                            .padding(.horizontal, 14)
                        Divider()
                        networkReleaseControls
                        Divider()
                        uninstallControls
                        if let error = monitor.operationError {
                            Text(error).font(.system(size: 12)).foregroundStyle(.orange).padding(12)
                        }
                    }
                }
            }
        }
    }

    private func infrastructureStatus(at date: Date) -> some View {
        let status = (routing.infrastructure ?? .init()).current(at: date)
        return VStack(spacing: 0) {
            infrastructureIndicator("Transition guard", symbol: "shield.lefthalf.filled", health: status.pf, checkedAt: status.checkedAt, at: date)
            Divider()
            infrastructureIndicator("Service monitor", symbol: "waveform.path.ecg", health: status.launchd, checkedAt: status.checkedAt, at: date)
        }
        .help("Independent checks run every 10 seconds. " + (status.checkedAt.map { "Last check: \($0.formatted(date: .omitted, time: .standard))." } ?? "No current inspection is available.") + " The active firewall blocks native application fallback; launchd reports startup jobs and saved service intent. Intentional Stop choices are healthy.")
        .padding(.horizontal, 14).frame(height: serviceRowHeight * 2 + 1)
    }

    private func infrastructureIndicator(_ title: String, symbol: String, health: MimoInfrastructureHealth, checkedAt: Date?, at date: Date) -> some View {
        let hasReport = monitor.connected || monitor.hasSupervisorReply(at: date)
        let color = monitor.installationInactive || hasReport && (health == .healthy || health == .released) ? Color.secondary : Color.orange
        return HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(title).font(serviceTitleFont).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(monitor.installationInactive ? (title == "Transition guard" ? "Released" : "Removed") : hasReport ? MimoHealthLabel.text(health == .stale ? "Stale" : health.title, checkedAt: checkedAt, at: date) : monitor.connection.rowTitle).lineLimit(1)
            }.font(serviceStatusFont).monospacedDigit().foregroundStyle(color)
                .frame(width: serviceStatusWidth, alignment: .leading)
                .help(hasReport ? "The latest reported inspection result." : monitor.connection.detail + " " + monitor.connection.lastReplyText(at: date))
            Color.clear.frame(width: serviceAccessoryWidth, height: 1).accessibilityHidden(true)
        }.font(serviceStatusFont).frame(maxWidth: .infinity).frame(height: serviceRowHeight)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var accessActions: some View {
        if monitor.installationInactive {
            EmptyView()
        } else if !monitor.connected {
            HStack {
                Button("Reconnect") { monitor.reconnect() }
                    .help("Reconnect this app to the background service without restarting it or changing routing.")
                if !installer.serviceInstalled || monitor.connection.phase == .incompatible {
                    Button(installer.serviceInstalled ? "Repair installation" : "Set up services") { installer.install() }.disabled(installer.isInstalling)
                }
            }.controlSize(.small)
        } else if monitor.connected && monitor.daemonState?.initialized != true {
            Button("Initialize shared settings") { Task { await monitor.initializeSharedSettings() } }.disabled(monitor.isChangingSettings)
        } else if routing.configuration.mode.requiresVerification && !routing.allowsTraffic {
            HStack {
                Button("Retry verification") { Task { await monitor.refresh() } }.disabled(!monitor.canRefresh)
                Button("Use Direct") { monitor.setMode(.direct) }.disabled(!monitor.canChangeSharedSettings)
            }.controlSize(.small)
        }
    }

    private func serviceRow(_ id: MimoServiceID, at date: Date) -> some View {
        let status = routing.services.first { $0.id == id }
        let health = status?.health ?? .unavailable
        let hasReport = monitor.hasServiceReport(id, at: date)
        let title = monitor.serviceOperation == id ? "Working…" : status?.healthTitle(at: date) ?? "Unavailable"
        let stale = health == .running && title != "Healthy" && monitor.serviceOperation != id
        let color = monitor.installationInactive ? Color.secondary : !hasReport || stale ? Color.orange : Color.secondary
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: serviceSymbol(id)).foregroundStyle(Color.secondary).frame(width: 20)
                Text(id.title).font(serviceTitleFont).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(monitor.serviceHealthLabel(id, at: date)).lineLimit(1)
                }
                    .font(serviceStatusFont).monospacedDigit().foregroundStyle(color).frame(width: serviceStatusWidth, alignment: .leading)
                    .help((hasReport ? "" : monitor.connection.detail + " ") + (status?.checkedAt.map { "Last checked: \($0.formatted(date: .omitted, time: .standard))." } ?? "No service inspection time is available."))
                serviceButtons(id, health: health).disabled(!hasReport || installer.isInstalling).frame(width: serviceAccessoryWidth, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text(serviceEndpoint(id, status: status)).font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).textSelection(.enabled).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, 26)
        }.frame(height: serviceRowHeight, alignment: .center)
            .overlay(alignment: .bottom) {
                if id != MimoServiceID.allCases.last { Divider() }
            }
    }

    private func serviceButtons(_ id: MimoServiceID, health: MimoServiceHealth) -> some View {
        HStack(spacing: 4) {
            if id == .profileHosting {
                Button("Open profile") { Task { openedProfile = await monitor.openProfile() } }.disabled(monitor.serviceOperation != nil || health != .running)
                Button("Reload") { monitor.changeService(.profileHosting, operation: .restart) }.disabled(monitor.serviceOperation != nil || health != .running)
                    .help("Regenerate the profile and verify again before protected traffic resumes.")
            } else {
                ForEach([MimoServiceOperation.start, .stop, .restart], id: \.rawValue) { operation in
                    Button(operation.rawValue.capitalized) {
                        if id == .mihomo && operation == .stop { installer.deactivate() }
                        else { monitor.changeService(id, operation: operation) }
                    }
                        .disabled(monitor.serviceOperation != nil || (operation == .start && health == .running) || (operation != .start && health == .stopped))
                        .accessibilityLabel("\(operation.rawValue.capitalized) \(id.title)")
                        .help("\(operation.rawValue.capitalized) \(id.title)")
                }
            }
        }.font(serviceControlFont).controlSize(.small).frame(height: 22)
    }

    private func dashboardCard<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }.padding(.horizontal, 14).frame(height: 38)
            Divider()
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
    }
    private func serviceSymbol(_ id: MimoServiceID) -> String {
        switch id { case .core: "cpu"; case .mihomo: "network"; case .profileHosting: "doc.text" }
    }
    private func serviceEndpoint(_ id: MimoServiceID, status: MimoServiceStatus?) -> String {
        switch id {
        case .core: "XPC / Mach · No TCP port"
        case .profileHosting: "In memory · Unix socket · No TCP port"
        case .mihomo: routing.networkReleased == true ? "Proxy 7890 · DNS 1053 · Released" : "127.0.0.1 · Proxy \(String(status?.port ?? 7890)) · DNS \(String(MimoRuntime.dnsPort))"
        }
    }
    private var accessTitle: String {
        switch presentation.kind {
        case .directWarning: "Check failed"
        case .checking: presentation.isRestoringDirect ? "Switching to Direct" : presentation.isClosing ? "Applying mode" : presentation.trafficIsBlocked ? "Blocked · Checking" : "Checking"
        case .unavailable: "Unavailable"
        case .blocked: "Blocked"
        case .direct, .verified: "Allowed"
        }
    }
    private var accessHeading: String {
        if monitor.installationInactive { return "Monitoring only · network controls released." }
        return switch presentation.kind {
        case .direct: routing.networkReleased == true ? "Direct · Engine stopped" : "You’re connected directly."
        case .verified: "You’re connected. Exit IP approved."
        case .blocked: "Internet is blocked."
        case .checking:
            presentation.isRestoringDirect ? (routing.networkReleaseRequested == true ? "Restoring system networking…" : "Switching to direct connection…") : presentation.isClosing ? "Closing internet access…" : presentation.trafficIsBlocked
                ? (presentation.isValidating ? "Blocked · Validating profile…" : presentation.isCheckingReadiness ? "Blocked · Checking readiness…" : "Blocked · Checking exit IP…")
                : "Checking your exit IP…"
        case .directWarning: "Direct · IP check unavailable."
        case .unavailable: monitor.connected ? "Status is unavailable." : monitor.connection.phase == .connecting ? "Connecting to background service…" : "Service communication interrupted."
        }
    }
    private var accessColor: Color {
        switch presentation.kind {
        case .direct, .verified: .blue
        case .checking, .directWarning: .orange
        case .blocked: .red
        case .unavailable: .secondary
        }
    }

}

struct SettingsView: View {
    private enum ScrollTarget: Hashable { case monitoringEvents }

    @ObservedObject var monitor: PublicIPMonitor
    @ObservedObject private var navigation = MimoSettingsNavigation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("mimo.appearance") private var appearance = "system"
    @AppStorage("mimo.reduceTransparency") private var reduceTransparency = false
    @State private var address = ""
    @State private var validationError: String?
    @State private var token = ""
    @State private var proxyDraft = MimoProxyDraft()
    @State private var bypassDraft = MimoBypassDraft()

    var body: some View {
        HStack(spacing: 0) {
            List(MimoSettingsSection.allCases, selection: $navigation.section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }.listStyle(.sidebar).frame(width: 190)
            Divider()
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(navigation.section.rawValue).font(.largeTitle.weight(.semibold))
                        if navigation.section != .general && navigation.section != .maintenance && monitor.connected && monitor.daemonState?.initialized != true {
                            MimoCard("Set up shared monitoring") {
                                Text("Initialize this Mac’s monitoring settings before editing the proxy, allowed IPs, or lookup providers.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Initialize shared settings") { Task { await monitor.initializeSharedSettings() } }
                                    .disabled(monitor.isChangingSettings)
                            }
                        }
                        content(scrollProxy: scrollProxy)
                        if let error = monitor.operationError { Text(error).foregroundStyle(.primary).font(.callout) }
                    }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    @ViewBuilder private func content(scrollProxy: ScrollViewProxy) -> some View {
        switch navigation.section {
        case .proxy: MimoProxyForm(monitor: monitor, draft: $proxyDraft)
        case .bypass: MimoBypassView(monitor: monitor, draft: $bypassDraft)
        case .allowedIPs: allowlist
        case .monitoring: monitoring(scrollProxy: scrollProxy)
        case .maintenance: maintenance
        case .general:
            Form {
                Section("Login item & appearance") {
                    LaunchAtLoginControl()
                    Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    Toggle("Reduce transparency", isOn: $reduceTransparency)
                }
                Section("Traffic policy") {
                    LabeledContent("Managed traffic", value: monitor.routingState.configuration.networkFamily.title)
                    Text("IPv4 captures and rejects IPv6, including NAT64 and proxy-side IPv6 hostname connections. Dual-stack carries both families through the selected proxy. Native LAN and Tailnet routes remain native.")
                    LabeledContent("Public ping / ping6", value: "Blocked without synthetic replies")
                    Text("Public DNS uses encrypted queries through the proxy. Known private names use their native resolver; unavailable private resolvers fail locally. macOS search domains are preserved.")
                }
                Section("Menu bar") {
                    Picker("Display", selection: Binding(get: { monitor.preferences.menuBarDisplayStyle }, set: { value in var preferences = monitor.preferences; preferences.menuBarDisplayStyle = value; monitor.apply(preferences) })) {
                        ForEach(MenuBarDisplayStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Highlight country changes", isOn: Binding(get: { monitor.preferences.highlightCountryChanges }, set: monitor.setCountryChangeHighlightsEnabled))
                }
            }.formStyle(.grouped)
        }
    }

    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 20) {
            MimoCard("Firewall rules") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Core manages one PF anchor: com.apple/000.mimo. Every rule has a mimo: purpose label. The profile decides proxy routing; the active firewall prevents native application fallback.")
                    DisclosureGroup("Active Rule / Global") {
                        Text("Allows Mimo’s own TUN and loopback, engine-owned TCP/UDP, native LAN and link-local addresses, DHCP, local mDNS and IPv6 link control. Tailnet addresses are allowed only on a verified native tunnel. Synthetic addresses and Tailnet traffic on another path are dropped before other exceptions. All remaining native outbound traffic is silently dropped, for IPv4 and IPv6.")
                            .padding(.top, 4)
                        Text("Rules create no connection states. Engine ownership uses Mimo’s private group; root alone does not grant public access. Native LAN ranges are 10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7 and fe80::/10. Intentional native destinations remain outside proxy protection.")
                            .padding(.top, 4)
                        Text("For the signed Tailscale system extension, core permits root-owned UDP on its held source ports and HTTPS only to its observed control/relay addresses, including startup before its tunnel exists. Core refreshes these scopes during its existing audit. Private Tailnet traffic still requires its verified native interface. This native VPN transport is an explicit exception; other users and arbitrary root HTTPS destinations are not allowed.")
                            .padding(.top, 4)
                    }
                    DisclosureGroup("Starting, verifying and recovering") {
                        Text("Blocks ordinary traffic, including the public local proxy and DNS listeners. Allows local control, DHCP and IPv6 neighbor/router control. Verification temporarily permits only the engine group’s TCP connection to the selected proxy endpoint, or the fixed HTTPS resolver for proxy-hostname bootstrap. Existing IPv4/IPv6 states are cleared when closing.")
                            .padding(.top, 4)
                    }
                    DisclosureGroup("Direct, Stop engine and uninstall") {
                        Text("Direct removes Mimo’s TUN and DNS override and leaves its PF policy empty. Stop engine and uninstall also remove owned services and current or legacy firewall controls. Cleanup preserves other applications’ firewall rules and restores native network settings. Check Event Log for each cleanup step.")
                            .padding(.top, 4)
                    }
                    maintenanceCommand("Inspect Mimo’s live rules", command: "sudo pfctl -a com.apple/000.mimo -sr", detail: "Read-only. Labels show each rule’s purpose; Direct has no Mimo packet rules.")
                }
            }
            MimoCard("Maintenance CLI") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Copy a command and run it in Terminal on this Mac. Administrator commands may ask for your password. These controls affect every account.")
                    maintenanceCommand("Supervisor status", command: "sudo /Library/PrivilegedHelperTools/mimo-manage status", detail: "Shows launchd status. The dashboard reports the complete service health check.")
                    maintenanceCommand("Inspect system DNS", command: "scutil --dns", detail: "Read-only. Mimo’s protected resolver uses 127.0.0.1:1053; native private scopes remain separate.")
                    maintenanceCommand("Stop engine and release controls", command: "sudo /Library/PrivilegedHelperTools/mimo-manage deactivate", detail: "Runs the shared cleanup and keeps the open app available for IP monitoring. The installed helper is removed after successful cleanup.")
                    maintenanceCommand("Install or restore all services", command: "sudo bash /Applications/Mimo.app/Contents/Resources/daemon.sh install", detail: "Requires Mimo.app. Restores all roles, checks health and asks before replacing conflicting services.")
                    maintenanceCommand("Uninstall with Homebrew", command: "brew uninstall --cask jxz345/tap/mimo", detail: "Removes network controls and the installed app through the Homebrew uninstall hook.")
                    maintenanceCommand("Remove services if the app was deleted", command: "sudo /Library/PrivilegedHelperTools/mimo-manage uninstall", detail: "Uses the retained helper to clean up services, DNS and current or older firewall rules. Local settings and logs are retained.")
                }
            }
        }.font(.callout)
    }

    private func maintenanceCommand(_ title: String, command: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).fontWeight(.medium)
            HStack(alignment: .top, spacing: 8) {
                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                MimoCopyButton(text: command, label: "Copy \(title)")
            }
            Text(detail).foregroundStyle(.secondary)
        }
    }

    private var allowlist: some View {
        MimoCard("Allowed exit IPs") {
            VStack(alignment: .leading, spacing: 12) {
                if monitor.allowedIPList.isEmpty { Text("No addresses yet. Rule and Global remain blocked.").foregroundStyle(.secondary) }
                ForEach(monitor.allowedIPList.addresses, id: \.self) { ip in
                    HStack { Text(ip).monospaced().textSelection(.enabled); Spacer(); Button { monitor.removeAllowedIP(ip) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove \(ip)") }
                }
                HStack {
                    TextField("IPv4 or IPv6 address", text: $address)
                    Button("Add") {
                        guard let normalized = IPAddressValidator.normalize(address) else { validationError = "Enter a valid IPv4 or IPv6 address."; return }
                        guard !monitor.allowedIPList.contains(normalized) else { validationError = "That address is already allowed."; return }
                        if monitor.addAllowedIP(normalized) { address = ""; validationError = nil }
                    }
                }
                if let validationError { Text(validationError).font(.caption).foregroundStyle(.primary) }
                Text("Approval is explicit. Retries never add an IP automatically. Direct bypasses this check.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!monitor.canChangeSharedSettings)
        }
    }

    private func systemEvent(_ title: String, action: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(action).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func monitoring(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            MimoCard("Verification") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Routine interval")
                        Spacer()
                        Picker("Routine interval", selection: Binding(get: { monitor.preferences.refreshInterval }, set: { value in var preferences = monitor.preferences; preferences.refreshInterval = value; monitor.apply(preferences) })) {
                            ForEach(RefreshInterval.allCases) { Text($0.displayName).tag($0) }
                        }.labelsHidden().fixedSize().disabled(!monitor.canChangeSharedSettings)
                    }
                    systemEvent("Network changes", action: "Rule / Global only")
                    systemEvent("Traffic", action: monitor.routingState.configuration.mode.requiresVerification ? (monitor.routingState.configuration.networkFamily == .ipv4 ? "IPv4; captured IPv6 blocked" : "IPv4 and IPv6 through proxy") : "System / other VPN")
                        .help("Rule and Global enforce the selected family policy. Direct uses system networking.")
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Rule / Global")
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                    scrollProxy.scrollTo(ScrollTarget.monitoringEvents, anchor: .top)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("View rules").underline()
                                    Image(systemName: "arrow.down")
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("View system and network event rules")
                            .help("Scroll to System & network events at the bottom of Monitoring.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text("Block → Verify IP → Reopen if approved")
                            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    Text("Direct ignores ordinary system/network events; tailnet and human controls remain active. One protected cycle runs at a time; controls wait until it finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            MimoCard("Lookup providers") {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                        GridRow {
                            Text("Provider").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Quota / day")
                            Text("Mimo / day")
                            Text("Used today")
                            Text("Remaining")
                        }.font(.caption).foregroundStyle(.secondary)
                        ForEach(ProviderID.allCases) { provider in
                            let used = monitor.lookupBudget.callsToday(for: provider)
                            let quota = LookupBudget.documentedDailyLimit(for: provider)
                            let budget = LookupBudget.dailyBudget(for: provider)
                            GridRow {
                                Toggle(provider.displayName, isOn: Binding(get: { monitor.preferences.providerPool.contains(provider) }, set: { enabled in
                                    var preferences = monitor.preferences
                                    if enabled { preferences.providerPool.append(provider) } else { preferences.providerPool.removeAll { $0 == provider } }
                                    guard let first = preferences.providerPool.first else { return }
                                    if !preferences.providerPool.contains(preferences.provider) { preferences.provider = first }
                                    monitor.apply(preferences)
                                }))
                                Text(quota.map { $0.formatted() } ?? "Unlimited")
                                Text(budget.map { $0.formatted() } ?? "—")
                                Text(used.formatted())
                                Text(budget.map { max(0, $0 - used).formatted() } ?? "—")
                            }.monospacedDigit()
                            if let until = monitor.pausedUntil(provider), until > monitor.displayDate {
                                GridRow {
                                    Text("\(provider.displayName): \(ProviderFailurePolicy.reason(monitor.providerHealth[provider]?.lastError)) · Paused until \(until.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .gridCellColumns(5)
                                }
                            }
                        }
                    }
                    Text("Mimo uses 80% of capped quotas; remaining is Mimo’s allowance. Counts reset at midnight UTC for this Mac. Other devices may share a provider’s quota. IPinfo Lite is unlimited with a token.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("If an IP lookup fails, Mimo tries the next available provider and avoids the failed provider for 10 minutes (or longer if requested by that provider). Pauses survive restarts. Unknown country data is not a failure.")
                        .font(.callout).foregroundStyle(.secondary)
                    SecureField("Shared IPinfo token", text: $token)
                    HStack {
                        Button("Import saved token") { Task { _ = await monitor.loadIPinfoToken() } }
                        Button("Save token") { Task { if await monitor.saveIPinfoToken(token) { token = "" } } }.disabled(token.isEmpty)
                        Button("Remove token") { Task { _ = await monitor.removeIPinfoToken() } }
                    }.controlSize(.small).disabled(monitor.isCredentialBusy)
                    Text(monitor.ipinfoCredentialStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Stored locally for all users. Sent only to IPinfo over HTTPS for authentication.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!monitor.canChangeSharedSettings)
            }
            MimoCard("System & network events") {
                VStack(alignment: .leading, spacing: 7) {
                    systemEvent("Wi-Fi, Ethernet, addresses & gateways", action: "Block → Check IP")
                    systemEvent("DNS, proxy, routes, interfaces & VPN", action: "Block → Check IP")
                    systemEvent("Sleep → Wake / cancelled sleep", action: "Block → Check before reopening")
                    systemEvent("Reboot / service recovery", action: "Restore protection → Verify")
                    systemEvent("Lock / unlock / login / logout / user switch", action: "Block → Check IP")
                    systemEvent("Display sleep / wake", action: "Block → Check IP")
                    systemEvent("Close / reopen Mimo", action: "Shared protection continues")
                    Text("Blocking applies to Rule / Global. Direct ignores these events; tailnet changes and human controls still work. Events received during verification are held for one follow-up; an external change keeps traffic blocked until a fresh result passes. Owned tunnel/DNS notifications are ignored. The system service observes session/display state every 0.5 seconds; sleep retains its independent firewall barrier.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                }
            }.id(ScrollTarget.monitoringEvents)
        }
    }


}

private struct MimoProxyForm: View {
    @ObservedObject var monitor: PublicIPMonitor
    @Binding var draft: MimoProxyDraft
    @State private var confirmRemoval = false
    @State private var error: String?
    private var conflicting: Bool { draft.conflicts(with: monitor.daemonState) }
    private var unavailable: Bool { !monitor.connected || monitor.daemonState?.initialized != true || draft.revision == nil }
    var body: some View {
        MimoCard("Shared proxies") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Active proxy", selection: Binding<UUID?>(get: {
                    monitor.routingState.configuration.activeProxyID
                }, set: { id in Task { _ = await monitor.selectProxy(id) } })) {
                    Text("None · Direct only").tag(nil as UUID?)
                    ForEach(monitor.routingState.configuration.proxies ?? []) { entry in
                        Text(entry.proxy.name).tag(Optional(entry.id))
                    }
                }.disabled(unavailable || monitor.isChangingSettings)
                ForEach(monitor.routingState.configuration.proxies ?? []) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.proxy.name).fontWeight(.medium)
                            Text("\(entry.proxy.type.displayName) · \(entry.proxy.server):\(String(entry.proxy.port))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.id == monitor.routingState.configuration.activeProxyID { Text("Active").font(.caption) }
                        Button("Edit") { draft.select(entry.id, from: monitor.daemonState); error = nil }
                    }
                }
                Button("Add proxy") { draft.select(nil, from: monitor.daemonState); error = nil }
                    .disabled(unavailable || monitor.isChangingSettings)
                Divider()
                Text(draft.proxyID == nil ? "New proxy" : "Edit proxy").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow { Text("Name"); TextField("Proxy name", text: $draft.name) }
                    GridRow { Text("Type"); Picker("Type", selection: $draft.type) { ForEach(ClashProxySettings.ProxyType.allCases) { Text($0.displayName).tag($0) } }.labelsHidden() }
                    GridRow { Text("Server"); TextField("proxy.example.com", text: $draft.server) }
                    GridRow { Text("Port"); TextField("1080", text: $draft.port) }
                    GridRow { Text("Username"); TextField("Optional", text: $draft.username) }
                    GridRow { Text("Password"); SecureField(draft.hasPassword ? "Saved locally" : "Optional", text: $draft.password) }
                }.textFieldStyle(.roundedBorder).disabled(unavailable || monitor.isChangingSettings)
                if draft.hasPassword { Toggle("Remove the saved password", isOn: $draft.clearPassword).disabled(unavailable || monitor.isChangingSettings) }
                if conflicting {
                    Text("Shared settings changed while this form was open. Your draft is preserved. Reload the latest settings before saving.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Reload and discard draft") { load(); error = nil }
                        .disabled(unavailable || monitor.isChangingSettings)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.primary) }
                HStack {
                    Button("Save proxy") { save() }.mimoGlassButton()
                    Button("Remove", role: .destructive) { confirmRemoval = true }.disabled(draft.proxyID == nil)
                    Spacer()
                    Button("Import my saved proxy") {
                        guard let revision = draft.revision else { return }
                        Task { if await monitor.importLegacyProxy(expectedRevision: revision) { load() } }
                    }
                }.disabled(unavailable || conflicting || monitor.isChangingSettings)
                Text("Shared by all users on this Mac. New proxies are saved inactive. Credentials are stored locally.").font(.caption).foregroundStyle(.secondary)
            }
        }.onChange(of: monitor.daemonState?.revision, initial: true) { _, _ in draft.receive(monitor.daemonState) }
            .onChange(of: monitor.daemonState?.initialized) { _, _ in draft.receive(monitor.daemonState) }
            .confirmationDialog("Remove the shared proxy?", isPresented: $confirmRemoval) {
                Button("Remove proxy", role: .destructive) {
                    guard let revision = draft.revision, let id = draft.proxyID else { return }
                    Task { if await monitor.removeProxy(id: id, expectedRevision: revision) { draft.select(nil, from: monitor.daemonState) } }
                }
            } message: { Text("Removing the active proxy switches this Mac to Direct.") }
    }
    private func load() {
        draft.receive(monitor.daemonState, discardChanges: true)
    }
    private func save() {
        do {
            guard let revision = draft.revision else { return }
            let value = try draft.validatedProxy(), password = draft.passwordChange
            Task { if await monitor.saveProxy(value, password: password, expectedRevision: revision, id: draft.proxyID) { error = nil; load() } }
        } catch { self.error = error.localizedDescription }
    }
}

private struct MimoCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
    }
}

private struct MimoReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var mimoReduceTransparency: Bool {
        get { self[MimoReduceTransparencyKey.self] }
        set { self[MimoReduceTransparencyKey.self] = newValue }
    }
}

@MainActor
enum MimoApplicationAppearance {
    static func apply(_ value: String) {
        // AppKit owns the whole window, including SwiftUI's native Form controls.
        // Clearing a per-view preferredColorScheme can leave those controls in the
        // previous scheme while the title bar has already returned to System.
        switch value {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
}

private struct MimoAppearance: ViewModifier {
    @AppStorage("mimo.appearance") private var appearance = "system"
    @AppStorage("mimo.reduceTransparency") private var reduceTransparency = false
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    func body(content: Content) -> some View {
        content
            .onChange(of: appearance) { _, value in MimoApplicationAppearance.apply(value) }
            .environment(\.mimoReduceTransparency, reduceTransparency || systemReduceTransparency)
    }
}

private struct MimoBarBackground: ViewModifier {
    @Environment(\.mimoReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.bar))
    }
}

private struct MimoGlassButton: ViewModifier {
    @Environment(\.mimoReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.foregroundStyle(.primary).buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private extension View {
    func mimoGlassButton() -> some View { modifier(MimoGlassButton()) }
}
