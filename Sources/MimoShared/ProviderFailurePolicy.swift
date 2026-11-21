import Foundation

public enum ProviderFailurePolicy {
    public static let pauseInterval: TimeInterval = 8 * 60 * 60

    /// Never shorten a longer Retry-After supplied by the provider itself.
    public static func resumeAt(after error: LookupError, now: Date) -> Date {
        max(now.addingTimeInterval(pauseInterval), error.retryAfter ?? now)
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
