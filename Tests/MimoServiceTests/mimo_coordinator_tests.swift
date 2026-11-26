import Foundation

@MainActor
enum MimoCoordinatorTests {
    static func run() async throws {
        try await familyChangeClosesOnce()
        try await configurationBarrierCannotOutliveItsEdit()
        try await ipv4ApprovalKeepsProviderHealthy()
        try await schedulerFailureClosesOnce()
        try await obsoleteSchedulerNoticeCannotCloseNewProbe()
        try await staleHeartbeatAfterClose()
        try await outOfOrderHeartbeats()
        try await heartbeatDuringTransition()
        try await networkChangeDuringPreparation()
        try await networkChangeDuringLookup()
        try await cancelledLookupCannotApprove()
        try await heartbeatPulseDoesNotWaitForStatus()
        try await credentialChangeDuringLookup()
        try await directRestoreFailure()
        try await delayedDirectCannotOpenClosedGate()
        try await delayedCloseCannotUndoDirect()
        try await nonRoutingRevisionPreservesVerifiedAccess()
        try await directFamilySurvivesSupervisorPoll()
        try await singlePreparationOwnsClosure()
        try await approvalProgressWaitsAndCannotUndoDirect()
        try await failedPreparationCannotProbe()
        try await supervisorEventInvalidatesWithoutDuplicateClose()
        try await exceptionRecoveryMatrix()
        try await directCancelsPendingLookupMatrix()
        print("PASS: stale supervisor replies, interrupted preparation/probes, credential mutation fencing and Direct failure isolation")
    }

    private static func familyChangeClosesOnce() async throws {
        for mode in [ProxyMode.rule, .global] {
            for family in MimoNetworkFamily.allCases {
                for approved in [false, true] {
                    let fixture = Fixture(mode: mode, family: family)
                    fixture.allowed = approved ? Fixture.allowed : AllowedIPList(addresses: [])
                    let coordinator = fixture.coordinator()
                    _ = try await coordinator.lookup(Fixture.lookupConfiguration)
                    var next = fixture.configuration
                    next.networkFamily = family == .ipv4 ? .dual : .ipv4
                    let before = fixture.closeRequests
                    await coordinator.beginConfigurationChange(reason: "Changing traffic family")
                    await coordinator.update(configuration: next, allowlist: fixture.allowed, revision: 2)
                    coordinator.endConfigurationChange()
                    print("Family change \(mode)/\(family)/approved=\(approved): \(fixture.closeRequests - before) close commands")
                    require(fixture.closeRequests - before == 1,
                            "one family edit must reuse its acknowledged pre-commit closure, not close twice")
                    _ = try await coordinator.lookup(Fixture.lookupConfiguration)
                    require(fixture.lookupCount == 2 && fixture.approvals.last?.revision == 2,
                            "one family edit requires one fresh IPv4 lookup at the committed revision")
                    require(coordinator.state.configuration.networkFamily == next.networkFamily &&
                            coordinator.state.allowsTraffic == approved,
                            "family changes preserve the actual allowlist outcome")
                }
            }
        }
    }

    private static func configurationBarrierCannotOutliveItsEdit() async throws {
        for invalidation in ["failed_close", "network_change", "finished_edit", "standalone_update"] {
            let fixture = Fixture()
            let coordinator = fixture.coordinator()
            _ = try await coordinator.lookup(Fixture.lookupConfiguration)
            var next = fixture.configuration; next.networkFamily = .dual
            if invalidation != "standalone_update" {
                fixture.failClose = invalidation == "failed_close"
                await coordinator.beginConfigurationChange(reason: "Changing traffic family")
                fixture.failClose = false
                if invalidation == "network_change" { coordinator.supervisorNetworkChanged() }
                if invalidation == "finished_edit" { coordinator.endConfigurationChange() }
            }
            let before = fixture.closeRequests
            await coordinator.update(configuration: next, allowlist: Fixture.allowed, revision: 2)
            require(fixture.closeRequests == before + 1,
                    "\(invalidation): an unconfirmed, invalidated or expired barrier must not suppress closure")
            if invalidation == "failed_close" || invalidation == "network_change" { coordinator.endConfigurationChange() }
            _ = try await coordinator.lookup(Fixture.lookupConfiguration)
            require(coordinator.state.allowsTraffic, "fresh preparation still verifies before opening")
        }
    }

    private static func ipv4ApprovalKeepsProviderHealthy() async throws {
        for mode in [ProxyMode.rule, .global] {
            for family in MimoNetworkFamily.allCases {
                let suite = "com.mimo.tests.ipv4-approval." + UUID().uuidString
                let storage = UserDefaults(suiteName: suite)!
                defer { storage.removePersistentDomain(forName: suite) }
                MonitoringPreferences(provider: .ipWhois, providerPool: [.ipWhois], refreshInterval: .never).save(to: storage)
                let fixture = Fixture(mode: .direct, family: family)
                fixture.allowed = AllowedIPList(addresses: ["192.0.2.99"])
                fixture.lookupFailure = .transport("IPv6 proxy connection refused")
                fixture.failureFamily = .ipv6
                let coordinator = fixture.coordinator()
                await coordinator.update(configuration: fixture.configuration, allowlist: fixture.allowed, revision: 1)
                var protected = fixture.configuration; protected.mode = mode
                await coordinator.update(configuration: protected, allowlist: fixture.allowed, revision: 2)
                let engine = MonitoringEngine(preferencesStore: storage, observeSystem: false,
                    snapshotStore: SnapshotStore(defaults: storage), cooldownStore: ProviderCooldownStore(defaults: storage),
                    refreshAttemptStore: RefreshAttemptStore(defaults: storage), lookupBudgetStore: LookupBudgetStore(defaults: storage),
                    indicatorStore: IndicatorStore(defaults: storage), allowedIPStore: AllowedIPStore(defaults: storage),
                    providerHealthStore: ProviderHealthStore(defaults: storage), diagnosticPreferencesStore: DiagnosticPreferencesStore(defaults: storage),
                    client: MimoLookupClient(coordinator))
                engine.setAllowedIPList(fixture.allowed)
                coordinator.willRequest = { try engine.accountActualRequest($0) }
                engine.requiredCheckUnavailable = { coordinator.requiredCheckUnavailable(reason: $0) }
                engine.start()
                defer { engine.stop() }
                try await wait { fixture.lookupCount > 0 && !engine.lookupInFlight }
                require(fixture.lookupCount == 1 && !engine.isCoolingDown,
                        "Direct→\(mode)/\(family): successful IPv4 must not request IPv6 or pause the healthy provider")
                require(coordinator.state.rejectedExit?.address == Fixture.snapshot.ipAddress,
                        "Display the rejected IPv4 instead of hiding it")
                require(engine.providerHealth[.ipWhois]?.lastSuccess != nil && engine.providerHealth[.ipWhois]?.lastError == nil,
                        "Allowlist rejection is a successful provider request")
                await coordinator.refreshSupervisorState()
                require(coordinator.state.displayedIP?.address == Fixture.snapshot.ipAddress, "Polling retains the rejected address")
                fixture.allowed = Fixture.allowed
                engine.setAllowedIPList(fixture.allowed)
                await coordinator.update(configuration: protected, allowlist: fixture.allowed, revision: 3)
                await engine.refresh(force: true, bypassMinimumInterval: true)
                require(coordinator.state.allowsTraffic && fixture.lookupCount == 2 && !engine.isCoolingDown,
                        "Allowlist-only repair opens after one fresh IPv4 check without changing proxy, token or mode")
            }
        }
        print("PASS: 4 IPv4 approval/provider-health cases across Rule/Global and IPv4/Dual-stack")
    }

    /// Exercise the real scheduler AND coordinator. Coordinator-only tests miss
    /// status notifications which can enqueue additional supervisor commands.
    private static func schedulerFailureClosesOnce() async throws {
        let suite = "com.mimo.tests.blocked-retry." + UUID().uuidString
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        MonitoringPreferences(provider: .ipWhois, providerPool: [.ipWhois], refreshInterval: .never).save(to: storage)
        let fixture = Fixture()
        fixture.lookupFailure = .transport("Temporary proxy outage")
        let coordinator = fixture.coordinator()
        let engine = MonitoringEngine(preferencesStore: storage, observeSystem: false,
            snapshotStore: SnapshotStore(defaults: storage), cooldownStore: ProviderCooldownStore(defaults: storage),
            refreshAttemptStore: RefreshAttemptStore(defaults: storage), lookupBudgetStore: LookupBudgetStore(defaults: storage),
            indicatorStore: IndicatorStore(defaults: storage), allowedIPStore: AllowedIPStore(defaults: storage),
            providerHealthStore: ProviderHealthStore(defaults: storage), diagnosticPreferencesStore: DiagnosticPreferencesStore(defaults: storage),
            client: MimoLookupClient(coordinator))
        coordinator.willRequest = { try engine.accountActualRequest($0) }
        // Same wiring as DaemonService; scheduler and coordinator both run.
        engine.requiredCheckUnavailable = { coordinator.requiredCheckUnavailable(reason: $0) }
        engine.start()
        defer { engine.stop() }
        try await wait { engine.isCoolingDown && !engine.lookupInFlight }
        print("Scheduler failure regression: \(fixture.lookupCount) lookup, \(fixture.closeRequests) close commands")
        require(fixture.lookupCount == 1 && fixture.closeRequests == 1,
                "one failed lookup must close once; scheduler status changes must not enqueue extra closes")
        fixture.lookupFailure = nil
        await engine.refresh(force: true, bypassMinimumInterval: true)
        require(fixture.lookupCount == 2 && coordinator.state.allowsTraffic && engine.manualRefresh?.phase == .succeeded,
                "the actual scheduler must retry a repaired connection in the same protected session")
    }

    private static func obsoleteSchedulerNoticeCannotCloseNewProbe() async throws {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        coordinator.requiredCheckUnavailable(reason: "Old scheduler failure")
        fixture.holdPrepare = true
        let release = Task {
            try await wait { fixture.prepareGate.waiting }
            fixture.prepareGate.resume(fixture.policy.state)
        }
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        try await release.value
        require(fixture.closeRequests == 0 && coordinator.state.allowsTraffic,
                "a queued old status notification must not revoke a newer probe")
        coordinator.requiredCheckUnavailable(reason: "Real fresh-check refusal")
        try await wait { fixture.closeRequests == 1 }
        require(!coordinator.state.allowsTraffic, "an unfulfilled required check must still revoke active approval")
    }

    private static func directCancelsPendingLookupMatrix() async throws {
        for mode in [ProxyMode.rule, .global] {
            for family in [MimoNetworkFamily.ipv4, .dual] {
                let fixture = Fixture(mode: mode, family: family)
                let coordinator = fixture.coordinator()
                fixture.holdLookup = true
                let pending = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
                try await wait { fixture.lookupGate.waiting }
                var direct = fixture.configuration; direct.mode = .direct
                // This must return before the pending network request does.
                await coordinator.update(configuration: direct, allowlist: fixture.allowed, revision: 2)
                require(coordinator.state.allowsTraffic && coordinator.state.effectiveMode == .direct,
                        "Direct must restore access without waiting for the stalled HTTP lookup")
                fixture.lookupGate.resume(Fixture.snapshot)
                try await cancelled(pending)
                require(fixture.approvals.isEmpty && coordinator.state.effectiveMode == .direct,
                        "The late lookup must not undo Direct or authorize a partial-family result")
            }
        }
        print("PASS: 4 pending-lookup Direct cancellation cases across Rule/Global and IPv4/dual")
    }

    private static func exceptionRecoveryMatrix() async throws {
        let failures: [(String, LookupError)] = [
            ("proxy refused", .transport("Proxy connection refused")),
            ("proxy timed out", .transport("Proxy connection timed out")),
            ("proxy authentication", .httpStatus(407, retryAfter: nil)),
            ("IP provider unavailable", .httpStatus(503, retryAfter: nil)),
            ("invalid IP provider response", .invalidResponse)
        ]
        var rows = 0
        for mode in [ProxyMode.rule, .global] {
            for family in [MimoNetworkFamily.ipv4, .dual] {
                for startInDirect in [false, true] {
                    for (name, failure) in failures {
                        let fixture = Fixture(mode: startInDirect ? .direct : mode, family: family)
                        let coordinator = fixture.coordinator()
                        if startInDirect {
                            await coordinator.update(configuration: fixture.configuration, allowlist: fixture.allowed, revision: 1)
                        } else {
                            _ = try await coordinator.lookup(Fixture.lookupConfiguration)
                        }
                        require(coordinator.state.allowsTraffic, "\(name): establish the starting mode")
                        let count = fixture.approvals.count
                        fixture.lookupFailure = failure
                        // Required IPv4 failures block both traffic settings.
                        fixture.failureFamily = .ipv4
                        var protected = fixture.configuration; protected.mode = mode
                        if startInDirect {
                            await coordinator.update(configuration: protected, allowlist: fixture.allowed, revision: 2)
                            require(!coordinator.state.allowsTraffic && coordinator.state.effectiveMode == nil &&
                                    fixture.lookupCount == 0 && fixture.closeRequests > 0,
                                    "Direct→\(mode): close before attempting a potentially failing lookup")
                        }
                        do {
                            _ = try await coordinator.lookup(Fixture.lookupConfiguration)
                            fatalError("\(name): failure was swallowed")
                        } catch let error as LookupError {
                            require(error == failure, "\(name): preserve the lookup error for monitoring feedback")
                        }
                        require(coordinator.state.phase == .blocked && !coordinator.state.allowsTraffic &&
                                coordinator.state.effectiveMode == nil && fixture.approvals.count == count &&
                                coordinator.state.configuration.mode == mode,
                                "\(name): no cached approval, partial-family approval or automatic Direct fallback")
                        require(coordinator.state.observedIP == nil && coordinator.state.rejectedExit == nil,
                                "A failed request returns no fresh address or allowlist verdict")
                        require((coordinator.state.lastKnownExit != nil) == !startInDirect,
                                "Show last known protected exit only when this proxy previously returned an address")
                        let failedCalls = fixture.lookupCount
                        for _ in 0..<5 { await coordinator.refreshSupervisorState() }
                        require((coordinator.state.lastKnownExit != nil) == !startInDirect,
                                "Status polling preserves display-only history")
                        require(fixture.lookupCount == failedCalls && !coordinator.state.allowsTraffic,
                                "Status polling must not trigger a failure/retry loop")
                        var direct = protected; direct.mode = .direct
                        await coordinator.update(configuration: direct, allowlist: fixture.allowed, revision: 3)
                        require(coordinator.state.allowsTraffic && coordinator.state.effectiveMode == .direct &&
                                fixture.lookupCount == failedCalls,
                                "Use Direct must restore networking while the failure still exists, without an IP lookup")
                        await coordinator.update(configuration: protected, allowlist: fixture.allowed, revision: 4)
                        fixture.lookupFailure = nil
                        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
                        require(coordinator.state.allowsTraffic && coordinator.state.effectiveMode == mode &&
                                fixture.approvals.count == count + 1,
                                "\(name): fresh successful verification restores the selected mode")
                        rows += 1
                    }
                    var rejectedLists = [AllowedIPList(addresses: []), AllowedIPList(addresses: ["192.0.2.99"])]
                    if family == .dual { rejectedLists.append(AllowedIPList(addresses: ["2001:db8::10"])) }
                    for rejected in rejectedLists {
                        let fixture = Fixture(mode: startInDirect ? .direct : mode, family: family)
                        let coordinator = fixture.coordinator()
                        if startInDirect {
                            await coordinator.update(configuration: fixture.configuration, allowlist: fixture.allowed, revision: 1)
                        } else {
                            _ = try await coordinator.lookup(Fixture.lookupConfiguration)
                        }
                        require(coordinator.state.allowsTraffic, "Establish the allowlist test's starting mode")
                        fixture.allowed = rejected
                        var protected = fixture.configuration; protected.mode = mode
                        await coordinator.update(configuration: protected, allowlist: rejected, revision: 2)
                        require(!coordinator.state.allowsTraffic && coordinator.state.effectiveMode == nil,
                                "Changing mode or allowlist must close before fresh verification")
                        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
                        require(coordinator.state.phase == .blocked && coordinator.state.rejectedExit != nil &&
                                coordinator.state.effectiveMode == nil && coordinator.state.configuration.mode == mode,
                                "Unapproved exit: successful lookup remains a policy rejection in the chosen mode")
                        let failedCalls = fixture.lookupCount
                        for _ in 0..<5 { await coordinator.refreshSupervisorState() }
                        require(fixture.lookupCount == failedCalls, "Rejection must not create a polling-triggered lookup loop")
                        var direct = protected; direct.mode = .direct
                        await coordinator.update(configuration: direct, allowlist: rejected, revision: 3)
                        require(coordinator.state.allowsTraffic && coordinator.state.effectiveMode == .direct &&
                                fixture.lookupCount == failedCalls,
                                "Direct remains usable even with an empty or incorrect allowlist")
                        fixture.allowed = AllowedIPList(addresses: ["192.0.2.10", "2001:db8::10"])
                        await coordinator.update(configuration: protected, allowlist: fixture.allowed, revision: 4)
                        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
                        require(coordinator.state.allowsTraffic, "Allowlist correction requires fresh verification")
                        rows += 1
                    }
                }
            }
        }
        require(rows == 60, "All failure, starting-mode and recovery combinations must execute")
        print("PASS: 60 exception/recovery simulations across Direct→Rule/Global and active Rule/Global, IPv4/dual (unapproved/empty/IPv6-only exits, proxy refusal/timeout/authentication, provider outage and invalid responses)")
    }

    private static func directFamilySurvivesSupervisorPoll() async throws {
        let fixture = Fixture(mode: .direct)
        let coordinator = fixture.coordinator()
        await coordinator.update(configuration: fixture.configuration, allowlist: Fixture.allowed, revision: 1)
        var next = fixture.configuration; next.networkFamily = .dual
        await coordinator.update(configuration: next, allowlist: Fixture.allowed, revision: 2, preservingAccess: true)
        await coordinator.refreshSupervisorState()
        require(coordinator.state.configuration.networkFamily == .dual && coordinator.state.allowsTraffic,
                "supervisor polls preserve the core's new family selection in Direct")
        require(fixture.lookupCount == 0, "Direct family selection does not verify a protected exit")
    }

    private static func singlePreparationOwnsClosure() async throws {
        let fixture = Fixture()
        fixture.holdPrepare = true
        let coordinator = fixture.coordinator()
        let task = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.prepareGate.waiting }
        require(coordinator.state.phase == .validating, "confirmed prepare progress must display blocking before profile completion")
        require(fixture.closeRequests == 0, "prepare must not be preceded by a duplicate close RPC")
        let staleProgress = fixture.lastProgress
        var blocked = MimoRoutingState(configuration: fixture.configuration)
        blocked.phase = .blocked
        fixture.prepareGate.resume(fixture.policy.state)
        _ = try await task.value
        staleProgress?(blocked)
        require(coordinator.state.allowsTraffic, "late preparation progress must not overwrite completed approval")
    }

    private static func approvalProgressWaitsAndCannotUndoDirect() async throws {
        let fixture = Fixture()
        fixture.holdApproval = true
        let coordinator = fixture.coordinator()
        let task = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.approvalGate.waiting }
        require(coordinator.state.phase == .checking && !coordinator.state.allowsTraffic,
                "approved IP must remain visibly blocked until readiness completes")
        require(coordinator.state.observedIP?.address == Fixture.snapshot.ipAddress,
                "readiness progress must show the newly checked IP")
        let lateProgress = fixture.lastProgress
        let old = fixture.policy.state
        var direct = fixture.configuration; direct.mode = .direct
        await coordinator.update(configuration: direct, allowlist: Fixture.allowed, revision: 2)
        lateProgress?(old)
        fixture.approvalGate.resume(old)
        try await cancelled(task)
        require(coordinator.state.allowsTraffic && coordinator.state.effectiveMode == .direct,
                "late readiness progress/results cannot undo the newer Direct selection")
    }

    private static func failedPreparationCannotProbe() async throws {
        let fixture = Fixture()
        fixture.failPrepareClose = true
        let coordinator = fixture.coordinator()
        do { _ = try await coordinator.lookup(Fixture.lookupConfiguration); fatalError("failed closure must abort") } catch {}
        require(fixture.lookupCount == 0 && fixture.approvals.isEmpty && coordinator.state.phase == .unavailable,
                "failed prepare closure must never spend an exit lookup, approve or display confirmed blocking")
    }

    private static func supervisorEventInvalidatesWithoutDuplicateClose() async throws {
        let fixture = Fixture()
        fixture.holdLookup = true
        let coordinator = fixture.coordinator()
        let old = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.lookupGate.waiting }
        coordinator.supervisorNetworkChanged()
        fixture.lookupGate.resume(Fixture.snapshot)
        try await cancelled(old)
        require(fixture.approvals.isEmpty && fixture.closeRequests == 0,
                "a supervisor event must revoke old results without requesting another full close")
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        require(coordinator.state.allowsTraffic && fixture.approvals.count == 1,
                "only the fresh post-event probe may approve")
    }

    private static func nonRoutingRevisionPreservesVerifiedAccess() async throws {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        require(coordinator.state.allowsTraffic, "fixture must first verify protected access")
        let proof = coordinator.state.verification
        await coordinator.update(configuration: fixture.configuration, allowlist: Fixture.allowed, revision: 2,
                                 preservingAccess: true)
        require(coordinator.state.allowsTraffic && coordinator.state.verification == proof && fixture.lookupCount == 1,
                "a Tailnet/diagnostic revision must preserve the independently verified public connection")
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        require(fixture.approvals.last?.revision == 2, "the next verification must use the new revision")
    }

    private static func delayedDirectCannotOpenClosedGate() async throws {
        let fixture = Fixture(mode: .direct)
        let coordinator = fixture.coordinator()
        fixture.holdDirectDelivery = true
        let old = Task { await coordinator.update(configuration: fixture.configuration, allowlist: Fixture.allowed, revision: 1) }
        try await wait { fixture.directDeliveryGate.waiting }
        var protected = fixture.configuration; protected.mode = .rule
        await coordinator.update(configuration: protected, allowlist: Fixture.allowed, revision: 2)
        fixture.directDeliveryGate.resume(true)
        await old.value
        require(fixture.policy.state.phase == .blocked && !fixture.policy.state.allowsTraffic,
                "a delayed old Direct command must not open the actual supervisor gate")
    }

    private static func delayedCloseCannotUndoDirect() async throws {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        fixture.holdCloseDelivery = true
        let old = Task { await coordinator.networkChanged() }
        try await wait { fixture.closeDeliveryGate.waiting }
        var direct = fixture.configuration; direct.mode = .direct
        await coordinator.update(configuration: direct, allowlist: Fixture.allowed, revision: 2)
        fixture.closeDeliveryGate.resume(true)
        await old.value
        require(fixture.policy.state.allowsTraffic && fixture.policy.state.effectiveMode == .direct,
                "a delayed old close must not undo a newer Direct selection")
    }

    private static func staleHeartbeatAfterClose() async throws {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        let old = fixture.policy.state
        fixture.holdHeartbeat = true
        let poll = Task { await coordinator.refreshSupervisorState() }
        try await wait { fixture.heartbeatGate.waiting }
        await coordinator.networkChanged()
        fixture.heartbeatGate.resume(.success(old))
        await poll.value
        require(coordinator.state.phase == .blocked, "a delayed active heartbeat must not replace a newer closed gate")
    }

    private static func outOfOrderHeartbeats() async throws {
        let fixture = Fixture()
        let coordinator = fixture.coordinator()
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        let old = fixture.policy.state
        fixture.holdHeartbeat = true
        let first = Task { await coordinator.refreshSupervisorState() }
        try await wait { fixture.heartbeatGate.waiting }
        fixture.failHeartbeat = true
        await coordinator.refreshSupervisorState()
        fixture.heartbeatGate.resume(.success(old))
        await first.value
        require(coordinator.state.phase == .unavailable, "an older successful poll must not hide a newer supervisor failure")
    }

    private static func heartbeatDuringTransition() async throws {
        let fixture = Fixture()
        fixture.holdPrepare = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.prepareGate.waiting }
        let candidate = fixture.policy.state
        fixture.holdHeartbeat = true
        let poll = Task { await coordinator.refreshSupervisorState() }
        try await wait { fixture.heartbeatGate.waiting }
        fixture.prepareGate.resume(candidate)
        _ = try await check.value
        require(coordinator.state.allowsTraffic, "the current probe must complete")
        fixture.heartbeatGate.resume(.success(candidate))
        await poll.value
        require(coordinator.state.allowsTraffic, "a poll begun during preparation must not overwrite its completed transition")
    }

    private static func networkChangeDuringPreparation() async throws {
        let fixture = Fixture()
        fixture.holdPrepare = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.prepareGate.waiting }
        let candidate = fixture.policy.state
        await coordinator.networkChanged()
        fixture.prepareGate.resume(candidate)
        try await cancelled(check)
        require(fixture.lookupCount == 0 && fixture.approvals.isEmpty,
                "superseded preparation must not spend a provider lookup or approve traffic")
        require(coordinator.state.phase == .blocked, "cancelled preparation must preserve confirmed blocking")
    }

    private static func networkChangeDuringLookup() async throws {
        let fixture = Fixture()
        fixture.holdLookup = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.lookupGate.waiting }
        await coordinator.networkChanged()
        fixture.lookupGate.resume(Fixture.snapshot)
        try await cancelled(check)
        require(fixture.approvals.isEmpty && coordinator.state.phase == .blocked,
                "an IP result from the previous network must never reach approval")
    }

    private static func cancelledLookupCannotApprove() async throws {
        let fixture = Fixture()
        fixture.holdLookup = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.lookupGate.waiting }
        check.cancel()
        fixture.lookupGate.resume(Fixture.snapshot)
        try await cancelled(check)
        require(fixture.approvals.isEmpty && !fixture.policy.state.allowsTraffic,
                "a timed-out or cancelled lookup must not submit a successful late result for approval")
        require(MimoLookupClient(coordinator).lookupTimeout > PublicIPLookupClient().lookupTimeout,
                "managed routing must budget preparation and activation separately from the HTTP deadline")
    }

    private static func heartbeatPulseDoesNotWaitForStatus() async throws {
        var configuration = MimoConfiguration()
        configuration.mode = .rule
        let statusGate = Gate<Bool>()
        var pulses = 0
        let coordinator = MimoCoordinator(configuration: configuration, allowlist: Fixture.allowed, revision: 1,
            transport: { message, _ in
                if message.livenessOnly == true { pulses += 1 }
                else if message.command == .heartbeat { _ = await statusGate.wait() }
                return MimoRoutingState(configuration: configuration)
            })
        await coordinator.start()
        try await wait { statusGate.waiting }
        let before = pulses
        try await Task.sleep(for: .milliseconds(1200))
        require(pulses > before, "liveness must continue while a status reply waits behind profile work")
        coordinator.stop()
        statusGate.resume(true)
    }

    private static func credentialChangeDuringLookup() async throws {
        let fixture = Fixture()
        fixture.holdLookup = true
        let coordinator = fixture.coordinator()
        let check = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await wait { fixture.lookupGate.waiting }
        await coordinator.beginConfigurationChange(reason: "Changing lookup credential")
        let blockedAttempt = Task { try await coordinator.lookup(Fixture.lookupConfiguration) }
        try await cancelled(blockedAttempt)
        require(fixture.lookupCount == 1, "no new probe may start while credentials and settings are being committed")
        await coordinator.update(configuration: fixture.configuration, allowlist: Fixture.allowed, revision: 2)
        fixture.lookupGate.resume(Fixture.snapshot)
        try await cancelled(check)
        coordinator.endConfigurationChange()
        require(fixture.approvals.isEmpty, "a pre-change credential result must not approve access")
        _ = try await coordinator.lookup(Fixture.lookupConfiguration)
        require(fixture.approvals.last?.revision == 2 && coordinator.state.allowsTraffic,
                "the next successful probe must use the committed revision")
    }

    private static func directRestoreFailure() async throws {
        let fixture = Fixture(mode: .direct)
        fixture.failDirect = true
        let coordinator = fixture.coordinator()
        do {
            _ = try await coordinator.lookup(Fixture.lookupConfiguration)
            fatalError("a failed Direct restore was treated as ready")
        } catch is MimoRuntimeError { }
        require(fixture.lookupCount == 0 && coordinator.state.phase == .unavailable,
                "Direct must not claim a live result until interception and blocking have been removed")
    }

    private static func cancelled(_ task: Task<MimoSnapshot, Error>) async throws {
        do { _ = try await task.value; fatalError("a superseded operation completed") }
        catch is CancellationError { }
    }

    private static func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { fatalError("test operation did not reach its suspension point") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }

    @MainActor
    private final class Gate<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?
        var waiting: Bool { continuation != nil }
        func wait() async -> Value {
            await withCheckedContinuation { continuation = $0 }
        }
        func resume(_ value: Value) {
            guard let continuation else { fatalError("test gate was not waiting") }
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }

    @MainActor
    private final class Fixture {
        static let allowed = AllowedIPList(addresses: ["192.0.2.10"])
        static let lookupConfiguration = LookupConfiguration(provider: .ipWhois, ipinfoToken: nil)
        static var snapshot: MimoSnapshot {
            MimoSnapshot(ipAddress: "192.0.2.10", countryCode: "SG", countryName: "Singapore", provider: .ipWhois)
        }
        let configuration: MimoConfiguration
        var allowed = Fixture.allowed
        var lookupFailure: LookupError?
        var failureFamily: MimoAddressFamily?
        var policy: MimoAccessPolicy
        var holdHeartbeat = false
        var failHeartbeat = false
        var failDirect = false
        var holdPrepare = false
        var holdApproval = false
        var holdLookup = false
        var lookupCount = 0
        var holdDirectDelivery = false
        var holdCloseDelivery = false
        var closeRequests = 0
        var failClose = false
        var failPrepareClose = false
        var lastProgress: MimoCoordinator.Progress?
        var commandFence = MimoCommandFence()
        let directDeliveryGate = Gate<Bool>()
        let closeDeliveryGate = Gate<Bool>()
        var approvals: [MimoVerification] = []
        let heartbeatGate = Gate<Result<MimoRoutingState, DaemonFailure>>()
        let prepareGate = Gate<MimoRoutingState>()
        let approvalGate = Gate<MimoRoutingState>()
        let lookupGate = Gate<MimoSnapshot>()

        init(mode: ProxyMode = .rule, family: MimoNetworkFamily = .ipv4) {
            var configuration = MimoConfiguration()
            configuration.mode = mode
            configuration.networkFamily = family
            configuration.proxy = MimoProxy(ClashProxySettings(name: "Test", type: .socks5,
                                                               server: "192.0.2.20", port: 1080))
            self.configuration = configuration
            if family == .dual { allowed = AllowedIPList(addresses: ["192.0.2.10", "2001:db8::10"]) }
            policy = MimoAccessPolicy(configuration: configuration)
        }

        func coordinator() -> MimoCoordinator {
            MimoCoordinator(configuration: configuration, allowlist: allowed, revision: 1,
                            transport: { try await self.handle($0, progress: $1) }, lookup: { request, protected in
                require(protected, "fixture probes must use the protected path")
                self.lookupCount += 1
                if let failure = self.lookupFailure, self.failureFamily == nil || request.family == self.failureFamily { throw failure }
                if self.holdLookup {
                    self.holdLookup = false
                    return await self.lookupGate.wait()
                }
                if request.family == .ipv6 {
                    return MimoSnapshot(ipAddress: "2001:db8::10", countryCode: "SG", countryName: "Singapore", provider: request.provider)
                }
                return Self.snapshot
            })
        }

        private func handle(_ message: MimoSupervisorRequest, progress: @escaping MimoCoordinator.Progress) async throws -> MimoRoutingState {
            if message.command == .direct, holdDirectDelivery {
                holdDirectDelivery = false
                _ = await directDeliveryGate.wait()
            }
            if message.command == .close, holdCloseDelivery {
                holdCloseDelivery = false
                _ = await closeDeliveryGate.wait()
            }
            guard let stamp = message.stamp,
                  commandFence.accept(stamp, peer: 42, currentCore: 42, enabled: true,
                                      heartbeat: message.command == .heartbeat || message.command == .state) else {
                throw DaemonFailure.conflict
            }
            switch message.command {
            case .heartbeat, .state:
                if holdHeartbeat {
                    holdHeartbeat = false
                    return try await heartbeatGate.wait().get()
                }
                if failHeartbeat { throw DaemonFailure.unavailable }
            case .close:
                closeRequests += 1
                if failClose { throw DaemonFailure.unavailable }
                policy.block("Verification required")
            case .direct:
                if failDirect { throw DaemonFailure.unavailable }
                policy.directRestored(configuration: message.configuration ?? configuration)
            case .prepare:
                policy.block("Preparing", confirmed: !failPrepareClose)
                if failPrepareClose { return policy.state }
                lastProgress = progress
                progress(policy.state)
                let token = policy.begin(configuration: message.configuration!, revision: message.revision!,
                                         networkGeneration: message.networkGeneration!)
                policy.checking(token)
                if holdPrepare {
                    holdPrepare = false
                    return await prepareGate.wait()
                }
            case .approve:
                if holdApproval {
                    holdApproval = false
                    policy.waitingForReadiness(address: message.address!, verification: message.verification!)
                    lastProgress = progress
                    progress(policy.state)
                    return await approvalGate.wait()
                }
                approvals.append(message.verification!)
                _ = policy.approve(observations: message.exitObservations!, allowlist: allowed,
                                   verification: message.verification!, runtimeMatches: true)
            case .service, .profile: throw DaemonFailure.invalidRequest
            }
            return policy.state
        }
    }
}
