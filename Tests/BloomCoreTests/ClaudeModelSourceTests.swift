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

    @Test("a newly released Sonnet remains selectable while Claude Code lists the previous one")
    func supplementsOlderCLI() {
        let models = ClaudeModelList.parse(ClaudeModelListTests.output).agentModels
        let sonnet = models.first { $0.id == "claude-sonnet-5-5" }

        #expect(sonnet?.displayName == "Sonnet 5.5")
        #expect(sonnet?.supportedEfforts.map(\.id) == ["low", "medium", "high", "xhigh", "max"])
        #expect(sonnet?.defaultEffort == "medium")
        #expect(models.contains { $0.id == "sonnet" && $0.displayName == "Sonnet 5" })
    }

    @Test("the CLI's Sonnet 5.5 alias replaces the temporary explicit choice")
    func currentCLI() {
        let listed = [ClaudeModel(
            id: "sonnet", label: "Sonnet 5.5", efforts: ["low", "medium", "high", "xhigh", "max"],
            resolvedModel: "claude-sonnet-5-5"
        )]

        #expect(listed.agentModels.map(\.id) == ["sonnet"])
    }

    @Test("an empty CLI answer leaves the fallback menu in use")
    func emptyCLI() {
        #expect([ClaudeModel]().agentModels.isEmpty)
    }
}
