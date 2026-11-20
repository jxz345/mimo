#if SWIFT_PACKAGE
import ExitIPShared
#endif
import Darwin
import Foundation

/// Watches the kernel routing socket for route, gateway, address, and interface changes.
/// `NetworkConfigurationObserver` only sees what is published to SystemConfiguration; a TUN tool
/// that installs its routes directly (e.g. split `0/1` + `128/1` default routes) is visible only here.
/// `RouteChangeFilter` drops kernel noise so ordinary traffic never triggers a lookup.
final class RouteChangeObserver {
    struct Change: Sendable {
        let type: Int32
        let interfaceName: String?
        let interfaceIndex: UInt16
        let processID: Int32?
        let addresses: [String]
    }
    private let queue = DispatchQueue(label: "com.example.exitipmonitor.route-socket")
    private var source: DispatchSourceRead?
    private let onRouteChange: ([Change]) -> Void

    init(onRouteChange: @escaping () -> Void) {
        self.onRouteChange = { _ in onRouteChange() }
    }

    init(onChanges: @escaping ([Change]) -> Void) { onRouteChange = onChanges }

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        let descriptor = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard descriptor >= 0 else {
            RuntimeLog.shared.error("route_monitor_unavailable", fields: ["errno": String(errno)])
            return
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain(descriptor)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Reads every pending message (one per `read`) and reports once per wakeup.
    /// The supervisor closes protected access immediately when it handles an
    /// external change; it does not debounce the firewall response.
    private func drain(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var changes: [Change] = []
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            if let change = buffer.withUnsafeBytes({ Self.change(UnsafeRawBufferPointer(rebasing: $0[..<count])) }) { changes.append(change) }
        }
        if !changes.isEmpty {
            onRouteChange(changes)
        }
    }

    private static func change(_ message: UnsafeRawBufferPointer) -> Change? {
        // Every routing message starts with msglen (u_short), version (u_char), type (u_char).
        guard message.count >= 4 else { return nil }
        let type = Int32(message[3])
        switch type {
        case RTM_ADD, RTM_DELETE, RTM_CHANGE:
            guard message.count >= MemoryLayout<rt_msghdr>.size else { return nil }
            let header = message.loadUnaligned(as: rt_msghdr.self)
            let metadata = routeAddresses(message, header: header)
            let index = header.rtm_index == 0 ? metadata.interface : header.rtm_index
            let name = interfaceName(for: index)
            guard RouteChangeFilter.isRelevant(messageType: type, routeFlags: header.rtm_flags, interfaceName: name) else { return nil }
            return Change(type: type, interfaceName: name, interfaceIndex: index, processID: header.rtm_pid, addresses: metadata.addresses)
        case RTM_NEWADDR, RTM_DELADDR:
            guard message.count >= MemoryLayout<ifa_msghdr>.size else { return nil }
            let header = message.loadUnaligned(as: ifa_msghdr.self)
            let name = interfaceName(for: header.ifam_index)
            guard RouteChangeFilter.isRelevant(messageType: type, interfaceName: name) else { return nil }
            return Change(type: type, interfaceName: name, interfaceIndex: header.ifam_index, processID: nil, addresses: [])
        case RTM_IFINFO:
            guard message.count >= MemoryLayout<if_msghdr>.size else { return nil }
            let header = message.loadUnaligned(as: if_msghdr.self)
            let name = interfaceName(for: header.ifm_index)
            guard RouteChangeFilter.isRelevant(messageType: type, interfaceName: name) else { return nil }
            return Change(type: type, interfaceName: name, interfaceIndex: header.ifm_index, processID: nil, addresses: [])
        default:
            return nil
        }
    }

    private static func routeAddresses(_ message: UnsafeRawBufferPointer, header: rt_msghdr) -> (interface: UInt16, addresses: [String]) {
        var offset = MemoryLayout<rt_msghdr>.size, index: UInt16 = 0, addresses: [String] = []
        for slot in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << slot) != 0 {
            guard offset + 2 <= message.count else { break }
            let length = Int(message[offset]), family = Int32(message[offset + 1])
            guard length > 0, offset + length <= message.count else { break }
            if family == AF_LINK, length >= 4, slot == Int(RTAX_IFP) || slot == Int(RTAX_GATEWAY) {
                index = message.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)
            }
            // Only actual destination/gateway/interface addresses, never netmasks.
            if [Int(RTAX_DST), Int(RTAX_GATEWAY), Int(RTAX_IFA)].contains(slot) {
                let addressOffset = family == AF_INET ? 4 : 8
                let addressLength = family == AF_INET ? 4 : family == AF_INET6 ? 16 : 0
                if addressLength > 0, length >= addressOffset + addressLength {
                    var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(family, message.baseAddress!.advanced(by: offset + addressOffset), &output, socklen_t(output.count)) != nil {
                        addresses.append(String(decoding: output.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
                    }
                }
            }
            offset += (length + 3) & ~3
        }
        return (index, addresses)
    }

    private static func interfaceName(for index: UInt16) -> String? {
        guard index > 0 else { return nil }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        let bytes = name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
