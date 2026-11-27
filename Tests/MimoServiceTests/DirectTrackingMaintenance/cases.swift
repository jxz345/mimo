import Foundation
import Darwin
final class Inventory: @unchecked Sendable {
    static let shared = Inventory()
    private let lock = NSLock()
    private var values = ["192.0.2.10"]
    private var hold = false
    private var enteredValue = false
    private var releasedValue = false
    var release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { enteredValue } }
    var released: Bool { lock.withLock { releasedValue } }
    func changeDestinations() { lock.withLock { values = ["192.0.2.12"] } }
    func setReleased() { lock.withLock { releasedValue = true } }
    func reset(changed: Bool, held: Bool) {
        lock.withLock { values = [changed ? "192.0.2.11" : "192.0.2.10"]; hold = held; enteredValue = false; releasedValue = false; release = DispatchSemaphore(value: 0) }
    }
    func snapshot() -> [String] {
        let saved = lock.withLock { enteredValue = true; return (values, hold) }
        if saved.1 { precondition(release.wait(timeout: .now() + 4) == .success) }
        return saved.0
    }
}
@main struct DirectTests {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]);let selected = Set(CommandLine.arguments.dropFirst(2));let planned = selected.isEmpty ? 6 : selected.count
        var results: [CaseResult] = []
        var names = ["changed-inventory-refreshes-direct-only", "unchanged-inventory-is-noop", "close-supersedes-direct-refresh", "release-supersedes-direct-refresh", "direct-contention-keeps-admission-responsive", "direct-acquisition-timeout-defers"]
        if selected.contains("inventory-drift-under-lock-is-superseded") { names.append("inventory-drift-under-lock-is-superseded") }
        for name in names {
            guard selected.isEmpty || selected.contains(name) else { continue }
            let drift = name == "inventory-drift-under-lock-is-superseded"
            let held = name.contains("supersedes"), changed = name != "unchanged-inventory-is-noop"
            let f = try Fixture(parent: output.appendingPathComponent("isolated-files"), name: name)
            Inventory.shared.reset(changed: changed, held: held)
            f.runtime.installedPolicy = nil; f.runtime.closed = false
            let initial = try MimoFirewallPolicy.directTracking(destinations: ["192.0.2.10"])
            Facts.shared.replacePolicy(initial);try f.write("gate.state", "direct");try f.write("guard.expected", initial)
            let beforeReceipt = MimoPFHealthReceipt(mutationEpoch: "initial-mutation", state: "direct", policyDigest: MimoPFHealthReceipt.digest(Data(initial.utf8)), observedAt: .now, completedAt: .now)
            f.runtime.latestPFHealthReceipt = beforeReceipt
            var callbacks = 0;f.runtime.nativePolicyDidCommit = { callbacks += 1 }
            var errors: [String] = [], operationError: String?
            var heldLock: HeldLock?
            let probe = AdmissionProbe(), started = ProcessInfo.processInfo.systemUptime
            if name.contains("contention") || name.contains("timeout") || drift { heldLock = try HeldLock(f.root.appendingPathComponent("Runtime/pf-mutation.lock")) }
            if name.contains("contention"), let owned = heldLock {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    let requested = ProcessInfo.processInfo.systemUptime
                    Task { @MainActor in f.runtime.admitDirectIntent();probe.record(ProcessInfo.processInfo.systemUptime - requested) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { owned.release() }
            }
            let work = Task { @MainActor in
                do { try await f.runtime.refreshDirectTracking(); return String?.none }
                catch { return String(describing: type(of: error)) }
            }
            if drift {
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while !Inventory.shared.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
                if !Inventory.shared.entered { errors.append("snapshot_not_exercised") }
                Inventory.shared.changeDestinations()
                heldLock?.release()
            }
            if held {
                let deadline = ContinuousClock.now.advanced(by: .seconds(0.4))
                while !Inventory.shared.entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
                if !Inventory.shared.entered { errors.append("maintenance_entry_not_exercised") }
                f.runtime.cancelNativePolicyUpdates()
                if name.hasPrefix("close") { f.runtime.closed = true;try f.write("gate.state", "blocked") }
                else { Inventory.shared.setReleased();try f.write("gate.state", "released") }
                try f.write("pf-mutation.epoch", "new-owner-mutation")
                Inventory.shared.release.signal()
            }
            operationError = await work.value
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            heldLock?.release()
            if name == "changed-inventory-refreshes-direct-only" || name.contains("contention") {
                if operationError != nil { errors.append("update_failed") }
                if Facts.shared.writes != 1 { errors.append("tracking_not_updated") }
                if try f.read("guard.expected") != MimoFirewallPolicy.directTracking(destinations: ["192.0.2.11"]) { errors.append("wrong_tracking_snapshot") }
                if !f.runtime.currentReceiptMatches() || callbacks != 1 { errors.append("receipt_or_reconciliation_missing") }
            } else if drift {
                if operationError != "CancellationError" { errors.append("old_inventory_not_superseded") }
                if try Facts.shared.writes != 0 || f.read("pf-mutation.epoch") != "initial-mutation" { errors.append("stale_inventory_changed_policy_or_epoch") }
                if callbacks != 0 || f.runtime.latestPFHealthReceipt != beforeReceipt { errors.append("stale_inventory_receipt_adopted") }
            } else if held {
                if try Facts.shared.writes != 0 || f.read("pf-mutation.epoch") != "new-owner-mutation" { errors.append("superseded_side_effect") }
            } else {
                if operationError != nil || Facts.shared.writes != 0 || callbacks != 0 || f.runtime.latestPFHealthReceipt != beforeReceipt { errors.append("no_op_or_defer_changed_state") }
            }
            if name.contains("contention") {
                let until = ContinuousClock.now.advanced(by: .seconds(1))
                while probe.delay == nil && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
                if elapsed < 0.7 { errors.append("lock_contention_not_exercised") }
                if !(probe.delay.map { $0 < 0.2 } ?? false) { errors.append("actor_admission_slow") }
            }
            if name.contains("timeout") && (elapsed < 4.9 || elapsed > 7) { errors.append("acquisition_timeout_not_exercised") }
            if !held && f.runtime.gateState != "direct" { errors.append("direct_gate_changed") }
            var observations = try f.observations(error: operationError)
            observations["callbacks"] = String(callbacks);observations["elapsed_seconds"] = String(elapsed)
            observations["admission_delay_seconds"] = probe.delay.map { String($0) } ?? "not_applicable"
            results.append(.init(name: name, passed: errors.isEmpty, failures: errors, observations: observations))
            print("\(results.count)/\(planned) \(name): \(errors.isEmpty ? "PASS" : "FAIL") \(errors.joined(separator: ","))")
        }
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(results).write(to: output.appendingPathComponent("results.json"))
        exit(results.count == planned && results.allSatisfy(\.passed) ? 0 : 1)
    }
}
