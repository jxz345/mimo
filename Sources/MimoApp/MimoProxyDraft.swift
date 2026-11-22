import Foundation

/// A Settings editor owns the revision it loaded, not the revision of the latest status poll.
/// Kept by SettingsView so switching sections does not discard an unfinished edit or secret.
struct MimoProxyDraft {
    var proxyID: UUID?
    var hasPassword = false
    var name = ""
    var server = ""
    var port = "1080"
    var username = ""
    var password = ""
    var type = ClashProxySettings.ProxyType.socks5
    var clearPassword = false
    private(set) var revision: Int?

    mutating func receive(_ state: DaemonState?, discardChanges: Bool = false) {
        guard let state, state.initialized, revision == nil || discardChanges else { return }
        let entry = state.routing?.configuration.proxies?.first(where: { $0.id == proxyID })
        let proxy = entry?.proxy
        hasPassword = entry?.hasPassword == true
        name = proxy?.name ?? ""
        server = proxy?.server ?? ""
        port = String(proxy?.port ?? 1080)
        username = proxy?.username ?? ""
        type = proxy?.type ?? .socks5
        password = ""
        clearPassword = false
        revision = state.revision
    }

    mutating func select(_ id: UUID?, from state: DaemonState?) {
        proxyID = id
        receive(state, discardChanges: true)
    }

    func conflicts(with state: DaemonState?) -> Bool {
        guard let revision, let state, state.initialized else { return false }
        return state.revision != revision
    }

    func validatedProxy() throws -> MimoProxy {
        guard let port = Int(port) else { throw ClashProxySettings.ValidationError.invalidPort }
        guard !server.contains(":") else { throw ClashProxySettings.ValidationError.invalidServer }
        return try MimoProxy(ClashProxySettings(name: name, type: type, server: server,
                                              port: port, username: username, password: clearPassword ? "" : password).validated())
    }

    var passwordChange: String? { clearPassword ? "" : password.isEmpty ? nil : password }
}
