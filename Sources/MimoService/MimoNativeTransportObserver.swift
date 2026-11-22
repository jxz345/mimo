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

    static func infrastructure(includeBootstrap: Bool = true, publish: (@Sendable (Set<String>) -> Void)? = nil) -> Set<String> {
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
        // Publish the live map before DNS work. Bootstrap DNS endpoints are a
        // separate map embedded by Tailscale and may be absent from this map.
        publish?(addresses)
        let collected = MimoInfrastructureCollection(addresses)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        let hosts = includeBootstrap ? MimoNativeInfrastructure.dnsHosts : Array(MimoNativeInfrastructure.dnsHosts.prefix(2))
        for host in hosts {
            queue.addOperation {
                let response = BoundedProcess.run("/usr/bin/curl", ["--silent", "--fail", "--max-time", "5",
                    "--noproxy", "*", "-H", "Accept: application/dns-json",
                    "https://1.1.1.1/dns-query?name=\(host)&type=A"], timeout: 6)
                guard response.status == 0, let data = response.text.data(using: .utf8) else { return }
                let answers = MimoNativeInfrastructure.ipv4Answers(data)
                collected.insert(answers)
                if !answers.isEmpty { publish?(answers) }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return collected.addresses
    }

    static func check(tailnetEnabled: Bool, infrastructure: Set<String>) -> MimoNativeTransport {
        check(interface: tailnetEnabled ? TailscaleProbe.check(previousUser: nil) : nil, infrastructure: infrastructure)
    }

    static func check(interface observation: TailscaleProbe.Result?, infrastructure: Set<String>) -> MimoNativeTransport {
        // The slow native CLI runs separately. Recheck the leased interface's
        // current route/address before taking the fresh socket snapshot.
        var interface: String?
        if let (name, address) = eligibleInterface(observation, at: .now) {
            let route = BoundedProcess.run("/sbin/route", ["-n", "get", "100.100.100.100"], timeout: 0.5)
            let config = BoundedProcess.run("/sbin/ifconfig", [name], timeout: 0.5)
            if route.status == 0, config.status == 0, NativeProviderProtocol.routeInterface(route.text) == name,
               NativeProviderProtocol.ownsAddress(config.text, interface: name, address: address) { interface = name }
        }
        let bytes = proc_listallpids(nil, 0) * Int32(MemoryLayout<pid_t>.size) * 2
        guard bytes > 0 else { return .init() }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        let candidates = pids.prefix(max(0, Int(count))).filter { $0 > 0 && trustedProcess($0) }
        guard candidates.count == 1, let pid = candidates.first else { return .init() }
        guard trustedProcess(pid) else { return .init() }
        return MimoNativeTransport(interface: interface)
    }

    static func eligibleInterface(_ observation: TailscaleProbe.Result?, at now: Date) -> (String, String)? {
        guard let observation, let checked = observation.status.checkedAt,
              (0..<5).contains(now.timeIntervalSince(checked)), let address = observation.address,
              NativeProviderProtocol.tailscaleAddress(address) == address,
              case .direct(let name) = observation.status.served else { return nil }
        return (name, address)
    }
}

private final class MimoInfrastructureCollection: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String>
    init(_ values: Set<String>) { self.values = values }
    func insert(_ values: Set<String>) { lock.withLock { self.values.formUnion(values) } }
    var addresses: Set<String> { lock.withLock { values.count <= 256 ? values : [] } }
}

/// Endpoint observations retain their original expiry across provider toggles.
final class MimoNativeInfrastructureObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var cache = MimoInfrastructureCache()
    func update(_ values: Set<String>) { lock.withLock { cache.update(values, at: .now) } }
    func addresses() -> Set<String> { lock.withLock { cache.addresses(at: .now) } }
}

/// Stop waits for in-flight application and fences late detached results.
final class MimoNativeObservationSession: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let store: MimoNativeInfrastructureObservations
    private var interface: TailscaleProbe.Result?

    init(infrastructure: MimoNativeInfrastructureObservations = .init()) { self.store = infrastructure }
    func infrastructure(_ values: Set<String>) { lock.withLock { if active { store.update(values) } } }
    func observed(_ value: TailscaleProbe.Result) {
        lock.withLock {
            guard active else { return }
            if let previous = interface?.status.checkedAt, let next = value.status.checkedAt, next < previous { return }
            interface = value
        }
    }
    func snapshot() -> (TailscaleProbe.Result?, Set<String>) { lock.withLock { (interface, store.addresses()) } }
    @discardableResult
    func apply(_ value: MimoNativeTransport, using operation: (MimoNativeTransport) -> Void) -> Bool {
        lock.withLock {
            guard active else { return false }
            operation(value)
            return true
        }
    }
    func stop(using operation: (MimoNativeTransport) -> Void) {
        lock.withLock { active = false; operation(.init()) }
    }
}

@MainActor
final class MimoNativeTransportObserver {
    typealias Probe = @Sendable (TailscaleProbe.Result?, Set<String>) -> MimoNativeTransport
    typealias InterfaceProbe = @Sendable (uid_t?) -> TailscaleProbe.Result
    private var tasks: [Task<Void, Never>] = []
    private let discoveryQueue = MimoBlockingWorkQueue("com.mimo.native-discovery")
    private let interfaceQueue = MimoBlockingWorkQueue("com.mimo.native-interface")
    private let socketQueue = MimoBlockingWorkQueue("com.mimo.native-sockets", qos: .userInitiated)
    private var session: MimoNativeObservationSession?
    private let infrastructure = MimoNativeInfrastructureObservations()
    private let changed: @Sendable (MimoNativeTransport) -> Void
    private let probe: Probe
    private let interfaceProbe: InterfaceProbe

    init(changed: @escaping @Sendable (MimoNativeTransport) -> Void,
         probe: @escaping Probe = { MimoNativeTransportProbe.check(interface: $0, infrastructure: $1) },
         interfaceProbe: @escaping InterfaceProbe = { TailscaleProbe.check(previousUser: $0) }) {
        self.changed = changed
        self.probe = probe
        self.interfaceProbe = interfaceProbe
    }

    func start(tailnetEnabled: Bool, discoverInfrastructure: Bool = false) {
        stop()
        // Retain unexpired authenticated endpoints across provider toggles.
        // Rotating DNS must not revoke a still-held control connection merely
        // because the inner tailnet route was stopped and started.
        let session = MimoNativeObservationSession(infrastructure: infrastructure)
        self.session = session
        let changed = changed, probe = probe, interfaceProbe = interfaceProbe
        let discoveryQueue = discoveryQueue, interfaceQueue = interfaceQueue, socketQueue = socketQueue
        if discoverInfrastructure {
            tasks.append(Task.detached(priority: .utility) {
                var nextBootstrap = ContinuousClock.now
                while !Task.isCancelled {
                    let includeBootstrap = ContinuousClock.now >= nextBootstrap
                    if includeBootstrap { nextBootstrap = .now.advanced(by: .seconds(60)) }
                    guard let refreshed = await discoveryQueue.run({
                        MimoNativeTransportProbe.infrastructure(includeBootstrap: includeBootstrap) {
                            session.infrastructure($0)
                        }
                    }), !Task.isCancelled else { return }
                    session.infrastructure(refreshed)
                    try? await Task.sleep(for: .seconds(10))
                }
            })
        }
        if tailnetEnabled {
            tasks.append(Task.detached(priority: .utility) {
                var previousUser: uid_t?
                while !Task.isCancelled {
                    guard let value = await interfaceQueue.run({ [previousUser] in
                        interfaceProbe(previousUser)
                    }), !Task.isCancelled else { return }
                    previousUser = value.user
                    session.observed(value)
                    try? await Task.sleep(for: .seconds(2))
                }
            })
        }
        tasks.append(Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                let applied = await socketQueue.run {
                    let (interface, addresses) = session.snapshot()
#if MIMO_VM_ACCEPTANCE
                    let began = Date()
#endif
                    let result = probe(interface, addresses)
#if MIMO_VM_ACCEPTANCE
                    let probed = Date()
#endif
                    guard session.apply(result, using: changed) else { return false }
#if MIMO_VM_ACCEPTANCE
                    RuntimeLog.shared.info("mimo_vm_native_observed", fields: [
                        "elapsedMs": String(Int(Date().timeIntervalSince(began) * 1000)),
                        "probeMs": String(Int(probed.timeIntervalSince(began) * 1000)),
                        "applyMs": String(Int(Date().timeIntervalSince(probed) * 1000)),
                        "interfaceVerified": result.interface == nil ? "false" : "true",
                        "infrastructureCount": String(result.infrastructure.count),
                        "tcpPorts": result.sockets.filter { $0.destination != nil }.map { String($0.port) }.sorted().joined(separator: ",")
                    ])
#endif
                    return true
                }
                guard !Task.isCancelled, applied == true else { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        })
    }

    /// Join a fresh native observation and its completed firewall/provider
    /// publication before a protected profile may load or begin inspection.
    func prepareForProfile(tailnetEnabled: Bool) async throws -> MimoNativeTransport {
        guard let session else { throw MimoRuntimeError.unavailable("Native transport observation is stopped.") }
        if tailnetEnabled {
            let previousUser = session.snapshot().0?.user
            let interfaceProbe = interfaceProbe
            guard let value = await interfaceQueue.run({ interfaceProbe(previousUser) }) else { throw CancellationError() }
            try Task.checkCancellation()
            guard self.session === session else { throw CancellationError() }
            session.observed(value)
        }
        let probe = probe, changed = changed
        guard let result = await socketQueue.run({ () -> MimoNativeTransport? in
            let (interface, addresses) = session.snapshot()
            let transport = probe(tailnetEnabled ? interface : nil, addresses)
            guard session.apply(transport, using: changed) else { return nil }
            return transport
        }), let result else { throw CancellationError() }
        try Task.checkCancellation()
        guard self.session === session else { throw CancellationError() }
        return result
    }

    func stop() {
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        if let session { session.stop(using: changed) }
        else { changed(.init()) }
        session = nil
    }
}
