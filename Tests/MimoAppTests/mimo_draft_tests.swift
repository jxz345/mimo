import Foundation

enum MimoDraftTests {
    static func run() throws {
        var draft = MimoProxyDraft()
        draft.receive(nil)
        precondition(draft.revision == nil, "An unavailable service must not initialize an empty draft")
        var state = DaemonState(instanceID: UUID(), build: "test", initialized: false, revision: 0,
            settings: MachineSettings(), presentation: UserPresentationPreferences(), status: .idle,
            indicators: MonitorIndicatorState(), authorizationState: .unavailable, providerHealth: [:],
            budget: LookupBudget(), nextProvider: .ipWhois, cooldowns: [:], hasIPinfoToken: false)
        draft.receive(state)
        precondition(draft.revision == nil, "Uninitialized machine settings must not consume the initial load")
        state.initialized = true; state.revision = 1
        var routing = MimoRoutingState()
        routing.configuration.proxy = MimoProxy(ClashProxySettings(name: "Original", type: .http, server: "192.0.2.1", port: 443))
        state.routing = routing
        draft.receive(state)
        precondition(draft.revision == 1 && draft.name == "Original")
        draft.name = "Unfinished edit"; draft.password = "only-in-memory"
        draft.receive(state)
        precondition(draft.name == "Unfinished edit" && draft.password == "only-in-memory")
        state.revision = 2; state.routing?.configuration.proxy?.name = "Another editor"
        draft.receive(state)
        precondition(draft.conflicts(with: state) && draft.revision == 1 && draft.name == "Unfinished edit",
                     "Status updates must preserve edits and their original revision")
        precondition(draft.password == "only-in-memory", "Conflicts must not discard the in-progress secret")
        draft.receive(state, discardChanges: true)
        precondition(!draft.conflicts(with: state) && draft.name == "Another editor" && draft.password.isEmpty)
        precondition(draft.passwordChange == nil)
        draft.clearPassword = true
        precondition(draft.passwordChange == "", "Password removal is explicit, distinct from retaining it")
        let validated = try draft.validatedProxy()
        precondition(validated.server == "192.0.2.1")
        draft.server = "2001:db8::1"
        do {
            _ = try draft.validatedProxy()
            preconditionFailure("IPv6 proxy input must be rejected")
        } catch ClashProxySettings.ValidationError.invalidServer { }
        var bypass = MimoBypassDraft()
        bypass.receive(state)
        bypass.blocks[0].name = "Unfinished bypass"
        state.revision += 1
        bypass.receive(state)
        precondition(bypass.conflicts(with: state) && bypass.blocks[0].name == "Unfinished bypass")
        bypass.receive(state, discard: true)
        precondition(!bypass.isDirty && !bypass.conflicts(with: state))
        state.revision += 1; state.settings.bypassBlocks = []
        bypass.receive(state)
        precondition(bypass.blocks.isEmpty && bypass.revision == state.revision)
        precondition(MimoSettingsSection.proxy.symbol != MimoSettingsSection.bypass.symbol)
        print("PASS: delayed Settings load, retained drafts/secrets, revision conflicts and explicit reload")
    }
}
