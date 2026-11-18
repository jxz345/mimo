import Foundation

public enum MimoNetworkChangePolicy {
    /// Engine route messages can omit the interface index. Kernel-created local-address
    /// routes have PID zero; those require a recorded owned address/interface and the
    /// bounded reload window, as well as the unchanged tunnel signature.
    public static func isExpectedTunnelChange(ownedInterface: Bool, recordedTunnelMatches: Bool,
                                             eventProcess: Int32?, engineProcess: Int32?,
                                             unresolvedInterface: Bool = false, ownedAddress: Bool = false,
                                             insideProfileChangeWindow: Bool = false) -> Bool {
        guard recordedTunnelMatches, let engineProcess, engineProcess > 0 else { return false }
        if let eventProcess, eventProcess > 0 {
            return eventProcess == engineProcess && (ownedInterface || unresolvedInterface)
        }
        return insideProfileChangeWindow && (ownedInterface || ownedAddress)
    }
}
