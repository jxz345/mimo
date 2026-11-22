import XCTest
@testable import MimoShared

final class IPinfoPrivacyTests: XCTestCase {
    func testTokenUsesHeaderAndNeverAppearsInURLOrOtherProviderRequests() async throws {
        let session = PrivacyURLProtocol.session()
        defer { session.invalidateAndCancel() }
        let client = PublicIPLookupClient(session: session)
        _ = try await client.lookup(configuration: .init(provider: .ipinfoLite, ipinfoToken: "synthetic-token"))
        let request = try XCTUnwrap(PrivacyURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.ipinfo.io/lite/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        _ = try await client.lookup(configuration: .init(provider: .ipWhois, ipinfoToken: "synthetic-token"))
        XCTAssertNil(PrivacyURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testTransportErrorDoesNotExposeTokenAndInvalidHeadersAreRejectedBeforeRequest() async throws {
        let session = PrivacyURLProtocol.session(failing: true)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await IPinfoLiteProvider(session: session).lookup(ipinfoToken: "synthetic-token")
            XCTFail("The transport must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("synthetic-token"))
        }
        PrivacyURLProtocol.reset()
        do {
            _ = try await IPinfoLiteProvider(session: session).lookup(ipinfoToken: "synthetic-token\r\nExtra: value")
            XCTFail("Header injection must be rejected")
        } catch { XCTAssertNil(PrivacyURLProtocol.lastRequest) }
    }

    func testIPinfoRedirectPolicyRejectsSameHostOtherHostAndHTTP() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = URL(string: "https://api.ipinfo.io/lite/me")!
        let task = session.dataTask(with: source)
        defer { task.cancel() }
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for destination in ["https://api.ipinfo.io/elsewhere", "https://example.com/", "http://api.ipinfo.io/lite/me"] {
            let redirected: URLRequest? = await withCheckedContinuation { continuation in
                IPinfoRequestPolicy.shared.urlSession(session, task: task, willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: URL(string: destination)!)) { continuation.resume(returning: $0) }
            }
            XCTAssertNil(redirected)
        }
    }
}

private final class PrivacyURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: URLRequest?
    nonisolated(unsafe) private static var failing = false
    static var lastRequest: URLRequest? { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = nil } }
    static func session(failing: Bool = false) -> URLSession {
        lock.withLock { recorded = nil; Self.failing = failing }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrivacyURLProtocol.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fail = Self.lock.withLock { Self.recorded = request; return Self.failing }
        if fail {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "PrivacyTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Request failed with synthetic-token"]))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ip":"192.0.2.10","country_code":"SG","country":"Singapore","success":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
