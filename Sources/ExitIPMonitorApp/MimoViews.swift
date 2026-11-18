import AppKit
import ServiceManagement
import SwiftUI

enum MimoSettingsSection: String, CaseIterable, Identifiable {
    case proxy = "Proxy", allowedIPs = "Allowed IPs", monitoring = "Monitoring", services = "Background services", general = "General"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .proxy: "point.3.connected.trianglepath.dotted"; case .allowedIPs: "checkmark.shield"; case .monitoring: "clock"; case .services: "cpu"; case .general: "gear" }
    }
}

@MainActor
final class MimoSettingsNavigation: ObservableObject {
    static let shared = MimoSettingsNavigation()
    @Published var section: MimoSettingsSection = .general
    static func open(_ section: MimoSettingsSection) { shared.section = section; ExitIPAppDelegate.showSettings() }
}

struct DashboardView: View {
    @ObservedObject var monitor: PublicIPMonitor
    @StateObject private var installer = DaemonInstallationModel()
    private var routing: MimoRoutingState { monitor.routingState }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Overview").font(.headline)
                Spacer()
                Button { ExitIPAppDelegate.showSettings() } label: { Label("Settings", systemImage: "gear") }
                Button { Task { await monitor.refresh() } } label: {
                    Label("Refresh now", systemImage: "arrow.clockwise").foregroundStyle(.primary)
                }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!monitor.connected || monitor.daemonState?.initialized != true || routing.phase == .checking || routing.phase == .validating)
                    .mimoGlassButton()
            }.padding(.horizontal, 20).padding(.vertical, 12).modifier(MimoBarBackground())
            Divider()
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Routing mode").font(.headline)
                                Text(routing.configuration.mode == .direct ? "Normal networking, without a proxy." : "Verify the exit before opening traffic.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Routing mode", selection: Binding(get: { routing.configuration.mode }, set: monitor.setMode)) {
                                ForEach(ProxyMode.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                                .disabled(!monitor.connected || monitor.daemonState?.initialized != true || monitor.isChangingSettings)
                        }
                        let layout = geometry.size.width >= 840 ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
                        layout {
                            connection.frame(maxWidth: .infinity, alignment: .topLeading)
                            services.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }.padding(20)
                }
            }
            Divider()
            HStack {
                Button("Event Log") { ExitIPAppDelegate.showEventLog() }
                Spacer()
                Text("Routing and monitoring continue when this window closes.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit GUI") { NSApp.terminate(nil) }
            }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 10).modifier(MimoBarBackground())
        }.tint(.blue).modifier(MimoAppearance())
    }

    private var connection: some View {
        MimoCard("Current connection") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(routing.blockingIP != nil && routing.phase != .unavailable ? "IP that triggered blocking" : routing.displayedIP != nil ? "Checked IP address" : routing.phase == .checking ? "Checking IP…" : "IP unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(routing.displayedIP?.address ?? "—")
                            .font(.system(size: routing.displayedIP?.address.contains(":") == true ? 17 : 23, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if let address = routing.displayedIP?.address {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy displayed IP address")
                    }
                }
                LabeledContent("IP check") { if let date = routing.displayedIP?.checkedAt { Text(date, style: .relative) } else { Text("No result") } }
                if let snapshot = monitor.snapshot, snapshot.ipAddress == routing.displayedIP?.address {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.locationSummary).font(.callout)
                        if let organization = snapshot.organization, !organization.isEmpty {
                            Text(organization).font(.caption)
                        }
                    }.foregroundStyle(.secondary)
                }
                LabeledContent("Allowed IPs") {
                    Button("\(monitor.allowedIPList.addresses.count) \(monitor.allowedIPList.addresses.count == 1 ? "address" : "addresses")") {
                        MimoSettingsNavigation.open(.allowedIPs)
                    }.buttonStyle(.link)
                }
                Divider()
                HStack {
                    Text("Selected profile").foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit") { MimoSettingsNavigation.open(.proxy) }.buttonStyle(.link)
                }
                Text(routing.configuration.proxy?.name ?? "No saved profile").font(.headline)
                Text(routing.configuration.proxy.map { "\($0.type.displayName) · 38 Rule-mode rules" } ?? "Add a proxy in Settings").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(monitor.preferences.refreshInterval.displayName).foregroundStyle(.secondary)
                    Spacer(); Button("Configure") { MimoSettingsNavigation.open(.monitoring) }.buttonStyle(.link)
                }
                Divider()
                LaunchAtLoginControl(compact: true)
            }.font(.callout)
        }
    }

    private var services: some View {
        MimoCard("Background services") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: accessSymbol).font(.title2).foregroundStyle(accessColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Internet access · \(accessTitle)").font(.headline)
                        Text(routing.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if routing.configuration.mode.requiresVerification && !routing.allowsTraffic {
                            HStack {
                                Button("Retry verification") { Task { await monitor.refresh() } }
                                    .disabled(!monitor.connected || monitor.daemonState?.initialized != true || routing.phase == .checking || routing.phase == .validating)
                                Button("Use Direct") { monitor.setMode(.direct) }
                                    .disabled(!monitor.connected || monitor.daemonState?.initialized != true || monitor.isChangingSettings)
                            }.controlSize(.small)
                        }
                    }
                }
                if !monitor.connected {
                    Button(installer.serviceInstalled ? "Repair installation" : "Set up services") { installer.install() }.disabled(installer.isInstalling)
                } else if monitor.daemonState?.initialized != true {
                    Button("Initialize shared settings") { Task { await monitor.initializeSharedSettings() } }.disabled(monitor.isChangingSettings)
                }
                ForEach(MimoServiceID.allCases) { service in serviceRow(service) }
                HStack {
                    Text("Shared across this Mac").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("Ports") { MimoSettingsNavigation.open(.services) }.buttonStyle(.link)
                }
                if let error = monitor.operationError ?? installer.message { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func serviceRow(_ id: MimoServiceID) -> some View {
        let health = routing.services.first { $0.id == id }?.health ?? .unavailable
        return VStack(spacing: 9) {
            Divider()
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(id.title).font(.callout.weight(.medium))
                    Text(monitor.serviceOperation == id ? "Working…" : health.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    ForEach([MimoServiceOperation.start, .stop, .restart], id: \.rawValue) { operation in
                        Button(operation.rawValue.capitalized) { monitor.changeService(id, operation: operation) }
                            .disabled(monitor.serviceOperation != nil || (operation == .start && health == .running) || (operation != .start && health == .stopped))
                            .accessibilityLabel("\(operation.rawValue.capitalized) \(id.title)")
                    }
                }.controlSize(.small)
            }
        }
    }
    private var accessTitle: String {
        switch routing.phase {
        case .unavailable: "Unavailable"
        case .validating: "Validating"
        case .checking: "Checking exit IP"
        case .active: routing.allowsTraffic ? "Allowed" : "Unavailable"
        case .blocked: "Blocked"
        }
    }
    private var accessSymbol: String {
        switch routing.phase {
        case .unavailable: "info.circle"
        case .checking, .validating: "clock"
        case .active: routing.allowsTraffic ? (routing.configuration.mode == .direct ? "arrow.up.right" : "checkmark.shield") : "info.circle"
        case .blocked: "hand.raised"
        }
    }
    private var accessColor: Color { routing.phase == .unavailable ? .secondary : routing.phase == .blocked ? .red : .blue }
}

struct SettingsView: View {
    @ObservedObject var monitor: PublicIPMonitor
    @ObservedObject private var navigation = MimoSettingsNavigation.shared
    @AppStorage("mimo.appearance") private var appearance = "system"
    @AppStorage("mimo.reduceTransparency") private var reduceTransparency = false
    @State private var address = ""
    @State private var validationError: String?
    @State private var token = ""
    @State private var proxyDraft = MimoProxyDraft()

    var body: some View {
        NavigationSplitView {
            List(MimoSettingsSection.allCases, selection: $navigation.section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }.navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(navigation.section.rawValue).font(.largeTitle.weight(.semibold))
                    content
                    if let error = monitor.operationError { Text(error).foregroundStyle(.red).font(.callout) }
                }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }.tint(.blue).modifier(MimoAppearance())
    }

    @ViewBuilder private var content: some View {
        switch navigation.section {
        case .proxy: MimoProxyForm(monitor: monitor, draft: $proxyDraft)
        case .allowedIPs: allowlist
        case .monitoring: monitoring
        case .services: serviceDetails
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
                }.disabled(!monitor.connected || monitor.isChangingSettings)
                if let validationError { Text(validationError).font(.caption).foregroundStyle(.red) }
                Text("Approval is explicit. Retries never add an IP automatically. Direct bypasses this check.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var monitoring: some View {
        VStack(alignment: .leading, spacing: 16) {
            MimoCard("Verification") {
                VStack(spacing: 14) {
                    Picker("Routine interval", selection: Binding(get: { monitor.preferences.refreshInterval }, set: { value in var preferences = monitor.preferences; preferences.refreshInterval = value; monitor.apply(preferences) })) {
                        ForEach(RefreshInterval.allCases) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent("When network settings change", value: "Immediately")
                    LabeledContent("IP protocol", value: "IPv4 only")
                    Text("IPv6 stays disabled while Mimo is installed, including in Direct. Uninstall restores the previous network-service settings.").font(.caption).foregroundStyle(.secondary)
                    Text("Every change to Wi-Fi, DNS, routes, interfaces, proxies, or VPN configuration requests a fresh check. Wake also triggers a check. Protected traffic closes first.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("On a failed required check"); Spacer(); Text("Block Rule / Global") }
                    Button("Check now") { Task { await monitor.refresh() } }.disabled(!monitor.connected)
                }
            }
            MimoCard("Lookup providers") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ProviderID.allCases) { provider in
                        Toggle(provider.displayName, isOn: Binding(get: { monitor.preferences.providerPool.contains(provider) }, set: { enabled in
                            var preferences = monitor.preferences
                            if enabled { preferences.providerPool.append(provider) } else { preferences.providerPool.removeAll { $0 == provider } }
                            guard let first = preferences.providerPool.first else { return }
                            if !preferences.providerPool.contains(preferences.provider) { preferences.provider = first }
                            monitor.apply(preferences)
                        }))
                        Text("\(monitor.lookupBudget.callsToday(for: provider)) requests today").font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("Shared IPinfo token", text: $token)
                    HStack {
                        Button("Import saved token") { Task { _ = await monitor.loadIPinfoToken() } }
                        Button("Save token") { Task { if await monitor.saveIPinfoToken(token) { token = "" } } }.disabled(token.isEmpty)
                        Button("Remove token") { Task { _ = await monitor.removeIPinfoToken() } }
                    }.controlSize(.small).disabled(monitor.isCredentialBusy)
                    Text(monitor.ipinfoCredentialStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var serviceDetails: some View {
        MimoCard("Service ports and transports") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(MimoServiceID.allCases) { id in
                    let status = monitor.routingState.services.first { $0.id == id }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(id.title).font(.headline)
                            Text(status?.transport ?? (id == .core ? "XPC / Mach" : id == .profileHosting ? "Private file delivery" : "Runtime unavailable")).font(.caption).foregroundStyle(.secondary)
                            if let address = status?.address { Text(address).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(status?.port.map(String.init) ?? (id == .core || id == .profileHosting ? "No TCP port" : "Unavailable")).monospaced()
                            if id == .mihomo { Text("DNS · 127.0.0.1:\(MimoRuntime.dnsPort)").font(.caption.monospaced()) }
                            Text(status?.bindingConfirmed == true ? "Listening confirmed" : "Configured / unconfirmed").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
                Text("Configured ports remain visible when stopped. Control service lifecycle from the dashboard.").font(.caption).foregroundStyle(.secondary)
                Button("Open dashboard") { ExitIPAppDelegate.showDashboard() }
            }
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
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Save and apply") { save() }.mimoGlassButton()
                    Button("Remove", role: .destructive) { confirmRemoval = true }
                    Spacer()
                    Button("Import my saved proxy") {
                        guard let revision = draft.revision else { return }
                        Task { if await monitor.importLegacyProxy(expectedRevision: revision) { load() } }
                    }
                }.disabled(unavailable || conflicting || monitor.isChangingSettings)
                Text("Shared across this Mac. Administrator authorization is required. Legacy Keychain entries are retained after import.").font(.caption).foregroundStyle(.secondary)
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

private struct MimoAppearance: ViewModifier {
    @AppStorage("mimo.appearance") private var appearance = "system"
    @AppStorage("mimo.reduceTransparency") private var reduceTransparency = false
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
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
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private extension View {
    func mimoGlassButton() -> some View { modifier(MimoGlassButton()) }
}
