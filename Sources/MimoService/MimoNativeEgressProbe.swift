import Darwin
import Foundation
import Security

/// Read-only native transport observation during core's existing policy audit.
/// No provider, CLI/network request, profile binding or separate watcher.
enum MimoNativeEgressProbe {
    private static let identifier = "io.tailscale.ipn.macsys.network-extension"

    private static func trusted(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        guard executable.hasPrefix("/Library/SystemExtensions/"),
              executable.hasSuffix("/\(identifier).systemextension/Contents/MacOS/\(identifier)") else { return nil }
        var code: SecCode?, requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"W5364U7YZB\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    static func snapshot() -> MimoNativeEgress {
        let bytes = proc_listallpids(nil, 0) * Int32(MemoryLayout<pid_t>.size) * 2
        guard bytes > 0, bytes <= 4_000_000 else { return .init() }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        let candidates = pids.prefix(max(0, min(Int(count), pids.count))).compactMap { pid -> (pid_t, String)? in
            guard pid > 0, let identity = trusted(pid) else { return nil }
            return (pid, identity)
        }
        guard candidates.count == 1, let (pid, identity) = candidates.first else { return .init() }
        // NetworkExtension can retain thousands of failed TCP descriptors. Keep
        // capture bounded without truncating a valid native observation at 64K.
        let sockets = BoundedProcess.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-i", "-F0puftPnT"], timeout: 1.5, outputLimit: 1_048_576)
        guard sockets.status == 0, trusted(pid) == identity else { return .init() }
        return MimoNativeEgress.parse(sockets.text, process: pid)
    }
}
