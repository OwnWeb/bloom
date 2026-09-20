import Testing
@testable import BloomCore

/// Claude Code's list as the model menu reads it. See `ClaudeModel.agentModel`.
@Suite("Claude Code's models in the model menu")
struct ClaudeModelSourceTests {
    @Test("a model keeps the CLI's id and name, and its efforts read as the menu spells them")
    func mapped() {
        let models = ClaudeModelList.parse(ClaudeModelListTests.output).map(\.agentModel)
        let opus = models[0]
        #expect(opus.id == "opus[1m]")
        #expect(opus.displayName == "Opus 5 with 1M context")
        #expect(opus.isDefault)
        #expect(opus.supportedEfforts.map(\.label) == ["Low", "Medium", "High", "Extra high", "Max"])
        #expect(opus.defaultEffort == "high")
    }

    /// Haiku takes no effort, and the runner leaves `--effort` off for an empty one.
    @Test("a model with no efforts keeps none rather than inheriting another's")
    func noEfforts() {
        let haiku = ClaudeModelList.parse(ClaudeModelListTests.output).map(\.agentModel).last
        #expect(haiku?.supportedEfforts.isEmpty == true)
        #expect(haiku?.resolvedEffort(preferring: "high") == "")
    }

    @Test("the menu's other backends are unchanged, and Claude's is the CLI")
    func registered() {
        #expect(Set(AgentModelSource.live().keys) == [.claudeCode, .codex, .grok])
    }
}
