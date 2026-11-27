extension MimoSupervisor {
    /// Seed the state already established by prepare, without touching host networking.
    func qualificationPrepare(_ configuration: MimoConfiguration,
                              readiness: Task<MimoReadinessReceipt, Error>,
                              receipt: MimoReadinessReceipt) throws -> MimoVerification {
        generation &+= 1
        cancelReadiness()
        allowlist = AllowedIPList(addresses: ["203.0.113.10"])
        policy = MimoAccessPolicy(configuration: configuration)
        let check = policy.begin(configuration: configuration, revision: 1, networkGeneration: generation)
        policy.checking(check)
        __PROTECTED_LEASE_SEED__
        activeProfile = "owned profile \(check.id)"
        proxy = ClashProxySettings(name: "Owned fixture", type: .socks5, server: "192.0.2.1", port: 1080)
        endpoint = "192.0.2.1"
        configurationKnown = true
        directRestorationAllowed = false
        verificationPowerEpoch = try powerGuard.fence.arm()
        powerGuard.fence.beginCycle()
        readinessCheck = readiness
        cachedServices = (.now, [])
        qualificationAwaitingReadiness = false
        ApprovalRaceRuntime.shared.loadedReceipt = receipt.profileDigest
        ApprovalRaceRuntime.shared.closed = true
        ApprovalRaceRuntime.shared.gateState = "blocked"
        return check
    }

    var qualificationState: MimoRoutingState { policy.state }

    var qualificationReadinessTask: Task<MimoReadinessReceipt, Error>? { readinessCheck }

    func qualificationWrapReadiness(_ inspection: Task<MimoReadinessReceipt, Error>, check: MimoVerification) {
        let readinessGeneration = generation
        __PROTECTED_LEASE_CAPTURE__
        profileInspection = inspection
        __READINESS_WRAPPER__
    }
}
