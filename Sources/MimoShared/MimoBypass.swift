import Foundation

public struct MimoBypassDomain: Codable, Equatable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable { case exact, suffix }
    public var domain: String
    public var match: Match
    public init(_ domain: String = "", match: Match = .suffix) { self.domain = domain; self.match = match }
    public func validated() throws -> Self {
        var value = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        // ASCII DNS labels (including explicit xn-- labels) only; no URL, wildcard or rule text.
        guard value.utf8.count <= 253, value.contains("."), IPAddressValidator.normalize(value) == nil,
              value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw MimoBypassError.invalidDomain(domain) }
        return Self(value, match: match)
    }
    public var rule: String { "\(match == .exact ? "DOMAIN" : "DOMAIN-SUFFIX"),\(domain),DIRECT" }
}

public struct MimoBypassBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var domains: [MimoBypassDomain]
    public init(id: UUID = UUID(), name: String = "New block", enabled: Bool = true, domains: [MimoBypassDomain] = []) {
        self.id = id; self.name = name; self.enabled = enabled; self.domains = domains
    }
    public static func validated(_ blocks: [Self]) throws -> [Self] {
        guard blocks.count <= 64, Set(blocks.map(\.id)).count == blocks.count,
              blocks.reduce(0, { $0 + $1.domains.count }) <= 4096 else { throw MimoBypassError.limit }
        return try blocks.map { block in
            var result = block
            result.name = block.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.name.isEmpty, result.name.count <= 80,
                  !result.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw MimoBypassError.name
            }
            guard !block.domains.isEmpty else { throw MimoBypassError.emptyBlock(result.name) }
            result.domains = try block.domains.map { try $0.validated() }
            return result
        }
    }
    public static func rules(_ blocks: [Self]) throws -> [String] {
        var seen = Set<String>()
        return try validated(blocks).filter(\.enabled).flatMap(\.domains).map(\.rule).filter { seen.insert($0).inserted }
    }
    public static let defaults: [Self] = [
        Self(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "Tailscale websites",
             domains: ["tailscale.com", "tailscale.io"].map { .init($0) }),
        Self(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, name: "YouTube + CDN",
             domains: ["youtube.com", "youtu.be", "youtube-nocookie.com", "googlevideo.com", "ytimg.com", "ggpht.com"].map { .init($0) } + [.init("youtubei.googleapis.com", match: .exact)]),
        Self(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, name: "Homebrew / GitHub",
             domains: [.init("brew.sh"), .init("ghcr.io", match: .exact), .init("githubusercontent.com"), .init("github.com")]),
        Self(id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, name: "Microsoft CDN",
             domains: ["microsoft.com", "msecnd.net", "azureedge.net", "azurefd.net", "msedge.net", "windowsupdate.com", "aka.ms"].map { .init($0) }),
        Self(id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!, name: "Zoom",
             domains: ["zoom.us", "zoom.com", "zoomgov.com"].map { .init($0) })
    ]
}

public enum MimoBypassError: LocalizedError {
    case invalidDomain(String), emptyBlock(String), name, limit
    public var errorDescription: String? {
        switch self {
        case .invalidDomain(let value): "Invalid domain: \(value). Enter a DNS name without a URL, port or wildcard. Use xn-- notation for international names."
        case .emptyBlock(let name): "\(name): add at least one domain or delete the empty block."
        case .name: "Give each block a name of 1–80 characters."
        case .limit: "Use up to 64 blocks and 4,096 domain entries, with unique block identities."
        }
    }
}
