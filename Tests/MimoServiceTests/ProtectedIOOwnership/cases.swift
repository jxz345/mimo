import Foundation
import Darwin

final class ProtectedIOFixture: @unchecked Sendable {
    nonisolated(unsafe) static var shared = ProtectedIOFixture()
    var directory: URL = URL(fileURLWithPath: "/unconfigured-test-fixture")
    var rules = MimoFirewallPolicy.startupBlocking
    var readbackFailure = false
    var allowed = true
    var validGroup = true
    var dnsMatches = true
    var apply: (() -> Void)?
    var afterCommit: (() -> Void)?
    var writes = 0
    func expanded(_ source: String) -> String {
        if source.contains("mimo:transition:deny") { return (MimoFirewallPolicy.controlReadback + ["block drop out quick all label \"mimo:transition:deny\""]).joined(separator:"\n")+"\n" }
        if source.contains("mimo:probe:deny") { return (MimoFirewallPolicy.controlReadback + ["pass out quick inet proto tcp from any to 192.0.2.1 port = 1080 group = 10000 no state label \"mimo:probe:proxy\"", "block drop out quick all label \"mimo:probe:deny\""]).joined(separator:"\n")+"\n" }
        return source
    }
    func command(_ tool: String, _ args: [String], input: Data?) throws {
        guard tool == "/sbin/pfctl", args.contains("-f"), let input else { fatalError("Unexpected external command") }
        rules = expanded(String(decoding: input, as: UTF8.self)); writes += 1
        if MimoFirewallPolicy.isClosedReadback(rules) { readbackFailure = false }
        else { let callback = apply; apply = nil; callback?() }
    }
    func run(_ tool: String, _ args: [String]) -> (text: String, status: Int32) {
        if tool == "/sbin/pfctl", args.contains("-sr") { return (rules, readbackFailure ? 1 : 0) }
        fatalError("Unexpected external process")
    }
    func write(_ value: String, _ name: String) throws { try Data(value.utf8).write(to:directory.appendingPathComponent(name)) }
}
struct OwnershipRow: Codable { let name: String; let passed: Bool; let writes: Int; let closed: Bool; let threw: Bool }
@main struct ProtectedOwnershipTests {
 static func main() throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1]);var rows:[OwnershipRow]=[]
    let scenarios=["permit-success","permit-stale","permit-cancel","permit-readback","grant-success","grant-stale","grant-cancel","grant-readback","grant-policy","grant-event","grant-old-readiness","grant-native","grant-tail","grant-new-direct","grant-dns","grant-group","grant-close-epoch","grant-tail-cancel","grant-receipt-cancel","grant-receipt-direct"]
    for scenario in scenarios {
        let f=ProtectedIOFixture();ProtectedIOFixture.shared=f;f.directory=output.deletingLastPathComponent().appendingPathComponent(scenario)
        try FileManager.default.createDirectory(at:f.directory,withIntermediateDirectories:true)
        var configuration=MimoConfiguration();configuration.mode = .rule
        let lease=MimoProtectedLease(configuration:configuration,revision:1)
        let fence=MimoPowerFence();let epoch=try fence.arm();fence.beginCycle()
        let policy=MimoPreparedProbePolicy(rules:try MimoFirewallPolicy.preparedPolicy(group:10000,endpoints:["192.0.2.1"],proxyPort:1080),group:10000,activeRules:try MimoFirewallPolicy.activePolicy(group:10000,nativeInterfaces:[],nativeEgress:.init()),nativeInterfaces:[],nativeEgress:.init())
        f.rules=f.expanded(policy.rules)
        try f.write("fixture-close","pf-close.epoch");try f.write("initial-mutation","pf-mutation.epoch");try f.write("blocked","gate.state");try f.write(f.rules,"guard.expected")
        var info=proc_bsdinfo();_ = proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size))
        let loaded=MimoLoadedProfileReceipt(process:getpid(),identity:"\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)",digest:Data("fixture".utf8))
        let receipt=MimoReadinessReceipt(process:getpid(),profileDigest:loaded.digest,checkedAt:scenario=="grant-old-readiness" ? ContinuousClock.now.advanced(by:.seconds(-20)):.now)
        if scenario.hasSuffix("stale") {lease.cancel()}
        if scenario.hasSuffix("cancel") {f.apply={lease.cancel()}}
        if scenario.hasSuffix("readback") {f.apply={f.readbackFailure=true}}
        if scenario=="grant-policy" {f.apply={f.allowed=false}}
        if scenario=="grant-event" {f.apply={_ = fence.deferCycleEvent()}}
        if scenario=="grant-dns" {f.dnsMatches=false}
        if scenario=="grant-group" {f.validGroup=false}
        if scenario=="grant-close-epoch" {try f.write("newer-close","pf-close.epoch")}
        if scenario=="grant-tail-cancel" {f.afterCommit={lease.cancel()}}
        if scenario=="grant-tail" {f.afterCommit={_ = fence.deferCycleEvent()}}
        if scenario=="grant-new-direct" {f.afterCommit={
            try! MimoFirewallLock.mutate { f.rules="";try f.write("direct","gate.state") }
            _ = fence.deferCycleEvent()
        }}
        var threw=false
        do {
            if scenario.hasPrefix("permit") {_ = try MimoProtectedIO().permit(policy,closeEpoch:"fixture-close",lease:lease,fence:fence,powerEpoch:epoch)}
            else {try MimoProtectedIO().grant(policy,loaded:loaded,dns:Data(),closeEpoch:"fixture-close",readiness:receipt,address:"203.0.113.10",nativeInterfaces:{scenario=="grant-native" ? ["utun999"]:[]},lease:lease,fence:fence,powerEpoch:epoch)}
            if scenario.hasPrefix("grant-receipt") {
                lease.cancel()
                if scenario=="grant-receipt-direct" {try MimoFirewallLock.mutate {f.rules="";try f.write("direct","gate.state")}}
                try MimoProtectedIO().closeOwnedGrant(lease)
                try lease.check()
            }
        } catch {threw=true}
        let closed=MimoFirewallPolicy.isClosedReadback(f.rules)
        let noMutation=["permit-stale","grant-stale","grant-old-readiness","grant-native","grant-dns","grant-group","grant-close-epoch"].contains(scenario)
        let success=scenario.hasSuffix("success")
        let directMarker = try String(contentsOf:f.directory.appendingPathComponent("gate.state"),encoding:.utf8)
        let passed=success ? !threw && !closed : noMutation ? threw && f.writes==0 : ["grant-new-direct","grant-receipt-direct"].contains(scenario) ? threw && f.rules.isEmpty && directMarker=="direct" : threw && closed
        rows.append(.init(name:scenario,passed:passed,writes:f.writes,closed:closed,threw:threw))
        print("\(scenario) \(passed ? "PASS":"FAIL") writes=\(f.writes)")
    }
    try JSONEncoder().encode(rows).write(to:output)
    print("RESULT \(rows.filter(\.passed).count)/\(rows.count)")
    exit(rows.allSatisfy(\.passed) ? 0:1)
 }
}
