import Foundation
import Darwin

public enum DaemonFailure:Error {case invalidRequest,conflict,unavailable}
enum MimoRuntimeError:Error {case unavailable(String)}
enum MihomoProfile {static let tunnelDevice="utun239"}
enum MimoRuntime {
    static var directory:URL {Facts.shared.root.appendingPathComponent("Runtime")}
    static var guardDirectory:URL {Facts.shared.root.appendingPathComponent("Guard")}
    static let mixedPort=7890,dnsPort=1053
}
final class RuntimeLog:Sendable {
    static let shared=RuntimeLog()
    func info(_ event:String,fields:[String:String]=[:]){Facts.shared.note(event)}
}
final class Facts:@unchecked Sendable {
    static let shared=Facts()
    private let lock=NSLock()
    private var rootValue=URL(fileURLWithPath:"/unconfigured-native-receipt-test")
    private var policyValue="",nativeValue=MimoNativeEgress(),writesValue=0,enteredValue=false
    private var holdValue=false,failedReadback=false,eventsValue:[String]=[]
    private var readsValue=0
    private var readHook:(@Sendable (Int)->(String,Int32)?)?
    var release=DispatchSemaphore(value:0)
    var root:URL {lock.withLock{rootValue}}
    var writes:Int {lock.withLock{writesValue}}
    var entered:Bool {lock.withLock{enteredValue}}
    var policy:String {lock.withLock{policyValue}}
    func reset(_ root:URL,policy:String,native:MimoNativeEgress,hold:Bool=false,failReadback:Bool=false){
        lock.withLock{rootValue=root;policyValue=policy;nativeValue=native;writesValue=0;enteredValue=false;holdValue=hold;failedReadback=failReadback;eventsValue=[];readsValue=0;readHook=nil;release=DispatchSemaphore(value:0)}
    }
    func note(_ event:String){lock.withLock{eventsValue.append(event)}}
    func replacePolicy(_ value:String){lock.withLock{policyValue=value}}
    func snapshot()->MimoNativeEgress{
        let pair=lock.withLock{enteredValue=true;return(nativeValue,holdValue)}
        if pair.1 {precondition(release.wait(timeout: .now() + 5) == .success,"Probe fixture was not released")}
        return pair.0
    }
    func install(_ value:String){lock.withLock{writesValue+=1;policyValue=Self.canonical(value)}}
    func setReadHook(_ hook: @escaping @Sendable (Int)->(String,Int32)?){lock.withLock{readHook=hook}}
    func read()->(text:String,status:Int32){
        let saved=lock.withLock{readsValue+=1;return(policyValue,failedReadback && writesValue>0 ? Int32(1):Int32(0),readHook,readsValue)}
        if let override=saved.2?(saved.3){return override}
        return(saved.0,saved.1)
    }
    static func canonical(_ value:String)->String{
        guard value.contains("mimo:transition:deny") else{return value}
        let native=value.split(separator:"\n").map(String.init).filter{$0.contains("mimo:active:native-vpn-")}
        return (MimoFirewallPolicy.controlReadback+native+["block drop out quick all label \"mimo:transition:deny\""]).joined(separator:"\n")+"\n"
    }
}
enum MimoNativeEgressProbe {static func snapshot()->MimoNativeEgress{Facts.shared.snapshot()}}
enum BoundedProcess {
    static func run(_ executable:String,_ arguments:[String])->(text:String,status:Int32){
        precondition(executable=="/sbin/pfctl" && arguments==["-a",MimoFirewallPolicy.anchor,"-sr"])
        return Facts.shared.read()
    }
}
final class AdmissionProbe:@unchecked Sendable {
    private let lock=NSLock();private var delayValue:Double?
    var delay:Double?{lock.withLock{delayValue}}
    func record(_ delay:Double){lock.withLock{delayValue=delay}}
}
final class HeldLock:@unchecked Sendable {
    private let lock=NSLock();private var value:SingleInstanceLock?
    init(_ path:URL)throws{value=try SingleInstanceLock(url:path);precondition(value != nil)}
    func release(){lock.withLock{value=nil}}
}
