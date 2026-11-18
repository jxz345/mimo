import Foundation

/// One presentation policy for the menu bar, Dock, widgets, and Control Center. A location alone
/// never implies that the supervisor has opened traffic.
public struct MimoStatusPresentation: Equatable, Sendable {
    public enum Kind: String, Sendable { case direct, checking, blocked, verified, tailnetWarning, unavailable }
    public let kind: Kind
    public let title: String
    public let detail: String
    public let address: String?
    public let country: String?
    public let countryChanged: Bool

    public init(routing: MimoRoutingState, snapshot: ExitIPSnapshot?, preferences: MonitoringPreferences, date: Date) {
        switch routing.phase {
        case .unavailable:
            kind = .unavailable
        case .checking, .validating:
            kind = .checking
        case .blocked:
            kind = .blocked
        case .active:
            if !routing.allowsTraffic { kind = .unavailable }
            else if routing.effectiveMode == .direct { kind = .direct }
            else if let tailnet = routing.services.first(where: { $0.id == .tailnetProvider }), tailnet.health != .running {
                kind = .tailnetWarning
            } else { kind = .verified }
        }
        address = kind == .unavailable ? nil : routing.displayedIP?.address
        let locationIsCurrent = snapshot?.ipAddress == routing.observedIP?.address
        country = kind == .blocked || ((kind == .verified || kind == .tailnetWarning) && locationIsCurrent)
            ? snapshot?.menuBarLabel(style: preferences.menuBarDisplayStyle) : nil
        countryChanged = (kind == .verified || kind == .tailnetWarning) && country != nil
            && preferences.highlightCountryChanges && (snapshot?.isCountryChangeHighlighted(at: date) ?? false)
        switch kind {
        case .direct: title = "Direct · No proxy"
        case .checking: title = "\(routing.configuration.mode.title) · Checking exit IP"
        case .blocked: title = "\(routing.configuration.mode.title) · Internet blocked"
        case .verified: title = "\(routing.configuration.mode.title) · Exit approved"
        case .tailnetWarning: title = "\(routing.configuration.mode.title) · Tailnet unavailable"
        case .unavailable: title = "Mimo · Status unavailable"
        }
        if kind == .unavailable, routing.phase != .unavailable {
            detail = "The routing state could not be confirmed. Open Dashboard to reconnect."
        } else if kind == .tailnetWarning {
            detail = "Public access is approved. The tailnet provider is not running; protected tailnet routes reject."
        } else if let rejected = routing.blockingIP, kind != .unavailable {
            detail = "IP that triggered blocking: \(rejected.address). \(routing.reason)"
        } else { detail = routing.reason }
    }

    public var visualKey: String { "\(kind.rawValue)|\(country ?? "")|\(countryChanged)" }
    public var symbol: String {
        switch kind {
        case .direct: "arrow.up.right"
        case .checking: "clock"
        case .blocked: "hand.raised.fill"
        case .verified: "checkmark.shield"
        case .tailnetWarning: "exclamationmark.triangle"
        case .unavailable: "info.circle"
        }
    }
    public var accessibilityText: String {
        [title, detail, address.map { "IP address \($0)" }].compactMap { $0 }.joined(separator: ". ")
    }
}
