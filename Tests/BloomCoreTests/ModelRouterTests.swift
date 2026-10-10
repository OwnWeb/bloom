import Testing
import Foundation
@testable import BloomCore

/// Lines shaped like the ones `claude -p --output-format stream-json --include-partial-messages`
/// writes, trimmed to the fields `ModelRouterProgress` reads.
private enum RouterStream {
    static func thinkingStart() -> String {
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#
    }

    static func thinking(_ text: String) -> String {
        let escaped = String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
        return #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"#
            + escaped + "}}}"
    }

    static func thinkingBlock(_ text: String) -> String {
        let escaped = String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
        return #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"#
            + escaped + #","signature":"sig"}]}}"#
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

/// A runner that plays a fixed stream back, counting how often it was launched.
private func replaying(_ lines: [String], launches: LaunchCount = LaunchCount()) -> ModelRouter.Run {
    { _ in
        launches.increment()
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

/// Everything a router said, last element included.
private func collect(_ router: ModelRouter, task: String = "Fix the typo in the README") async -> [ModelRouterProgress] {
    var seen: [ModelRouterProgress] = []
    for await step in router.progress(task: task, project: "Bloom", template: "{{task}}") {
        seen.append(step)
    }
    return seen
}

@Suite("Model router")
struct ModelRouterTests {
    // MARK: - Invocation

    @Test("the routing call carries no tools, no MCP servers and no project settings", .tags(.security))
    func argvIsMinimal() {
        let arguments = ModelRouter.argv()

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
        let arguments = ModelRouter.argv()
        let format = arguments.firstIndex(of: "--output-format").map { arguments[$0 + 1] }
        #expect(format == "stream-json")
        // The CLI refuses stream-json under `-p` without it.
        #expect(arguments.contains("--verbose"))
        #expect(arguments.contains("--include-partial-messages"))
        #expect(arguments.contains("--json-schema"))
    }

    @Test("a small, cheap model, translated for the CLI")
    func model() {
        #expect(ModelRouter.argv().contains(ModelAlias.cliValue(for: ModelRouter.model)))
    }

    @Test("the task is written to stdin, so one starting with a dash is never a flag", .tags(.security))
    func taskGoesToStdin() {
        let launch = ModelRouter.launch(prompt: "--dangerously-skip-permissions")
        #expect(launch.stdin == "--dangerously-skip-permissions")
        #expect(!launch.arguments.contains("--dangerously-skip-permissions"))
    }

    @Test("it runs somewhere with no repository in it")
    func runsOutsideTheWorktree() {
        let launch = ModelRouter.launch(prompt: "anything")
        #expect(launch.cwd == AgentScratchDirectory.current())
        #expect(launch.cwd != NSHomeDirectory())
    }

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

    // MARK: - The prompt

    @Test("the prompt carries the task and the project")
    func promptRenders() {
        let prompt = ModelRouter.prompt(task: "Add a dark mode toggle", project: "Bloom")
        #expect(prompt.contains("Add a dark mode toggle"))
        #expect(prompt.contains("Bloom"))
        #expect(!prompt.contains("{{"))
    }

    @Test("the built-in prompt names every rung the schema allows")
    func promptNamesEveryRung() {
        let template = PromptRegistry.definition(for: .routeTask).defaultTemplate
        for rung in TaskComplexity.allCases {
            #expect(template.contains("- \(rung.rawValue):"), "the prompt never describes \(rung.rawValue)")
        }
    }

    @Test("a pasted stack trace is capped rather than paid for")
    func promptCapsTheTask() {
        let huge = String(repeating: "stack frame\n", count: 5_000)
        let prompt = ModelRouter.prompt(task: huge, project: "Bloom")
        #expect(prompt.count < ModelRouter.taskLimit + 2_000)
    }

    // MARK: - The whole path, against a replayed stream

    @Test("thinking arrives as it is written, and the answer ends the stream", .tags(.agentProtocol))
    func happyPath() async throws {
        let router = ModelRouter(run: replaying([
            RouterStream.thinkingStart(),
            RouterStream.thinking("A typo "),
            RouterStream.thinking("in one file."),
            RouterStream.thinkingBlock("A typo in one file."),
            RouterStream.structuredTool(complexity: "trivial", reason: "One word in the README."),
            RouterStream.result(complexity: "trivial", reason: "One word in the README."),
        ]))

        let seen = await collect(router)
        let last = try #require(seen.last)

        #expect(seen.contains { $0.reasoning == "A typo " && $0.phase == .thinking })
        // Once, although the CLI sent it twice: in pieces, and then whole.
        #expect(last.reasoning == "A typo in one file.")
        #expect(last.answer == ModelRouterAnswer(complexity: .trivial, reason: "One word in the README."))
        // Exactly one finished element, and it is the last one.
        #expect(seen.filter(\.isFinished).count == 1)
    }

    @Test("a process that fails is not an error, it is no answer")
    func failedProcess() async throws {
        let router = ModelRouter(run: { _ in
            AsyncThrowingStream { $0.finish(throwing: ShellError(command: "claude", status: 1, stderr: "offline")) }
        })
        let last = try #require(await collect(router).last)
        #expect(last.phase == .failed)
    }

    @Test("an error result is no answer either")
    func errorResult() async throws {
        let router = ModelRouter(run: replaying([RouterStream.failedResult()]))
        let last = try #require(await collect(router).last)
        #expect(last.phase == .failed)
    }

    @Test("a stream that stops before its result has not answered")
    func truncated() async throws {
        let router = ModelRouter(run: replaying([RouterStream.thinking("Hmm")]))
        let last = try #require(await collect(router).last)
        #expect(last.phase == .failed)
        #expect(last.reasoning == "Hmm")
    }

    @Test("a task with nothing in it asks nothing rather than sending a blank turn")
    func emptyTask() async throws {
        let launches = LaunchCount()
        let router = ModelRouter(run: replaying([], launches: launches))
        let last = try #require(await collect(router, task: "   ").last)
        #expect(launches.value == 0)
        #expect(last.phase == .failed)
    }

    /// The bound below is the router's own deadline, made small so the test is not a minute long.
    /// What is asserted is the outcome, not how long it took: a stream that never ends must still
    /// end the route, failed, and before the suite's own limit kills the test from outside.
    @Test("a router that never answers is given up on", .timeLimit(.minutes(1)))
    func neverAnswers() async throws {
        let router = ModelRouter(
            run: { _ in AsyncThrowingStream { _ in } },
            timeout: .milliseconds(50)
        )
        let last = try #require(await collect(router).last)
        #expect(last.phase == .failed)
    }

    // MARK: - Reading the stream

    @Test("an answer only in the result text is still found", .tags(.agentProtocol))
    func answerInResultText() {
        var progress = ModelRouterProgress()
        progress.ingest(line: #"{"type":"result","is_error":false,"result":"{\"complexity\":\"complex\",\"reason\":\"Many files.\"}"}"#)
        #expect(progress.answer == ModelRouterAnswer(complexity: .complex, reason: "Many files."))
    }

    @Test("an answer only in the tool call is still found", .tags(.agentProtocol))
    func answerInToolCall() {
        var progress = ModelRouterProgress()
        progress.ingest(line: RouterStream.structuredTool(complexity: "deep", reason: "A race."))
        progress.ingest(line: RouterStream.emptyResult())
        #expect(progress.answer == ModelRouterAnswer(complexity: .deep, reason: "A race."))
    }

    @Test("a fenced answer in the result text is forgiven")
    func fencedAnswer() {
        let fenced = "```json\n{\"complexity\":\"simple\",\"reason\":\"\"}\n```"
        #expect(ModelRouterProgress.object(in: fenced)?["complexity"]?.stringValue == "simple")
    }

    @Test("thinking with no deltas is read off the whole block")
    func thinkingWithoutDeltas() {
        var progress = ModelRouterProgress()
        let changed = progress.ingest(line: RouterStream.thinkingBlock("Small change."))
        #expect(changed)
        #expect(progress.reasoning == "Small change.")
    }

    @Test("a second block of thinking starts a new paragraph")
    func secondThinkingBlock() {
        var progress = ModelRouterProgress()
        progress.ingest(line: RouterStream.thinking("First."))
        progress.ingest(line: RouterStream.thinkingStart())
        progress.ingest(line: RouterStream.thinking("Second."))
        #expect(progress.reasoning == "First.\n\nSecond.")
    }

    @Test("nothing after the answer can change it")
    func settledIsFinal() {
        var progress = ModelRouterProgress()
        progress.ingest(line: RouterStream.result(complexity: "simple", reason: ""))
        let changed = progress.ingest(line: RouterStream.thinking("late"))
        #expect(!changed)
        #expect(progress.reasoning.isEmpty)
        #expect(progress.answer?.complexity == .simple)
    }

    @Test(
        "lines that are not the protocol are ignored",
        arguments: ["", "not json", "{}", #"{"type":"system","subtype":"init"}"#]
    )
    func noise(line: String) {
        var progress = ModelRouterProgress()
        #expect(!progress.ingest(line: line))
        #expect(progress.phase == .thinking)
    }
}

@Suite("Model routing")
struct ModelRoutingTests {
    // MARK: - Reading the answer

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

    // MARK: - Turning it into a model

    @Test("every rung lands where the table says", arguments: TaskComplexity.allCases)
    func followsTheTable(rung: TaskComplexity) {
        let route = ModelRouting.route(
            ModelRouterAnswer(complexity: rung, reason: ""), current: "claude-fable-5-1"
        )
        let choice = ModelRouterTable.standard.choice(for: rung)
        #expect(route.model == choice.model)
        #expect(route.effort == choice.effort)
    }

    @Test("the table climbs: no rung runs a smaller model than the one below it")
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
        let route = ModelRouting.route(
            ModelRouterAnswer(complexity: .complex, reason: ""), current: "opus[1m]"
        )
        #expect(route.model == "opus[1m]")
        #expect(route.effort == "high")
    }

    @Test("a family the account does not offer keeps the model the chat already had")
    func unavailableFamily() {
        let models = [
            AgentModel(id: "sonnet", displayName: "Sonnet", supportedEfforts: efforts("low", "medium", "high")),
            AgentModel(id: "opus", displayName: "Opus", supportedEfforts: efforts("low", "medium", "high")),
        ]
        let route = ModelRouting.route(
            ModelRouterAnswer(complexity: .trivial, reason: ""), current: "sonnet", models: models
        )
        #expect(route.model == "sonnet")
    }

    @Test("an effort the model does not take lands on one it does")
    func clampsTheEffort() {
        let models = [
            AgentModel(
                id: "opus", displayName: "Opus",
                supportedEfforts: efforts("low", "medium", "high"), defaultEffort: "high"
            ),
        ]
        let route = ModelRouting.route(
            ModelRouterAnswer(complexity: .deep, reason: ""), current: "sonnet", models: models
        )
        #expect(route.model == "opus")
        #expect(route.effort == "high")
    }

    @Test("a model listed with no efforts is sent none")
    func modelWithoutEffort() {
        let models = [
            AgentModel(id: "haiku", displayName: "Haiku"),
            AgentModel(id: "opus", displayName: "Opus", supportedEfforts: efforts("high")),
        ]
        let route = ModelRouting.route(
            ModelRouterAnswer(complexity: .trivial, reason: ""), current: "opus", models: models
        )
        #expect(route.model == "haiku")
        #expect(route.effort.isEmpty)
    }

    @Test(
        "a family is read the way the CLI reads one",
        arguments: [
            ("opus", "opus"), ("opus[1m]", "opus"), ("claude-opus-5-5", "opus"),
            ("claude-sonnet-5[1m]", "sonnet"), ("Haiku", "haiku"), ("gpt-5.5", nil), ("", nil),
        ] as [(String, String?)]
    )
    func family(id: String, expected: String?) {
        #expect(ModelRouting.family(of: id) == expected)
    }

    // MARK: - Whether to ask

    @Test("a Bloom chat on Claude Code with something written is routed")
    func routes() {
        #expect(ModelRouting.shouldRoute(
            isEnabled: true, isAgentAvailable: true, mode: .chat, backend: .claudeCode,
            prompt: "Fix it", isResuming: false
        ))
    }

    @Test("everything else is not")
    func declines() {
        func asks(
            isEnabled: Bool = true, isAgentAvailable: Bool = true, mode: WorkspaceStartMode = .chat,
            backend: AgentKind = .claudeCode, prompt: String = "Fix it", isResuming: Bool = false
        ) -> Bool {
            ModelRouting.shouldRoute(
                isEnabled: isEnabled, isAgentAvailable: isAgentAvailable, mode: mode,
                backend: backend, prompt: prompt, isResuming: isResuming
            )
        }
        #expect(!asks(isEnabled: false))
        #expect(!asks(isAgentAvailable: false))
        #expect(!asks(mode: .claudeCLI))
        #expect(!asks(mode: .terminal))
        #expect(!asks(backend: .codex))
        #expect(!asks(prompt: " \n "))
        #expect(!asks(isResuming: true))
    }

    @Test("a model or an effort picked by hand takes over, and nothing else does")
    func takesOver() {
        let before = ComposerControls(model: "opus", effort: "high")

        var model = before
        model.model = "sonnet"
        #expect(ModelRouting.takesOver(from: before, to: model))

        var effort = before
        effort.effort = "low"
        #expect(ModelRouting.takesOver(from: before, to: effort))

        var mode = before
        mode.permissionMode = .plan
        mode.isFastMode = true
        #expect(!ModelRouting.takesOver(from: before, to: mode))
    }

    @Test("off unless somebody turns it on")
    func preferenceDefaultsOff() throws {
        let suite = "bloom.router.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = ModelRouterPreferences(defaults: defaults)
        #expect(!preferences.isEnabled)
        preferences.isEnabled = true
        #expect(ModelRouterPreferences(defaults: defaults).isEnabled)
    }

    private func efforts(_ ids: String...) -> [AgentModelEffort] {
        ids.map { AgentModelEffort(id: $0, label: $0) }
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

        let haiku = ModelRoute(complexity: .trivial, model: "haiku", effort: "", reason: "")
        #expect(ModelRouteCaption.title(route: haiku, isSettled: true) == "Haiku")
    }

    @Test("every state says something, and none of it is a dash")
    func sentences() {
        let route = ModelRoute(complexity: .simple, model: "sonnet", effort: "medium", reason: "One file.")
        let sentences = [
            ModelRouteCaption.title(route: nil, isSettled: false),
            ModelRouteCaption.title(route: nil, isSettled: true),
            ModelRouteCaption.detail(route: nil, isSettled: false, wasSkipped: false),
            ModelRouteCaption.detail(route: nil, isSettled: true, wasSkipped: true),
            ModelRouteCaption.detail(route: nil, isSettled: true, wasSkipped: false),
            ModelRouteCaption.detail(route: route, isSettled: true, wasSkipped: false),
            ModelRouteCaption.tableSummary(),
            ModelRouting.holdSentence,
        ]
        for sentence in sentences {
            #expect(!sentence.isEmpty)
            #expect(!sentence.contains("\u{2014}") && !sentence.contains("\u{2013}"))
        }
        #expect(ModelRouteCaption.detail(route: route, isSettled: true, wasSkipped: false) == "Simple task. One file.")
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
