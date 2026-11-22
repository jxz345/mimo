import Foundation

enum MimoInstallationReadiness {
    static func problems(flags: MimoServicePreferences, supervisor: MimoRoutingState?,
                         provider: MimoServiceStatus?, now: Date = .now) -> [String] {
        var problems: [String] = []
        if !flags.core || !flags.engine || !flags.profile || flags.networkReleaseRequested { problems.append("service_intent") }
        guard let supervisor else { return problems + ["supervisor"] }
        func fresh(_ date: Date?) -> Bool {
            guard let age = MimoHealthLabel.age(checkedAt: date, at: now) else { return false }
            return age <= 10
        }
        if supervisor.phase == .unavailable || !fresh(supervisor.supervisorCheckedAt) { problems.append("supervisor") }
        if supervisor.networkReleaseRequested == true { problems.append("network_released") }
        for service in [MimoServiceID.core, .mihomo, .profileHosting] {
            guard let report = supervisor.services.first(where: { $0.id == service }),
                  report.health == .running, fresh(report.checkedAt) else { problems.append(service.rawValue); continue }
        }
        if provider?.health != .running || provider?.bindingConfirmed != true || provider?.port != 18766 || !fresh(provider?.checkedAt) {
            problems.append("tailnetProvider")
        }
        let infrastructure = supervisor.infrastructure?.current(at: now)
        if ![MimoInfrastructureHealth.healthy, .released].contains(infrastructure?.pf ?? .unknown) { problems.append("firewall_monitor") }
        if infrastructure?.launchd != .healthy { problems.append("launchd_monitor") }
        return problems
    }
}
