import Testing
@testable import BloomCore

private func preferences(
    _ kind: AgentKind,
    model: String = "m1",
    effort: String = "high",
    permissionMode: PermissionMode = .auto,
    advisor: AdvisorLaunch = .consult(.inherit)
) -> RunnerPreferences {
    RunnerPreferences(
        session: Session(
            workspaceID: nil, model: model, effort: effort, agentKind: kind, permissionMode: permissionMode
        ),
        advisor: advisor
    )
}

struct RunnerPreferencesTests {
    @Test("an OpenCode model or effort change keeps the process and is handed to it")
    func openCodeAdoptsComposerSettings() {
        let running = preferences(.openCode)
        for next in [preferences(.openCode, model: "m2"), preferences(.openCode, effort: "none")] {
            #expect(!running.restarts(for: next, midTurn: false))
            #expect(!running.restarts(for: next, midTurn: true))
            #expect(running.adoptsComposerSettings(of: next))
        }
        #expect(!running.adoptsComposerSettings(of: running))
    }

    @Test("an OpenCode permission mode change still restarts, being a launch setting")
    func openCodePermissionModeRestarts() {
        let next = preferences(.openCode, model: "m2", permissionMode: .acceptEdits)
        #expect(preferences(.openCode).restarts(for: next, midTurn: false))
    }

    @Test("a model change restarts every backend that does not take it live")
    func otherBackendsRestartOnModelChange() {
        for kind in [AgentKind.claudeCode, .codex, .grok] {
            let running = preferences(kind)
            let next = preferences(kind, model: "m2")
            #expect(running.restarts(for: next, midTurn: false))
            #expect(!running.adoptsComposerSettings(of: next))
        }
    }

    @Test("moving to or from OpenCode restarts, whatever the model")
    func backendChangeRestarts() {
        #expect(preferences(.openCode).restarts(for: preferences(.grok), midTurn: false))
        #expect(!preferences(.grok).adoptsComposerSettings(of: preferences(.openCode, model: "m2")))
    }

    @Test("an advisor change waits for the turn to end")
    func advisorWaitsForTheTurn() {
        let running = preferences(.claudeCode)
        let next = preferences(.claudeCode, advisor: .off)
        #expect(!running.restarts(for: next, midTurn: true))
        #expect(running.restarts(for: next, midTurn: false))
    }
}
