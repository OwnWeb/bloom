import Testing
import Foundation
@testable import BloomCore

@Suite("OpenCode client")
struct OpenCodeClientTests {
    @Test("launch is `opencode acp` with updates off and no injected config until a mode asks for one")
    func launchShape() {
        let launch = OpenCodeClient.launch(OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]))
        #expect(launch.executable == "opencode")
        #expect(launch.arguments == ["acp"])
        #expect(launch.cwd == "/tmp/w")
        #expect(launch.environment["OPENCODE_DISABLE_AUTOUPDATE"] == "1")
        #expect(launch.environment["OPENCODE_CONFIG_CONTENT"] == nil)
    }

    @Test("a permission mode becomes the rules OpenCode is launched with", arguments: [
        (PermissionMode.auto, ["edit", "shell"]),
        (.acceptEdits, ["shell"]),
        (.plan, ["edit", "shell"]),
    ])
    func permissionModeIsInjected(mode: PermissionMode, asking: [String]) throws {
        let launch = OpenCodeClient.launch(OpenCodeClient.Configuration(
            cwd: "/tmp/w", environment: [:], permissionMode: mode
        ))
        let content = try #require(launch.environment["OPENCODE_CONFIG_CONTENT"])
        let rules = try #require(JSONValue.parse(Data(content.utf8))?["permission"]?.objectValue)
        #expect(rules.keys.sorted() == asking)
        #expect(rules.values.allSatisfy { $0.stringValue == "ask" })
        // A wildcard would outrank whatever the user had denied in their own config.
        #expect(rules["*"] == nil)
    }

    @Test("bypass adds no rule, so the user's own OpenCode config decides")
    func bypassInjectsNothing() {
        let launch = OpenCodeClient.launch(OpenCodeClient.Configuration(
            cwd: "/tmp/w", environment: [:], permissionMode: .bypassPermissions
        ))
        #expect(launch.environment["OPENCODE_CONFIG_CONTENT"] == nil)
    }

    @Test("config options are read by id, and a model with no effort levels has no effort option")
    func configOptionsDecode() {
        let withEffort = OpenCodeConfigOptions.decode(
            OpenCodeFixture.configOptions(model: OpenCodeFixture.hostedModel, efforts: ["none", "high", "default"])
        )
        #expect(withEffort.currentModel == OpenCodeFixture.hostedModel)
        #expect(withEffort.models.map(\.value) == [OpenCodeFixture.localModel, OpenCodeFixture.hostedModel])
        #expect(withEffort.models.last?.name == "opencode/Hy4 flash Free")
        #expect(withEffort.efforts.map(\.value) == ["none", "high", "default"])
        #expect(withEffort.currentEffort == "default")
        #expect(withEffort.offersEffort("high"))

        let without = OpenCodeConfigOptions.decode(OpenCodeFixture.configOptions(model: OpenCodeFixture.localModel))
        #expect(without.efforts.isEmpty)
        #expect(!without.offersEffort("high"))
    }

    @Test("the mode option is read by id, with the session's stored mode")
    func modeOptionDecodes() {
        let options = OpenCodeConfigOptions.decode(
            OpenCodeFixture.configOptions(model: OpenCodeFixture.localModel, mode: "plan")
        )
        #expect(options.modes.map(\.value) == ["build", "plan"])
        #expect(options.currentMode == "plan")
        #expect(options.offersMode("plan"))
        #expect(!options.offersMode("review"))
    }

    @Test("the injected block puts back the built-in agents' denials it would otherwise reopen")
    func injectedBlockRestoresDenials() throws {
        let ask = try #require(OpenCodePermission.configContent(for: .auto))
        let parsed = JSONValue.parse(Data(ask.utf8))
        #expect(parsed?["permission"]?["edit"]?.stringValue == "ask")
        #expect(parsed?["agent"]?["explore"]?["permission"]?["edit"]?.stringValue == "deny")
        #expect(parsed?["agent"]?["title"]?["permission"]?["shell"]?.stringValue == "deny")
        // The plan agent's rules are read in key order, last match winning, so the order is the
        // string's and not the parsed dictionary's.
        let wildcard = try #require(ask.range(of: "\"*\":\"deny\""))
        let planDirectory = try #require(ask.range(of: "\"{env:HOME}/.opencode/plan/*\":\"allow\""))
        #expect(wildcard.lowerBound < planDirectory.lowerBound)

        let acceptEdits = try #require(OpenCodePermission.configContent(for: .acceptEdits))
        let agents = JSONValue.parse(Data(acceptEdits.utf8))?["agent"]?.objectValue
        #expect(agents?.keys.sorted() == ["summary", "title"])
        #expect(agents?["summary"]?["permission"]?["edit"] == nil)
        #expect(OpenCodePermission.configContent(for: .bypassPermissions) == nil)
    }

    @Test("plan is offered on OpenCode, and Codex's unavailable flag only greys out Codex")
    func planAvailabilityIsPerAgent() {
        #expect(InteractionMode.plan.nearest(on: .openCode) == .plan)
        #expect(CodexPlanningCapability.planIsAvailable(on: .openCode, codexReportedUnavailable: true))
        #expect(!CodexPlanningCapability.planIsAvailable(on: .codex, codexReportedUnavailable: true))
        #expect(CodexPlanningCapability.planIsAvailable(on: .codex, codexReportedUnavailable: false))
        #expect(!CodexPlanningCapability.planIsAvailable(on: .grok, codexReportedUnavailable: false))
    }

    @Test("handshake needs no `initialized`, and session/new returns the id with its options")
    func handshakeAndNewSession() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([
            "agentInfo": .object(["name": .string("OpenCode"), "version": .string("2.3.2")]),
        ]))
        var created = OpenCodeFixture.configOptions(model: OpenCodeFixture.hostedModel).objectValue ?? [:]
        created["sessionId"] = .string("ses_1")
        box.reply(to: "session/new", with: .object(created))
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        #expect(await client.agentVersion == "2.3.2")
        let session = try await client.newSession(cwd: "/tmp/w")
        #expect(session.id == "ses_1")
        #expect(session.options.currentModel == OpenCodeFixture.hostedModel)
        #expect(box.process.sentMethods == ["initialize", "session/new"])
        await client.stop()
    }

    @Test("a config option travels as a bare string, which is the only form OpenCode accepts")
    func configOptionValueIsABareString() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([:]))
        box.reply(to: "session/set_config_option", with: OpenCodeFixture.configOptions(
            model: OpenCodeFixture.localModel
        ))
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        let options = try await client.setConfigOption(
            sessionID: "ses_1", configID: "model", value: OpenCodeFixture.localModel
        )
        #expect(options.currentModel == OpenCodeFixture.localModel)
        let sent = box.process.stdin.compactMap(JSONValue.parse)
            .first { $0["method"]?.stringValue == "session/set_config_option" }
        #expect(sent?["params"]?["value"]?.stringValue == OpenCodeFixture.localModel)
        #expect(sent?["params"]?["configId"]?.stringValue == "model")
        await client.stop()
    }

    @Test("session/resume replies with no session id, so the id asked for is the id resumed")
    func resumeKeepsTheAskedID() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([:]))
        box.reply(to: "session/resume", with: OpenCodeFixture.configOptions(model: OpenCodeFixture.localModel))
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        let session = try await client.resumeSession("ses_stored", cwd: "/tmp/w")
        #expect(session.id == "ses_stored")
        #expect(session.options.currentModel == OpenCodeFixture.localModel)
        await client.stop()
    }

    @Test("a model detected after the session opened is waited for, and found in the announcement")
    func waitsForAnnouncedModel() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([:]))
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        // A cap on infinity: the announcement below is what ends the wait.
        let waiting = Task { await client.waitUntilOffered(OpenCodeFixture.localModel, within: .seconds(30)) }
        // Measured: a first announcement can lack the local provider that a second one carries.
        box.process.emit(OpenCodeFixture.announcementLine(model: OpenCodeFixture.hostedModel))
        box.process.emit(OpenCodeFixture.announcementLine(model: OpenCodeFixture.localModel))
        #expect(await waiting.value)
        let announced = await client.latestAnnouncedOptions(after: .zero)
        #expect(announced?.models.contains { $0.value == OpenCodeFixture.localModel } == true)
        await client.stop()
    }

    @Test("a model never announced is reported as not offered once the cap passes")
    func unannouncedModelIsNotOffered() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([:]))
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        #expect(await client.waitUntilOffered("nope/none", within: .milliseconds(10)) == false)
        await client.stop()
    }

    /// A prompt sent while a cancelled one is still open is refused by OpenCode 2.3.2.
    @Test("waiting for no prompt returns once the open prompt has replied")
    func waitsForTheOpenPromptToEnd() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([:]))
        box.ignore("session/prompt")
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        await client.waitUntilNoPrompt(within: .seconds(30))
        let id = try await client.beginPrompt(sessionID: "ses_1", text: "one")
        #expect(await client.hasPromptInFlight)
        // A cap on infinity: the reply below is what ends the wait.
        let waiting = Task { await client.waitUntilNoPrompt(within: .seconds(30)) }
        box.process.emit("{\"jsonrpc\":\"2.0\",\"id\":\(id.jsonLiteral),\"result\":{\"stopReason\":\"cancelled\"}}")
        await waiting.value
        #expect(await client.hasPromptInFlight == false)
        await client.stop()
    }

    @Test("a refused resume throws, so the runner can open a new session instead")
    func refusedResumeThrows() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([:]))
        box.fail("session/resume", code: -32602, message: "Invalid params: session not found: ses_gone")
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        await #expect(throws: ACPRPCError.self) {
            _ = try await client.resumeSession("ses_gone", cwd: "/tmp/w")
        }
        await client.stop()
    }
}

@Suite("OpenCode model catalogue")
struct OpenCodeModelCatalogTests {
    @Test("discovery walks every model for its effort levels and deletes the session it used")
    func discoveryReadsEffortsAndCleansUp() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([:]))
        var created = OpenCodeFixture.configOptions(model: OpenCodeFixture.hostedModel).objectValue ?? [:]
        created["sessionId"] = .string("ses_scratch")
        box.reply(to: "session/new", with: .object(created))
        box.reply(to: "session/set_config_option", with: OpenCodeFixture.configOptions(
            model: OpenCodeFixture.hostedModel, efforts: ["none", "high", "default"]
        ))
        box.reply(to: "session/delete", with: .object([:]))
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        // No announcement here, so the reply's own list is used once the wait gives up.
        let models = try await OpenCodeModelCatalog.discover(
            on: client, cwd: "/tmp/w", announcementWait: .milliseconds(10)
        )
        await client.stop()

        #expect(models.map(\.id) == [OpenCodeFixture.localModel, OpenCodeFixture.hostedModel])
        // The default is the model the new session opened on, before anything was selected.
        #expect(models.filter(\.isDefault).map(\.id) == [OpenCodeFixture.hostedModel])
        #expect(models.last?.agentModel.supportedEfforts.map(\.id) == ["none", "high", "default"])
        #expect(models.last?.agentModel.defaultEffort == "default")
        let selections = box.process.sentMethods.filter { $0 == "session/set_config_option" }
        #expect(selections.count == 2)
        #expect(box.process.sentMethods.last == "session/delete")
        #expect(!box.process.sentMethods.contains("session/prompt"))
    }

    @Test("a provider the session reply missed is taken from the announcement after it")
    func discoveryUsesTheAnnouncement() async throws {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([:]))
        var created = OpenCodeFixture.optionsWithoutOllama().objectValue ?? [:]
        created["sessionId"] = .string("ses_scratch")
        box.reply(to: "session/new", with: .object(created))
        box.reply(to: "session/delete", with: .object([:]))
        let client = OpenCodeClient(
            configuration: OpenCodeClient.Configuration(cwd: "/tmp/w", environment: [:]),
            makeProcess: box.factory
        )
        try await client.start()
        box.process.emit(OpenCodeFixture.announcementLine(model: OpenCodeFixture.hostedModel))
        // No window: the announcement is read off the wire before the `session/new` reply behind it.
        let models = try await OpenCodeModelCatalog.discover(
            on: client, cwd: "/tmp/w", announcementWait: .zero
        )
        await client.stop()
        #expect(models.map(\.id).contains(OpenCodeFixture.localModel))
    }

    @Test("a slash names a provider, and a Bedrock ARN is not one")
    func recognition() {
        #expect(OpenCodeModelRank.recognises("ollama/qwen3.5:4b"))
        #expect(OpenCodeModelRank.recognises("anthropic/claude-sonnet-5-5"))
        #expect(!OpenCodeModelRank.recognises("arn:aws:bedrock:eu-west-1:1:inference-profile/eu.anthropic.claude"))
        #expect(!OpenCodeModelRank.recognises("opus"))
        #expect(!OpenCodeModelRank.recognises("gpt-5.6-sol"))
        #expect(!OpenCodeModelRank.recognises("grok-4.6"))
        #expect(!OpenCodeModelRank.recognises("/model"))
        #expect(!OpenCodeModelRank.recognises("provider/"))
    }
}
