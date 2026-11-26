import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LookupError: Error, LocalizedError, Sendable, Equatable {
    case missingToken(ProviderID)
    case invalidResponse
    case httpStatus(Int, retryAfter: Date?)
    case rateLimited(retryAfter: Date?)
    case providerMessage(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken(let provider):
            "Add an API token for \(provider.displayName) in Settings."
        case .invalidResponse:
            "The IP-location service returned an invalid response."
        case .httpStatus(let status, _):
            "The IP-location service returned HTTP \(status)."
        case .rateLimited:
            "The IP-location service asked the app to slow down."
        case .providerMessage(let message):
            message
        case .transport(let message):
            message
        }
    }

    /// Rate limits and authentication failures are intentionally not routed to another vendor.
    /// This prevents provider rotation from being used to evade a service's usage limits.
    public var supportsResilienceRetry: Bool {
        switch self {
        case .transport, .invalidResponse:
            true
        case .httpStatus(let status, _):
            (500...599).contains(status)
        case .missingToken, .rateLimited, .providerMessage:
            false
        }
    }

    /// The provider is refusing this client—rate limit, exhausted quota, payment, or credentials—so it
    /// must be paused (per-provider cooldown) rather than retried or replaced by another vendor.
    public var pausesProvider: Bool {
        switch self {
        case .rateLimited:
            true
        case .httpStatus(let status, _):
            [401, 402, 403].contains(status)
        case .providerMessage(let message):
            Self.isQuotaMessage(message)
        case .missingToken, .invalidResponse, .transport:
            false
        }
    }

    /// Providers report quota exhaustion in the JSON body (e.g. ipapi.co `"reason": "RateLimited"`).
    static func isQuotaMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return ["ratelimit", "rate limit", "rate-limit", "quota", "limit exceeded", "too many", "exceeded", "hit the", "usage limit"]
            .contains { lowered.contains($0) }
    }

    public var retryAfter: Date? {
        switch self {
        case .httpStatus(_, let retryAfter), .rateLimited(let retryAfter):
            retryAfter
        default:
            nil
        }
    }

    public var category: String {
        switch self {
        case .missingToken: "missing_token"
        case .invalidResponse: "invalid_response"
        case .httpStatus(let status, _): "http_\(status)"
        case .rateLimited: "rate_limited"
        case .providerMessage: "provider_error"
        case .transport: "transport"
        }
    }
}

public struct LookupConfiguration: Sendable {
    public let provider: ProviderID
    public let ipinfoToken: String?
    public let family: MimoAddressFamily?
    public let lookupID: UUID?

    public init(provider: ProviderID, ipinfoToken: String?, family: MimoAddressFamily? = nil, lookupID: UUID? = nil) {
        self.provider = provider
        self.ipinfoToken = ipinfoToken
        self.family = family
        self.lookupID = lookupID
    }
}

/// Injectable boundary used by the monitor so provider behavior can be tested without network calls.
public protocol PublicIPLookupClientProtocol: Sendable {
    /// Includes any managed routing preparation/activation around the HTTP lookup.
    var lookupTimeout: Duration { get }
    var accountsActualRequests: Bool { get }
    func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot
    func confirmCountryChange(primaryProvider: ProviderID, ipinfoToken: String?) async throws -> MimoSnapshot
}

public extension PublicIPLookupClientProtocol {
    var lookupTimeout: Duration { .seconds(15) }
    var accountsActualRequests: Bool { false }
}

/// A confirmation request occurs only after a successful primary lookup reports a country change.
/// It is not a fallback path for quota errors or ordinary refresh failures.
public enum CountryChangeConfirmationPolicy {
    public static func secondaryProvider(for primary: ProviderID) -> ProviderID {
        primary == .ipWhois ? .ipapiCo : .ipWhois
    }
}

public protocol IPLocationProvider: Sendable {
    var id: ProviderID { get }
    func lookup(ipinfoToken: String?) async throws -> MimoSnapshot
}

public struct PublicIPLookupClient: Sendable, PublicIPLookupClientProtocol {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    /// Use a cache-free session with bounded request/resource time so failed connectivity
    /// returns to the provider rotation policy promptly.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false
        #endif
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    public func lookup(configuration: LookupConfiguration) async throws -> MimoSnapshot {
        let provider: any IPLocationProvider
        switch configuration.provider {
        case .ipinfoLite:
            provider = IPinfoLiteProvider(session: session, family: configuration.family)
        case .ipapiCo:
            provider = IpapiCoProvider(session: session)
        case .ipWhois:
            provider = IPWhoisProvider(session: session)
        case .ipapiIs:
            provider = IpapiIsProvider(session: session)
        }
        var snapshot = try await provider.lookup(ipinfoToken: configuration.ipinfoToken)
        try Task.checkCancellation()
        guard let address = IPAddressValidator.normalize(snapshot.ipAddress) else {
            throw LookupError.invalidResponse
        }
        snapshot.ipAddress = address
        if let countryCode = CountryCodeResolver.resolvedCode(
            code: snapshot.countryCode,
            countryName: snapshot.countryName
        ) {
            snapshot.countryCode = countryCode
        } else {
            // Geography is display metadata. A valid exit IP still goes through
            // the normal allowlist check; missing geography must not cause a
            // provider retry and another protected verification cycle.
            snapshot.countryCode = "--"
            snapshot.countryName = "Unknown"
        }
        return snapshot
    }

    public func confirmCountryChange(
        primaryProvider: ProviderID,
        ipinfoToken: String?
    ) async throws -> MimoSnapshot {
        let secondary = CountryChangeConfirmationPolicy.secondaryProvider(for: primaryProvider)
        return try await lookup(configuration: LookupConfiguration(provider: secondary, ipinfoToken: ipinfoToken))
    }
}

public struct IPinfoLiteProvider: IPLocationProvider {
    public let id: ProviderID = .ipinfoLite

    private let session: URLSession
    private let family: MimoAddressFamily?

    public init(session: URLSession = .shared, family: MimoAddressFamily? = nil) {
        self.session = session
        self.family = family
    }

    public func lookup(ipinfoToken: String?) async throws -> MimoSnapshot {
        guard let ipinfoToken, !ipinfoToken.isEmpty else {
            throw LookupError.missingToken(.ipinfoLite)
        }

        let response: IPinfoLiteResponse = try await JSONHTTPClient.get(
            URL(string: "https://\(family.map { $0 == .ipv4 ? "v4." : "v6." } ?? "")api.ipinfo.io/lite/me")!, session: session, bearerToken: ipinfoToken)
        guard !response.ip.isEmpty else { throw LookupError.invalidResponse }

        return MimoSnapshot(
            ipAddress: response.ip,
            countryCode: response.countryCode ?? "--",
            countryName: response.country ?? response.countryCode ?? "Unknown",
            autonomousSystem: response.asn,
            organization: response.asName,
            provider: id
        )
    }
}

public struct IpapiCoProvider: IPLocationProvider {
    public let id: ProviderID = .ipapiCo

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lookup(ipinfoToken: String?) async throws -> MimoSnapshot {
        let response: IpapiCoResponse = try await JSONHTTPClient.get(URL(string: "https://ipapi.co/json/")!, session: session)
        if response.error == true {
            throw LookupError.providerMessage(response.reason ?? "ipapi.co could not locate the current IP address.")
        }
        guard let ip = response.ip, !ip.isEmpty else { throw LookupError.invalidResponse }

        return MimoSnapshot(
            ipAddress: ip,
            countryCode: response.countryCode ?? "--",
            countryName: response.countryName ?? response.countryCode ?? "Unknown",
            city: response.city,
            region: response.region,
            timezone: response.timezone,
            autonomousSystem: response.asn,
            organization: response.organization,
            provider: id
        )
    }
}

public struct IPWhoisProvider: IPLocationProvider {
    public let id: ProviderID = .ipWhois

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lookup(ipinfoToken: String?) async throws -> MimoSnapshot {
        let response: IPWhoisResponse = try await JSONHTTPClient.get(URL(string: "https://ipwho.is/")!, session: session)
        if response.success == false {
            throw LookupError.providerMessage(response.message ?? "IPWHOIS.io could not locate the current IP address.")
        }
        guard let ip = response.ip, !ip.isEmpty else { throw LookupError.invalidResponse }

        return MimoSnapshot(
            ipAddress: ip,
            countryCode: response.countryCode ?? "--",
            countryName: response.country ?? response.countryCode ?? "Unknown",
            city: response.city,
            region: response.region,
            timezone: response.timezone?.id,
            autonomousSystem: response.connection?.asn.map { "AS\($0)" },
            organization: response.connection?.organization,
            provider: id
        )
    }
}

/// Anonymous HTTPS lookup with a deliberately small response surface. The service documents
/// a 30-request/day anonymous limit, so it is part of the explicit rotation pool rather than
/// a hidden fallback after another provider is rate-limited.
public struct IpapiIsProvider: IPLocationProvider {
    public let id: ProviderID = .ipapiIs

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lookup(ipinfoToken: String?) async throws -> MimoSnapshot {
        let response: IpapiIsResponse = try await JSONHTTPClient.get(URL(string: "https://api.ipapi.is/")!, session: session)
        if let error = response.error { throw LookupError.providerMessage(error) }
        guard let rawIP = response.ip, let ip = IPAddressValidator.normalize(rawIP) else {
            throw LookupError.invalidResponse
        }
        // Missing geography does not invalidate a successfully returned IP.
        let countryCode = response.country.flatMap(CountryCodeResolver.code(forCountryName:))

        return MimoSnapshot(
            ipAddress: ip,
            countryCode: countryCode ?? "--",
            countryName: countryCode == nil ? "Unknown" : (response.country ?? "Unknown"),
            city: response.city,
            region: response.region,
            timezone: response.timezone,
            autonomousSystem: response.asn,
            organization: response.company,
            provider: id
        )
    }
}

/// IPinfo authentication is scoped to its fixed HTTPS endpoint. Never forward it on redirects.
final class IPinfoRequestPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = IPinfoRequestPolicy()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum JSONHTTPClient {
    static func get<Response: Decodable>(_ url: URL, session: URLSession, bearerToken: String? = nil) async throws -> Response {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mimo/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken {
            guard url.scheme == "https", ["api.ipinfo.io", "v4.api.ipinfo.io", "v6.api.ipinfo.io"].contains(url.host ?? ""), url.query == nil,
                  !bearerToken.isEmpty, bearerToken.utf8.count <= 4096,
                  !bearerToken.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
                throw LookupError.invalidResponse
            }
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request, delegate: bearerToken == nil ? nil : IPinfoRequestPolicy.shared)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LookupError.invalidResponse
            }

            let retryAfter = retryAfterDate(from: httpResponse)
            if httpResponse.statusCode == 429 {
                throw LookupError.rateLimited(retryAfter: retryAfter)
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw LookupError.httpStatus(httpResponse.statusCode, retryAfter: retryAfter)
            }

            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw LookupError.invalidResponse
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as LookupError {
            throw error
        } catch {
            // Underlying URL/session errors may contain request details. Never emit a token.
            throw LookupError.transport(bearerToken == nil ? error.localizedDescription : "IPinfo HTTPS request failed.")
        }
    }

    private static func retryAfterDate(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) {
            return Date.now.addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

private struct IPinfoLiteResponse: Decodable {
    let ip: String
    let asn: String?
    let asName: String?
    let countryCode: String?
    let country: String?

    enum CodingKeys: String, CodingKey {
        case ip, asn, country
        case asName = "as_name"
        case countryCode = "country_code"
    }
}

private struct IpapiCoResponse: Decodable {
    let ip: String?
    let city: String?
    let region: String?
    let countryCode: String?
    let countryName: String?
    let timezone: String?
    let asn: String?
    let organization: String?
    let error: Bool?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case ip, city, region, timezone, asn, error, reason
        case countryCode = "country_code"
        case countryName = "country_name"
        case organization = "org"
    }
}

private struct IPWhoisResponse: Decodable {
    let ip: String?
    let success: Bool?
    let country: String?
    let countryCode: String?
    let region: String?
    let city: String?
    let timezone: IPWhoisTimezone?
    let connection: IPWhoisConnection?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case ip, success, country, region, city, timezone, connection, message
        case countryCode = "country_code"
    }
}

private struct IPWhoisTimezone: Decodable {
    let id: String?
}

private struct IPWhoisConnection: Decodable {
    let asn: Int?
    let organization: String?

    enum CodingKeys: String, CodingKey {
        case asn
        case organization = "org"
    }
}

// Anonymous response documented at https://ipapi.is/free-tier.html (September 2026).
// City/region/ASN are optional, but a response without a resolvable country is rejected
// (`IpapiIsProvider`), so it never reaches the snapshot or the allowlist check.
struct IpapiIsResponse: Decodable {
    let ip: String?
    let country: String?
    let city: String?
    let region: String?
    let timezone: String?
    let asn: String?
    let company: String?
    let error: String?
}
