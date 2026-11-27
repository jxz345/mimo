    let infrastructureQueue = MimoBlockingWorkQueue("test.health-isolated")
    var infrastructureEpoch = 0
    var infrastructureInspection: MimoInfrastructureInspection?
    var latestPFHealthReceipt:MimoPFHealthReceipt?
    var directory:URL {TestClock.shared.directory.appendingPathComponent("Runtime")}
    var onlineDirectRelease = false
    var maintenanceActive = false
    nonisolated var networkReleaseRequested: Bool { false }
    var engineInspection = MimoServiceStatus(id: .mihomo, health: .running, transport: "test", address: "loopback", port: 0, checkedAt: TestClock.shared.date)
    nonisolated func secureDirectory(_ path: URL) throws {}
    nonisolated func secureFile(_ path: URL) throws {}
    nonisolated func servicePreferences() throws -> Preferences { Preferences() }
    nonisolated func isRunning(_ label: String) -> Bool { true }
    nonisolated func checkInstalledController() throws {}
    nonisolated func bootIdentifier() throws -> String { "fixture" }
    var gateState: String? { "active" }
