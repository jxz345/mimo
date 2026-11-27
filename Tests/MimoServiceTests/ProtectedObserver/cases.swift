import Foundation
import Darwin
@MainActor final class ObserverFacts {
 static var shared=ObserverFacts()
 var signature="inet 198.18.0.1",dns=NSDictionary(dictionary:["ServerAddresses":["127.0.0.1"]]),interfaces=["en0"]
}
struct ObserverRow:Codable {let name:String;let passed:Bool;let events:Int;let elapsed:Double}
func waitObserver(_ semaphore:DispatchSemaphore)->DispatchTimeoutResult {semaphore.wait(timeout:.now()+2)}
@main struct ObserverTests {
 @MainActor static func main()async throws {
  let out=URL(fileURLWithPath:CommandLine.arguments[1]);var rows:[ObserverRow]=[]
  for name in ["owned-dns","external-dns","owned-route","external-route","owned-burst","mixed-burst","overflow-external","nested"] {
   ObserverFacts.shared=ObserverFacts();let f=ObserverFacts.shared
   let fence=MimoPowerFence();let epoch=try fence.arm();fence.beginCycle()
   var changes=0;let observer=MimoNetworkObserver(earlyBlock:{nil},changed:{_,_ in changes += 1})
   observer.testSeed();observer.willChangeProfile(engineProcess:123)
   if name=="nested" {observer.willChangeProfile(engineProcess:123)}
   let count=name.contains("burst") ? 128 : name=="overflow-external" ? 257:1
   for index in 0..<count {
    let early=try fence.observeNetworkChange {}
    if name.contains("route") {
     let owned=name=="owned-route"
     observer.testRoute([.init(type:RTM_ADD,interfaceName:owned ? MihomoProfile.tunnelDevice:"en0",interfaceIndex:0,processID:owned ? 123:456,addresses:[])],early:early)
    } else {
     let external=name=="external-dns" || (name=="mixed-burst" && index==127) || (name=="overflow-external" && index==256)
     observer.testConfiguration([external ? "Setup:/Network/Service/test/DNS":MimoRuntime.dnsStateKey],early:early)
    }
   }
   let before=changes
   f.signature="inet 198.18.0.2";f.dns=NSDictionary(dictionary:["ServerAddresses":["127.0.0.1"],"ServerPort":1053])
   let entered=DispatchSemaphore(value:0)
   let held=Task.detached {try fence.activate(epoch:epoch) {entered.signal();Thread.sleep(forTimeInterval:0.5)}}
   _ = await Task.detached {waitObserver(entered)}.value
   let start=Date()
   await observer.didChangeProfileOnline()
   if name=="nested" {
    guard changes==0,observer.testPending==1 else {fatalError("Nested completion replayed too early")}
    await observer.didChangeProfileOnline()
   }
   let elapsed=Date().timeIntervalSince(start)
   _ = try await held.value
   let external=name.hasPrefix("external") || name=="mixed-burst" || name=="overflow-external"
   var canGrant=true;do {try fence.validateCycleEvents()}catch{canGrant=false}
   let passed=changes==(external ? 1:0) && canGrant == !external && observer.testPending==0 && elapsed<0.2 && (before==0 || name=="overflow-external")
   rows.append(.init(name:name,passed:passed,events:changes,elapsed:elapsed));print("\(name) \(passed ? "PASS":"FAIL") events=\(changes) elapsed=\(elapsed)")
  }
  try JSONEncoder().encode(rows).write(to:out);print("RESULT \(rows.filter(\.passed).count)/\(rows.count)");exit(rows.allSatisfy(\.passed) ? 0:1)
 }
}
