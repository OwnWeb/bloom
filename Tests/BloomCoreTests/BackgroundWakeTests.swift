import Foundation
import Testing
@testable import BloomCore

/// A turn the CLI started because a background task finished, and the row that says so.
///
/// The lines are from a probe of `claude 2.1.268` on 11 September 2026: a five second background
/// `sleep`, a turn ended straight after it, and the turn the CLI started when the command exited.
@Suite("A background task opening a turn")
struct BackgroundWakeTests {
    /// Verbatim from the probe, minus the uuid and session id.
    static let commandLine = #"""
    {"type":"system","subtype":"task_notification","task_id":"b1u04xrxg",\
    "tool_use_id":"toolu_01Bvp96FxPWLvXFdW1QmRADF","status":"completed",\
    "output_file":"/private/tmp/claude-501/-private-tmp-bgprobe/9816/tasks/b1u04xrxg.output",\
    "summary":"Background command \"Wait five seconds\" completed (exit code 0)"}
    """#.replacingOccurrences(of: "\\\n", with: "")

    private func report(_ line: String) throws -> SubagentReport {
        let json = try #require(JSONValue.parse(line))
        guard case .reported(let report)? = SubagentSignal.decode(json, raw: Data(line.utf8)) else {
            Issue.record("not a notification")
            throw CancellationError()
        }
        return report
    }

    private func wake(status: String, summary: String) -> BackgroundWake {
        BackgroundWake(SubagentReport(id: SubagentID("t"), status: status, summary: summary))
    }

    @Test("a command that exited cleanly is named by its description")
    func finishedCommand() throws {
        let wake = BackgroundWake(try report(Self.commandLine))
        #expect(wake.source == .command)
        #expect(wake.outcome == .finished)
        #expect(wake.title == "Background command finished")
        #expect(wake.name == "Wait five seconds")
        #expect(wake.exitLabel == "exit 0")
        #expect(wake.outputFile?.hasSuffix("b1u04xrxg.output") == true)
    }

    /// The CLI says `completed` for a process that ended, whatever it ended with.
    @Test("a completed command with a non zero exit code failed")
    func nonZeroExit() {
        let wake = wake(status: "completed", summary: #"Background command "Run tests" completed (exit code 1)"#)
        #expect(wake.outcome == .failed)
        #expect(wake.title == "Background command failed")
        #expect(wake.exitLabel == "exit 1")
    }

    @Test("a killed task was stopped")
    func killed() {
        let wake = wake(status: "killed", summary: #"Background command "Serve" was stopped"#)
        #expect(wake.outcome == .stopped)
        #expect(wake.name == "Serve")
    }

    /// The shape in `claude-api-retry.ndjson`: an agent, no quotes, no exit code. It still draws,
    /// as the sentence.
    @Test("an agent's summary with nothing quoted falls back to the sentence")
    func agentWithoutName() {
        let wake = wake(status: "failed", summary: "Agent terminated early due to an API error: 529 Overloaded.")
        #expect(wake.source == .agent)
        #expect(wake.outcome == .failed)
        #expect(wake.title == "Background agent failed")
        #expect(wake.name == nil)
        #expect(wake.exitLabel == nil)
        #expect(wake.summary.hasPrefix("Agent terminated early"))
    }

    @Test("a name that quotes something keeps its own quotes")
    func nestedQuotes() {
        let wake = wake(status: "completed", summary: #"Background command "grep "todo" src" completed (exit code 0)"#)
        #expect(wake.name == #"grep "todo" src"#)
    }

    /// `claude 2.1.281`, a subagent's foreground Bash call: the summary is the command, because a
    /// task that ends with no summary of its own reports its description instead.
    static let subagentCommandLine = #"""
    {"type":"system","subtype":"task_notification","task_id":"bx7","tool_use_id":"toolu_01E7",\
    "status":"completed","output_file":"","summary":"curl -s -o /dev/null -w \"%{http_code}\\n\" http://127.0.0.1:8153/login"}
    """#.replacingOccurrences(of: "\\\n", with: "")

    @Test("a summary in none of the CLI's wording is a task, and names nothing")
    func commandAsSummary() throws {
        let wake = BackgroundWake(try report(Self.subagentCommandLine))
        #expect(wake.source == .task)
        #expect(wake.title == "Background task finished")
        #expect(wake.name == nil)
    }

    /// The rows stored before the summary was asked about are turned away when read back.
    @Test("a notification in none of the CLI's wording is not a row")
    func notARow() {
        let payload = Data(Self.subagentCommandLine.utf8)
        #expect(!BackgroundWake.isRow(kind: .system, payload: payload))
        #expect(TranscriptRowInk.drawsNothing(kind: .system, payload: payload))
    }

    @Test("an agent's summary is a row whether or not it names the agent")
    func agentRows() {
        for summary in [#"Agent \"Build it\" finished"#, "Agent terminated early due to an API error"] {
            let line = #"{"type":"system","subtype":"task_notification","task_id":"a","summary":"\#(summary)"}"#
            #expect(BackgroundWake.isRow(kind: .system, payload: Data(line.utf8)))
        }
    }

    @Test("a task that reports to a subagent opens nothing, in any wording")
    func subagentsTask() {
        let command = SubagentReport(id: SubagentID("t"), status: "completed", summary: #"Background command "Serve" completed"#)
        let bare = SubagentReport(id: SubagentID("t"), status: "completed", summary: "npm test")
        #expect(BackgroundWake.opensTurn(command, during: .idle, reportsToSubagent: false))
        #expect(!BackgroundWake.opensTurn(command, during: .idle, reportsToSubagent: true))
        #expect(!BackgroundWake.opensTurn(bare, during: .idle, reportsToSubagent: false))
    }

    @Test("a subagent's command and a nested agent both report to a subagent")
    func reportsToSubagent() throws {
        let line = #"{"type":"system","subtype":"task_started","task_id":"b1","owned_by_subagent":true,"task_type":"local_bash"}"#
        guard case .started(let start)? = SubagentSignal.decode(try #require(JSONValue.parse(line))) else {
            Issue.record("not a start")
            return
        }
        #expect(start.ownedBySubagent)
        #expect(start.reportsToSubagent)
        #expect(SubagentStart(id: SubagentID("a"), spawnDepth: 2).reportsToSubagent)
        #expect(!SubagentStart(id: SubagentID("a"), spawnDepth: 1).reportsToSubagent)
    }

    @Test("only a notification between turns opens one")
    func onlyBetweenTurns() {
        #expect(BackgroundWake.opensTurn(during: .idle))
        #expect(BackgroundWake.opensTurn(during: .failed))
        #expect(BackgroundWake.opensTurn(during: .cancelled))
        #expect(!BackgroundWake.opensTurn(during: .running))
        #expect(!BackgroundWake.opensTurn(during: .waiting))
    }

    @Test("the row is found by its first bytes, and only as a system row")
    func sniff() {
        let payload = Data(Self.commandLine.utf8)
        #expect(BackgroundWake.isRow(kind: .system, payload: payload))
        #expect(!BackgroundWake.isRow(kind: .user, payload: payload))
        let initLine = Data(#"{"type":"system","subtype":"init","cwd":"/tmp"}"#.utf8)
        #expect(!BackgroundWake.isRow(kind: .system, payload: initLine))
    }

    @Test("the row draws, unlike every other system row but an init")
    func draws() {
        #expect(!TranscriptRowInk.drawsNothing(kind: .system, payload: Data(Self.commandLine.utf8)))
    }
}

/// The row must stay on screen: folded into "17 actions" it would hide the one line explaining them.
@Suite("A background task's row and the fold")
struct BackgroundWakeFoldTests {
    private func tool(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .toolUse)
    }

    private func wake(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .system, opensTurn: true)
    }

    private func footer(_ seq: Int) -> TranscriptFold.Fact {
        TranscriptFold.Fact(seq: seq, kind: .result)
    }

    /// The shape from the owner's transcript: a footer, the notification, and a turn of work.
    @Test("the row opens the turn and is never part of its fold")
    func neverFolded() throws {
        let facts = [footer(0), wake(1), tool(2), tool(3), tool(4), tool(5)]
        let folds = TranscriptFold.folds(in: facts)
        let work = try #require(folds.all.first)
        #expect(folds.all.count == 1)
        #expect(work.firstSeq == 2)
        #expect(!work.rows.contains { $0.seq == 1 })
        #expect(TranscriptFold.hiddenIndices(work, revealed: [], drawn: 0..<100) == [2, 3, 4, 5])
    }

    /// Without it, the activity either side would join up into one fold spanning two turns.
    @Test("it divides activity like a prompt does")
    func divides() {
        let facts = [tool(0), tool(1), tool(2), wake(3), tool(4), tool(5), tool(6)]
        let folds = TranscriptFold.folds(in: facts)
        #expect(folds.all.map(\.firstSeq) == [0, 4])
    }
}

@Suite("Storing a background task's notification")
struct BackgroundWakeStorageTests {
    private func makeSession(_ store: Store) async throws -> Session {
        let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "w", branch: "b", path: "/tmp/w", baseBranch: "main"
        ))
        return try await store.upsert(Session(workspaceID: workspace.id, model: "opus"))
    }

    private var line: AgentEvent {
        get throws { try #require(AgentEvent.decode(line: BackgroundWakeTests.commandLine)) }
    }

    @Test("between turns it is stored, as the line itself")
    func storedWhenIdle() async throws {
        let store = try makeTestStore("wake-idle")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)

        await runner.ingest(try line)

        let stored = try await store.messages(sessionID: session.id)
        #expect(stored.map(\.kind) == [.system])
        let payload = try #require(stored.first?.payload)
        #expect(BackgroundWake.isRow(kind: .system, payload: payload))
    }

    /// The thirteen rows in the owner's transcript: a background subagent's Bash calls, finishing
    /// while the parent was idle.
    @Test("a task a subagent owns is not stored, even between turns")
    func notStoredForSubagent() async throws {
        let store = try makeTestStore("wake-subagent")
        let session = try await makeSession(store)
        let runner = AgentRunner(workspacePath: "/tmp/w", session: session, store: store)
        let started = #"{"type":"system","subtype":"task_started","task_id":"b1u04xrxg","owned_by_subagent":true,"task_type":"local_bash"}"#

        await runner.ingest(try #require(AgentEvent.decode(line: started)))
        await runner.ingest(try line)
        await runner.ingest(try #require(AgentEvent.decode(line: BackgroundWakeTests.subagentCommandLine)))

        #expect(try await store.messages(sessionID: session.id).isEmpty)
    }

    /// Mid turn the model reads it inside the turn and nothing new begins, so there is nothing
    /// for a row to open.
    @Test("during a turn it is not stored")
    func notStoredMidTurn() async throws {
        let store = try makeTestStore("wake-running")
        let session = try await makeSession(store)
        let runner = AgentRunner(
            workspacePath: "/tmp/w", session: session.with { $0.apply(.turnStarted) }, store: store
        )

        await runner.ingest(try line)

        #expect(try await store.messages(sessionID: session.id).isEmpty)
    }
}
