extension PublicIPMonitor {
    var rapidModeGate: Bool { MODE_GATE }
    func rapidChange(_ request: DaemonRequest) async -> Bool { await changeShared(request) }
    func rapidAdvanceConnection() { connectionGeneration += 1 }
    func rapidServiceBusy(_ busy: Bool) { serviceOperation = busy ? .mihomo : nil }
}
