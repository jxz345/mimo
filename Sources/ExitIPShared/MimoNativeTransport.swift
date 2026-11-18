import Foundation

/// Socket-scoped exceptions for the independently verified native Tailscale process.
/// PF cannot match a PID. Restrict exceptions to root-owned, currently held socket
/// source ports instead; never grant every root process or every utun public egress.
public struct MimoNativeTransport: Equatable, Sendable {
    public struct Socket: Hashable, Sendable {
        public var ipv6: Bool
        public var source: String?
        public var port: Int
        public var destination: String?
    }

    public var sockets: Set<Socket>
    public var interface: String?
    public var infrastructure = Set<String>()

    public init(sockets: Set<Socket> = [], interface: String? = nil) {
        self.sockets = sockets
        self.interface = interface
    }

    /// Parses lsof's NUL-delimited machine format, never its human table.
    public static func parse(_ text: String, process: Int32) -> Self {
        var owner: String?, pid: String?, fields: [String: String] = [:], sockets = Set<Socket>()
        func endpoint(_ value: String) -> (String?, Int)? {
            guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]),
                  (1024...65535).contains(port) else { return nil }
            let host = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if host == "*" { return (nil, port) }
            guard let address = IPAddressValidator.normalize(host) else { return nil }
            return (address, port)
        }
        func finish() {
            defer { fields = [:] }
            guard pid == String(process), owner == "0", ["IPv4", "IPv6"].contains(fields["t"] ?? ""),
                  let name = fields["n"], sockets.count < 256 else { return }
            let ipv6 = fields["t"] == "IPv6"
            if fields["P"] == "UDP", !name.contains("->"), let source = endpoint(name) {
                sockets.insert(Socket(ipv6: ipv6, source: source.0, port: source.1, destination: nil))
            } else if fields["P"] == "TCP", ["ST=ESTABLISHED", "ST=SYN_SENT"].contains(fields["T"] ?? "") {
                let parts = name.components(separatedBy: "->")
                guard parts.count == 2, let source = endpoint(parts[0]), let local = source.0,
                      parts[1].hasSuffix(":443") else { return }
                let host = String(parts[1].dropLast(4)).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                guard let destination = IPAddressValidator.normalize(host), !destination.hasPrefix("127."), destination != "::1" else { return }
                sockets.insert(Socket(ipv6: ipv6, source: local, port: source.1, destination: destination))
            }
        }
        for raw in text.split(separator: "\0", omittingEmptySubsequences: true) {
            let value = raw.trimmingCharacters(in: .newlines)
            guard let key = value.first else { continue }
            let payload = String(value.dropFirst())
            if key == "p" { finish(); pid = payload; owner = nil }
            else if key == "u" { owner = payload }
            else if key == "f" { finish(); fields["f"] = payload }
            else if key == "T", !payload.hasPrefix("ST=") { continue }
            else { fields[String(key)] = payload }
        }
        finish()
        return Self(sockets: sockets)
    }

    public func render() throws -> String {
        guard sockets.count <= 256, infrastructure.count <= 256,
              infrastructure.allSatisfy({ IPAddressValidator.normalize($0) == $0 }) else { throw DaemonFailure.invalidRequest }
        let trustedKeys = Set(infrastructure.compactMap(IPAddressValidator.canonicalKey))
        var rules: [String] = []
        for socket in sockets {
            guard !socket.ipv6 else { continue }
            guard (1024...65535).contains(socket.port),
                  socket.source.map({ IPAddressValidator.normalize($0) == $0 && $0.contains(":") == socket.ipv6 }) ?? true,
                  socket.destination.map({ IPAddressValidator.normalize($0) == $0 && $0.contains(":") == socket.ipv6 }) ?? true else {
                throw DaemonFailure.invalidRequest
            }
            let family = socket.ipv6 ? "inet6" : "inet"
            let source = socket.source ?? "any"
            if let destination = socket.destination {
                guard let key = IPAddressValidator.canonicalKey(destination), trustedKeys.contains(key) else { continue }
                rules.append("pass out quick \(family) proto tcp from \(source) port \(socket.port) to \(destination) port 443 user 0 no state")
            } else {
                // Protected modes use authenticated DERP relays for peer data.
                // STUN is limited to trusted infrastructure; arbitrary native UDP
                // sockets and diagnostic dial requests cannot become a bypass.
                for destination in infrastructure where destination.contains(":") == socket.ipv6 {
                    rules.append("pass out quick \(family) proto udp from \(source) port \(socket.port) to \(destination) port 3478 user 0 no state")
                }
            }
        }
        if let interface {
            guard interface != MihomoProfile.tunnelDevice, interface.hasPrefix("utun"),
                  !interface.dropFirst(4).isEmpty, interface.dropFirst(4).allSatisfy(\.isNumber) else { throw DaemonFailure.invalidRequest }
            // Inner tailnet packets only; public exit-node traffic is not exempt.
            rules.append("pass out quick on \(interface) inet to 100.64.0.0/10 no state")
        }
        return rules.sorted().joined(separator: "\n") + "\n"
    }
}

/// Retains only recently authenticated DNS/DERP observations. Rotating DNS answers
/// must not immediately revoke another still-current control endpoint. Socket/code
/// validation is still required before any address produces a firewall exception.
public struct MimoInfrastructureCache: Codable, Sendable {
    private var observed: [String: Date] = [:]
    public private(set) var refreshedAt = Date.distantPast

    public init() {}

    public func needsRefresh(at date: Date) -> Bool {
        date.timeIntervalSince(refreshedAt) >= 10 || date < refreshedAt
    }

    public func addresses(at date: Date) -> Set<String> {
        Set(observed.compactMap { address, seen in
            date >= seen && date.timeIntervalSince(seen) < 300 ? address : nil
        })
    }

    public mutating func update(_ addresses: Set<String>, at date: Date) {
        observed = observed.filter { date >= $0.value && date.timeIntervalSince($0.value) < 300 }
        for address in addresses where IPAddressValidator.normalize(address) == address { observed[address] = date }
        if observed.count > 256 { observed = [:] }
        refreshedAt = date
    }
}
