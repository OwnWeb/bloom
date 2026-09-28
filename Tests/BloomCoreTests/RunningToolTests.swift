import Foundation
import Testing
@testable import BloomCore

@Suite("A running tool, as the live tail names it")
struct RunningToolTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("a streamed name is useful before its input has arrived")
    func theNameIsTheProvisionalLabel() {
        #expect(RunningTool(name: "Bash").text(at: Self.start) == "Running Bash")
        #expect(
            RunningTool(name: "mcp__\(BridgeRegistration.serverName)__workspace_say")
                .text(at: Self.start) == "Running Bloom: workspace say"
        )
    }

    @Test("a Bash description replaces its generic name")
    func aCommandUsesItsDescription() {
        let tool = RunningTool(
            use: AgentToolUse(
                id: "toolu_1",
                name: "Bash",
                input: .object([
                    "command": .string("while ! test -f assets.zip; do sleep 1; done"),
                    "description": .string("Wait for assets, download fresh"),
                ])
            ),
            startedAt: Self.start
        )

        #expect(tool.text(at: Self.start) == "Wait for assets, download fresh")
    }

    @Test("a completed call without a more useful label keeps the running verb")
    func aGenericLabelStillSaysItIsRunning() {
        let tool = RunningTool(
            use: AgentToolUse(id: "toolu_1", name: "Bash", input: .object([:])),
            startedAt: Self.start
        )

        #expect(tool.text(at: Self.start) == "Running Bash")
    }

    @Test("elapsed time appears at five seconds and keeps counting")
    func elapsedTimeWaitsForItsThreshold() {
        let tool = RunningTool(
            use: AgentToolUse(
                id: "toolu_1",
                name: "Bash",
                input: .object(["description": .string("Wait for assets")])
            ),
            startedAt: Self.start
        )

        #expect(tool.text(at: Self.start.addingTimeInterval(4.99)) == "Wait for assets")
        #expect(tool.text(at: Self.start.addingTimeInterval(5)) == "Wait for assets · 5s")
        #expect(tool.text(at: Self.start.addingTimeInterval(72)) == "Wait for assets · 1m 12s")
    }

    @Test("a wall clock correction cannot produce a negative duration")
    func aClockCorrectionKeepsTheLabel() {
        let tool = RunningTool(
            use: AgentToolUse(id: "toolu_1", name: "Read", input: .object([:])),
            startedAt: Self.start
        )

        #expect(tool.text(at: Self.start.addingTimeInterval(-30)) == "Running Read")
    }
}
