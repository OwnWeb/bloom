import Foundation
import Testing
@testable import BloomCore

/// OpenCode's terminal interface as a CLI chat. Every expected value here was read off OpenCode
/// 2.3.2 in isolation: see "The terminal interface" in `docs/OPENCODE.md`.
@Suite struct OpenCodeTerminalTests {
    private static let bloomSession = SessionID("3f2a9c1e-7b4d-4e8f-9a01-23456789abcd")

    @Test func aChatLaunchesOnASessionIdOpenCodeAccepts() {
        let id = OpenCodeTerminal.sessionID(for: Self.bloomSession)
        #expect(id == "ses_3f2a9c1e7b4d4e8f9a0123456789abcd")
        #expect(OpenCodeTerminal.sessionID(for: Self.bloomSession) == id)
    }

    /// Joined by `=`: a task starting with `-` given as its own argument made OpenCode print its
    /// help and exit, and this one kept its newline, its `=` and its `--help` intact.
    @Test func theFirstLaunchNamesTheSessionAndSendsThePromptLast() throws {
        let prompt = "- fix the bug\n- then run a=b --help and acp"
        let arguments = try #require(AgentKind.openCode.interactiveArguments(
            prompt: prompt, sessionID: Self.bloomSession, model: "ollama/qwen3.5:4b", effort: "high"
        ))
        #expect(arguments == [
            "--standalone", "--session", "ses_3f2a9c1e7b4d4e8f9a0123456789abcd", "--prompt=" + prompt,
        ])
    }

    /// `--prompt` on an existing session sends it again, so a resume carries none.
    @Test func aResumeNamesTheSessionItWasGivenAndSendsNothing() throws {
        let arguments = try #require(AgentKind.openCode.interactiveArguments(
            prompt: "", sessionID: Self.bloomSession, model: "", effort: "", resuming: "ses_native"
        ))
        #expect(arguments == ["--standalone", "--session", "ses_native"])
    }

    @Test func theConfigurationCarriesRulesModelPluginAndBridge() throws {
        let bridge = BridgeAttachment(
            shimPath: "/Applications/Bloom.app/Contents/MacOS/bloom-bridge",
            socketPath: "/tmp/bloom.sock", token: "secret", role: .workspace
        )
        let plugin = URL(fileURLWithPath: "/Users/me/Library/Application Support/Bloom/opencode-status-plugin")
        let text = OpenCodeTerminal.configuration(
            permissionMode: .acceptEdits, model: "ollama/qwen3.5:4b", bridge: bridge, statusPlugin: plugin
        )
        let config = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(config["permission"] as? [String: String] == ["shell": "ask"])
        #expect(config["model"] as? String == "ollama/qwen3.5:4b")
        #expect(config["plugin"] as? [String] == [plugin.path])
        let servers = try #require(config["mcp"] as? [String: [String: Any]])
        let server = try #require(servers[BridgeRegistration.serverName])
        #expect(server["type"] as? String == "local")
        #expect(server["command"] as? [String] == [bridge.shimPath])
        #expect(server["environment"] as? [String: String] == bridge.environment)
    }

    @Test func bypassAddsNoRulesAndKeepsTheRest() throws {
        let text = OpenCodeTerminal.configuration(
            permissionMode: .bypassPermissions, model: "", bridge: nil,
            statusPlugin: URL(fileURLWithPath: "/tmp/plugin")
        )
        let config = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(config["permission"] == nil)
        #expect(config["model"] == nil)
        #expect(config["plugin"] as? [String] == ["/tmp/plugin"])
    }

    /// Run through a shell as the terminal runs it, with a stand-in `opencode` that prints what
    /// it was handed, so quoting a JSON document and a prompt is checked rather than assumed.
    @Test func theLaunchHandsOpenCodeItsConfigurationThroughTheEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-terminal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("opencode")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$OPENCODE_CONFIG_CONTENT\" \"$BLOOM_OPENCODE_SESSION\" "
            + "\"$OPENCODE_DISABLE_AUTOUPDATE\"\nfor argument do printf '%s\\n' \"$argument\"; done\n"
        try Data(script.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let prompt = "- $(touch unwanted); 'quoted' `touch unwanted`"
        let command = try #require(AgentKind.openCode.interactiveCommand(
            directory: root.path, prompt: prompt, sessionID: Self.bloomSession,
            model: "ollama/qwen3.5:4b", effort: "", permissionMode: .auto
        ))
        let result = try await Shell.run("/bin/sh", ["-c", command], env: ["PATH": root.path + ":/usr/bin:/bin"])
        #expect(result.ok)
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let config = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(config["model"] as? String == "ollama/qwen3.5:4b")
        #expect(config["permission"] as? [String: String] == ["edit": "ask", "shell": "ask"])
        #expect(lines[1] == "ses_3f2a9c1e7b4d4e8f9a0123456789abcd")
        #expect(lines[2] == "1")
        #expect(Array(lines[3...5]) == ["--standalone", "--session", "ses_3f2a9c1e7b4d4e8f9a0123456789abcd"])
        #expect(lines[6] == "--prompt=" + prompt)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unwanted").path))
    }

    @Test func aResumeCommandCanBeOfferedBack() throws {
        let command = try #require(AgentKind.openCode.interactiveCommand(
            directory: "/tmp/worktree", prompt: "", sessionID: .new(),
            model: "", effort: "", resuming: "ses_native"
        ))
        #expect(TerminalCommandMemory.offerable(command, maximumLength: 262_144) == command)
    }

    @Test func theBusyBarIsReadAndTheIdleLineAndACardAreNot() {
        let busy = "   ⬝⬝⬝■■■■■ esc interrupt                 shift+tab agents  ctrl+p commands    /…/cwd"
        let idle = "  /private/var/folders/n8/T/oc-measure/cwd        5.8K (2%)  ctrl+p commands    /…/cwd"
        let card = [
            "  ┃  △ Permission required",
            "  ┃  $ echo card-test",
            "  ┃   Allow once   Always allow   Reject      ctrl+f fullscreen  ⇆ select  enter confirm",
            idle,
        ]
        #expect(AgentKind.openCode.interactiveScreenIsBusy(lines: ["  ┃  Build · qwen3.5:4b Ollama", busy, "", ""]))
        #expect(!AgentKind.openCode.interactiveScreenIsBusy(lines: ["  ┃  Build · qwen3.5:4b Ollama", idle]))
        #expect(!AgentKind.openCode.interactiveScreenIsBusy(lines: card))
        #expect(!AgentKind.openCode.interactiveScreenIsBusy(lines: [busy] + Array(repeating: "output", count: 4)))
        #expect(!AgentKind.openCode.interactiveScreenIsBusy(lines: ["  ┃  explain ⬝⬝⬝⬝⬝⬝⬝⬝ esc interrupt"]))
    }

    @Test(arguments: [
        ("/opt/homebrew/Cellar/opencode-v2/2.3.2/bin/opencode --standalone --session ses_abc --prompt run the tests", true),
        ("opencode --standalone --session ses_abc --prompt=please run acp", true),
        ("opencode --standalone --session ses_abc --prompt=- fix the bug", true),
        ("opencode --standalone --session ses_abc", true),
        ("opencode", true),
        ("opencode /Users/me/project", true),
        ("opencode acp", false),
        ("/opt/homebrew/Cellar/opencode-v2/2.3.2/bin/opencode serve --stdio --port 0", false),
        ("opencode run hello", false),
        ("opencode --version", false),
        ("opencode mini --session ses_abc", false),
    ])
    func theInterfaceIsToldFromItsSubcommands(command: String, isInterface: Bool) {
        #expect((ProcessTable.interactiveAgent(command: command) == .openCode) == isInterface)
    }

    @Test(arguments: [
        ("UserPromptSubmit", SessionState.running), ("PermissionRequest", .waiting), ("PreToolUse", .running),
        ("Stop", .idle), ("StopFailure", .failed),
    ])
    func thePluginsRecordsReadAsHookStates(hook: String, expected: SessionState) {
        #expect(OpenCodeTerminal.statusPluginSource.contains("\"\(hook)\""))
        let record = Data("{\"hook_event_name\":\"\(hook)\",\"session_id\":\"ses_abc\"}".utf8)
        #expect(AgentKind.interactiveHookState(data: record) == expected)
        #expect(AgentKind.interactiveHookSessionID(data: record) == "ses_abc")
    }

    /// OpenCode reloads a plugin whose directory changes, and this runs on every activity pass.
    @Test func thePluginIsWrittenOnlyWhenItsTextDiffers() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-plugin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = try OpenCodeTerminal.installStatusPlugin(base: base)
        let file = directory.appendingPathComponent("server.js")
        #expect(try String(contentsOf: file, encoding: .utf8) == OpenCodeTerminal.statusPluginSource)
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)

        try OpenCodeTerminal.installStatusPlugin(base: base)
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(modified == past)
    }
}
