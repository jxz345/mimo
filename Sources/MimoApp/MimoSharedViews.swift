import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarCountryLabel: View {
    let snapshot: MimoSnapshot?
    let displayStyle: MenuBarDisplayStyle
    let refreshInterval: RefreshInterval
    let indicators: MonitorIndicatorState
    /// The verified exit IP is outside the allowlist (warn-only).
    let outsideAllowlist: Bool
    let date: Date

    /// A red stop sign beside the location. After a failed lookup the error stop sign replaces the
    /// flag instead, so this one is not added.
    var showsAllowlistStop: Bool { outsideAllowlist && !indicators.suppressLocation }

    /// The red stop sign shown beside the location while the exit IP is outside the allowlist.
    static var allowlistStop: some View {
        Image(systemName: MimoIndicatorSymbol.outsideAllowlist)
            .foregroundStyle(.red)
            .accessibilityLabel("Not on the allowlist")
    }

    var body: some View {
        let isChanged = !indicators.suppressLocation && (snapshot?.isCountryChangeHighlighted(at: date) ?? false)
        HStack(spacing: 3) {
            if indicators.suppressLocation {
                // A stop sign in place of the flag; text styles also say so in words.
                Image(systemName: MimoIndicatorSymbol.lookupError)
                    .foregroundStyle(.red)
                if displayStyle != .flag {
                    Text("Exit IP error")
                        .lineLimit(1)
                }
            } else {
                Text(statusLabel(at: date))
                    .lineLimit(1)
                    .fontWeight(isChanged ? .bold : .regular)
            }
            if showsAllowlistStop {
                Self.allowlistStop
            }
            if isChanged {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Country changed")
            }
        }
        .padding(.horizontal, isChanged ? 4 : 0)
        .padding(.vertical, isChanged ? 2 : 0)
        .background(isChanged ? Color.yellow.opacity(0.24) : .clear, in: Capsule())
        .accessibilityLabel(accessibilityText(at: date))
    }

    /// Everything that changes what this menu-bar label draws.
    var visualKey: String {
        let isChanged = !indicators.suppressLocation && (snapshot?.isCountryChangeHighlighted(at: date) ?? false)
        return [displayStyle.rawValue, indicators.suppressLocation ? "error" : statusLabel(at: date),
                isChanged ? "changed" : "-", showsAllowlistStop ? "outside" : "-"].joined(separator: "|")
    }

    func accessibilityText(at date: Date) -> String {
        if indicators.suppressLocation { return "Exit IP error" }
        let allowlist = showsAllowlistStop ? ", not on the allowlist" : ""
        guard let snapshot else { return "Exit IP location unavailable" + allowlist }
        let stale = snapshot.isStale(at: date, threshold: refreshInterval.snapshotStaleThreshold)
        if snapshot.isCountryChangeHighlighted(at: date) {
            return "Exit IP country changed from \(snapshot.countryChange?.previousName ?? "previous location") to \(snapshot.countryName)" + allowlist + (stale ? ", data is stale" : "")
        }
        return "Exit IP country: \(snapshot.countryName)" + allowlist + (stale ? ", data is stale" : "")
    }

    private func statusLabel(at date: Date) -> String {
        guard !indicators.suppressLocation else { return "Exit IP error" }
        guard let snapshot else { return "Locating" }
        let label = snapshot.menuBarLabel(style: displayStyle)
        return snapshot.isStale(at: date, threshold: refreshInterval.snapshotStaleThreshold) ? "Stale · \(label)" : label
    }
}

struct LaunchAtLoginControl: View {
    /// The dashboard's one-row form: toggle and Login Items button side by side, explanation as help.
    var compact = false
    var dashboardStyle = false
    @ObservedObject private var loginItem = LoginItemController.shared

    private static let label = "Show menu-bar app at login"
    private static let serviceExplanation = "mimo-core starts at boot and keeps running when you quit Mimo’s interface."
    private static let explanation = "Show Mimo's menu-bar interface when this account logs in. " + serviceExplanation + " This switch does not change the system services."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dashboardStyle {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.label)
                        Text(statusMessage ?? "This account · Interface only").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    toggle.labelsHidden().toggleStyle(.switch).controlSize(.small)
                }.help(statusMessage ?? Self.explanation)
                Text(Self.serviceExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if compact {
                HStack {
                    toggle
                    Spacer()
                    Button("Login Items…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                .help(Self.explanation)
            } else {
                toggle
                Text(Self.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let statusMessage, !dashboardStyle {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if !compact {
                Button("Open Login Items Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var toggle: some View {
        Toggle(Self.label, isOn: Binding(
            get: { loginItem.status.map { $0 == .enabled } ?? LoginItemSync.storedChoice ?? false },
            set: { loginItem.setEnabled($0) }
        )).disabled(loginItem.isBusy || loginItem.status == nil)
    }

    private var statusMessage: String? {
        if let errorMessage = loginItem.errorMessage { return errorMessage }
        if loginItem.isBusy || loginItem.status == nil { return "Checking login-item setting…" }
        return loginItem.status == .requiresApproval ? "macOS requires approval in Login Items Settings." : nil
    }
}

