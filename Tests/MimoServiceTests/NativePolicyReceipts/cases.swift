import Foundation
import Darwin

struct CaseResult: Codable {
    let name: String
    var passed: Bool
    var failures: [String]
    var observations: [String: String]
}

@MainActor
struct Fixture {
    let runtime: MimoSystemRuntime
    let root: URL
    let initialPolicy: String
    let initialObservedAt: Date

    init(parent: URL, name: String, blocked: Bool = false, hold: Bool = false,
         failReadback: Bool = false, fullAge: Double = 1, changedNative: Bool = true) throws {
        root = parent.appendingPathComponent(name)
        let oldNative = Self.native(10), newNative = Self.native(changedNative ? 11 : 10)
        initialPolicy = blocked
            ? Facts.canonical(try MimoFirewallPolicy.blockedPolicy(nativeEgress: oldNative))
            : try MimoFirewallPolicy.activePolicy(group: 10000, nativeEgress: oldNative)
        initialObservedAt = Date().addingTimeInterval(-fullAge)
        Facts.shared.reset(root, policy: initialPolicy, native: newNative,
                           hold: hold, failReadback: failReadback)
        try FileManager.default.createDirectory(at: MimoRuntime.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: MimoRuntime.guardDirectory, withIntermediateDirectories: true)
        runtime = MimoSystemRuntime()
        runtime.closed = blocked
        runtime.blockedNativeEgress = oldNative
        runtime.installedPolicy = Self.policy(oldNative)
        try write("gate.state", blocked ? "blocked" : "active")
        try write("guard.expected", initialPolicy)
        try write("pf-mutation.epoch", "initial-mutation")
        try write("pf-close.epoch", "initial-close")
        let digest = MimoPFHealthReceipt.digest(Data(initialPolicy.utf8))
        runtime.latestPFHealthReceipt = .init(mutationEpoch: "initial-mutation", state: blocked ? "blocked" : "active",
            policyDigest: digest, observedAt: initialObservedAt, completedAt: Date().addingTimeInterval(-0.1))
        let record: [String: Any] = ["boot": "isolated-boot", "checkedAt": initialObservedAt.timeIntervalSince1970,
            "pf": "enabled", "launchd": "healthy", "pfCheckedAt": initialObservedAt.timeIntervalSince1970,
            "launchdCheckedAt": Date().addingTimeInterval(-1).timeIntervalSince1970,
            "completedAt": Date().addingTimeInterval(-0.1).timeIntervalSince1970,
            "pfMutationEpoch": "initial-mutation", "pfState": blocked ? "blocked" : "active", "pfPolicyDigest": digest]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: MimoRuntime.guardDirectory.appendingPathComponent("health.json"))
    }
    static func native(_ value: Int) -> MimoNativeEgress {
        var result = MimoNativeEgress(); result.https = ["192.0.2.\(value)"]; return result
    }
    static func policy(_ native: MimoNativeEgress) -> MimoPreparedProbePolicy {
        .init(rules: "isolated-private-probe", group: 10000,
            activeRules: try! MimoFirewallPolicy.activePolicy(group: 10000, nativeEgress: native),
            nativeInterfaces: [], nativeEgress: native)
    }
    func write(_ name: String, _ value: String) throws {
        try Data(value.utf8).write(to: root.appendingPathComponent("Runtime").appendingPathComponent(name), options: .atomic)
    }
    func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Runtime").appendingPathComponent(name), encoding: .utf8)
    }
    func update(blocked: Bool) async -> String? {
        do {
            if blocked { try await runtime.refreshBlockedNativeTransport() }
            else { try await runtime.auditPolicies() }
            return nil
        } catch { return String(describing: type(of: error)) }
    }
    func waitForSnapshot() async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while !Facts.shared.entered {
            guard ContinuousClock.now < until else { throw TestFailure.fixture("Snapshot was not entered") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func observations(error: String? = nil) throws -> [String: String] {
        let status = runtime.infrastructureStatus()
        return ["pf_writes": String(Facts.shared.writes), "pf": status.pf.rawValue,
            "evidence_current": String(status.pfEvidenceCurrent == true),
            "receipt_matches": String(runtime.currentReceiptMatches()),
            "mutation_epoch": try read("pf-mutation.epoch"), "gate_state": runtime.gateState ?? "nil",
            "error_class": error ?? "none"]
    }
}
enum TestFailure: Error { case fixture(String) }

@main
struct Tests {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let casesRoot = output.appendingPathComponent("isolated-files")
        var results: [CaseResult] = []
        let selected = Set(CommandLine.arguments.dropFirst(2))
        let planned = selected.isEmpty ? 10 : selected.count
        func result(_ name: String, _ checks: [(Bool, String)], _ observations: [String: String]) -> CaseResult {
            let failures = checks.filter { !$0.0 }.map(\.1)
            return .init(name: name, passed: failures.isEmpty, failures: failures, observations: observations)
        }
        // Each body is run once. A failed product assertion does not suppress the
        // remaining independent controls; fixture errors are explicit failures.
        func run(_ name: String, extra: Bool = false, _ body: () async throws -> CaseResult) async {
            guard !extra || !selected.isEmpty else { return }
            guard selected.isEmpty || selected.contains(name) else { return }
            do { results.append(try await body()) }
            catch { results.append(.init(name: name, passed: false,
                failures: ["fixture_error"], observations: ["error_class": String(describing: type(of: error))])) }
            let row = results.last!
            print("\(results.count)/\(planned) \(row.name): \(row.passed ? "PASS" : "FAIL") \(row.failures.joined(separator: ","))")
        }
        for blocked in [false, true] {
            let name = blocked ? "blocked-native-update-current-receipt" : "active-native-update-current-receipt"
            await run(name) {
                let f = try Fixture(parent: casesRoot, name: name, blocked: blocked)
                let error = await f.update(blocked: blocked)
                let status = f.runtime.infrastructureStatus()
                return result(name, [(error == nil, "unexpected_operation_failure"),
                    (Facts.shared.writes == 1, "update_not_exercised"),
                    (try f.read("pf-mutation.epoch") != "initial-mutation", "mutation_not_stamped"),
                    (f.runtime.currentReceiptMatches(), "missing_current_receipt"),
                    (status.pf == .healthy && status.pfEvidenceCurrent == true, "healthy_policy_projected_unavailable")], try f.observations(error: error))
            }
        }
        for change in ["epoch", "close", "direct", "intent"] {
            let name = "superseded-\(change)-has-no-policy-or-epoch-side-effect"
            await run(name) {
                let blocked = change == "direct"
                let f = try Fixture(parent: casesRoot, name: name, blocked: blocked, hold: true)
                let work = Task { @MainActor in await f.update(blocked: blocked) }
                try await f.waitForSnapshot()
                // Supersession happens after the old worker captured its input,
                // before that worker re-enters the actor to commit.
                try f.write("pf-mutation.epoch", "new-owner-mutation")
                // Epoch-only ownership replacement deliberately keeps the
                // closure epoch and policy bytes unchanged (same-policy ABA).
                if change != "epoch" { try f.write("pf-close.epoch", "new-owner-close") }
                var ownedPolicy = f.initialPolicy
                if change == "close" {
                    f.runtime.closed = true
                    try f.write("gate.state", "blocked")
                    ownedPolicy = Facts.canonical(MimoFirewallPolicy.startupBlocking)
                } else if change == "direct" {
                    f.runtime.closed = false
                    try f.write("gate.state", "direct")
                    ownedPolicy = ""
                } else if change == "intent" {
                    f.runtime.installedPolicy = Fixture.policy(Fixture.native(12))
                    ownedPolicy = f.runtime.installedPolicy!.activeRules!
                }
                Facts.shared.replacePolicy(ownedPolicy)
                try f.write("guard.expected", ownedPolicy)
                let ownerState = f.runtime.gateState!
                let stamp = Date().addingTimeInterval(-0.01)
                let ownerReceipt = MimoPFHealthReceipt(mutationEpoch: "new-owner-mutation", state: ownerState,
                    policyDigest: MimoPFHealthReceipt.digest(Data(ownedPolicy.utf8)), observedAt: stamp, completedAt: stamp)
                f.runtime.latestPFHealthReceipt = ownerReceipt
                Facts.shared.release.signal()
                let error = await work.value
                return result(name, [(Facts.shared.writes == 0, "stale_worker_wrote_policy"),
                    (try f.read("pf-mutation.epoch") == "new-owner-mutation", "stale_worker_invalidated_new_epoch"),
                    (try f.read("guard.expected") == ownedPolicy, "stale_worker_replaced_expected_policy"),
                    (f.runtime.latestPFHealthReceipt == ownerReceipt && f.runtime.currentReceiptMatches(), "new_owner_receipt_lost")], try f.observations(error: error))
            }
        }
        await run("narrow-readback-does-not-renew-expired-full-guard") {
            let name = "narrow-readback-does-not-renew-expired-full-guard"
            let f = try Fixture(parent: casesRoot, name: name, fullAge: 45)
            let error = await f.update(blocked: false)
            // Supply a valid narrow receipt for the actual successful readback.
            // This negative control must exercise freshness even while today's
            // mutation path omits receipt publication (covered by cases 1–2).
            let readbackAt = Date()
            f.runtime.latestPFHealthReceipt = .init(mutationEpoch: try f.read("pf-mutation.epoch"), state: "active",
                policyDigest: MimoPFHealthReceipt.digest(Data(try f.read("guard.expected").utf8)),
                observedAt: readbackAt, completedAt: readbackAt)
            let status = f.runtime.infrastructureStatus()
            return result(name, [(error == nil && Facts.shared.writes == 1, "mutation_not_exercised"),
                (f.runtime.currentReceiptMatches(), "negative_control_receipt_not_current"),
                (status.pf == .stale, "expired_full_guard_was_blessed"),
                (abs((status.pfCheckedAt ?? .distantFuture).timeIntervalSince(f.initialObservedAt)) < 0.001,
                    "full_guard_observation_renewed")], try f.observations(error: error))
        }
        await run("failed-readback-cannot-publish-healthy-receipt") {
            let name = "failed-readback-cannot-publish-healthy-receipt"
            let f = try Fixture(parent: casesRoot, name: name, failReadback: true)
            let oldReceipt = f.runtime.latestPFHealthReceipt
            let error = await f.update(blocked: false)
            return result(name, [(error != nil && Facts.shared.writes == 1, "failed_readback_not_exercised"),
                (!f.runtime.currentReceiptMatches(), "failed_readback_has_current_receipt"),
                (f.runtime.latestPFHealthReceipt == oldReceipt, "failed_readback_published_receipt"),
                (f.runtime.infrastructureStatus().pf != .healthy, "failed_readback_blessed_policy")], try f.observations(error: error))
        }
        for blocked in [false, true] {
            let name = blocked ? "blocked-lock-contention-keeps-admission-responsive" : "active-lock-contention-keeps-admission-responsive"
            await run(name) {
                let f = try Fixture(parent: casesRoot, name: name, blocked: blocked, hold: true)
                let held = try HeldLock(f.root.appendingPathComponent("Runtime/pf-mutation.lock"))
                let probe = AdmissionProbe()
                let work = Task { @MainActor in await f.update(blocked: blocked) }
                try await f.waitForSnapshot()
                let contentionStarted = ProcessInfo.processInfo.systemUptime
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    let requested = ProcessInfo.processInfo.systemUptime
                    Task { @MainActor in
                        f.runtime.admitDirectIntent()
                        _ = f.runtime.infrastructureStatus()
                        probe.record(ProcessInfo.processInfo.systemUptime - requested)
                    }
                }
                // The release is independent of MainActor, so a synchronous
                // waiter cannot deadlock this control or manufacture a pass.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { held.release() }
                Facts.shared.release.signal()
                let error = await work.value
                let mutationElapsed = ProcessInfo.processInfo.systemUptime - contentionStarted
                let until = ContinuousClock.now.advanced(by: .seconds(2))
                while probe.delay == nil && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
                var observations = try f.observations(error: error)
                observations["admission_delay_seconds"] = probe.delay.map { String($0) } ?? "missing"
                observations["admission_count"] = String(f.runtime.directIntentAdmissions)
                observations["contended_mutation_seconds"] = String(mutationElapsed)
                return result(name, [(error == nil && Facts.shared.writes == 1, "contended_mutation_not_completed"),
                    (mutationElapsed >= 0.7, "real_lock_contention_not_exercised"),
                    (f.runtime.directIntentAdmissions == 1, "actor_callback_not_admitted"),
                    (probe.delay.map { $0 < 0.2 } ?? false, "main_actor_starved_by_pf_lock")], observations)
            }
        }
        await run("stale-scope-read-error-is-superseded", extra: true) {
            let name = "stale-scope-read-error-is-superseded"
            let f = try Fixture(parent: casesRoot, name: name)
            let epochURL = f.root.appendingPathComponent("Runtime/pf-mutation.epoch")
            Facts.shared.setReadHook { number in
                guard number == 1 else { return nil }
                try! Data("replacement-mutation".utf8).write(to: epochURL, options: .atomic)
                return ("", 1)
            }
            let error = await f.update(blocked: false)
            return result(name, [(error == "CancellationError", "stale_read_became_failure"),
                (Facts.shared.writes == 0, "stale_read_wrote_policy"),
                (try f.read("pf-mutation.epoch") == "replacement-mutation", "stale_read_changed_epoch")], try f.observations(error: error))
        }
        await run("stale-noop-snapshot-is-superseded", extra: true) {
            let name = "stale-noop-snapshot-is-superseded"
            let f = try Fixture(parent: casesRoot, name: name, hold: true, changedNative: false)
            let work = Task { @MainActor in await f.update(blocked: false) }
            try await f.waitForSnapshot()
            try f.write("pf-mutation.epoch", "replacement-mutation")
            Facts.shared.release.signal()
            let error = await work.value
            return result(name, [(error == "CancellationError", "stale_noop_reported_current"),
                (Facts.shared.writes == 0, "stale_noop_wrote_policy"),
                (try f.read("pf-mutation.epoch") == "replacement-mutation", "stale_noop_changed_epoch")], try f.observations(error: error))
        }
        await run("cancel-after-admission-skips-pf-command", extra: true) {
            let name = "cancel-after-admission-skips-pf-command"
            let f = try Fixture(parent: casesRoot, name: name, hold: true)
            let work = Task { @MainActor in await f.update(blocked: false) }
            try await f.waitForSnapshot()
            let owner = f.runtime.nativePolicyOwner!
            Facts.shared.setReadHook { number in
                if number == 2 { owner.cancel() }
                return nil
            }
            Facts.shared.release.signal()
            let error = await work.value
            return result(name, [(error == "CancellationError", "cancel_not_terminal"),
                (Facts.shared.writes == 0, "cancelled_owner_executed_pf_command"),
                (!f.runtime.currentReceiptMatches(), "post_admission_cancel_blessed_new_epoch")], try f.observations(error: error))
        }
        await run("pf-acquisition-timeout-defers-without-recovery", extra: true) {
            let name = "pf-acquisition-timeout-defers-without-recovery"
            let f = try Fixture(parent: casesRoot, name: name)
            let held = try HeldLock(f.root.appendingPathComponent("Runtime/pf-mutation.lock"))
            let receipt = f.runtime.latestPFHealthReceipt
            var reconciliations = 0
            f.runtime.nativePolicyDidCommit = { reconciliations += 1 }
            let began = ProcessInfo.processInfo.systemUptime
            let error = await f.update(blocked: false)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            held.release()
            var observations = try f.observations(error: error)
            observations["acquisition_wait_seconds"] = String(elapsed)
            observations["reconciliations"] = String(reconciliations)
            return result(name, [(elapsed >= 4.9 && elapsed < 7, "bounded_lock_timeout_not_exercised"),
                (error == nil, "acquisition_congestion_became_recovery_failure"),
                (try Facts.shared.writes == 0 && f.read("pf-mutation.epoch") == "initial-mutation", "deferred_work_changed_pf"),
                (f.runtime.latestPFHealthReceipt == receipt && f.runtime.currentReceiptMatches(), "deferred_work_changed_receipt"),
                (reconciliations == 0, "deferred_work_scheduled_reconciliation")], observations)
        }
        let data = try JSONEncoder.pretty.encode(results)
        try data.write(to: output.appendingPathComponent("results.json"), options: .atomic)
        print("Finished \(results.count)/\(planned); \(results.filter(\.passed).count) passed; \(results.filter { !$0.passed }.count) failed.")
        exit(results.count == planned && results.allSatisfy(\.passed) ? 0 : 1)
    }
}
extension JSONEncoder {
    static var pretty: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value }
}
