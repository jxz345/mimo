import Foundation

public enum ProviderFailurePolicy {
    public static let pauseInterval: TimeInterval = 10 * 60

    /// Never shorten a longer Retry-After supplied by the provider itself.
    public static func resumeAt(after error: LookupError, now: Date) -> Date {
        max(now.addingTimeInterval(pauseInterval), error.retryAfter ?? now)
    }

    /// The ten-minute automatic backoff is not a provider restriction when no
    /// Retry-After/refusal was received. An explicit repair/Retry can try once;
    /// daily budgets and any subsequent provider restriction still apply.
    public static func allowsExplicitRetry(after error: LookupError) -> Bool {
        guard error.retryAfter == nil, !error.pausesProvider else { return false }
        if case .httpStatus(407, _) = error { return true } // Proxy authentication.
        return error.supportsResilienceRetry
    }

    public static func reason(_ category: String?) -> String {
        switch category {
        case "transport": "Connection failed"
        case "invalid_response": "Invalid IP response"
        case "rate_limited": "Rate limited"
        case "missing_token": "Token required"
        case "provider_error": "Provider error"
        case let code? where code.hasPrefix("http_"): "HTTP \(code.dropFirst(5))"
        case let value?: value.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: "Provider unavailable"
        }
    }
}
