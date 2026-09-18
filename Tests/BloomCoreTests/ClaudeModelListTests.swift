import Foundation
import Testing
@testable import BloomCore

@Suite("Claude Code's own model list")
struct ClaudeModelListTests {
    /// Claude Code 2.1.276's `initialize` answer, trimmed to the lines and fields that matter and
    /// otherwise as it arrived: a hook line first, then the control response.
    static let output = #"""
    {"type":"system","subtype":"hook_started"}
    {"type":"control_response","response":{"subtype":"success","request_id":"bloom-models","response":{"commands":[],"models":[{"value":"default","resolvedModel":"claude-opus-5[1m]","displayName":"Default (recommended)","description":"Opus 5 with 1M context · Best for everyday, complex tasks","supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsFastMode":true},{"value":"opus[1m]","resolvedModel":"claude-opus-5[1m]","displayName":"Opus (1M context)","description":"Opus 5 with 1M context · Best for everyday, complex tasks","supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsFastMode":true},{"value":"claude-fable-5-1[1m]","resolvedModel":"claude-fable-5-1","displayName":"Fable","description":"Fable 5.1 · Most capable for your hardest and longest-running tasks","supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"sonnet","resolvedModel":"claude-sonnet-5","displayName":"Sonnet","description":"Sonnet 5 · Efficient for routine tasks","supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku","description":"Haiku 4.5 · Fastest for quick answers"}]}}}
    """#

    @Test("the models come from the CLI's answer, in its order, with the alias taken out")
    func parsesTheAnswer() {
        let models = ClaudeModelList.parse(Self.output)
        #expect(models.map(\.id) == ["opus[1m]", "claude-fable-5-1[1m]", "sonnet", "haiku"])
        #expect(models.map(\.label) == ["Opus 5 with 1M context", "Fable 5.1", "Sonnet 5", "Haiku 4.5"],
                "the version is in the description, not in the display name")
        #expect(models.first?.efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(models.last?.efforts == [], "a model with no effort levels offers none")
        #expect(models.map(\.isDefault) == [true, false, false, false], "`default` marks the model it resolves to")
        #expect(models.first?.supportsFastMode == true)
    }

    @Test("output with no answer in it is no models rather than an error")
    func nothingToRead() {
        #expect(ClaudeModelList.parse("").isEmpty)
        #expect(ClaudeModelList.parse(#"{"type":"system","subtype":"hook_started"}"#).isEmpty)
    }
}
