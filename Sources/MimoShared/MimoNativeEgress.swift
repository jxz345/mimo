import Foundation

/// Public transport used by the independently signed native VPN, not arbitrary
/// app sockets. PF cannot match PID: UDP uses currently held source ports and
/// HTTPS uses observed relay/control destinations, always with root ownership.
public struct MimoNativeEgress: Equatable, Sendable {
    public struct Datagram: Hashable, Sendable {
        public let ipv6: Bool
        public let source: String?
        public let port: Int
        public init(ipv6: Bool, source: String?, port: Int) {
            self.ipv6 = ipv6; self.source = source; self.port = port
        }
    }
    public var datagrams: Set<Datagram> = []
    public var https: Set<String> = []
    public init() {}

    /// lsof's machine format; callers must verify the running code identity
    /// before and after collecting these root-owned socket observations.
    public static func parse(_ text: String, process: Int32) -> Self {
        var result = Self(), fields: [String: String] = [:]
        var pid: String?, uid: String?
        func endpoint(_ value: String) -> (String?, Int)? {
            guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]),
                  (1...65535).contains(port) else { return nil }
            let host = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if ["*", "0.0.0.0", "::"].contains(host) { return (nil, port) }
            guard let address = IPAddressValidator.normalize(host) else { return nil }
            return (address, port)
        }
        func finish() {
            defer { fields = [:] }
            guard pid == String(process), uid == "0", ["IPv4", "IPv6"].contains(fields["t"] ?? ""),
                  let name = fields["n"], result.datagrams.count + result.https.count < 128 else { return }
            let ipv6 = fields["t"] == "IPv6"
            if fields["P"] == "UDP", !name.contains("->"), let (source, port) = endpoint(name), port >= 1024,
               source.map({ $0.contains(":") == ipv6 }) ?? true {
                result.datagrams.insert(.init(ipv6: ipv6, source: source, port: port))
            } else if fields["P"] == "TCP", ["ST=ESTABLISHED", "ST=SYN_SENT", "ST=CLOSED"].contains(fields["T"] ?? "") {
                // A blocked connect may already be CLOSED when sampled. Retain
                // only its destination while the verified process holds the fd;
                // the next retry uses a different ephemeral source port.
                let parts = name.components(separatedBy: "->")
                guard parts.count == 2, let (source, port) = endpoint(parts[0]), source != nil, port >= 1024,
                      let (destination, remotePort) = endpoint(parts[1]), let destination, remotePort == 443,
                      destination.contains(":") == ipv6 else { return }
                result.https.insert(destination)
            }
        }
        for raw in text.split(separator: "\0", omittingEmptySubsequences: true) {
            let field = raw.trimmingCharacters(in: .newlines)
            guard let key = field.first else { continue }
            let value = String(field.dropFirst())
            if key == "p" { finish(); pid = value; uid = nil }
            else if key == "u" { uid = value }
            else if key == "f" { finish() }
            else if key == "T", !value.hasPrefix("ST=") { continue }
            else { fields[String(key)] = value }
        }
        finish()
        return result
    }

    public func rules() throws -> [String] {
        guard datagrams.count + https.count <= 128 else { throw DaemonFailure.invalidRequest }
        var result: [String] = []
        for socket in datagrams {
            guard (1024...65535).contains(socket.port), socket.source.map({
                IPAddressValidator.normalize($0) == $0 && $0.contains(":") == socket.ipv6
            }) ?? true else { throw DaemonFailure.invalidRequest }
            result.append("pass out quick \(socket.ipv6 ? "inet6" : "inet") proto udp from \(socket.source ?? "any") port = \(socket.port) to any user = 0 no state label \"mimo:active:native-vpn-udp\"")
        }
        for destination in https {
            guard IPAddressValidator.normalize(destination) == destination else { throw DaemonFailure.invalidRequest }
            result.append("pass out quick \(destination.contains(":") ? "inet6" : "inet") proto tcp from any to \(destination) port = 443 user = 0 no state label \"mimo:active:native-vpn-https\"")
        }
        return result.sorted()
    }
}
