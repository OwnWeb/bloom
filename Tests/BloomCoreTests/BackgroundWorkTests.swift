import Testing
import Foundation
@testable import BloomCore

/// The sentence under a finished turn naming what the agent left running. See `BackgroundWork`.
@Suite struct BackgroundWorkTests {
    /// A fixed start, so the clock in the quiet line is a fact of the test rather than of when it ran.
    private let started = Date(timeIntervalSince1970: 1_000_000)

    private func command(_ description: String, state: SubagentState = .running) -> Subagent {
        Subagent(
            id: SubagentID(UUID().uuidString), description: description,
            taskType: "local_bash", state: state, startedAt: started
        )
    }

    private func agent(_ description: String) -> Subagent {
        Subagent(
            id: SubagentID(UUID().uuidString), description: description,
            taskType: "local_agent", startedAt: started
        )
    }

    /// The quiet line a given number of seconds into the wait.
    private func detail(_ note: BackgroundWork.Note?, after seconds: Int) -> String? {
        note?.detail(at: started.addingTimeInterval(TimeInterval(seconds)))
    }

    @Test func nothingRunningSaysNothing() {
        #expect(BackgroundWork.note(for: SubagentRoster()) == nil)
        #expect(BackgroundWork.note(for: [command("Done already", state: .completed)]) == nil)
    }

    /// The case the screenshot was of. The name leads, because it is the only line anybody
    /// reads this plate for.
    @Test func oneCommandLeadsWithItsName() {
        let note = BackgroundWork.note(for: [command("Wait for the PR's Test run to finish")])
        #expect(note?.title == "Wait for the PR's Test run to finish")
        #expect(detail(note, after: 252) == "Background command, running 4m 12s")
    }

    /// The second question after "something is still running" is "how long".
    @Test func theClockStartsOnceThereIsOneToRead() {
        let note = BackgroundWork.note(for: [command("Serve the app")])
        #expect(note?.isTimed == true)
        #expect(detail(note, after: 0) == "Background command, running")
        #expect(detail(note, after: 9) == "Background command, running 9s")
        #expect(detail(note, after: 7_260) == "Background command, running 2h 1m")
    }

    @Test func finishedOnesAreLeftOut() {
        let note = BackgroundWork.note(for: [
            command("Wait for main head's Test run to finish", state: .completed),
            command("Wait for the PR's Test run to finish"),
        ])
        #expect(note?.title == "Wait for the PR's Test run to finish")
        #expect(detail(note, after: 30) == "Background command, running 30s")
    }

    /// More than one and the count takes the lead back, because three names do not fit in it.
    @Test func severalOfOneKindAreCountedAndNamed() {
        let note = BackgroundWork.note(for: [command("Build"), command("Test")])
        #expect(note?.title == "2 background commands still running")
        #expect(detail(note, after: 30) == "Build and Test")
    }

    /// Two clocks cannot be read from one line, so several tasks draw none and nothing ticks.
    @Test func severalTasksCarryNoClock() {
        let note = BackgroundWork.note(for: [command("Build"), command("Test")])
        #expect(note?.isTimed == false)
    }

    @Test func aSubagentIsNamedTheSameWay() {
        let note = BackgroundWork.note(for: [agent("Audit the parser")])
        #expect(note?.title == "Audit the parser")
        #expect(detail(note, after: 30) == "Subagent, running 30s")
    }

    @Test func mixedKindsShareOneNoun() {
        let note = BackgroundWork.note(for: [command("Build"), agent("Audit the parser")])
        #expect(note?.title == "2 background tasks still running")
        #expect(detail(note, after: 30) == "Build and Audit the parser")
    }

    @Test func aLongListIsCut() {
        let note = BackgroundWork.note(for: ["A", "B", "C", "D", "E"].map { command($0) })
        #expect(note?.title == "5 background commands still running")
        #expect(detail(note, after: 30) == "A, B, C and 2 more")
    }

    @Test func anArchiveThatStoppedNothingSaysNothing() {
        #expect(BackgroundWork.archived("Docs", stopping: []) == nil)
    }

    @Test func anArchiveNamesTheCommandsItStopped() {
        #expect(BackgroundWork.archived("Docs", stopping: [command("Serve the app")])
            == "Docs was archived. It stopped a background command: Serve the app.")
        #expect(BackgroundWork.archived("Docs", stopping: [command("Serve the app"), command("Serve docs")])
            == "Docs was archived. It stopped 2 background commands: Serve the app and Serve docs.")
    }

    /// The notice draws its first sentence large and the rest small, so the split has to land
    /// between the archive and what it stopped.
    @Test func theArchiveNoticeSplitsAfterTheFact() throws {
        let message = try #require(BackgroundWork.archived("Docs", stopping: [command("Serve on 127.0.0.1:8018")]))
        let text = NoticeText(message)
        #expect(text.fact.map(\.text).joined() == "Docs was archived.")
        #expect(text.reason.map(\.text).joined() == "It stopped a background command: Serve on 127.0.0.1:8018.")
    }
}
