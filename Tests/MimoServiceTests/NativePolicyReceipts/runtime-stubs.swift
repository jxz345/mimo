    nonisolated let directory = MimoRuntime.directory
    nonisolated let group: UInt32 = 10000
    nonisolated let firewallPreparationQueue = MimoBlockingWorkQueue("test.native-policy")
    var onlineDirectRelease = false
    var nativePolicyOwner: MimoNativePolicyOwner?
    var nativePolicyWorkCount = 0
    var nativePolicyDidCommit: (() -> Void)?
    nonisolated var networkReleaseRequested: Bool { false }
    var installedPolicy: MimoPreparedProbePolicy?
    var blockedNativeEgress = MimoNativeEgress()
    var closed = false
    var maintenanceActive = false
    var infrastructureRepairPending = false
    var infrastructureInspection: MimoInfrastructureInspection?
    var latestPFHealthReceipt: MimoPFHealthReceipt?
    var directIntentAdmissions = 0
    nonisolated func nativeTunnelInterfaces() throws -> [String] { [] }
    nonisolated func secureDirectory(_ path: URL) throws {}
    nonisolated func secureFile(_ path: URL) throws {}
    nonisolated func bootIdentifier() throws -> String { "isolated-boot" }
    nonisolated func writePrivate(_ data: Data, name: String) throws -> URL {
        let path=directory.appendingPathComponent(name);try data.write(to:path,options:.atomic);return path
    }
    nonisolated func command(_ executable: String,_ arguments:[String],input:Data?=nil) throws {
        precondition(executable=="/sbin/pfctl" && arguments==["-a",MimoFirewallPolicy.anchor,"-f","-"])
        guard let input,let rules=String(data:input,encoding:.utf8) else {throw DaemonFailure.invalidRequest}
        Facts.shared.install(rules)
    }
    func admitDirectIntent() { directIntentAdmissions += 1 }
    func currentReceiptMatches() -> Bool {latestPFHealthReceipt.map(pfHealthReceiptIsCurrent) ?? false}
