import Foundation
import Network

/// The same session policy is used by core and the isolated mihomo integration tests.
enum MimoLookupSession {
    static func make(probePassword: String? = nil, probePort: Int = MimoRuntime.probePort) throws -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        if let password = probePassword {
            guard password.count == 64, password.allSatisfy(\.isHexDigit),
                  (1...65535).contains(probePort),
                  let port = NWEndpoint.Port(rawValue: UInt16(probePort)) else { throw DaemonFailure.credential }
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
            proxy.allowFailover = false
            proxy.applyCredential(username: MimoRuntime.probeUser, password: password)
            config.proxyConfigurations = [proxy]
        } else {
            config.connectionProxyDictionary = [:]
        }
        return URLSession(configuration: config)
    }
}
