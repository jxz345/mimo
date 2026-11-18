import Foundation

enum MimoCommandFenceTests {
    static func run() {
        var fence = MimoCommandFence()
        let controller = UUID()
        func stamp(_ value: UInt64) -> MimoCommandStamp {
            MimoCommandStamp(controller: controller, sequence: value)
        }
        require(fence.accept(stamp(2), peer: 42, currentCore: 42, enabled: true, heartbeat: false),
                "the newest command must be accepted even if it arrives first")
        for value: UInt64 in [0, 1, 2] {
            require(!fence.accept(stamp(value), peer: 42, currentCore: 42, enabled: true, heartbeat: false),
                    "older and duplicate commands must be rejected before changing traffic")
        }
        require(!fence.accept(stamp(3), peer: 42, currentCore: nil, enabled: true, heartbeat: false),
                "a dead core cannot issue a delayed command")
        require(!fence.accept(stamp(3), peer: 42, currentCore: 43, enabled: true, heartbeat: false),
                "an old process cannot command a replacement core's session")
        require(!fence.accept(stamp(3), peer: 42, currentCore: 42, enabled: false, heartbeat: true),
                "a stopped core cannot extend the watchdog heartbeat")
        require(!fence.accept(.init(controller: UUID(), sequence: 3), peer: 42, currentCore: 42,
                             enabled: true, heartbeat: false), "a caller cannot reset its sequence with a new UUID")
        require(fence.accept(stamp(3), peer: 42, currentCore: 42, enabled: true, heartbeat: true),
                "a heartbeat can overtake a pending command")
        require(fence.accept(stamp(3), peer: 42, currentCore: 42, enabled: true, heartbeat: false),
                "a heartbeat must not consume that command's sequence")
        require(!fence.accept(stamp(2), peer: 42, currentCore: 42, enabled: true, heartbeat: true),
                "an older heartbeat cannot refresh the watchdog after a newer command")
        require(fence.accept(.init(controller: UUID(), sequence: 1), peer: 43, currentCore: 43,
                             enabled: true, heartbeat: false), "a new running core starts a new sequence")

        var configuration = MimoConfiguration()
        var message = MimoSupervisorRequest(.direct)
        message.revision = 10
        require(MimoCommandFence.matchesSavedRouting(message, configuration: configuration, revision: 10),
                "current saved Direct permits Direct recovery")
        require(!MimoCommandFence.matchesSavedRouting(message, configuration: configuration, revision: 11),
                "a supervisor restart must not make a stale revision current")
        configuration.mode = .rule
        require(!MimoCommandFence.matchesSavedRouting(message, configuration: configuration, revision: 10),
                "saved protected mode forbids an old Direct request even without sequence history")
        message.command = .prepare; message.configuration = configuration
        require(MimoCommandFence.matchesSavedRouting(message, configuration: configuration, revision: 10),
                "preparation must match the saved configuration")
        configuration.mode = .global
        require(!MimoCommandFence.matchesSavedRouting(message, configuration: configuration, revision: 10),
                "a different candidate cannot pass the saved-policy check")
        message.command = .approve; configuration.mode = .direct
        require(!MimoCommandFence.matchesSavedRouting(message, configuration: configuration, revision: 10),
                "approval cannot replace saved Direct")
        print("PASS: supervisor command ordering, live-core identity, heartbeat isolation and saved-revision checks")
    }

    private static func require(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
}
