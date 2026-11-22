import Foundation

/// OpenCode's terminal interface as a Bloom CLI chat: how it is launched, what its screen says
/// while it works, and how its state reaches Bloom. Every fact here is measured in
/// `docs/OPENCODE.md`, "The terminal interface".
///
/// The interface has no `--model` and no hook flag, so nearly everything Claude Code and Codex
/// take as arguments goes in `OPENCODE_CONFIG_CONTENT` instead: the permission block a chat over
/// ACP is launched with, the model, the bridge as an MCP server, and a plugin that writes the
/// state file the other two write from their hooks.
public enum OpenCodeTerminal {
    /// The session the status plugin reports, so a subagent's session is never taken for the
    /// chat's own and copied into `agentSessionID`.
    public static let sessionVariable = "BLOOM_OPENCODE_SESSION"

    /// The OpenCode session a Bloom chat launches on, chosen by Bloom as Claude Code's
    /// `--session-id` is, so the first launch and every resume name the same session. OpenCode
    /// refuses an id that does not start with `ses`, and creates one that does under exactly
    /// that id. Bloom's own ids are lowercased UUIDs, so this is `ses_` and their hex digits.
    public static func sessionID(for session: SessionID) -> String {
        let digits = session.rawValue.unicodeScalars.filter {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }
        return "ses_" + String(String.UnicodeScalarView(digits))
    }

    /// `--standalone` so the interface runs a private server, which reads this launch's
    /// environment: the shared background service has its own, and may be started or installed
    /// by a launch without it. The prompt is joined to `--prompt` by `=`: as a separate argument, a
    /// task starting with `-` is read as options, and the interface prints its help and exits. It
    /// goes last, because `isInterface` stops reading options there, and it is sent at launch,
    /// into an existing session too, so a resume carries none.
    public static func arguments(session: String, prompt: String) -> [String] {
        var arguments = ["--standalone", "--session", session]
        if !prompt.isEmpty { arguments.append(promptOption + prompt) }
        return arguments
    }

    private static let promptOption = "--prompt="

    /// Assignments for `/usr/bin/env`, ahead of the executable.
    public static func environment(session: String, configuration: String) -> [String] {
        [
            "OPENCODE_DISABLE_AUTOUPDATE=1",
            "OPENCODE_CONFIG_CONTENT=\(configuration)",
            "\(sessionVariable)=\(session)",
        ]
    }

    /// The configuration merged last over the user's and the project's own, with sorted keys
    /// because OpenCode reads a permission object's rules in key order (`OpenCodePermission`).
    /// Bypass adds no permission block and still carries the rest.
    public static func configuration(
        permissionMode: PermissionMode?, model: String, bridge: BridgeAttachment?, statusPlugin: URL?
    ) -> String {
        var config = permissionMode.flatMap(OpenCodePermission.config(for:)) ?? [:]
        if !model.isEmpty { config["model"] = .string(model) }
        if let statusPlugin { config["plugin"] = .array([.string(statusPlugin.path)]) }
        if let bridge {
            config["mcp"] = .object([BridgeRegistration.serverName: .object([
                "type": .string("local"),
                "command": .array([.string(bridge.shimPath)]),
                "environment": .object(bridge.environment.mapValues(JSONValue.string)),
            ])])
        }
        return OpenCodePermission.orderedJSON(.object(config))
    }

    // MARK: - The state file

    /// Where the status plugin lives, beside the launch scripts. One directory for every chat,
    /// because its text never changes between them.
    public static func statusPluginDirectory(base: URL) -> URL {
        base.appendingPathComponent("opencode-status-plugin", isDirectory: true)
    }

    /// Writes the plugin when its text differs from what is there. Called on every activity pass,
    /// and OpenCode's server watches a configured plugin's directory (its log says so) to reload
    /// it on a change, so an unconditional write could reload it in every running chat every few
    /// seconds.
    @discardableResult
    public static func installStatusPlugin(base: URL) throws -> URL {
        let directory = statusPluginDirectory(base: base)
        let file = directory.appendingPathComponent("server.js")
        let data = Data(statusPluginSource.utf8)
        guard (try? Data(contentsOf: file)) != data else { return directory }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: file, options: .atomic)
        return directory
    }

    /// OpenCode 2's plugin shape: a directory whose `server.js` exports by default `{id, setup}`,
    /// and `setup` receives `event.subscribe`, an async iterable. The events are written as the
    /// hook names `AgentKind.interactiveHookState` already reads. A Reject on the card and Esc
    /// during a tool both end the turn with an event mapped to `Stop`.
    static let statusPluginSource = #"""
    // Bloom's status plugin for the OpenCode terminal interface.
    //
    // Writes the turn's state to $BLOOM_CLI_STATUS_FILE in the shape Claude Code's and Codex's
    // hooks write it, so Bloom reads all three the same way. Only the session Bloom launched is
    // reported ($BLOOM_OPENCODE_SESSION), so a subagent's session is never taken for the chat's.
    import { mkdirSync, renameSync, writeFileSync } from "node:fs"
    import { dirname } from "node:path"

    const HOOKS = {
      "session.execution.started": "UserPromptSubmit",
      "permission.asked": "PermissionRequest",
      "permission.replied": "PreToolUse",
      "session.execution.succeeded": "Stop",
      "session.execution.interrupted": "Stop",
      "session.execution.failed": "StopFailure",
    }

    function report(hook, sessionID) {
      const file = process.env.BLOOM_CLI_STATUS_FILE
      if (!file) return
      const temporary = `${file}.${process.pid}.tmp`
      try {
        mkdirSync(dirname(file), { recursive: true, mode: 0o700 })
        writeFileSync(temporary, JSON.stringify({ hook_event_name: hook, session_id: sessionID }), { mode: 0o600 })
        renameSync(temporary, file)
      } catch {
        // Bloom falls back to reading the screen.
      }
    }

    async function follow(stream, session) {
      for await (const event of stream) {
        const sessionID = event?.data?.sessionID
        if (session && sessionID !== session) continue
        const hook = HOOKS[event?.type]
        if (hook) report(hook, sessionID)
      }
    }

    export default {
      id: "bloom.status",
      setup: async (context) => {
        const stream = context.event.subscribe({ types: Object.keys(HOOKS) })
        follow(stream, process.env.BLOOM_OPENCODE_SESSION).catch(() => {
          // A stream that fails leaves Bloom reading the screen, as it does with no plugin.
        })
      },
    }

    """#

    // MARK: - Reading the terminal

    /// The left of the status line under the input during a turn: an eight cell bar of `⬝` and
    /// `■`, then `esc interrupt`, with hints and the directory after it, so nothing is anchored at
    /// the end. The bar is gone while a permission card waits, which the state file covers.
    public static func screenIsBusy(lines: [String]) -> Bool {
        lines.suffix(3).contains {
            $0.range(of: #"^\s*[⬝■]{8} esc interrupt(\s|$)"#, options: .regularExpression) != nil
        }
    }

    /// Whether an `opencode` command line, as `ps` prints it, is the interface rather than one of
    /// its subcommands. `ps` drops argument boundaries, so reading stops at `--prompt`, which a
    /// Bloom launch puts last: a word of the prompt is never taken for a subcommand.
    static func isInterface(arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--prompt" || argument.hasPrefix(promptOption) { return true }
            if refusingOptions.contains(argument) { return false }
            if valueOptions.contains(argument) {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                // The first positional is the directory, or a subcommand.
                return !subcommands.contains(argument)
            }
        }
        return true
    }

    private static let valueOptions: Set<String> = ["--session", "-s", "--server", "--log-level", "--completions"]
    private static let refusingOptions: Set<String> = ["--help", "-h", "--version", "-v", "--wizard"]
    /// `opencode --help` on 2.3.2. `mini` is an interface too, with a screen of its own that nothing
    /// here reads.
    private static let subcommands: Set<String> = [
        "upgrade", "update", "uninstall", "acp", "api", "debug", "auth", "mcp", "plugin", "models",
        "stats", "mini", "run", "session", "service", "reload", "pair", "serve", "help",
    ]
}
