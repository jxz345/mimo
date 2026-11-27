import Foundation

struct CaseResult: Codable {
    let name:String;let passed:Bool;let detail:String;let checks:[Check];let samples:[Sample]
}
@MainActor final class ManualTimer {
    var now = 0.0
    var waits:[UUID:(Double,CheckedContinuation<Void,Error>)]=[:]
    func sleep(_ seconds:Double) async throws {
        let id=UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waits[id]=(now+seconds,$0) }
        } onCancel:{Task{@MainActor in self.waits.removeValue(forKey:id)?.1.resume(throwing:CancellationError())}}
    }
    func advance(_ seconds:Double) {
        now += seconds
        for id in waits.keys.filter({waits[$0]!.0<=now}) {waits.removeValue(forKey:id)?.1.resume()}
    }
}
@main struct Cases {
    @MainActor static func spin() async {for _ in 0..<20 {await Task.yield()}}
    @MainActor static func main() async throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1]);let script=URL(fileURLWithPath:CommandLine.arguments[2]);let c=TestClock.shared
        if CommandLine.arguments.count>3 {
            try await receiptControls(output:output,script:script,includeFailed:CommandLine.arguments[3] != "--new-receipts")
            return
        }
        var results:[CaseResult]=[]
        func record(_ name:String,_ passed:Bool,_ detail:String,trace:Bool=false) {
            results.append(.init(name:name,passed:passed,detail:detail,checks:trace ? c.checks:[],samples:trace ? c.samples:[]))
            print("\(passed ? "PASS":"FAIL") \(name): \(detail)")
        }
        // Only the previously failing diagnostic is repeated. Five passing
        // diagnostic cases remain excluded; all other controls below are new.
        try c.reset("two-discrete-deferrals",root:output.appendingPathComponent("deferrals"),script:script,start:10,checkedAt:0,until:50)
        let h=SupervisorHarness();h.start();await h.infrastructureMonitor?.value
        record("two-discrete-deferrals",c.checks.contains{$0.status==75} && !c.samples.contains{$0.elapsed>=34 && $0.pf=="stale"} && h.networkChecks==0,
            "Real guard+monitor+projection; no overdue health or IP recheck after bounded deferrals.",trace:true)
        do {
            let clock=ManualTimer();let scheduler=MimoInfrastructureScheduler(now:{clock.now},sleep:{try await clock.sleep($0)})
            var finished=false;let task=Task{await scheduler.wait(after:.completed);finished=true};await spin()
            for _ in 0..<100 {scheduler.request(reason:"test_transition")};await spin();clock.advance(0.99);await spin()
            let before = !finished;clock.advance(0.01);await spin();await task.value
            record("coalesced-transition-wake",before && finished && clock.waits.isEmpty,"100 requests coalesce to one1-second wake.");scheduler.stop()
        }
        do {
            var delays:[Double]=[];let scheduler=MimoInfrastructureScheduler(sleep:{delays.append($0)})
            scheduler.request(reason:"completed_while_inspecting");await scheduler.wait(after:.completed);await scheduler.wait(after:.completed)
            record("request-during-inspection",delays==[1,10],"Pending transition wakes once; normal cadence resumes.");scheduler.stop()
        }
        do {
            var delays:[Double]=[];let scheduler=MimoInfrastructureScheduler(sleep:{delays.append($0)})
            for _ in 0..<6 {await scheduler.wait(after:.deferred)}
            record("bounded-deferral-backoff",delays==[1,2,4,4,4,4],"Deferred retries cap at4seconds.");scheduler.stop()
        }
        do {
            let clock=ManualTimer();let scheduler=MimoInfrastructureScheduler(now:{clock.now},sleep:{try await clock.sleep($0)})
            var finished=false;let task=Task{await scheduler.wait(after:.deferred);finished=true};await spin();scheduler.stop();await task.value;await spin()
            scheduler.request(reason:"after_stop");await scheduler.wait(after:.completed)
            record("stop-drains-health-wait",finished && clock.waits.isEmpty,"Stop drains waiter; no new timer.")
        }
        do {
            try c.reset("superseded-receipt",root:output.appendingPathComponent("superseded"),script:script,start:10,checkedAt:0,until:21)
            let h=SupervisorHarness();h.infrastructureRecoveryPending=true;h.policy.state.phase = .blocked;h.start();await h.infrastructureMonitor?.value
            record("superseded-receipt-no-recovery",h.networkChecks==0 && h.infrastructureRecoveryPending,"Old generation cannot cause recovery/IP recheck.",trace:true)
        }
        do {
            var delays:[Double]=[];let scheduler=MimoInfrastructureScheduler(sleep:{delays.append($0)})
            await scheduler.wait(after:.deferred);await scheduler.wait(after:.failed);await scheduler.wait(after:.superseded)
            record("failure-and-supersession-cadence",delays==[1,10,10],"Failed/superseded outcomes reset fast retry level.");scheduler.stop()
        }
        do {
            try c.reset("transition-health-only",root:output.appendingPathComponent("transition"),script:script,start:10,checkedAt:0,until:24)
            let h=SupervisorHarness();for _ in 0..<50 {h.requestInfrastructureReconciliation("protected_active")};h.start();await h.infrastructureMonitor?.value
            record("transition-wake-does-not-verify",h.networkChecks==0 && h.failureCount==0 && c.checks.count>=2,"Actual reconciliation helper/monitor only checks health.",trace:true)
        }
        do {
            let date=Date(timeIntervalSince1970:100);let check=MimoInfrastructureInspection(id:"fixture",generation:1,startedAt:date)
            let value=MimoInfrastructureStatus(pf:.healthy,launchd:.healthy,checkedAt:date.addingTimeInterval(-40),pfCheckedAt:date.addingTimeInterval(-40),launchdCheckedAt:date.addingTimeInterval(-5),completedAt:date,inspection:check)
            record("independent-component-ages",value.current(at:date).pf == .stale && value.current(at:date).launchd == .healthy && value.healthLabel(firewall:true,at:date).hasPrefix("Check overdue") && value.healthLabel(firewall:false,at:date).hasPrefix("Checking"),"Checking/completion cannot reset PF age; launchd ages independently.")
        }
        do {
            try c.reset("evidence-owner",root:output.appendingPathComponent("owner"),script:script,start:10,checkedAt:9,until:20)
            let runtime=MimoSystemRuntime();runtime.infrastructureInspection = .init(id:"new_check",generation:2,startedAt:c.date)
            let value=runtime.infrastructureStatus(generation:2)
            record("new-scan-does-not-adopt-old-evidence",value.pf != .healthy && value.launchd == .healthy,"A new progress owner cannot adopt old PF evidence or invalidate launchd history.")
        }
        do {
            try c.reset("genuine-check-failure",root:output.appendingPathComponent("partial"),script:script,start:10,checkedAt:0,until:20)
            _=BoundedProcess.run("/usr/bin/perl",[script.path,"--check"],timeout:25,captureError:true);let value=c.record()!
            record("partial-scan-retains-launchd-evidence",value.pf=="unavailable" && value.launchd=="healthy" && value.launchdCheckedAt==c.base && value.pfCheckedAt==c.base+11,"PF failure preserves actual previous launchd result/time.")
        }
        do {
            let date=Date(timeIntervalSinceReferenceDate:100);let data=Data("{\"pf\":\"healthy\",\"launchd\":\"healthy\",\"checkedAt\":90}".utf8)
            let old=try JSONDecoder().decode(MimoInfrastructureStatus.self,from:data)
            var current=old;current.inspection = .init(id:"fixture",generation:1,startedAt:date,completedAt:date,outcome:.deferred,reason:"snapshot_changed")
            let roundtrip=try JSONDecoder().decode(MimoInfrastructureStatus.self,from:JSONEncoder().encode(current))
            record("legacy-progress-roundtrip",old.current(at:date).pf == .healthy && roundtrip==current && current.healthLabel(firewall:true,at:date).hasPrefix("Check pending") && current.healthLabel(firewall:true,at:date.addingTimeInterval(30)).hasPrefix("Check overdue"),"Legacy record and new progress decode; overdue outranks pending.")
        }
        do {
            try c.reset("persistent-failure-episode",root:output.appendingPathComponent("persistent"),script:script,start:10,checkedAt:0,until:26)
            let h=SupervisorHarness();h.start();await h.infrastructureMonitor?.value
            record("persistent-failure-single-episode",h.failureCount==1 && c.checks.count<=3,"Persistent failure closes once; no1s close/wake loop.",trace:true)
        }
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(results).write(to:output.appendingPathComponent("results.json"))
        print("\(results.filter(\.passed).count)/\(results.count) passed");if results.contains(where:{!$0.passed}) {exit(1)}
    }

    @MainActor static func receiptControls(output:URL,script:URL,includeFailed:Bool) async throws {
        let c=TestClock.shared;var results:[CaseResult]=[]
        func record(_ name:String,_ passed:Bool,_ detail:String,trace:Bool=false) {
            results.append(.init(name:name,passed:passed,detail:detail,checks:trace ? c.checks:[],samples:trace ? c.samples:[]))
            print("\(passed ? "PASS":"FAIL") \(name): \(detail)")
        }
        func reset(_ name:String,old:Double=9) throws -> MimoSystemRuntime {
            try c.reset(name,root:output.appendingPathComponent(name),script:script,start:10,checkedAt:old,until:26)
            let runtime=MimoSystemRuntime();runtime.infrastructureInspection = .init(id:"new_check",generation:2,startedAt:c.date)
            return runtime
        }
        func receipt(_ state:String="active",policy:String="fixture policy",epoch:String="fixture-epoch") -> MimoPFHealthReceipt {
            .init(mutationEpoch:epoch,state:state,policyDigest:MimoPFHealthReceipt.digest(Data(policy.utf8)),observedAt:c.date,completedAt:c.date)
        }
        if includeFailed {
            let runtime=try reset("evidence-owner");let value=runtime.infrastructureStatus(generation:2)
            record("new-scan-does-not-adopt-old-evidence",value.pf != .healthy && value.launchd == .healthy,
                "New progress is not PF evidence; launchd history is independent.")
        }
        if includeFailed {
            _=try reset("persistent-failure-episode",old:0)
            let h=SupervisorHarness();h.start();await h.infrastructureMonitor?.value
            record("persistent-failure-single-episode",h.failureCount==1 && c.checks.count<=3,"Persistent fault closes once and retains bounded normal retry.",trace:true)
        }
        do {
            let runtime=try reset("replacement-epoch");runtime.latestPFHealthReceipt=receipt()
            let before=runtime.infrastructureStatus(generation:2)
            try Data("replacement-epoch".utf8).write(to:runtime.directory.appendingPathComponent("pf-mutation.epoch"))
            let after=runtime.infrastructureStatus(generation:2)
            record("replacement-epoch-rejects-policy-receipt",before.pf == .healthy && after.pf == .unknown && after.launchd == .healthy,
                "Actual current-scope reader rejects a replaced epoch without erasing independent launchd evidence.")
        }
        do {
            let runtime=try reset("direct-receipt")
            try Data("direct".utf8).write(to:runtime.directory.appendingPathComponent("gate.state"))
            try Data().write(to:runtime.directory.appendingPathComponent("guard.expected"))
            runtime.latestPFHealthReceipt=receipt("direct",policy:"")
            let before=runtime.infrastructureStatus(generation:2)
            try Data("new protected policy".utf8).write(to:runtime.directory.appendingPathComponent("guard.expected"))
            let after=runtime.infrastructureStatus(generation:2)
            record("direct-receipt-requires-exact-empty-policy",before.pf == .healthy && after.pf == .unknown,
                "Direct evidence cannot bless a different policy even if the epoch/state text is unchanged.")
        }
        do {
            let runtime=try reset("policy-evidence-owner")
            runtime.latestPFHealthReceipt=receipt()
            runtime.infrastructureInspection = .init(id:"old_progress",generation:1,startedAt:c.date,completedAt:c.date,outcome:.superseded,isCurrent:false)
            let value=runtime.infrastructureStatus(generation:2)
            record("policy-evidence-independent-of-check-progress",value.pf == .healthy && value.launchd == .healthy && value.pfEvidenceCurrent==true && value.pfCheckedAt==Date(timeIntervalSince1970:c.base+9),
                "Genuine matching policy evidence remains current across check ownership changes; its age remains conservative.")
        }
        do {
            let runtime=try reset("narrow-policy-stale-baseline",old:-30)
            runtime.latestPFHealthReceipt=receipt()
            let stale=runtime.infrastructureStatus(generation:2)
            let future=MimoPFHealthReceipt(mutationEpoch:"fixture-epoch",state:"active",policyDigest:MimoPFHealthReceipt.digest(Data("fixture policy".utf8)),observedAt:c.date,completedAt:c.date.addingTimeInterval(1))
            record("narrow-policy-cannot-refresh-full-baseline",stale.pf == .stale && stale.pfCheckedAt==Date(timeIntervalSince1970:c.base-30) && !future.matches(epoch:"fixture-epoch",state:"active",policy:Data("fixture policy".utf8),at:c.date),
                "Fresh narrow readback cannot renew40s full-guard evidence; future completion is rejected.")
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(results).write(to:output.appendingPathComponent("results.json"))
        print("\(results.filter(\.passed).count)/\(results.count) passed");if results.contains(where:{!$0.passed}) {exit(1)}
    }
}
