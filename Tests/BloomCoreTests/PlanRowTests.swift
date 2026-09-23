import Testing
import Foundation
@testable import BloomCore

/// A proposed plan is drawn as a document and kept out of "N actions". See `PlanRow`.
@Suite("A proposed plan is content, not an action")
struct PlanRowTests {
    private func claudeCall(_ name: String, input: String = ##"{"plan":"# Plan\n\n1. Do it"}"##) -> Data {
        Data(#"{"type":"assistant","message":{"model":"opus","id":"m1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"\#(name)","input":\#(input)}]}}"#.utf8)
    }

    /// The line Bloom writes for a Codex plan item as it starts, through the translation itself,
    /// because the order of its keys is whatever the encoder chose rather than anything written
    /// here.
    private func codexCall(text: String = "") -> (payload: Data, use: AgentToolUse) {
        let item = CodexItem.plan(CodexPlan(id: "p1", text: text))
        let input = CodexTranslation.input(for: item)
        let block = JSONValue.object([
            "type": .string("tool_use"),
            "id": .string("p1"),
            "name": .string(CodexTranslation.toolName(for: item)),
            "input": input,
        ])
        let payload = CodexTranslation.assistantLine(
            blocks: [block], messageID: "p1", model: "gpt-5.6-sol", usage: .zero, sessionID: "thread"
        )
        return (payload, AgentToolUse(id: "p1", name: CodexTranslation.toolName(for: item), input: input))
    }

    @Test("both agents' plan calls are recognised, and nothing else is")
    func recognised() {
        #expect(PlanRow.isCall(claudeCall("ExitPlanMode")))
        #expect(PlanRow.isCall(codexCall().payload))
        #expect(!PlanRow.isCall(claudeCall("Bash", input: #"{"command":"ls"}"#)))
        // A subagent of the Plan type is an Agent call that happens to say "Plan", not a plan.
        #expect(!PlanRow.isCall(claudeCall("Task", input: #"{"subagent_type":"Plan","prompt":"x"}"#)))
    }

    @Test("Claude Code's plan is the call's input")
    func claudeMarkdown() {
        let use = AgentToolUse(id: "t1", name: "ExitPlanMode", input: .object(["plan": .string("  # Plan\n\n1. Do it\n")]))
        #expect(PlanRow.markdown(of: use, resultText: "User has approved your plan.") == "# Plan\n\n1. Do it")
    }

    @Test("Codex's plan is the item's result, and an empty one is not drawn yet")
    func codexMarkdown() {
        let started = codexCall().use
        #expect(PlanRow.markdown(of: started, resultText: nil) == nil)
        #expect(PlanRow.markdown(of: started, resultText: "") == nil)
        #expect(PlanRow.markdown(of: started, resultText: "## Steps\n- one") == "## Steps\n- one")
    }

    /// Only a Codex row is Codex's `Plan`: the name alone could be anybody's tool.
    @Test("a call named Plan that is not Codex's is not a plan")
    func onlyCodexsPlan() {
        let use = AgentToolUse(id: "t1", name: "Plan", input: .object(["text": .string("hello")]))
        #expect(PlanRow.markdown(of: use, resultText: "hello") == nil)
        #expect(PlanRow.markdown(of: AgentToolUse(id: "t2", name: "Bash", input: .object([:])), resultText: "x") == nil)
    }
}
