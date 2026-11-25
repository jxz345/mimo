import Foundation

/// One presentation policy for the menu bar, dashboard, widgets, and Control Center. A location alone
/// never implies that the supervisor has opened traffic.
public struct MimoStatusPresentation: Equatable, Sendable {
    public enum Kind: String, Sendable { case direct, directWarning, checking, blocked, verified, unavailable }
    public let kind: Kind
    public let title: String
    public let detail: String
    public let address: String?
    public let country: String?
    public let countryChanged: Bool
    public let isDirect: Bool
    public let trafficIsBlocked: Bool
    public let isValidating: Bool
    public let isCheckingReadiness: Bool
    public let isClosing: Bool
    public let isRestoringDirect: Bool
    public let isBackgroundVerification: Bool

    public init(routing: MimoRoutingState, snapshot: MimoSnapshot?, preferences: MonitoringPreferences, date: Date, monitoringStatus: MonitoringStatus = .ready) {
        isDirect = routing.phase == .active && routing.allowsTraffic && routing.effectiveMode == .direct
        trafficIsBlocked = routing.phase == .blocked || (routing.configuration.mode.requiresVerification
            && [.validating, .checking].contains(routing.phase))
        isValidating = routing.phase == .validating
        isCheckingReadiness = routing.phase == .checking && routing.observedIP != nil
        isClosing = routing.phase == .closing
        isRestoringDirect = routing.phase == .restoringDirect
        isBackgroundVerification = routing.allowsTraffic && routing.configuration.mode.requiresVerification && routing.backgroundVerification == true
        switch routing.phase {
        case .unavailable:
            kind = .unavailable
        case .closing, .checking, .validating, .restoringDirect:
            kind = .checking
        case .blocked:
            kind = .blocked
        case .active:
            if !routing.allowsTraffic { kind = .unavailable }
            else if routing.effectiveMode == .direct {
                switch monitoringStatus {
                case .refreshing: kind = .checking
                case .failed, .awaitingConfirmation, .waitingForIPinfoToken, .coolingDown, .providerPaused: kind = .directWarning
                default: kind = .direct
                }
            }
            else { kind = .verified }
        }
        address = kind == .unavailable ? nil : routing.displayedIP?.address
        let locationIsCurrent = snapshot?.ipAddress == routing.observedIP?.address
        country = snapshot?.hasValidCountryCode == true &&
            (kind == .blocked || ((isDirect || kind == .verified) && locationIsCurrent))
            ? snapshot?.menuBarLabel(style: preferences.menuBarDisplayStyle) : nil
        countryChanged = (kind == .direct || kind == .verified) && country != nil
            && preferences.highlightCountryChanges && (snapshot?.isCountryChangeHighlighted(at: date) ?? false)
        switch kind {
        case .direct: title = routing.networkReleased == true ? "Direct · Engine stopped" : "Direct · No proxy"
        case .directWarning: title = "Direct · IP check unavailable"
        case .checking:
            title = isRestoringDirect ? (routing.networkReleaseRequested == true ? "Restoring networking" : "Switching to Direct") : isClosing ? "\(routing.configuration.mode.title) · Closing traffic" : trafficIsBlocked
                ? "\(routing.configuration.mode.title) · Blocked · \(isValidating ? "Validating profile" : isCheckingReadiness ? "Checking readiness" : "Checking exit IP")"
                : "\(routing.configuration.mode.title) · Checking exit IP"
        case .blocked: title = "\(routing.configuration.mode.title) · Internet blocked"
        case .verified: title = "\(routing.configuration.mode.title) · Allowed"
        case .unavailable: title = "Mimo · Status unavailable"
        }
        if kind == .verified {
            detail = "Exit IP approved. Internet is allowed."
        } else if kind == .directWarning {
            let reason: String
            switch monitoringStatus {
            case .failed(let message), .awaitingConfirmation(let message): reason = message
            case .waitingForIPinfoToken: reason = "Save an IPinfo token in Settings → Monitoring."
            default: reason = "Lookup providers are paused or out of budget."
            }
            detail = "Direct remains selected. \(reason)"
        } else if kind == .checking && routing.effectiveMode == .direct {
            detail = "Checking the exit IP. Direct remains selected."
        } else if kind == .unavailable, routing.phase != .unavailable {
            detail = "The routing state could not be confirmed. Open Dashboard to reconnect."
        } else if kind == .blocked, case .failed(let message) = monitoringStatus {
            // A later gate-close notification may have a generic reason. Keep
            // the failed verification's actionable cause visible in every UI.
            if let rejected = routing.blockingIP, !message.contains(rejected.address) {
                detail = "IP that triggered blocking: \(rejected.address). \(message)"
            } else { detail = message }
        } else if let rejected = routing.blockingIP, kind != .unavailable {
            detail = routing.reason.contains(rejected.address) ? routing.reason
                : "IP that triggered blocking: \(rejected.address). \(routing.reason)"
        } else { detail = routing.reason }
    }

    /// Remains visible after a fast check, without delaying the real firewall or
    /// replaying stale status. An active protected state proves these steps passed.
    public var verificationProgress: String? {
        guard !isDirect else { return nil }
        switch kind {
        case .checking where trafficIsBlocked:
            return isValidating ? "Traffic blocked → Validate profile → Check IP → Reopen if allowed"
                : isCheckingReadiness ? "Traffic blocked → Exit IP approved → Checking readiness" : "Traffic blocked → Checking exit IP → Reopen if allowed"
        case .verified:
            return "Traffic blocked → Exit IP approved → Internet reopened"
        default: return nil
        }
    }

    public var visualKey: String { "\(kind.rawValue)|\(country ?? "")|\(countryChanged)|\(isDirect)|\(trafficIsBlocked)|\(isValidating)|\(isCheckingReadiness)|\(isClosing)|\(isRestoringDirect)" }
    public var symbol: String {
        switch kind {
        case .direct: "arrow.up.right"
        case .directWarning: "exclamationmark.triangle"
        case .checking: "clock"
        case .blocked: MimoIndicatorSymbol.outsideAllowlist
        case .verified: "checkmark.shield"
        case .unavailable: "info.circle"
        }
    }
    public var accessibilityText: String {
        [title, detail, address.map { "IP address \($0)" }].compactMap { $0 }.joined(separator: ". ")
    }
}
