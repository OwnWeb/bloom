import BloomProtocol
import Foundation
import Synchronization
import Testing
@testable import BloomCore

/// A Cloud machine retires its agent process after every turn, so every turn is a new process, and
/// whether it continues the chat's conversation depends on what that process is launched from.
///
/// These drive the real `AgentRunner` under the real runtime, with only the `claude` process
/// scripted, because both bugs lived in the seam between the two: the runtime built each runner
/// from the row as it was when the chat was first loaded, so turn two launched without the
/// `--resume` turn one had stored; and a `--resume` of a conversation the machine no longer had
/// failed before its first request, for ever.
@Suite("Cloud chats resume their conversation", .scratchDirectory, .tags(.persistence))
struct RemoteConversationResumeTests {
    static let freek = MessageAuthor(userID: "01k5bx7j9d3v2r8q6m4n0p1s2t", name: "Freek")

    struct Fixture {
        let store: Store
        let session: Session
        let runtime: WorkspaceRuntime
        let processes: ScriptedClaudeProcesses
    }

    func fixture(agentSessionID: String? = nil, scripts: [ScriptedClaude.Script]) async throws -> Fixture {
        let store = try makeTestStore("remote-resume")
        let repo = try await store.upsert(Repo(name: "bloom", path: TestScratch.unique("repo")))
        let path = TestScratch.unique("worktree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let workspace = try await store.upsert(Workspace(repoID: repo.id, name: "Resume", branch: "resume", path: path, baseBranch: "main"))
        let session = try await store.upsert(Session(
            workspaceID: workspace.id, title: "Chat", agentSessionID: agentSessionID,
            model: "opus", permissionMode: .acceptEdits
        ))
        let processes = ScriptedClaudeProcesses(scripts: scripts)
        let runtime = WorkspaceRuntime(
            store: store, workspaceID: workspace.id,
            makeRunner: { session, path, store, _, _, _ in
                AgentRunner(workspacePath: path, session: session, store: store, makeProcess: processes.factory)
            },
            installedAgents: { [.claudeCode] }, models: { _ in [] },
            runnerExitGrace: .milliseconds(50), retiresRunnerAfterTurn: true
        )
        try await runtime.start()
        return Fixture(store: store, session: session, runtime: runtime, processes: processes)
    }

    static func caller() -> RemoteCaller {
        RemoteCaller(author: freek, abilities: ["view", "prompt"], sessionToken: "token-for-freek")
    }

    func send(_ text: String, in fixture: Fixture) async {
        _ = await fixture.runtime.respond(
            to: CommandRequest(.send(chatID: fixture.session.id.rawValue, text: text)), as: Self.caller()
        )
    }

    /// Thirty seconds is a cap on "never", not a measurement: every step here is a few actor hops.
    func waitForIdle(_ fixture: Fixture, launches: Int) async {
        await waitUntil("launch \(launches) finished its turn", within: .seconds(30)) {
            guard fixture.processes.launches.count == launches,
                  fixture.processes.all.last?.wasTerminated == true else { return false }
            return (try? await fixture.store.session(id: fixture.session.id))?.state == .idle
        }
    }

    /// Fails without re-reading the row in `WorkspaceRuntime.liveSession`'s factory: the second
    /// launch is built from the copy read before turn one stored its id, and has no `--resume`.
    @Test("the second turn on a retiring machine resumes the conversation the first one stored")
    func secondTurnResumes() async throws {
        let fixture = try await fixture(scripts: [.answer(conversation: "conv-1"), .answer(conversation: "conv-1")])

        await send("First", in: fixture)
        await waitForIdle(fixture, launches: 1)
        #expect(try await fixture.store.session(id: fixture.session.id)?.agentSessionID == "conv-1")
        await send("Second", in: fixture)
        await waitForIdle(fixture, launches: 2)

        let launches = fixture.processes.launches
        #expect(ScriptedClaude.resumeID(launches[0]) == nil)
        #expect(ScriptedClaude.resumeID(launches[1]) == "conv-1")
        await fixture.runtime.shutdown()
    }

    /// Fails for the same reason as the one above: the stale copy puts the old model and
    /// permission mode back on every launch.
    @Test("a model and permission mode changed between turns reach the next launch")
    func preferencesReachTheNextLaunch() async throws {
        let fixture = try await fixture(scripts: [.answer(conversation: "conv-1"), .answer(conversation: "conv-1")])

        await send("First", in: fixture)
        await waitForIdle(fixture, launches: 1)
        try await fixture.store.updateSessionPreferences(id: fixture.session.id, model: "haiku", permissionMode: .plan)
        await send("Second", in: fixture)
        await waitForIdle(fixture, launches: 2)

        let first = fixture.processes.launches[0].arguments
        let second = fixture.processes.launches[1].arguments
        #expect(ScriptedClaude.value(of: "--model", in: first) == ModelAlias.cliValue(for: "opus"))
        #expect(ScriptedClaude.value(of: "--model", in: second) == ModelAlias.cliValue(for: "haiku"))
        #expect(ScriptedClaude.value(of: "--permission-mode", in: first) == PermissionMode.acceptEdits.cliValue)
        #expect(ScriptedClaude.value(of: "--permission-mode", in: second) == PermissionMode.plan.cliValue)
        await fixture.runtime.shutdown()
    }

    /// Fails without `RemoteSession.restartWithoutResume`: the turn ends on the first launch's
    /// error, the queue pauses, and the second launch never happens. And without
    /// `AgentRunner.forgetMissingConversation` the relaunch resumes the same missing id again.
    @Test("a resume of a conversation the machine no longer has starts a new one, once, and the turn completes")
    func missingConversationStartsAgain() async throws {
        let fixture = try await fixture(
            agentSessionID: "gone-1",
            scripts: [.conversationNotFound, .answer(conversation: "conv-2")]
        )

        await send("Hello", in: fixture)
        await waitForIdle(fixture, launches: 2)

        let launches = fixture.processes.launches
        try #require(launches.count == 2, "One fresh launch, and no more")
        #expect(ScriptedClaude.resumeID(launches[0]) == "gone-1")
        #expect(ScriptedClaude.resumeID(launches[1]) == nil)
        let second = try #require(fixture.processes.all.last)
        #expect(second.stdin.count == 1 && second.stdin[0].contains("Hello"), "The same turn went to the fresh process")

        let row = try #require(try await fixture.store.session(id: fixture.session.id))
        #expect(row.agentSessionID == "conv-2")
        #expect(try await fixture.store.setting(RemotePromptQueue.pauseKey(fixture.session.id)) != "true",
                "The queue carries on rather than pausing on the lost conversation")
        let messages = try await fixture.store.messages(sessionID: fixture.session.id)
        let notes = messages.filter { $0.kind == .notice }.compactMap { ConversationNotResumed.sentence(fromNote: $0.payload) }
        #expect(notes == [ConversationNotResumed.sentence])
        #expect(messages.filter { $0.kind == .user }.count == 1, "The message is recorded once, by its claim, and not again")
        await fixture.runtime.shutdown()
    }

    @Test("the same failure said only on stderr starts a new conversation too")
    func missingConversationOnStderr() async throws {
        let fixture = try await fixture(
            agentSessionID: "gone-1",
            scripts: [.conversationNotFoundOnStderr, .answer(conversation: "conv-2")]
        )

        await send("Hello", in: fixture)
        await waitForIdle(fixture, launches: 2)

        let launches = fixture.processes.launches
        try #require(launches.count == 2)
        #expect(ScriptedClaude.resumeID(launches[0]) == "gone-1")
        #expect(ScriptedClaude.resumeID(launches[1]) == nil)
        #expect(try await fixture.store.session(id: fixture.session.id)?.agentSessionID == "conv-2")
        await fixture.runtime.shutdown()
    }

    @Test("only the exact failure is read as a missing conversation")
    func matchingIsNarrow() {
        let missing = Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"x","errors":["No conversation found with session ID: x"]}"#.utf8)
        let other = Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"x","errors":["Credit balance is too low"]}"#.utf8)
        #expect(ConversationNotResumed.matches(AgentResult(isError: true, raw: missing)))
        #expect(!ConversationNotResumed.matches(AgentResult(isError: true, raw: other)))
        #expect(!ConversationNotResumed.matches(AgentResult(isError: false, raw: missing)))
        #expect(ConversationNotResumed.sentence(fromNote: Data(#"{"type":"rate_limit_event"}"#.utf8)) == nil)
    }
}

/// Every scripted `claude` the runtime launched, in order.
final class ScriptedClaudeProcesses: Sendable {
    private let state: Mutex<(scripts: [ScriptedClaude.Script], made: [ScriptedClaude])>

    init(scripts: [ScriptedClaude.Script]) {
        state = Mutex((scripts, []))
    }

    var factory: @Sendable (AgentLaunch) -> any AgentProcessing {
        { launch in
            self.state.withLock { state in
                let script = state.scripts.isEmpty ? .answer(conversation: "extra") : state.scripts.removeFirst()
                let process = ScriptedClaude(launch: launch, script: script)
                state.made.append(process)
                return process
            }
        }
    }

    var all: [ScriptedClaude] { state.withLock(\.made) }
    var launches: [AgentLaunch] { all.map(\.launch) }
}

/// Answers the first turn written to it the way the CLI does, and ends when terminated.
final class ScriptedClaude: AgentProcessing, Sendable {
    enum Script: Sendable {
        /// An init naming the conversation, then a successful result, then waits for more stdin.
        case answer(conversation: String)
        /// What claude 2.1.280 prints for a `--resume` of an id it cannot find, measured: one error
        /// result carrying the sentence, the same sentence on stderr, and exit 1.
        case conversationNotFound
        /// The same failure from a CLI that says it on stderr alone and prints no result.
        case conversationNotFoundOnStderr
    }

    let launch: AgentLaunch
    let script: Script
    let lines: AsyncThrowingStream<String, Error>
    let errorLines: AsyncStream<String>
    private let out: AsyncThrowingStream<String, Error>.Continuation
    private let err: AsyncStream<String>.Continuation
    private let state = Mutex<(written: [String], running: Bool, terminated: Bool, status: Int32)>(([], true, false, 0))

    init(launch: AgentLaunch, script: Script) {
        self.launch = launch
        self.script = script
        (lines, out) = AsyncThrowingStream.makeStream(bufferingPolicy: .unbounded)
        (errorLines, err) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    var isRunning: Bool { state.withLock(\.running) }
    var exitStatus: Int32 { get async { state.withLock(\.status) } }
    var stdin: [String] { state.withLock(\.written) }
    var wasTerminated: Bool { state.withLock(\.terminated) }

    func writeLine(_ text: String) {
        let first = state.withLock { state in
            state.written.append(text)
            return state.written.count == 1
        }
        guard first, text.contains(#""type":"user""#) else { return }
        switch script {
        case .answer(let conversation):
            out.yield(#"{"type":"system","subtype":"init","session_id":"\#(conversation)","cwd":"/tmp","model":"opus","permissionMode":"acceptEdits"}"#)
            out.yield(#"{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"duration_api_ms":5,"num_turns":1,"result":"Done.","session_id":"\#(conversation)","total_cost_usd":0,"usage":{"input_tokens":1,"output_tokens":1}}"#)
        case .conversationNotFound:
            let id = Self.resumeID(launch) ?? ""
            let sentence = "No conversation found with session ID: \(id)"
            out.yield(#"{"type":"result","subtype":"error_during_execution","duration_ms":0,"duration_api_ms":0,"is_error":true,"num_turns":0,"stop_reason":null,"session_id":"\#(id)","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"errors":["\#(sentence)"]}"#)
            err.yield(sentence)
            end(status: 1)
        case .conversationNotFoundOnStderr:
            err.yield("No conversation found with session ID: \(Self.resumeID(launch) ?? "")")
            end(status: 1)
        }
    }

    func closeStdin() {}
    func terminate() {
        state.withLock { $0.terminated = true }
        end(status: 143)
    }
    func kill() { terminate() }

    private func end(status: Int32) {
        let wasRunning = state.withLock { state -> Bool in
            defer { state.running = false }
            if state.running { state.status = status }
            return state.running
        }
        guard wasRunning else { return }
        out.finish()
        err.finish()
    }

    static func resumeID(_ launch: AgentLaunch) -> String? {
        value(of: "--resume", in: launch.arguments)
    }

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
