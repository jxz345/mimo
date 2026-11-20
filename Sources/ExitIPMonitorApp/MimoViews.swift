import AppKit
import ServiceManagement
import SwiftUI

enum MimoMainTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", settings = "Settings"
    var id: String { rawValue }
}

enum MimoSettingsSection: String, CaseIterable, Identifiable {
    case proxy = "Proxy", allowedIPs = "Allowed IPs", monitoring = "Monitoring", general = "General"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .proxy: "point.3.connected.trianglepath.dotted"; case .allowedIPs: "checkmark.shield"; case .monitoring: "clock"; case .general: "gear" }
    }
}

@MainActor
final class MimoSettingsNavigation: ObservableObject {
    static let shared = MimoSettingsNavigation()
    @Published var tab: MimoMainTab = .dashboard
    @Published var section: MimoSettingsSection = .general
    static func open(_ section: MimoSettingsSection) { shared.section = section; ExitIPAppDelegate.showSettings() }
}

struct DashboardView: View {
    @ObservedObject var monitor: PublicIPMonitor
    @ObservedObject private var navigation = MimoSettingsNavigation.shared
    @StateObject private var installer = DaemonInstallationModel()
    @State private var openedProfile: String?
    private let primaryTextSize: CGFloat = 21
    private let primaryIconSize: CGFloat = 26
    private let primaryIconWidth: CGFloat = 34
    private let serviceTitleFont = Font.system(size: 13, weight: .medium)
    private let serviceStatusFont = Font.system(size: 13)
    private let serviceControlFont = Font.system(size: 11)
    private let serviceStatusWidth: CGFloat = 104
    private let serviceAccessoryWidth: CGFloat = 170
    private var routing: MimoRoutingState { monitor.routingState }
    private var presentation: MimoStatusPresentation { monitor.statusPresentation }
    private var location: ExitIPSnapshot? { monitor.snapshot.flatMap { $0.ipAddress == routing.displayedIP?.address ? $0 : nil } }
    private var savedSettingsKnown: Bool { monitor.daemonState != nil }
    private var proxyTitle: String {
        routing.configuration.proxy?.name ?? (savedSettingsKnown ? "No proxy configured" : "Configuration unavailable")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Main tab", selection: $navigation.tab) {
                    ForEach(MimoMainTab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                Button { Task { await monitor.refresh() } } label: { Label("Refresh now", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command).disabled(!monitor.canRefresh).mimoGlassButton()
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
                Button { ExitIPAppDelegate.showEventLog() } label: { Label("Event Log", systemImage: "list.bullet") }
                Spacer()
                Text("Routing continues when this window closes.").font(.caption).foregroundStyle(.secondary)
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
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Routing mode").font(.headline)
                            Text(routing.configuration.mode == .direct ? "Normal networking, without a proxy." : routing.configuration.mode == .rule ? "Apply the rules in your saved profile." : "Route public internet through your proxy.")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Picker("Routing mode", selection: Binding(get: { routing.configuration.mode }, set: monitor.setMode)) {
                            ForEach(ProxyMode.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 280).disabled(!monitor.canChangeSharedSettings)
                    }.frame(height: 40)
                    let wide = geometry.size.width >= 840
                    let cardHeight = max(415, geometry.size.height - 116)
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
                    layout {
                        connection.frame(width: wide ? max(300, (geometry.size.width - 50) * 0.34) : nil, height: cardHeight)
                        services.frame(maxWidth: .infinity).frame(height: cardHeight)
                    }
                    HStack(spacing: 8) {
                        Label("This Mac", systemImage: "desktopcomputer")
                        Image(systemName: "arrow.right")
                        Text(routeTitle).foregroundStyle(.primary)
                        Spacer()
                        Label(tailnetNote, systemImage: "network").lineLimit(1)
                    }.font(.caption).foregroundStyle(.secondary).frame(height: 20)
                }.padding(16)
            }
        }
    }

    private var connection: some View {
        dashboardCard("Current connection", detail: presentation.isDirect ? "Direct" : accessTitle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Group { if let location { Text(location.countryFlag) } else { Image(systemName: "globe") } }
                        .font(.system(size: primaryIconSize)).frame(width: primaryIconWidth)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(routing.blockingIP != nil && routing.phase != .unavailable ? "IP that triggered blocking" : routing.displayedIP != nil ? (presentation.isDirect ? "Public IP" : "Checked proxy exit IP") : routing.phase == .checking ? "Checking IP…" : "IP unavailable")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(routing.displayedIP?.address ?? "—").font(.system(size: primaryTextSize, weight: .medium, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.65).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let address = routing.displayedIP?.address {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy displayed IP address")
                    }
                }.frame(height: 47)
                VStack(spacing: 9) {
                    HStack { Text("Network").foregroundStyle(.secondary); Spacer(); Text(location?.organization ?? location?.locationSummary ?? "Unavailable").lineLimit(1).help(location?.locationSummary ?? "Location unavailable") }
                    HStack { Text("IP check").foregroundStyle(.secondary); Spacer(); if let date = routing.displayedIP?.checkedAt { Text(date, style: .relative) } else { Text("No result") } }
                    HStack {
                        Text("Allowed IPs").foregroundStyle(.secondary); Spacer()
                        Button { MimoSettingsNavigation.open(.allowedIPs) } label: {
                            Text(savedSettingsKnown ? "\(monitor.allowedIPList.addresses.count) \(monitor.allowedIPList.addresses.count == 1 ? "address" : "addresses")" : "Unavailable")
                            Image(systemName: "arrow.right")
                        }
                            .buttonStyle(.plain)
                    }
                }.font(.callout).padding(.vertical, 4)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text("Proxy configuration").foregroundStyle(.secondary); Spacer(); Button { MimoSettingsNavigation.open(.proxy) } label: { Text("Edit"); Image(systemName: "arrow.right") }.buttonStyle(.plain) }
                    Text(proxyTitle).font(.headline).lineLimit(1).help(proxyTitle)
                    Text(routing.configuration.proxy.map { "\($0.type.displayName) · Shared proxy" } ?? (savedSettingsKnown ? "Add a proxy in Settings" : "Connect to services to load saved settings"))
                        .font(.caption).foregroundStyle(.secondary)
                }.font(.callout).padding(.top, 3)
                Spacer(minLength: 0)
                HStack { Label(monitor.preferences.refreshInterval.displayName, systemImage: "clock").lineLimit(1); Spacer(minLength: 4); Button("Configure") { MimoSettingsNavigation.open(.monitoring) }.buttonStyle(.plain) }
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                LaunchAtLoginControl(compact: true, dashboardStyle: true)
            }.padding(14)
        }
    }

    private var services: some View {
        dashboardCard("Background services", detail: "Health & configured endpoints") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: presentation.symbol).font(.system(size: primaryIconSize))
                        .foregroundStyle(accessColor)
                        .frame(width: primaryIconWidth, height: 47).accessibilityLabel(presentation.accessibilityText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Internet access").font(.caption).foregroundStyle(.secondary)
                        Text(accessHeading).font(.system(size: primaryTextSize, weight: .medium))
                            .lineLimit(1).help(accessHeading)
                        Text(presentation.verificationProgress ?? presentation.detail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true).help(presentation.detail)
                        accessActions.frame(height: 22).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 14).padding(.top, 10).frame(height: 112, alignment: .top)
                Divider()
                infrastructureStatus
                Divider()
                VStack(spacing: 0) { ForEach(MimoServiceID.allCases) { service in serviceRow(service) } }
                    .padding(.horizontal, 14).frame(maxHeight: .infinity)
                Divider()
                Label(monitor.operationError ?? installer.message ?? monitor.lookupStatusMessage ?? "Shared across this Mac · Services continue when Mimo closes.", systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    .help(monitor.operationError ?? installer.message ?? monitor.lookupStatusMessage ?? "")
                    .padding(.horizontal, 14).frame(height: 30, alignment: .leading)
            }
        }
    }

    private var infrastructureStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = (routing.infrastructure ?? .init()).current(at: context.date)
            VStack(spacing: 0) {
                infrastructureIndicator("PF firewall", symbol: "shield.lefthalf.filled", health: status.pf, checkedAt: status.checkedAt)
                Divider()
                infrastructureIndicator("launchd monitor", symbol: "waveform.path.ecg", health: status.launchd, checkedAt: status.checkedAt)
            }
            .help("Independent checks run every 10 seconds. " + (status.checkedAt.map { "Last check: \($0.formatted(date: .omitted, time: .standard))." } ?? "No current inspection is available.") + " PF reports the main firewall policy; launchd reports startup jobs and saved service intent. Intentional Stop choices are healthy.")
        }.padding(.horizontal, 14).frame(height: 76)
    }

    private func infrastructureIndicator(_ title: String, symbol: String, health: MimoInfrastructureHealth, checkedAt: Date?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(title).font(serviceTitleFont).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Circle().fill(health == .healthy ? Color.secondary : Color.orange).frame(width: 5, height: 5)
                Text(health.title).lineLimit(1)
            }.font(serviceStatusFont).foregroundStyle(health == .healthy ? Color.secondary : Color.orange)
                .frame(width: serviceStatusWidth, alignment: .leading)
            HStack(spacing: 6) {
                Text("Last check").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Group {
                    if let checkedAt { Text(checkedAt, style: .relative) }
                    else { Text("No result") }
                }.monospacedDigit().lineLimit(1)
            }.font(serviceControlFont).frame(width: serviceAccessoryWidth, alignment: .trailing)
        }.font(serviceStatusFont).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var accessActions: some View {
        if !monitor.connected && routing.services.first(where: { $0.id == .core })?.health != .stopped {
            Button(installer.serviceInstalled ? "Repair installation" : "Set up services") { installer.install() }.disabled(installer.isInstalling)
        } else if monitor.connected && monitor.daemonState?.initialized != true {
            Button("Initialize shared settings") { Task { await monitor.initializeSharedSettings() } }.disabled(monitor.isChangingSettings)
        } else if routing.configuration.mode.requiresVerification && !routing.allowsTraffic {
            HStack {
                Button("Retry verification") { Task { await monitor.refresh() } }.disabled(!monitor.canRefresh)
                Button("Use Direct") { monitor.setMode(.direct) }.disabled(!monitor.canChangeSharedSettings)
            }.controlSize(.small)
        }
    }

    private func serviceRow(_ id: MimoServiceID) -> some View {
        let status = routing.services.first { $0.id == id }
        let health = status?.health ?? .unavailable
        let tailnetFailure = id == .tailnetProvider && (health == .unavailable || health == .notInstalled
            || (health == .stopped && routing.tailnetExpected == true))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: serviceSymbol(id)).foregroundStyle(tailnetFailure ? Color.red : Color.secondary).frame(width: 20)
                Text(id.title).font(serviceTitleFont).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) { Circle().fill(tailnetFailure ? Color.red : Color.secondary).frame(width: 5, height: 5); Text(monitor.serviceOperation == id ? "Working…" : health.rawValue.capitalized).lineLimit(1) }
                    .font(serviceStatusFont).foregroundStyle(tailnetFailure ? Color.red : Color.secondary).frame(width: serviceStatusWidth, alignment: .leading)
                serviceButtons(id, health: health).frame(width: serviceAccessoryWidth, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                if id == .profileHosting { Text("In memory · Unix socket · No TCP port").font(.caption2).foregroundStyle(.secondary) }
                HStack(spacing: 4) {
                    if id == .profileHosting {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(MimoRuntime.blockingProfile.path, forType: .string) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11)).frame(width: 14, height: 14)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Copy startup profile file path").help("Copy startup profile file path")
                    }
                    Text(serviceEndpoint(id, status: status)).font(.system(size: 10, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .help(id == .profileHosting ? "Credential-free startup profile: \(MimoRuntime.blockingProfile.path). The runtime profile is delivered in memory." : serviceEndpoint(id, status: status))
                }
            }.padding(.leading, 26)
            if id != MimoServiceID.allCases.last { Divider().padding(.top, 1) }
        }.padding(.top, 1).frame(maxHeight: .infinity)
    }

    private func serviceButtons(_ id: MimoServiceID, health: MimoServiceHealth) -> some View {
        HStack(spacing: 4) {
            if id == .profileHosting {
                Button("Open profile") { Task { openedProfile = await monitor.openProfile() } }.disabled(monitor.serviceOperation != nil || health == .unavailable)
                Button("Reload") { monitor.changeService(.profileHosting, operation: .restart) }.disabled(monitor.serviceOperation != nil || health == .unavailable)
                    .help("Regenerate the profile and verify again before protected traffic resumes.")
            } else {
                ForEach([MimoServiceOperation.start, .stop, .restart], id: \.rawValue) { operation in
                    Button(operation.rawValue.capitalized) { monitor.changeService(id, operation: operation) }
                        .disabled(monitor.serviceOperation != nil || (id == .tailnetProvider && !monitor.canChangeSharedSettings) || (operation == .start && health == .running) || (operation != .start && health == .stopped))
                        .accessibilityLabel("\(operation.rawValue.capitalized) \(id.title)")
                        .help(id == .tailnetProvider ? "Tailscale reconnecting starts this provider automatically. Stopping it while Tailscale is running reports a failure." : "\(operation.rawValue.capitalized) \(id.title)")
                }
            }
        }.font(serviceControlFont).controlSize(.small)
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
        switch id { case .core: "cpu"; case .mihomo, .tailnetProvider: "network"; case .profileHosting: "doc.text" }
    }
    private func serviceEndpoint(_ id: MimoServiceID, status: MimoServiceStatus?) -> String {
        switch id {
        case .core: "XPC / Mach · No TCP port"
        case .profileHosting: MimoRuntime.blockingProfile.path
        case .mihomo: "127.0.0.1 · Proxy \(String(status?.port ?? 7890)) · DNS \(String(MimoRuntime.dnsPort))"
        case .tailnetProvider: "\(status?.address ?? "127.0.0.1"):\(String(status?.port ?? 18766)) · HTTP"
        }
    }
    private var accessTitle: String {
        switch presentation.kind {
        case .directWarning: "Check failed"
        case .tailnetWarning: "Tailnet unavailable"
        case .checking: presentation.isRestoringDirect ? "Switching to Direct" : presentation.isClosing ? "Applying mode" : presentation.trafficIsBlocked ? "Blocked · Checking" : "Checking"
        case .unavailable: "Unavailable"
        case .blocked: "Blocked"
        case .direct, .verified: "Allowed"
        }
    }
    private var accessHeading: String {
        switch presentation.kind {
        case .direct: "You’re connected directly."
        case .verified: "You’re connected. Exit IP approved."
        case .blocked: "Internet is blocked."
        case .checking:
            presentation.isRestoringDirect ? "Switching to direct connection…" : presentation.isClosing ? "Closing internet access…" : presentation.trafficIsBlocked
                ? (presentation.isValidating ? "Blocked · Validating profile…" : "Blocked · Checking exit IP…")
                : "Checking your exit IP…"
        case .directWarning: "Direct · IP check unavailable."
        case .tailnetWarning: "Connected · Tailnet unavailable."
        case .unavailable: "Status is unavailable."
        }
    }
    private var accessColor: Color {
        switch presentation.kind {
        case .direct, .verified: .blue
        case .checking, .directWarning, .tailnetWarning: .orange
        case .blocked: .red
        case .unavailable: .secondary
        }
    }
    private var routeTitle: String {
        if !monitor.connected { return "Status unknown" }
        if presentation.isRestoringDirect { return "Switching to Direct" }
        if presentation.isDirect { return "Direct connection" }
        if !routing.allowsTraffic { return "Internet blocked" }
        return routing.configuration.mode == .rule ? "Profile rules" : "Proxy public internet"
    }
    private var tailnetNote: String {
        if routing.services.first(where: { $0.id == .tailnetProvider })?.health == .running { return "LAN & Tailscale stay local" }
        return presentation.isDirect ? "Direct routing · Tailnet provider stopped" : "LAN stays local · Tailnet access blocked"
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
                        if navigation.section != .general && monitor.connected && monitor.daemonState?.initialized != true {
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
        case .allowedIPs: allowlist
        case .monitoring: monitoring(scrollProxy: scrollProxy)
        case .general:
            Form {
                Section("Login item & appearance") {
                    LaunchAtLoginControl()
                    Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    Toggle("Reduce transparency", isOn: $reduceTransparency)
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

    private var allowlist: some View {
        MimoCard("Allowed exit IPs") {
            VStack(alignment: .leading, spacing: 12) {
                if monitor.allowedIPList.isEmpty { Text("No addresses yet. Rule and Global remain blocked.").foregroundStyle(.secondary) }
                ForEach(monitor.allowedIPList.addresses, id: \.self) { ip in
                    HStack { Text(ip).monospaced().textSelection(.enabled); Spacer(); Button { monitor.removeAllowedIP(ip) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove \(ip)") }
                }
                HStack {
                    TextField("IPv4 address", text: $address)
                    Button("Add") {
                        guard let normalized = IPAddressValidator.normalize(address), !normalized.contains(":") else { validationError = "Enter a valid IPv4 address. Mimo does not support IPv6."; return }
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
                    systemEvent("Network changes", action: "Check immediately")
                    systemEvent("Traffic", action: "IPv4 only · IPv6 disabled")
                        .help("IPv6 stays disabled while Mimo is installed, including Direct. Uninstall restores the previous network-service settings.")
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
                    Text("Direct stays open during IP checks. Failed required checks keep Rule / Global blocked.")
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
                        }
                    }
                    Text("Mimo uses 80% of capped quotas; remaining is Mimo’s allowance. Counts reset at midnight UTC for this Mac. Other devices may share a provider’s quota. IPinfo Lite is unlimited with a token.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("Shared IPinfo token", text: $token)
                    HStack {
                        Button("Import saved token") { Task { _ = await monitor.loadIPinfoToken() } }
                        Button("Save token") { Task { if await monitor.saveIPinfoToken(token) { token = "" } } }.disabled(token.isEmpty)
                        Button("Remove token") { Task { _ = await monitor.removeIPinfoToken() } }
                    }.controlSize(.small).disabled(monitor.isCredentialBusy)
                    Text(monitor.ipinfoCredentialStatus).font(.caption).foregroundStyle(.secondary)
                }.disabled(!monitor.canChangeSharedSettings)
            }
            MimoCard("System & network events") {
                VStack(alignment: .leading, spacing: 7) {
                    systemEvent("Wi-Fi, Ethernet, addresses & gateways", action: "Block → Check IP")
                    systemEvent("DNS, proxy, routes, interfaces & VPN", action: "Block → Check IP")
                    systemEvent("Sleep → Wake / cancelled sleep", action: "Block → Check before reopening")
                    systemEvent("Reboot / service recovery", action: "Restore protection → Verify")
                    systemEvent("Login / user switch / display wake", action: "Refresh shared status")
                    systemEvent("Logout / lock / close Mimo", action: "Shared protection continues")
                    Text("Blocking applies to Rule / Global. VPN events include connect, disconnect and configuration changes. Login or display wake alone refreshes status. Notifications are asynchronous; remote exit-IP changes need routine or manual checks.")
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
        MimoCard("Shared proxy configuration") {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow { Text("Name"); TextField("Proxy name", text: $draft.name) }
                    GridRow { Text("Type"); Picker("Type", selection: $draft.type) { ForEach(ClashProxySettings.ProxyType.allCases) { Text($0.displayName).tag($0) } }.labelsHidden() }
                    GridRow { Text("Server"); TextField("proxy.example.com", text: $draft.server) }
                    GridRow { Text("Port"); TextField("1080", text: $draft.port) }
                    GridRow { Text("Username"); TextField("Optional", text: $draft.username) }
                    GridRow { Text("Password"); SecureField(monitor.routingState.hasProxyPassword ? "Saved in System Keychain" : "Optional", text: $draft.password) }
                }.textFieldStyle(.roundedBorder).disabled(unavailable || monitor.isChangingSettings)
                if monitor.routingState.hasProxyPassword { Toggle("Remove the saved password", isOn: $draft.clearPassword).disabled(unavailable || monitor.isChangingSettings) }
                if conflicting {
                    Text("Shared settings changed while this form was open. Your draft is preserved. Reload the latest settings before saving.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Reload and discard draft") { load(); error = nil }
                        .disabled(unavailable || monitor.isChangingSettings)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.primary) }
                HStack {
                    Button("Save and apply") { save() }.mimoGlassButton()
                    Button("Remove", role: .destructive) { confirmRemoval = true }
                    Spacer()
                    Button("Import my saved proxy") {
                        guard let revision = draft.revision else { return }
                        Task { if await monitor.importLegacyProxy(expectedRevision: revision) { load() } }
                    }
                }.disabled(unavailable || conflicting || monitor.isChangingSettings)
                Text("Shared across this Mac. No administrator password is needed after installation. Legacy Keychain entries are retained after import.").font(.caption).foregroundStyle(.secondary)
            }
        }.onChange(of: monitor.daemonState?.revision, initial: true) { _, _ in draft.receive(monitor.daemonState) }
            .onChange(of: monitor.daemonState?.initialized) { _, _ in draft.receive(monitor.daemonState) }
            .confirmationDialog("Remove the shared proxy?", isPresented: $confirmRemoval) {
                Button("Remove proxy", role: .destructive) {
                    guard let revision = draft.revision else { return }
                    Task { if await monitor.removeProxy(expectedRevision: revision) { load() } }
                }
            } message: { Text("Rule and Global will remain blocked. Direct stays available.") }
    }
    private func load() {
        draft.receive(monitor.daemonState, discardChanges: true)
    }
    private func save() {
        do {
            guard let revision = draft.revision else { return }
            let value = try draft.validatedProxy(), password = draft.passwordChange
            Task { if await monitor.saveProxy(value, password: password, expectedRevision: revision) { error = nil; load() } }
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
