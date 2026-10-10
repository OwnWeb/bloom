import Testing
import Foundation
@testable import BloomCore

/// Lines shaped like the ones `claude -p --output-format stream-json --include-partial-messages`
/// writes, trimmed to the fields `ClaudeRouterAsk.Decoder` reads.
private enum ClaudeStream {
    static func quoted(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
    }

    static func thinkingStart() -> String {
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#
    }

    static func thinking(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"#
            + quoted(text) + "}}}"
    }

    static func thinkingBlock(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"#
            + quoted(text) + #","signature":"sig"}]}}"#
    }

    static func structuredTool(complexity: String, reason: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"StructuredOutput","input":{"complexity":""#
            + complexity + #"","reason":""# + reason + #""}}]}}"#
    }

    static func result(complexity: String, reason: String) -> String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"complexity":""#
            + complexity + #"","reason":""# + reason + #""}}"#
    }

    static func emptyResult() -> String {
        #"{"type":"result","subtype":"success","is_error":false,"result":""}"#
    }

    static func failedResult() -> String {
        #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"offline"}"#
    }
}

private let haiku = RouterAnalyser(kind: .claudeCode, model: "haiku", effort: "low", name: "Claude Haiku")

/// A Claude Code runner that plays a fixed stream back, counting how often it was launched.
private func replaying(_ lines: [String], launches: LaunchCount = LaunchCount()) -> ModelRouter.Ask {
    { request in
        ClaudeRouterAsk.ask(request, run: { _ in
            launches.increment()
            return AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
        })
    }
}

/// An asker that hands back fixed signals, whichever agent was asked.
private func signalling(_ signals: [RouterSignal]) -> ModelRouter.Ask {
    { _ in
        AsyncThrowingStream { continuation in
            for signal in signals { continuation.yield(signal) }
            continuation.finish()
        }
    }
}

/// Everything a router said, last element included.
private func collect(
    _ router: ModelRouter,
    task: String = "Fix the typo in the README",
    analyser: RouterAnalyser = haiku
) async -> [ModelRouterProgress] {
    var seen: [ModelRouterProgress] = []
    for await step in router.progress(task: task, project: "Bloom", template: "{{task}}", analyser: analyser) {
        seen.append(step)
    }
    return seen
}

private func model(_ id: String, _ efforts: String..., hidden: Bool = false, name: String = "") -> AgentModel {
    AgentModel(
        id: id,
        displayName: name,
        hidden: hidden,
        supportedEfforts: efforts.map { AgentModelEffort(id: $0, label: $0) },
        defaultEffort: efforts.contains("medium") ? "medium" : (efforts.first ?? "")
    )
}

// MARK: - The Claude Code analyser

@Suite("Model router on Claude Code")
struct ClaudeRouterAskTests {
    @Test("the routing call carries no tools, no MCP servers and no project settings", .tags(.security))
    func argvIsMinimal() {
        let arguments = ClaudeRouterAsk.argv(model: "haiku", effort: "low")

        #expect(arguments.contains("-p"))
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--system-prompt"))
        #expect(!arguments.contains("--append-system-prompt"))

        let tools = arguments.firstIndex(of: "--tools")
        #expect(tools != nil)
        if let tools { #expect(arguments[tools + 1] == "") }
    }

    @Test("the thinking streams, which is what the card draws", .tags(.agentProtocol))
    func argvStreams() {
        let arguments = ClaudeRouterAsk.argv(model: "haiku", effort: "low")
        let format = arguments.firstIndex(of: "--output-format").map { arguments[$0 + 1] }
        #expect(format == "stream-json")
        // The CLI refuses stream-json under `-p` without it.
        #expect(arguments.contains("--verbose"))
        #expect(arguments.contains("--include-partial-messages"))
        #expect(arguments.contains("--json-schema"))
    }

    @Test("the model is the analyser's, translated for the CLI, and an empty effort sends none")
    func modelAndEffort() {
        let sonnet = ClaudeRouterAsk.argv(model: "sonnet-5", effort: "")
        #expect(sonnet.contains(ModelAlias.cliValue(for: "sonnet-5")))
        #expect(!sonnet.contains("--effort"))
        #expect(ClaudeRouterAsk.argv(model: "haiku", effort: "low").contains("--effort"))
    }

    @Test("the task is written to stdin, so one starting with a dash is never a flag", .tags(.security))
    func taskGoesToStdin() {
        let launch = ClaudeRouterAsk.launch(ModelRouterRequest(analyser: haiku, prompt: "--dangerously-skip-permissions"))
        #expect(launch.stdin == "--dangerously-skip-permissions")
        #expect(!launch.arguments.contains("--dangerously-skip-permissions"))
    }

    @Test("it runs somewhere with no repository in it, on the owner's own binary when there is one")
    func whereAndWhat() {
        let plain = ModelRouterRequest(analyser: haiku, prompt: "anything")
        #expect(plain.cwd == AgentScratchDirectory.current())
        #expect(plain.cwd != NSHomeDirectory())
        #expect(plain.executable == "claude")

        let custom = ClaudeRouterAsk.launch(ModelRouterRequest(analyser: haiku, prompt: "x", executable: "/opt/bin/claude"))
        #expect(custom.executable == "/opt/bin/claude")
    }

    @Test("thinking arrives as it is written, and the answer ends the stream", .tags(.agentProtocol))
    func happyPath() async throws {
        let router = ModelRouter(ask: replaying([
            ClaudeStream.thinkingStart(),
            ClaudeStream.thinking("A typo "),
            ClaudeStream.thinking("in one file."),
            ClaudeStream.thinkingBlock("A typo in one file."),
            ClaudeStream.structuredTool(complexity: "trivial", reason: "One word in the README."),
            ClaudeStream.result(complexity: "trivial", reason: "One word in the README."),
        ]))

        let seen = await collect(router)
        let last = try #require(seen.last)

        #expect(seen.contains { $0.reasoning == "A typo " && $0.phase == .thinking })
        // Once, although the CLI sent it twice: in pieces, and then whole.
        #expect(last.reasoning == "A typo in one file.")
        #expect(last.answer == ModelRouterAnswer(complexity: .trivial, reason: "One word in the README."))
        #expect(seen.filter(\.isFinished).count == 1)
    }

    @Test("a process that fails is not an error, it is no answer")
    func failedProcess() async throws {
        let router = ModelRouter(ask: { request in
            ClaudeRouterAsk.ask(request, run: { _ in
                AsyncThrowingStream { $0.finish(throwing: ShellError(command: "claude", status: 1, stderr: "offline")) }
            })
        })
        let last = try #require(await collect(router).last)
        #expect(last.phase == .failed)
    }

    @Test("an error result is no answer either")
    func errorResult() async throws {
        let last = try #require(await collect(ModelRouter(ask: replaying([ClaudeStream.failedResult()]))).last)
        #expect(last.phase == .failed)
    }

    @Test("a stream that stops before its result has not answered")
    func truncated() async throws {
        let last = try #require(await collect(ModelRouter(ask: replaying([ClaudeStream.thinking("Hmm")]))).last)
        #expect(last.phase == .failed)
        #expect(last.reasoning == "Hmm")
    }

    @Test("a task with nothing in it asks nothing rather than sending a blank turn")
    func emptyTask() async throws {
        let launches = LaunchCount()
        let router = ModelRouter(ask: replaying([], launches: launches))
        let last = try #require(await collect(router, task: "   ").last)
        #expect(launches.value == 0)
        #expect(last.phase == .failed)
    }

    @Test("an answer only in the result text is still found", .tags(.agentProtocol))
    func answerInResultText() async throws {
        let line = #"{"type":"result","is_error":false,"result":"{\"complexity\":\"complex\",\"reason\":\"Many files.\"}"}"#
        let last = try #require(await collect(ModelRouter(ask: replaying([line]))).last)
        #expect(last.answer == ModelRouterAnswer(complexity: .complex, reason: "Many files."))
    }

    @Test("an answer only in the tool call is still found", .tags(.agentProtocol))
    func answerInToolCall() async throws {
        let last = try #require(await collect(ModelRouter(ask: replaying([
            ClaudeStream.structuredTool(complexity: "deep", reason: "A race."),
            ClaudeStream.emptyResult(),
        ]))).last)
        #expect(last.answer == ModelRouterAnswer(complexity: .deep, reason: "A race."))
    }

    @Test("thinking with no deltas is read off the whole block, and a second block is a new paragraph")
    func thinkingBlocks() {
        var decoder = ClaudeRouterAsk.Decoder()
        let said1 = decoder.signals(for: ClaudeStream.thinkingBlock("Small change."))
        #expect(said1 == [.thinking("Small change.")])
        let said2 = decoder.signals(for: ClaudeStream.thinkingBlock("Still small."))
        #expect(said2 == [.thinking("\n\nStill small.")])

        var streaming = ClaudeRouterAsk.Decoder()
        _ = streaming.signals(for: ClaudeStream.thinking("First."))
        let said3 = streaming.signals(for: ClaudeStream.thinkingStart())
        #expect(said3 == [.thinking("\n\n")])
    }

    @Test(
        "lines that are not the protocol say nothing",
        arguments: ["", "not json", "{}", #"{"type":"system","subtype":"init"}"#]
    )
    func noise(line: String) {
        var decoder = ClaudeRouterAsk.Decoder()
        let said4 = decoder.signals(for: line)
        #expect(said4.isEmpty)
    }
}

// MARK: - The router, whichever agent answers

@Suite("Model router")
struct ModelRouterTests {
    @Test("the schema offers exactly the rungs the table has", .tags(.agentProtocol))
    func schema() throws {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(ModelRouter.jsonSchema.utf8)) as? [String: Any]
        )
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.keys.sorted() == ["complexity", "reason"])
        #expect(object["additionalProperties"] as? Bool == false)

        let complexity = try #require(properties["complexity"] as? [String: Any])
        let rungs = try #require(complexity["enum"] as? [String])
        #expect(rungs == TaskComplexity.allCases.map(\.rawValue))
    }

    @Test("the deadline is a cap on a call that never returns, not a measurement")
    func timeout() {
        #expect(ModelRouter.timeout > .seconds(40))
        #expect(ModelRouter.timeout <= .seconds(90))
    }

    @Test("the prompt carries the task and the project")
    func promptRenders() {
        let prompt = ModelRouter.prompt(task: "Add a dark mode toggle", project: "Bloom")
        #expect(prompt.contains("Add a dark mode toggle"))
        #expect(prompt.contains("Bloom"))
        #expect(!prompt.contains("{{"))
    }

    @Test("the built-in prompt names every rung, and asks for the JSON in words")
    func promptNamesEveryRung() {
        let template = PromptRegistry.definition(for: .routeTask).defaultTemplate
        for rung in TaskComplexity.allCases {
            #expect(template.contains("- \(rung.rawValue):"), "the prompt never describes \(rung.rawValue)")
        }
        #expect(template.contains("\"complexity\""))
        #expect(template.contains("\"reason\""))
    }

    @Test("a pasted stack trace is capped rather than paid for")
    func promptCapsTheTask() {
        let huge = String(repeating: "stack frame\n", count: 5_000)
        let prompt = ModelRouter.prompt(task: huge, project: "Bloom")
        #expect(prompt.count < ModelRouter.taskLimit + 2_000)
    }

    @Test("the answer is the same whichever agent gave it")
    func agentAgnostic() async throws {
        let codex = RouterAnalyser(kind: .codex, model: "gpt-5.5-mini", effort: "low", name: "GPT-5.5 mini")
        let router = ModelRouter(ask: signalling([
            .thinking("Looks small."),
            .text(#"Here it is: {"complexity":"simple","reason":"One function."}"#),
            .finished(isError: false),
        ]))
        let last = try #require(await collect(router, analyser: codex).last)
        #expect(last.reasoning == "Looks small.")
        #expect(last.answer == ModelRouterAnswer(complexity: .simple, reason: "One function."))
    }

    @Test("an agent Bloom cannot talk to is no answer, and asks nothing")
    func unsupportedAgent() async throws {
        let cursor = RouterAnalyser(kind: .cursor, model: "", effort: "", name: "Cursor")
        let last = try #require(await collect(ModelRouter(ask: ModelRouter.live), analyser: cursor).last)
        #expect(last.phase == .failed)
    }

    /// The bound below is the router's own deadline, made small so the test is not a minute long.
    /// What is asserted is the outcome, not how long it took: a stream that never ends must still
    /// end the route, failed, and before the suite's own limit kills the test from outside.
    @Test("an analyser that never answers is given up on", .timeLimit(.minutes(1)))
    func neverAnswers() async throws {
        let router = ModelRouter(ask: { _ in AsyncThrowingStream { _ in } }, timeout: .milliseconds(50))
        let last = try #require(await collect(router).last)
        #expect(last.phase == .failed)
    }
}

@Suite("Model router progress")
struct ModelRouterProgressTests {
    @Test("a forced structure wins over prose")
    func structureWins() {
        var progress = ModelRouterProgress()
        progress.ingest(.text(#"{"complexity":"trivial","reason":"prose"}"#))
        progress.ingest(.structured(.object(["complexity": .string("deep"), "reason": .string("schema")])))
        progress.ingest(.finished(isError: false))
        #expect(progress.answer == ModelRouterAnswer(complexity: .deep, reason: "schema"))
    }

    @Test("prose is read whether fenced, introduced or bare")
    func proseShapes() {
        #expect(ModelRouterProgress.object(in: "```json\n{\"complexity\":\"simple\"}\n```")?["complexity"]?.stringValue == "simple")
        #expect(ModelRouterProgress.object(in: "Sure. {\"complexity\":\"deep\"} Done.")?["complexity"]?.stringValue == "deep")
        #expect(ModelRouterProgress.object(in: "no object here") == nil)
        #expect(ModelRouterProgress.object(in: "[1, 2]") == nil)
    }

    @Test("an error ends it without an answer, whatever arrived before")
    func errorFinish() {
        var progress = ModelRouterProgress()
        progress.ingest(.structured(.object(["complexity": .string("simple")])))
        progress.ingest(.finished(isError: true))
        #expect(progress.phase == .failed)
    }

    @Test("nothing after the end can change it")
    func settledIsFinal() {
        var progress = ModelRouterProgress()
        progress.ingest(.structured(.object(["complexity": .string("simple")])))
        progress.ingest(.finished(isError: false))
        let changed = progress.ingest(.thinking("late"))
        #expect(!changed)
        #expect(progress.reasoning.isEmpty)
        #expect(progress.answer?.complexity == .simple)
    }
}

// MARK: - The Codex and Grok analysers

@Suite("Model router on Codex")
struct CodexRouterAskTests {
    private func delta(_ text: String, item: String = "r1", thread: String = "t1") -> CodexEvent {
        .reasoningDelta(CodexTextDelta(itemID: item, threadID: thread, turnID: "u1", text: text))
    }

    private func message(_ text: String, phase: CodexMessagePhase) -> CodexEvent {
        .itemCompleted(CodexItemEvent(item: .agentMessage(CodexAgentMessage(id: "m1", text: text, phase: phase)), threadID: "t1", turnID: "u1"))
    }

    @Test("reasoning streams, with a paragraph between two items", .tags(.agentProtocol))
    func reasoning() {
        var decoder = CodexRouterAsk.Decoder(threadID: "t1")
        let said5 = decoder.signals(for: delta("One."))
        #expect(said5 == [.thinking("One.")])
        let said6 = decoder.signals(for: delta(" More."))
        #expect(said6 == [.thinking(" More.")])
        let said7 = decoder.signals(for: delta("Two.", item: "r2"))
        #expect(said7 == [.thinking("\n\nTwo.")])
    }

    @Test("another thread on the same connection says nothing")
    func otherThread() {
        var decoder = CodexRouterAsk.Decoder(threadID: "t1")
        let said8 = decoder.signals(for: delta("Elsewhere.", thread: "t2"))
        #expect(said8.isEmpty)
    }

    @Test("the answer is the final message, and narration before it is not", .tags(.agentProtocol))
    func answer() {
        var decoder = CodexRouterAsk.Decoder(threadID: "t1")
        let said9 = decoder.signals(for: message("Let me think.", phase: .commentary))
        #expect(said9.isEmpty)
        let said10 = decoder.signals(for: message(#"{"complexity":"moderate"}"#, phase: .finalAnswer))
        #expect(said10 == [.text(#"{"complexity":"moderate"}"#)])
        // Providers do not always set the phase, so an unknown one is still an answer.
        let said11 = decoder.signals(for: message("x", phase: .unknown))
        #expect(said11 == [.text("x")])
    }

    @Test("the turn's end finishes it, and a failed turn is an error")
    func turnEnds() {
        var done = CodexRouterAsk.Decoder(threadID: "t1")
        _ = done.signals(for: message("{}", phase: .finalAnswer))
        let said12 = done.signals(for: .turnCompleted(CodexTurn(id: "u1", threadID: "t1", status: .completed)))
        #expect(said12 == [.finished(isError: false)])
        #expect(done.isFinished)

        var failed = CodexRouterAsk.Decoder(threadID: "t1")
        let said13 = failed.signals(for: .turnCompleted(CodexTurn(id: "u1", threadID: "t1", status: .failed)))
        #expect(said13 == [.finished(isError: true)])
    }

    @Test("an answer only in the completed turn is still found")
    func lateAnswer() {
        var decoder = CodexRouterAsk.Decoder(threadID: "t1")
        let turn = CodexTurn(
            id: "u1", threadID: "t1", status: .completed,
            items: [.agentMessage(CodexAgentMessage(id: "m1", text: "{}", phase: .finalAnswer))]
        )
        let said14 = decoder.signals(for: .turnCompleted(turn))
        #expect(said14 == [.text("{}"), .finished(isError: false)])
    }

    @Test("an error the server will retry is not the end, and a closed connection is")
    func errors() {
        var decoder = CodexRouterAsk.Decoder(threadID: "t1")
        let retry = CodexTurnError(threadID: "t1", turnID: "u1", message: "busy", willRetry: true)
        let said15 = decoder.signals(for: .turnError(retry))
        #expect(said15.isEmpty)
        #expect(!decoder.isFinished)
        let said16 = decoder.signals(for: .closed(reason: "gone"))
        #expect(said16 == [.finished(isError: true)])
    }
}

@Suite("Model router on Grok")
struct GrokRouterAskTests {
    private func update(_ kind: GrokSessionUpdate.Kind, session: String = "s1") -> GrokEvent {
        .update(GrokSessionUpdate(sessionID: session, kind: kind, raw: .null))
    }

    @Test("thoughts are reasoning and message chunks are the answer", .tags(.agentProtocol))
    func chunks() {
        var decoder = GrokRouterAsk.Decoder(session: "s1", promptID: .number(3))
        let said17 = decoder.signals(for: update(.thought("Hmm.")))
        #expect(said17 == [.thinking("Hmm.")])
        let said18 = decoder.signals(for: update(.text("{\"complexity\"")))
        #expect(said18 == [.text("{\"complexity\"")])
        let said19 = decoder.signals(for: update(.thought("x"), session: "other"))
        #expect(said19.isEmpty)
    }

    @Test("only this prompt's reply ends it, and a refusal is an error")
    func ends() {
        var decoder = GrokRouterAsk.Decoder(session: "s1", promptID: .number(3))
        let other = GrokPromptResult(requestID: .number(2), sessionID: "s1", stopReason: "end_turn", raw: .null)
        let said20 = decoder.signals(for: .promptCompleted(other))
        #expect(said20.isEmpty)

        let refused = GrokPromptResult(requestID: .number(3), sessionID: "s1", stopReason: "refusal", raw: .null)
        let said21 = decoder.signals(for: .promptCompleted(refused))
        #expect(said21 == [.finished(isError: true)])
        #expect(decoder.isFinished)
    }

    @Test("the instructions travel ahead of the task, since ACP has no system prompt", .tags(.security))
    func instructionsFirst() {
        let grok = RouterAnalyser(kind: .grok, model: "grok-5-fast", effort: "low", name: "Grok 5 Fast")
        let prompt = GrokRouterAsk.prompt(for: ModelRouterRequest(analyser: grok, prompt: "The task."))
        #expect(prompt.hasPrefix(ModelRouter.systemPrompt))
        #expect(prompt.hasSuffix("The task."))
    }
}

// MARK: - Choosing the analyser

@Suite("Router analyser")
struct RouterAnalyserTests {
    private let lists: [AgentKind: [AgentModel]] = [
        .codex: [model("gpt-5.5", "low", "medium", "high"), model("gpt-5.5-mini", "minimal", "low", "medium", name: "GPT-5.5 mini")],
        .grok: [model("grok-5", "low", "high"), model("grok-5-fast", "low")],
    ]

    private func resolve(
        chat: AgentKind,
        connected: Set<AgentKind>,
        settings: ModelRouterSettings = ModelRouterSettings()
    ) -> RouterAnalyser? {
        RouterAnalyser.resolve(chatBackend: chat, settings: settings, connected: connected, models: lists)
    }

    @Test("the chat's own agent analyses when it is connected")
    func followsTheChat() {
        #expect(resolve(chat: .codex, connected: [.claudeCode, .codex])?.kind == .codex)
        #expect(resolve(chat: .claudeCode, connected: [.claudeCode, .codex])?.kind == .claudeCode)
    }

    @Test("otherwise the first connected agent, in the order Bloom offers them")
    func fallsBack() {
        #expect(resolve(chat: .codex, connected: [.grok, .claudeCode])?.kind == .claudeCode)
        #expect(resolve(chat: .claudeCode, connected: [.grok])?.kind == .grok)
    }

    @Test("a named agent wins while it is connected, and falls back when it is not")
    func namedAgent() {
        let grokFirst = ModelRouterSettings(analyser: .agent(.grok))
        #expect(resolve(chat: .claudeCode, connected: [.claudeCode, .grok], settings: grokFirst)?.kind == .grok)
        #expect(resolve(chat: .claudeCode, connected: [.claudeCode], settings: grokFirst)?.kind == .claudeCode)
    }

    @Test("nobody connected, or only agents Bloom cannot talk to, is nobody")
    func nobody() {
        #expect(resolve(chat: .claudeCode, connected: []) == nil)
        #expect(resolve(chat: .claudeCode, connected: [.cursor, .openCode]) == nil)
    }

    @Test("the suggested model is each agent's light one")
    func suggestions() {
        #expect(RouterAnalyser.suggestedModel(for: .claudeCode, models: []) == "haiku")
        #expect(RouterAnalyser.suggestedModel(for: .codex, models: lists[.codex] ?? []) == "gpt-5.5-mini")
        #expect(RouterAnalyser.suggestedModel(for: .grok, models: lists[.grok] ?? []) == "grok-5-fast")
        // No light model: the least capable on the list. No list: the agent's own default.
        #expect(RouterAnalyser.suggestedModel(for: .codex, models: [model("gpt-5.5"), model("gpt-5.4")]) == "gpt-5.4")
        #expect(RouterAnalyser.suggestedModel(for: .codex, models: []).isEmpty)
    }

    @Test("the lightest effort that still thinks, and none for a model that takes none")
    func efforts() throws {
        let codex = try #require(resolve(chat: .codex, connected: [.codex]))
        #expect(codex.model == "gpt-5.5-mini")
        #expect(codex.effort == "low")
        #expect(codex.name == "GPT-5.5 mini")

        let haikuOnly = RouterAnalyser.analyser(on: .claudeCode, stored: nil, models: [model("haiku")])
        #expect(haikuOnly.effort.isEmpty)
        #expect(RouterAnalyser.analyser(on: .claudeCode, stored: nil, models: []).effort == "low")
    }

    @Test("the owner's model is kept while the list still offers it")
    func storedModel() {
        let stored = ModelRouteChoice(model: "gpt-5.5", effort: "medium")
        let kept = RouterAnalyser.analyser(on: .codex, stored: stored, models: lists[.codex] ?? [])
        #expect(kept.model == "gpt-5.5")
        #expect(kept.effort == "medium")

        let retired = ModelRouteChoice(model: "gpt-4.1", effort: "medium")
        #expect(RouterAnalyser.analyser(on: .codex, stored: retired, models: lists[.codex] ?? []).model == "gpt-5.5-mini")
    }

    @Test("a name is always something a person can read")
    func names() {
        #expect(RouterAnalyser.analyser(on: .claudeCode, stored: nil, models: []).name == "Claude Haiku")
        #expect(RouterAnalyser.analyser(on: .codex, stored: nil, models: []).name == "Codex's default model")
    }
}

// MARK: - Tables and settings

@Suite("Router tables")
struct ModelRouterTableTests {
    private let codex = [
        model("gpt-5.5", "minimal", "low", "medium", "high", "xhigh"),
        model("gpt-5.5-mini", "low", "medium", "high"),
        model("codex-auto-review", "low", hidden: true),
    ]

    @Test("Claude Code's table is the written one, whatever its list says")
    func claude() {
        #expect(ModelRouterTable.suggested(for: .claudeCode, models: []) == .standard)
    }

    @Test("Codex's is read off its list: the light model low, the full one high", .tags(.agentProtocol))
    func codexTable() throws {
        let table = try #require(ModelRouterTable.suggested(for: .codex, models: codex))
        #expect(table.choice(for: .trivial) == ModelRouteChoice(model: "gpt-5.5-mini", effort: "low"))
        #expect(table.choice(for: .simple) == ModelRouteChoice(model: "gpt-5.5-mini", effort: "medium"))
        #expect(table.choice(for: .moderate) == ModelRouteChoice(model: "gpt-5.5", effort: "medium"))
        #expect(table.choice(for: .complex) == ModelRouteChoice(model: "gpt-5.5", effort: "high"))
        #expect(table.choice(for: .deep) == ModelRouteChoice(model: "gpt-5.5", effort: "xhigh"))
    }

    @Test("an account with no light model runs every rung on the full one")
    func noLightModel() throws {
        let table = try #require(ModelRouterTable.suggested(for: .grok, models: [model("grok-5", "low", "high")]))
        #expect(TaskComplexity.allCases.allSatisfy { table.choice(for: $0).model == "grok-5" })
        #expect(table.choice(for: .trivial).effort == "low")
        #expect(table.choice(for: .deep).effort == "high")
    }

    @Test("nothing to read is no table")
    func nothing() {
        #expect(ModelRouterTable.suggested(for: .codex, models: []) == nil)
        #expect(ModelRouterTable.suggested(for: .cursor, models: codex) == nil)
    }

    @Test("the owner's rungs go over the suggestion, and only those")
    func overrides() throws {
        let settings = ModelRouterSettings(tables: [.codex: [.deep: ModelRouteChoice(model: "gpt-5.5", effort: "high")]])
        let table = try #require(settings.table(for: .codex, models: codex))
        #expect(table.choice(for: .deep).effort == "high")
        #expect(table.choice(for: .trivial).model == "gpt-5.5-mini")
    }

    @Test("a Codex route stays on Codex models, and keeps the chat's model when a stored one is gone")
    func codexRoute() throws {
        let table = try #require(ModelRouterTable.suggested(for: .codex, models: codex))
        let trivial = ModelRouting.route(
            ModelRouterAnswer(complexity: .trivial, reason: ""), table: table, backend: .codex,
            current: "gpt-5.5", models: codex
        )
        #expect(trivial.model == "gpt-5.5-mini")
        #expect(trivial.effort == "low")

        let stale = ModelRouterTable(choices: [.deep: ModelRouteChoice(model: "gpt-4.1", effort: "high")])
        let kept = ModelRouting.route(
            ModelRouterAnswer(complexity: .deep, reason: ""), table: stale, backend: .codex,
            current: "gpt-5.5", models: codex
        )
        #expect(kept.model == "gpt-5.5")
    }

    @Test("a rung the table does not have keeps the chat's model")
    func missingRung() {
        let route = ModelRouting.route(
            ModelRouterAnswer(complexity: .simple, reason: ""), table: ModelRouterTable(choices: [:]),
            backend: .grok, current: "grok-5"
        )
        #expect(route.model == "grok-5")
    }
}

@Suite("Router settings")
struct ModelRouterSettingsTests {
    @Test("everything the owner chose survives a round trip")
    func roundTrip() throws {
        let settings = ModelRouterSettings(
            analyser: .agent(.codex),
            analyserModels: [.codex: ModelRouteChoice(model: "gpt-5.5-mini", effort: "low")],
            tables: [.grok: [.deep: ModelRouteChoice(model: "grok-5", effort: "high")]]
        )
        let raw = try #require(settings.encoded())
        #expect(raw.contains("\"codex\""))
        #expect(ModelRouterSettings.decode(raw) == settings)
    }

    @Test("the defaults store nothing, and nothing reads back as the defaults")
    func empty() {
        #expect(ModelRouterSettings().encoded() == nil)
        #expect(ModelRouterSettings.decode(nil) == ModelRouterSettings())
        #expect(ModelRouterSettings.decode("not json") == ModelRouterSettings())
    }

    @Test("an agent or a rung from somewhere else is left out, and the rest is kept")
    func unknownEntries() {
        let raw = #"{"analyser":"copilot","analyserModels":{"codex":{"model":"m","effort":"low"},"copilot":{"model":"x","effort":""}},"tables":{"grok":{"epic":{"model":"y","effort":""},"deep":{"model":"grok-5","effort":"high"}}}}"#
        let settings = ModelRouterSettings.decode(raw)
        #expect(settings.analyser == .followChat)
        #expect(settings.analyserModels.keys.map(\.rawValue) == ["codex"])
        #expect(settings.tables[.grok]?.keys.map(\.rawValue) == ["deep"])
    }

    @Test("off unless somebody turns it on, and the settings live beside the switch")
    func preferences() throws {
        let suite = "bloom.router.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = ModelRouterPreferences(defaults: defaults)
        #expect(!preferences.isEnabled)
        preferences.isEnabled = true
        #expect(ModelRouterPreferences(defaults: defaults).isEnabled)

        preferences.settings = ModelRouterSettings(analyser: .agent(.grok))
        #expect(ModelRouterPreferences(defaults: defaults).settings.analyser == .agent(.grok))
        preferences.settings = ModelRouterSettings()
        #expect(defaults.string(forKey: ModelRouterPreferences.settingsKey) == nil)
    }
}

// MARK: - The rules

@Suite("Model routing")
struct ModelRoutingTests {
    @Test("a rung is read whatever case or wrapping it arrives in")
    func forgivingRung() throws {
        let answer = try #require(ModelRouting.answer(from: .object([
            "complexity": .string(" \"Moderate.\" "), "reason": .string("A form field."),
        ])))
        #expect(answer.complexity == .moderate)
    }

    @Test("a rung the table does not have is no answer", arguments: ["", "hard", "5", "medium"])
    func unknownRung(word: String) {
        #expect(ModelRouting.answer(from: .object(["complexity": .string(word)])) == nil)
    }

    @Test("a missing reason is not a missing answer")
    func missingReason() {
        let answer = ModelRouting.answer(from: .object(["complexity": .string("simple")]))
        #expect(answer == ModelRouterAnswer(complexity: .simple, reason: ""))
    }

    @Test("a reason is one line, capped at a word")
    func reasonIsCleaned() throws {
        #expect(ModelRouting.cleanReason("Two\nlines\tand  gaps") == "Two lines and gaps")
        #expect(ModelRouting.cleanReason("   ") == nil)

        let long = String(repeating: "word ", count: 100)
        let cleaned = try #require(ModelRouting.cleanReason(long))
        #expect(cleaned.count <= ModelRouting.reasonLimit + 1)
        #expect(cleaned.hasSuffix("word\u{2026}"))
    }

    @Test("every rung lands where Claude Code's table says", arguments: TaskComplexity.allCases)
    func followsTheTable(rung: TaskComplexity) {
        let route = ModelRouting.route(ModelRouterAnswer(complexity: rung, reason: ""), current: "claude-fable-5-1")
        let choice = ModelRouterTable.standard.choice(for: rung)
        #expect(route.model == choice.model)
        #expect(route.effort == choice.effort)
    }

    @Test("Claude Code's table climbs: no rung runs a smaller model than the one below it")
    func tableIsOrdered() {
        let order = ["haiku", "sonnet", "opus", "fable"]
        let ranks = TaskComplexity.allCases.map { rung in
            order.firstIndex(of: ModelRouterTable.standard.choice(for: rung).model) ?? -1
        }
        #expect(!ranks.contains(-1))
        #expect(ranks == ranks.sorted())
    }

    @Test("the owner's own variant of the same family is kept")
    func keepsTheVariant() {
        let route = ModelRouting.route(ModelRouterAnswer(complexity: .complex, reason: ""), current: "opus[1m]")
        #expect(route.model == "opus[1m]")
        #expect(route.effort == "high")
    }

    @Test("a family the account does not offer keeps the model the chat already had")
    func unavailableFamily() {
        let models = [model("sonnet", "low", "medium", "high"), model("opus", "low", "medium", "high")]
        let route = ModelRouting.route(ModelRouterAnswer(complexity: .trivial, reason: ""), current: "sonnet", models: models)
        #expect(route.model == "sonnet")
    }

    @Test("an effort the model does not take lands on one it does")
    func clampsTheEffort() {
        let models = [model("opus", "low", "medium", "high")]
        let route = ModelRouting.route(ModelRouterAnswer(complexity: .deep, reason: ""), current: "sonnet", models: models)
        #expect(route.model == "opus")
        #expect(route.effort == "medium")
    }

    @Test("a model listed with no efforts is sent none")
    func modelWithoutEffort() {
        let models = [model("haiku"), model("opus", "high")]
        let route = ModelRouting.route(ModelRouterAnswer(complexity: .trivial, reason: ""), current: "opus", models: models)
        #expect(route.model == "haiku")
        #expect(route.effort.isEmpty)
    }

    @Test(
        "a Claude family is read the way the CLI reads one",
        arguments: [
            ("opus", "opus"), ("opus[1m]", "opus"), ("claude-opus-5-5", "opus"),
            ("claude-sonnet-5[1m]", "sonnet"), ("Haiku", "haiku"), ("gpt-5.5", nil), ("", nil),
        ] as [(String, String?)]
    )
    func family(id: String, expected: String?) {
        #expect(ModelRouting.family(of: id) == expected)
    }

    @Test("a Bloom chat on any agent Bloom runs, with an analyser and something written, is routed")
    func routes() {
        for backend in AgentKind.runnable {
            #expect(ModelRouting.shouldRoute(
                isEnabled: true, hasAnalyser: true, mode: .chat, backend: backend,
                prompt: "Fix it", isResuming: false
            ))
        }
    }

    @Test("everything else is not")
    func declines() {
        func asks(
            isEnabled: Bool = true, hasAnalyser: Bool = true, mode: WorkspaceStartMode = .chat,
            backend: AgentKind = .claudeCode, prompt: String = "Fix it", isResuming: Bool = false
        ) -> Bool {
            ModelRouting.shouldRoute(
                isEnabled: isEnabled, hasAnalyser: hasAnalyser, mode: mode,
                backend: backend, prompt: prompt, isResuming: isResuming
            )
        }
        #expect(!asks(isEnabled: false))
        #expect(!asks(hasAnalyser: false))
        #expect(!asks(mode: .claudeCLI))
        #expect(!asks(mode: .terminal))
        #expect(!asks(backend: .cursor))
        #expect(!asks(prompt: " \n "))
        #expect(!asks(isResuming: true))
    }

    @Test("a model or an effort picked by hand takes over, and nothing else does")
    func takesOver() {
        let before = ComposerControls(model: "opus", effort: "high")

        var picked = before
        picked.model = "sonnet"
        #expect(ModelRouting.takesOver(from: before, to: picked))

        var effort = before
        effort.effort = "low"
        #expect(ModelRouting.takesOver(from: before, to: effort))

        var mode = before
        mode.permissionMode = .plan
        mode.isFastMode = true
        #expect(!ModelRouting.takesOver(from: before, to: mode))
    }
}

@Suite("Model route caption")
struct ModelRouteCaptionTests {
    @Test("the card stays while the router thinks, and goes when the conversation starts")
    func visibility() {
        #expect(ModelRouteCaption.showsCard(isSettled: false, isDismissed: true, hasConversationStarted: true))
        #expect(ModelRouteCaption.showsCard(isSettled: true, isDismissed: false, hasConversationStarted: false))
        #expect(!ModelRouteCaption.showsCard(isSettled: true, isDismissed: true, hasConversationStarted: false))
        #expect(!ModelRouteCaption.showsCard(isSettled: true, isDismissed: false, hasConversationStarted: true))
    }

    @Test("a route reads as a model and an effort")
    func title() {
        let route = ModelRoute(complexity: .deep, model: "opus", effort: "xhigh", reason: "")
        #expect(ModelRouteCaption.title(route: route, isSettled: true) == "Opus \u{00B7} Extra high effort")

        let haikuRoute = ModelRoute(complexity: .trivial, model: "haiku", effort: "", reason: "")
        #expect(ModelRouteCaption.title(route: haikuRoute, isSettled: true) == "Haiku")
    }

    @Test("the card names whoever is reading")
    func namesTheAnalyser() {
        let detail = ModelRouteCaption.detail(route: nil, isSettled: false, wasSkipped: false, analyser: "GPT-5.5 mini")
        #expect(detail.hasPrefix("GPT-5.5 mini is reading"))
        let codex = RouterAnalyser(kind: .codex, model: "gpt-5.5-mini", effort: "low", name: "GPT-5.5 mini")
        #expect(ModelRouteCaption.analyserNote(codex) == "Read by GPT-5.5 mini, on Codex.")
    }

    @Test("every state says something, and none of it is a dash")
    func sentences() {
        let route = ModelRoute(complexity: .simple, model: "sonnet", effort: "medium", reason: "One file.")
        var sentences = [
            ModelRouteCaption.title(route: nil, isSettled: false),
            ModelRouteCaption.title(route: nil, isSettled: true),
            ModelRouteCaption.detail(route: nil, isSettled: false, wasSkipped: false, analyser: "Claude Haiku"),
            ModelRouteCaption.detail(route: nil, isSettled: true, wasSkipped: true, analyser: "Claude Haiku"),
            ModelRouteCaption.detail(route: nil, isSettled: true, wasSkipped: false, analyser: "Claude Haiku"),
            ModelRouteCaption.detail(route: route, isSettled: true, wasSkipped: false, analyser: "Claude Haiku"),
            ModelRouteCaption.tableSummary(),
            ModelRouting.holdSentence,
        ]
        sentences += AgentKind.allCases.map(ModelRouteCaption.safetyNote(for:))
        for sentence in sentences {
            #expect(!sentence.isEmpty)
            #expect(!sentence.contains("\u{2014}") && !sentence.contains("\u{2013}"))
        }
        #expect(ModelRouteCaption.detail(route: route, isSettled: true, wasSkipped: false, analyser: "x") == "Simple task. One file.")
    }

    @Test("the thinking is shown from its newest end, starting at a word")
    func reasoningTail() {
        #expect(ModelRouteCaption.reasoningTail("One.\n\nTwo.") == "One. Two.")

        let long = (1...200).map { "word\($0)" }.joined(separator: " ")
        let tail = ModelRouteCaption.reasoningTail(long, limit: 40)
        #expect(tail.hasPrefix("\u{2026}word"))
        #expect(tail.hasSuffix("word200"))
        #expect(tail.count <= 41)
    }
}

/// Counts launches made from a `@Sendable` closure.
private final class LaunchCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
