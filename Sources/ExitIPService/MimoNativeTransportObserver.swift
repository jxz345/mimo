import Darwin
import Foundation
import Security

/// Read-only identification of the official native extension and its held sockets.
/// No credentials, private Tailscale state, or network-map secrets are read.
enum MimoNativeTransportProbe {
    static let extensionIdentifier = "io.tailscale.ipn.macsys.network-extension"
    static let team = "W5364U7YZB"

    static func trustedProcess(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == 0 else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let executable = String(cString: path)
        guard executable.hasPrefix("/Library/SystemExtensions/"),
              executable.hasSuffix("/\(extensionIdentifier).systemextension/Contents/MacOS/\(extensionIdentifier)") else { return false }
        var code: SecCode?, requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        let rule = "anchor apple generic and identifier \"\(extensionIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func trustedCLI() -> Bool {
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"io.tailscale.ipn.macsys\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: TailscaleProbe.cli) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func infrastructure() -> Set<String> {
        guard trustedCLI() else { return [] }
        var addresses = Set<String>()
        if let user = TailscaleProbe.candidateUsers(previousUser: nil).first {
            let map = TailscaleProbe.runAsUser(user, arguments: ["debug", "derp-map"])
            if map.status == 0, let data = map.text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let regions = object["Regions"] as? [String: [String: Any]] {
                for region in regions.values {
                    for node in region["Nodes"] as? [[String: Any]] ?? [] {
                        for key in ["IPv4"] {
                            if let raw = node[key] as? String, let address = IPAddressValidator.normalize(raw) { addresses.insert(address) }
                        }
                    }
                }
            }
        }
        // The native control/log endpoints are bootstrapped through the same fixed
        // TLS resolver allowed to Mimo's private runtime group. No system DNS grant.
        for host in ["controlplane.tailscale.com", "log.tailscale.com"] {
            for type in ["A"] {
                let response = BoundedProcess.run("/usr/bin/curl", ["--silent", "--fail", "--max-time", "5",
                    "--noproxy", "*", "-H", "Accept: application/dns-json",
                    "https://1.1.1.1/dns-query?name=\(host)&type=\(type)"], timeout: 6)
                guard response.status == 0, let data = response.text.data(using: .utf8),
                      let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      answer["Status"] as? Int == 0 else {
                    // A failed query contributes nothing, but must not discard
                    // independently authenticated DERP or other DNS answers.
                    continue
                }
                for record in answer["Answer"] as? [[String: Any]] ?? [] {
                    if let kind = record["type"] as? Int, [1, 28].contains(kind),
                       let raw = record["data"] as? String, let address = IPAddressValidator.normalize(raw) { addresses.insert(address) }
                }
            }
        }
        return addresses.count <= 256 ? addresses : []
    }

    static func check(tailnetEnabled: Bool, infrastructure: Set<String>) -> MimoNativeTransport {
        let bytes = proc_listallpids(nil, 0) * Int32(MemoryLayout<pid_t>.size) * 2
        guard bytes > 0 else { return .init() }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        let candidates = pids.prefix(max(0, Int(count))).filter { $0 > 0 && trustedProcess($0) }
        guard candidates.count == 1, let pid = candidates.first else { return .init() }
        let sockets = BoundedProcess.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-i", "-sTCP:^CLOSED", "-F0puftPnT"], timeout: 2)
        guard sockets.status == 0, trustedProcess(pid) else { return .init() }
        var result = MimoNativeTransport.parse(sockets.text, process: pid)
        result.infrastructure = infrastructure
        if tailnetEnabled {
            let probe = TailscaleProbe.check(previousUser: nil)
            if case .direct(let interface) = probe.status.served { result.interface = interface }
        }
        guard trustedProcess(pid) else { return .init() }
        return result
    }
}

@MainActor
final class MimoNativeTransportObserver {
    private var task: Task<Void, Never>?
    private var infrastructureTask: Task<Void, Never>?
    private var cache = MimoInfrastructureCache()
    private var enabled = false
    private var generation = 0
    private let changed: (MimoNativeTransport) -> Void

    init(changed: @escaping (MimoNativeTransport) -> Void) { self.changed = changed }

    func start(tailnetEnabled: Bool) {
        stop()
        enabled = tailnetEnabled
        let epoch = generation
        infrastructureTask = Task { [weak self] in
            while !Task.isCancelled {
                let refreshed = await Task.detached(priority: .utility) { MimoNativeTransportProbe.infrastructure() }.value
                guard let self, !Task.isCancelled, epoch == self.generation else { return }
                self.cache.update(refreshed, at: .now)
                try? await Task.sleep(for: .seconds(10))
            }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let enabled = self.enabled
                // Slow DNS must not delay observing/revoking native socket rules.
                let addresses = self.cache.addresses(at: .now)
                let result = await Task.detached(priority: .utility) {
                    MimoNativeTransportProbe.check(tailnetEnabled: enabled, infrastructure: addresses)
                }.value
                guard !Task.isCancelled, epoch == self.generation else { return }
                self.changed(result)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel(); task = nil
        infrastructureTask?.cancel(); infrastructureTask = nil
        changed(.init())
    }
}
