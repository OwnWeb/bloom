import BloomProtocol
import Foundation
import Testing

/// The checked-in examples in `Protocol/v1/vectors.json` are what these types encode to, and they
/// decode back to the same values.
///
/// The file is what a client in another language is tested against, so a change to a Swift type
/// that moves the JSON has to move the file in the same commit, and this test is what says so.
/// Regenerate with `BLOOM_WRITE_VECTORS=1 swift test` inside this package, then read the diff.
struct WireVectorTests {
    static let vectorsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Protocol/v1/vectors.json")

    @Test func theCheckedInVectorsAreWhatTheTypesEncodeTo() throws {
        let encoded = try Self.encodedVectors()
        if ProcessInfo.processInfo.environment["BLOOM_WRITE_VECTORS"] == "1" {
            try FileManager.default.createDirectory(at: Self.vectorsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded.write(to: Self.vectorsURL)
            return
        }
        let stored = try Data(contentsOf: Self.vectorsURL)
        #expect(String(decoding: stored, as: UTF8.self) == String(decoding: encoded, as: UTF8.self))
    }

    @Test func everyVectorDecodesBackToItsValue() throws {
        let decoder = WireJSON.decoder()
        let encoder = WireJSON.encoder()
        for (name, operation) in WireExamples.operations {
            let request = CommandRequest(operation, commandID: WireExamples.commandID)
            let back = try decoder.decode(CommandRequest.self, from: encoder.encode(request))
            #expect(back == request, "operation \(name)")
        }
        for (name, result) in WireExamples.results {
            let reply = CommandReply(commandID: WireExamples.commandID, result: result)
            let back = try decoder.decode(CommandReply.self, from: encoder.encode(reply))
            #expect(back == reply, "result \(name)")
        }
        for (name, event) in WireExamples.events {
            #expect(try decoder.decode(WorkspaceEvent.self, from: encoder.encode(event)) == event, "event \(name)")
        }
        for (name, frame) in WireExamples.terminalFrames {
            #expect(try decoder.decode(TerminalControlFrame.self, from: encoder.encode(frame)) == frame, "frame \(name)")
        }
    }

    @Test func anOperationIsOneFlatObjectWithItsKind() throws {
        let data = try WireJSON.encode(CommandRequest(.send(chatID: "chat", text: "Run the tests"), commandID: "c1"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"{"command_id":"c1","operation":{"chat_id":"chat","kind":"send","text":"Run the tests"},"protocol":"bloom-workspace","version":1}"#)
    }

    @Test func datesAreISO8601InUTC() throws {
        let data = try WireJSON.encode(SetupRecord(state: "running", startedAt: WireExamples.date))
        #expect(String(decoding: data, as: UTF8.self).contains(#""started_at":"2026-09-17T09:40:02.500Z""#))
        #expect(WireDate.date(from: "2026-09-17T09:40:02Z") == Date(timeIntervalSince1970: 1_789_638_002))
    }

    @Test func anUnknownKindIsRefusedRatherThanGuessed() {
        let data = Data(#"{"command_id":"c1","operation":{"kind":"catalogue"},"protocol":"bloom-workspace","version":1}"#.utf8)
        #expect(throws: DecodingError.self) { try WireJSON.decode(CommandRequest.self, from: data) }
    }

    static func encodedVectors() throws -> Data {
        var vectors: [String: WireValue] = [:]
        let encoder = WireJSON.encoder()
        func value(_ encodable: some Encodable) throws -> WireValue {
            try JSONDecoder().decode(WireValue.self, from: encoder.encode(encodable))
        }
        vectors["requests"] = .object(try WireExamples.operations.reduce(into: [:]) { result, pair in
            result[pair.0] = try value(CommandRequest(pair.1, commandID: WireExamples.commandID))
        })
        vectors["replies"] = .object(try WireExamples.results.reduce(into: [:]) { result, pair in
            result[pair.0] = try value(CommandReply(commandID: WireExamples.commandID, result: pair.1))
        })
        vectors["errors"] = .object(try WireExamples.errors.reduce(into: [:]) { result, pair in
            result[pair.0] = try value(CommandReply(commandID: WireExamples.commandID, error: pair.1))
        })
        vectors["events"] = .object(try WireExamples.events.reduce(into: [:]) { result, pair in
            result[pair.0] = try value(pair.1)
        })
        vectors["terminal_frames"] = .object(try WireExamples.terminalFrames.reduce(into: [:]) { result, pair in
            result[pair.0] = try value(pair.1)
        })
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try pretty.encode(vectors) + Data("\n".utf8)
    }
}

enum WireExamples {
    static let commandID = "00000000-0000-4000-8000-000000000001"
    static let date = Date(timeIntervalSince1970: 1_789_638_002.5)
    static let author = AuthorRecord(userID: "01k5bx7j9d3v2r8q6m4n0p1s2t", name: "Freek", email: "freek@spatie.be")
    /// Somebody runbloom.app has no display name for, which is the shape a client has to draw from
    /// the email. It used to arrive with an empty name and nothing else, and an unlabelled message
    /// in a shared workspace reads as the reader's own.
    static let nameless = AuthorRecord(userID: "01k5bx7j9d3v2r8q6m4n0p1s2u", name: "", email: "technical@spatie.be")
    static let controls = ComposerControlsRecord(agent: "claude", model: "claude-opus-5", effort: "high", permissionMode: "acceptEdits", interactionMode: "build")
    static let setup = SetupRecord(state: "succeeded", step: nil, startedAt: date, finishedAt: date)
    static let chat = ChatRecord(id: "chat-1", title: "Chat", agent: "claude", model: "claude-opus-5", effort: "high", permissionMode: "acceptEdits",
                                 interactionMode: "build", state: "running", lastSeq: 4, createdAt: date, updatedAt: date)
    static let message = MessageRecord(cursor: 118, chatID: "chat-1", seq: 4, kind: "user",
                                       payload: .object(["type": .string("user"), "message": .object(["role": .string("user")])]), author: author, createdAt: date)
    static let queue = QueueRecord(chatID: "chat-1", prompts: [
        QueuedPromptRecord(id: "delivery-1", text: "And the docs", author: author, state: "queued", createdAt: date),
        QueuedPromptRecord(id: "delivery-2", text: "Then push", author: author, state: "blocked",
                           blocked: BlockedRecord(limit: "concurrent_machines", message: "Your team already has 20 Bloom Cloud workspaces running. Close one to open this."), createdAt: date),
    ])
    static let question = QuestionRecord(requestID: "ask-1", chatID: "chat-1", ask: .object(["tool_name": .string("Bash")]), askedAt: date)
    static let workspace = WorkspaceRecord(id: "01k5bx7j9d3v2r8q6m4n0p1s2w", name: "Queue retries", branch: "freek/queue-retries", baseBranch: "main", setup: setup)

    static let operations: [(String, WorkspaceOperation)] = [
        ("workspace", .workspace),
        ("transcript", .transcript(chatID: "chat-1", afterSeq: 3, limit: 200)),
        ("composer", .composer(chatID: "chat-1")),
        ("composer_for_a_new_chat", .composer(chatID: nil)),
        ("setup_output", .setupOutput),
        ("files", .files),
        ("history", .history(limit: 50, before: nil)),
        // The next page, which is the only time `before` is sent.
        ("history_next_page", .history(limit: 50, before: "9f1c0b6a2d3e4f5061728394a5b6c7d8e9f01234")),
        ("revert_file", .revertFile(path: "app/Queue.php", scope: .uncommitted)),
        ("transcript_search", .transcriptSearch(query: "retry the queue", limit: 30)),
        ("discard_hunk", .discardHunk(path: "app/Queue.php", scope: .uncommitted,
                                      patch: "@@ -1,3 +1,4 @@\n context\n+added\n context\n context\n")),
        ("commit_files", .commitFiles(sha: "9f1c0b6a2d3e4f5061728394a5b6c7d8e9f01234")),
        ("commit_patch", .commitPatch(sha: "9f1c0b6a2d3e4f5061728394a5b6c7d8e9f01234", path: "app/Queue.php")),
        ("file", .file(path: "README.md")),
        ("download", .download(path: "storage/logs/laravel.log")),
        ("review_snapshot", .reviewSnapshot(scope: .branch, knownRevision: nil, wait: true)),
        // Asked again with the revision already held, which is how a client waits for a change.
        ("review_snapshot_known_revision", .reviewSnapshot(scope: .branch, knownRevision: "revision-2", wait: true)),
        ("review_snapshot_staged", .reviewSnapshot(scope: .staged, knownRevision: nil, wait: false)),
        ("review_patch_unstaged", .reviewPatch(path: "app/Queue.php", scope: .unstaged, knownRevision: nil)),
        ("review_patch", .reviewPatch(path: "README.md", scope: .uncommitted, knownRevision: "revision-1")),
        ("run_scripts", .runScripts),
        ("quick_prompts", .quickPrompts),
        ("notes", .notes),
        ("pull_request", .pullRequest),
        ("archive_preview", .archivePreview),
        ("new_chat", .newChat(controls: controls)),
        ("rename_chat", .renameChat(chatID: "chat-1", title: "Review")),
        ("close_chat", .closeChat(chatID: "chat-1")),
        ("mark_read", .markRead(chatID: "chat-1", seq: 4)),
        ("set_composer", .setComposer(chatID: "chat-1", controls: controls)),
        // A Codex chat switched to fast. Absent `codex_fast_mode` means the chat inherits Codex's
        // own configuration; an explicit false is standard speed and must survive as that.
        ("set_composer_codex_fast", .setComposer(chatID: "chat-2", controls: ComposerControlsRecord(
            agent: "codex", model: "gpt-5.5", effort: "medium", permissionMode: "acceptEdits", interactionMode: "build",
            codexFastMode: true))),
        ("send", .send(chatID: "chat-1", text: "Run the tests")),
        // The same call addressed to somebody rather than to the agent. **Absent means the agent**,
        // so the vector above is what an installed client keeps sending and it keeps working.
        // Sent by an agent on the person's behalf, from a workspace on their Mac. The token is still
        // the person's; `via` is a label every client draws under the author. See `ViaRecord`.
        ("send_by_an_agent", .send(chatID: "chat-1", text: "Rebase on main and push when the tests pass",
                                   via: ViaRecord(workspace: "Queue retries", chat: "Chat"))),
        ("send_to_a_person", .send(chatID: "chat-1", text: "@sebdd can you look at the migration?",
                                   audience: AudienceRecord(kind: "person", userID: "01k5bx7j9d3v2r8q6m4n0p1s2u",
                                                            mention: "@sebdd"))),
        ("cancel_queued", .cancelQueued(chatID: "chat-1", promptID: "delivery-1")),
        ("stop", .stop(chatID: "chat-1")),
        ("answer_allow_once", .answer(chatID: "chat-1", requestID: "ask-1", answer: .allowOnce)),
        ("answer_deny", .answer(chatID: "chat-1", requestID: "ask-1", answer: .deny(message: "Not that file", endsTurn: true))),
        ("answer_plan", .answer(chatID: "chat-1", requestID: "ask-1", answer: .approvePlan(permissionMode: "acceptEdits"))),
        ("answer_question", .answer(chatID: "chat-1", requestID: "ask-1", answer: .question(input: .object(["answers": .object(["Which?": .string("Both")])])))),
        ("write_file", .writeFile(path: "README.md", text: "# Bloom\n", revision: "revision-1")),
        ("upload_file", .uploadFile(name: "screenshot.png", data: Data([0x89, 0x50, 0x4E, 0x47]))),
        ("commit", .commit(message: "Retry the queue")),
        ("push", .push),
        ("create_pull_request", .createPullRequest(title: "Retry the queue", body: "", draft: true)),
        ("save_notes", .saveNotes(text: "Check the retry limit")),
        ("rename_workspace", .renameWorkspace(name: "Queue retries")),
        ("run_setup", .runSetup),
        ("stop_setup", .stopSetup),
        // Continuing after the merge, telling the agent in a chat of the caller's choosing. Without
        // `chat_id` the machine picks the most recent chat.
        ("continue_after_merge", .continueAfterMerge(chatID: "chat-1")),
        ("run_script", .runScript(id: "tests")),
        ("close_terminal", .closeTerminal(name: "terminal-1")),
        ("archive", .archive(confirmationID: "00000000-0000-4000-8000-000000000002")),
    ]

    static let results: [(String, OperationResult)] = [
        ("accepted", .accepted),
        ("workspace", .workspace(WorkspaceSnapshotRecord(workspace: workspace, chats: [chat],
                                                          presence: [PresenceRecord(userID: author.userID, name: author.name, lastInputAt: date)], cursor: 118,
                                                          composerDefaults: controls,
                                                          // Two people with access, one of whom is
                                                          // not connected: the list a client offers
                                                          // completion from is who has access, not
                                                          // who is here.
                                                          members: [
                                                              MemberRecord(userID: author.userID, name: "Freek", handle: "freek"),
                                                              MemberRecord(userID: nameless.userID, name: "", handle: "sebdd"),
                                                          ]))),
        ("transcript", .transcript(TranscriptRecord(chat: chat, messages: [message], hasMore: false, questions: [question], busy: true,
                                                    streamingText: "Running", queue: queue))),
        // Two models so the vector shows both: one with a fast tier, and one whose `fast_tier` is
        // absent, which is what no fast mode looks like.
        ("composer", .composer(ComposerRecord(chatID: "chat-1", controls: controls, availableAgents: ["claude", "codex"],
            models: [ModelRecord(agent: "codex", id: "gpt-5.5", label: "GPT-5.5", efforts: ["low", "medium", "high"], defaultEffort: "medium", isDefault: true,
                                 fastTier: "priority"),
                     ModelRecord(agent: "codex", id: "gpt-5.5-mini", label: "GPT-5.5 mini", efforts: ["low", "medium"], defaultEffort: "low", isDefault: false),
                     // Claude Code's own list, read from the CLI: the `[1m]` variant is its own
                     // model id, and the CLI names no default effort.
                     ModelRecord(agent: "claude", id: "opus[1m]", label: "Opus 5 with 1M context",
                                 efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: nil, isDefault: true),
                     ModelRecord(agent: "claude", id: "sonnet", label: "Sonnet 5",
                                 efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: nil, isDefault: false)],
            commands: [SlashCommandRecord(name: "review", description: "Review the branch")], outputStyles: ["default", "Explanatory"]))),
        // The same answer about a chat nobody has made yet, which is what `composer` with no
        // `chat_id` asks: no `chat_id` comes back either.
        ("composer_for_a_new_chat", .composer(ComposerRecord(chatID: nil, controls: controls, availableAgents: ["claude", "codex"],
            models: [ModelRecord(agent: "codex", id: "gpt-5.5", label: "GPT-5.5", efforts: ["low", "medium", "high"], defaultEffort: "medium", isDefault: true)],
            commands: [SlashCommandRecord(name: "review", description: "Review the branch")], outputStyles: ["default", "Explanatory"]))),
        ("setup_output", .setupOutput(SetupOutputRecord(setup: SetupRecord(state: "running", step: "setup", startedAt: date), log: "Installing\n"))),
        ("files", .files(paths: ["README.md", "app/Queue.php"])),
        ("history", .history(HistoryRecord(commits: [
            CommitRecord(sha: "9f1c0b6a2d3e4f5061728394a5b6c7d8e9f01234", subject: "Retry the queue", authorName: "Freek",
                         authorEmail: "freek@spatie.be", date: Date(timeIntervalSince1970: 1_789_638_000),
                         body: "Twice, with a wait.", parents: ["0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"], pushed: true),
        ], hasMore: false))),
        ("search", .search(SearchRecord(matches: [
            SearchMatchRecord(chatID: "01k5a7d3v1x0m8n2q4r6s9t0wy", chatTitle: "Queue retries", seq: 12, cursor: 4_211,
                              kind: "assistantText", at: Date(timeIntervalSince1970: 1_789_638_000),
                              excerpt: [.init(text: "I will ", isMatch: false), .init(text: "retry", isMatch: true),
                                        .init(text: " the queue.", isMatch: false)]),
        ], total: 3))),
        ("commit_files", .commitFiles(files: [
            ChangedFileRecord(path: "app/Queue.php", change: "modified", additions: 12, deletions: 3, isBinary: false,
                              layer: "unstaged"),
        ])),
        ("file", .file(TextFileRecord(path: "README.md", text: "# Bloom\n", revision: "revision-1"))),
        ("download", .download(DownloadRecord(path: "logo.png", data: Data([0x89, 0x50])))),
        ("review_snapshot", .reviewSnapshot(ReviewSnapshotRecord(revision: "revision-2", files: [
            ChangedFileRecord(path: "app/Queue.php", change: "modified", additions: 12, deletions: 3, isBinary: false, contentRevision: "file-revision"),
            ChangedFileRecord(path: "app/Retry.php", oldPath: "app/Retries.php", change: "renamed", additions: 0, deletions: 0, isBinary: false),
        ]))),
        ("review_snapshot_unchanged", .reviewSnapshot(ReviewSnapshotRecord(revision: "revision-2", files: nil))),
        ("review_patch", .reviewPatch(PatchSnapshotRecord(revision: "file-revision", patch: "diff --git a/README.md b/README.md\n"))),
        ("run_scripts", .runScripts(scripts: [RunScriptRecord(id: "tests", name: "Tests", command: "composer test")])),
        // A worked example of everything a menu has to draw: a prompt that composes in the chat on
        // screen, one that opens a new chat, and the sentence for one that was left out. **No
        // `send_immediately` on any of them**, and there never will be: see `QuickPromptRecord`.
        ("quick_prompts", .quickPrompts(prompts: [
            QuickPromptRecord(id: "explain changes", name: "Explain changes", prompt: "Explain what changed on this branch and why.",
                              symbol: "doc.text", isNewChat: false, source: ".bloom/settings.toml"),
            QuickPromptRecord(id: "release notes", name: "Release notes", prompt: "Draft release notes for the commits since the last tag.",
                              symbol: "\u{1F4DD}", isNewChat: true, source: ".bloom/settings.toml"),
        ], issues: [
            SettingsIssueRecord(source: ".bloom/settings.toml",
                                message: "Quick prompt \u{201C}Deploy\u{201D} will not send on its own: send_immediately is not supported in a shared settings file.",
                                line: 14),
        ])),
        ("text", .text("https://github.com/spatie/example/pull/12")),
        ("chat", .chat(chat)),
        ("queued", .queued(promptID: "delivery-1")),
        ("archive_preview", .archivePreview(ArchivePreviewRecord(confirmationID: "00000000-0000-4000-8000-000000000002", hasUncommittedChanges: true,
            untrackedFiles: ["notes.txt"], unpushedCommits: 2, detachedCommits: 0, isAgentRunning: false, isPullRequestMerged: false, createdAt: date))),
        ("terminal", .terminal(TerminalRecord(name: "run-tests", title: "Tests"))),
    ]

    static let errors: [(String, WireError)] = [
        ("busy", WireError(.busy, "Stop the current turn before changing its settings.")),
        ("conflict", WireError(.conflict, "This file changed since it was opened. Reload it before saving.")),
        ("outcome_unknown", WireError(.outcomeUnknown, "The server stopped while handling this command. Check the workspace before sending it again.")),
    ]

    static let events: [(String, WorkspaceEvent)] = [
        ("message", .message(message)),
        // A message one person wrote to another. **The agent is never given this**, now or on any
        // later replay; see `AudienceRecord`. The mention travels resolved rather than re-parsed.
        ("message_to_a_person", .message(MessageRecord(
            cursor: 120, chatID: "chat-1", seq: 6, kind: "user",
            payload: .object(["type": .string("user"), "message": .object(["role": .string("user")])]),
            author: author, createdAt: date,
            audience: AudienceRecord(kind: "person", userID: nameless.userID, mention: "@sebdd")))),
        // The same message from somebody with no display name, which is the case a client has to
        // draw from the address instead. See `AuthorRecord.label`.
        ("message_from_a_nameless_author", .message(MessageRecord(
            cursor: 119, chatID: message.chatID, seq: 5, kind: message.kind,
            payload: message.payload, author: nameless, createdAt: message.createdAt))),
        ("stream_snapshot", .stream(chatID: "chat-1", text: "Reading the queue", snapshot: true)),
        ("stream_delta", .stream(chatID: "chat-1", text: " worker", snapshot: false)),
        ("chat", .chat(chat)),
        ("queue", .queue(queue)),
        // A crew chat an agent opened with `agent_start`, which names the chat that asked for it.
        // The last event about a chat somebody closed. A client that did not close it removes it
        // from its strip on this, rather than waiting for the next full read.
        ("chat_closed", .chat(ChatRecord(id: chat.id, title: chat.title, agent: chat.agent, model: chat.model, effort: chat.effort,
                                         permissionMode: chat.permissionMode, interactionMode: chat.interactionMode, state: "idle",
                                         lastSeq: chat.lastSeq, createdAt: date, updatedAt: date, closedAt: date))),
        ("chat_from_a_crew", .chat(ChatRecord(id: "chat-2", title: "Check the migrations", agent: "claude", model: "claude-opus-5",
                                              effort: "high", permissionMode: "acceptEdits", interactionMode: "build", state: "running",
                                              parentChatID: "chat-1", lastSeq: 0, createdAt: date, updatedAt: date))),
        // A queue that stopped, with the sentence the machine writes when it does.
        ("queue_paused", .queue(QueueRecord(chatID: "chat-1", prompts: [queue.prompts[0]],
                                            error: "Queue paused. Send a message to resume."))),
        // A tool call carries the tool's own id as `ref_id`, which its result names; the turn's
        // closing row carries how long the turn took.
        // A picture an agent showed with `media_show` on a machine. The payload names a copy in the
        // worktree's ignored scratch folder, fetched with `download`: never the bytes themselves.
        // The same message as the machine keeps it: the person is the author, and `via` says an
        // agent wrote it.
        ("message_by_an_agent", .message(MessageRecord(
            cursor: 124, chatID: "chat-1", seq: 10, kind: "user",
            payload: .object(["type": .string("user"), "message": .object(["role": .string("user")])]),
            author: author, createdAt: date, via: ViaRecord(workspace: "Queue retries", chat: "Chat")))),
        ("message_media", .message(MessageRecord(
            cursor: 123, chatID: "chat-1", seq: 9, kind: "media",
            payload: .object([
                "path": .string(".bloom/scratch/media/5f1d3c0e9a7b2e4f6c8d0a1b3c5e7f9a2b4d6e8f0a1c3e5b7d9f1a3c5e7b9d1f.png"),
                "name": .string("login.png"), "caption": .string("The login page after the fix"),
                "kind": .string("image"), "mime": .string("image/png"), "bytes": .number(48213),
            ]),
            createdAt: date))),
        ("message_tool_use", .message(MessageRecord(
            cursor: 121, chatID: "chat-1", seq: 7, kind: "toolUse",
            payload: .object(["type": .string("tool_use"), "id": .string("toolu_01"), "name": .string("Bash")]),
            createdAt: date, refID: "toolu_01"))),
        ("message_result", .message(MessageRecord(
            cursor: 122, chatID: "chat-1", seq: 8, kind: "result",
            payload: .object(["type": .string("result"), "subtype": .string("success")]),
            createdAt: date, durationMS: 48_200))),
        ("questions", .questions(chatID: "chat-1", questions: [question])),
        ("composer", .composer(chatID: "chat-1", controls: controls, changedBy: author)),
        ("setup", .setup(SetupRecord(state: "running", step: "prepare", startedAt: date))),
        // Setup that failed. `note` is the tail of the log, at most eight lines, so a client can say
        // why without fetching the whole of it.
        ("setup_failed", .setup(SetupRecord(state: "failed", startedAt: date, finishedAt: date,
                                            note: "[bloom] Running the setup script.\n"
                                                + "Your requirements could not be resolved to an installable set of packages.\n"
                                                + "[bloom] The setup script exited with status 2."))),
        ("setup_output", .setupOutput(text: "Reading package lists...\n")),
        // An agent on a machine asking for a browser pane. It names the chat it is speaking for, so
        // a client can put the pane beside it, and no url at all means this workspace's own public
        // address, which a client connected to it already has.
        ("pane_requested", .paneRequested(url: "http://127.0.0.1:3000/dashboard", chatID: chat.id,
                                          placement: "split")),
        ("presence", .presence([PresenceRecord(userID: author.userID, name: author.name, lastInputAt: nil)])),
        ("workspace", .workspace(workspace)),
        // The same record while the machine cannot reach runbloom.app, which is the only time it
        // carries `reporting` and the shape a client draws that warning from. It carries services
        // too, in the three states worth drawing differently: one up, one that cannot have its port
        // and is restarting, and one that has never been launched at all because what it waits for
        // never came up. The third is the one nothing could show before this record existed.
        ("workspace_not_reporting", .workspace(WorkspaceRecord(
            id: workspace.id, name: workspace.name, branch: workspace.branch, baseBranch: workspace.baseBranch,
            setup: workspace.setup, reporting: ReportingRecord(unreachableSince: date, shed: 3),
            services: [
                ServiceRecord(name: "vite", state: "running"),
                // The one the preview routes to, which here is neither the healthy one nor the
                // one everything is waiting on: that is the whole reason the mark is on the wire.
                ServiceRecord(name: "web", state: "waiting", message: "Waiting for db.", isHTTP: true),
                ServiceRecord(name: "app", state: "crashed", restarts: 412,
                              message: "Exited with status 1. Starting again in 1 s. It asked for port 8081, "
                                  + "which is Bloom Runner itself."),
                ServiceRecord(name: "horizon", state: "waiting", message: "Waiting for app."),
            ]))),
        ("sleeping", .sleeping),
        ("closing", .closing(WireError(.tokenExpired, "The session token expired."))),
    ]

    static let terminalFrames: [(String, TerminalControlFrame)] = [
        ("auth", .auth(token: "eyJhbGciOiJFZERTQSJ9.example.signature")),
        ("reauth", .reauth(token: "eyJhbGciOiJFZERTQSJ9.example.signature")),
        ("resize", .resize(columns: 120, rows: 40)),
    ]
}

/// What a client does with a reply from a machine older than a key it now reads.
@Suite("Decoding a setup record")
struct SetupRecordDecodingTests {
    @Test("a setup record with no enabled key reads as enabled")
    func absentEnabledIsTrue() throws {
        let record = try JSONDecoder().decode(SetupRecord.self, from: Data(#"{"state": "succeeded"}"#.utf8))
        #expect(record.isEnabled)
    }

    @Test("a setup record that says setup is off is read as off")
    func statedEnabledIsKept() throws {
        let record = try JSONDecoder().decode(SetupRecord.self, from: Data(#"{"state": "skipped", "enabled": false}"#.utf8))
        #expect(!record.isEnabled)
        #expect(record.state == "skipped")
    }

    /// The machine writes the key on every reply, which is the half that lets a client tell a
    /// workspace with setup turned off from one whose setup has not been reached yet.
    @Test("a setup record always encodes the key")
    func alwaysEncoded() throws {
        let data = try JSONEncoder().encode(SetupRecord(state: "pending"))
        #expect(String(decoding: data, as: UTF8.self).contains("\"enabled\":true"))
    }
}

/// What a client does with a machine built before a field existed.
@Suite("Reading an older machine")
struct OlderMachineDecodingTests {
    /// **Every machine running today was made before `members` existed.** A synthesised decoder
    /// throws on a missing key, and the symptom is not a missing list of names: it is that the
    /// workspace will not open at all.
    @Test("a snapshot with no members reads as none rather than throwing")
    func snapshotWithoutMembers() throws {
        let json = #"""
        {"workspace": {"id": "w1", "name": "Queue", "branch": "queue", "base_branch": "main",
                       "services": [], "setup": {"state": "succeeded", "enabled": true}},
         "chats": [], "presence": [], "cursor": 4,
         "composer_defaults": {"agent": "claude", "model": "", "effort": "", "permission_mode": "default",
                               "interaction_mode": "normal"}}
        """#
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshotRecord.self, from: Data(json.utf8))

        #expect(snapshot.members.isEmpty)
        #expect(snapshot.workspace.name == "Queue")
    }

    /// The same rule, two records over. **Found by asking where else it had not been applied**,
    /// which is where four separate bugs came from in one day: a rule written for one case and not
    /// carried to the next.
    @Test("a workspace record with no services reads as none rather than throwing")
    func workspaceWithoutServices() throws {
        let json = #"""
        {"id": "w1", "name": "Queue", "branch": "queue", "base_branch": "main",
         "setup": {"state": "succeeded"}}
        """#
        let workspace = try JSONDecoder().decode(WorkspaceRecord.self, from: Data(json.utf8))

        #expect(workspace.services.isEmpty)
        #expect(workspace.setup.isEnabled, "and the setup record's own absent-means-true still holds")
    }

    /// Before the key existed, archiving always took the conversation with it, so that is what its
    /// absence means.
    @Test("an archive preview with no deletes_conversation reads as the answer that used to be true")
    func archivePreviewWithoutTheKey() throws {
        let json = #"""
        {"confirmation_id": "c1", "has_uncommitted_changes": false, "untracked_files": [],
         "unpushed_commits": 0, "detached_commits": 0, "is_agent_running": false,
         "is_pull_request_merged": false, "created_at": "2026-09-18T10:00:00.000Z"}
        """#
        let preview = try WireJSON.decode(ArchivePreviewRecord.self, from: Data(json.utf8))

        #expect(preview.deletesConversation)
    }

    /// And a machine new enough to send it is read as it meant.
    @Test("a snapshot with members keeps them")
    func snapshotWithMembers() throws {
        let json = #"""
        {"workspace": {"id": "w1", "name": "Queue", "branch": "queue", "base_branch": "main",
                       "services": [], "setup": {"state": "succeeded", "enabled": true}},
         "chats": [], "presence": [], "cursor": 4,
         "composer_defaults": {"agent": "claude", "model": "", "effort": "", "permission_mode": "default",
                               "interaction_mode": "normal"},
         "members": [{"user_id": "u1", "name": "Sebastian", "handle": "sebdd"}]}
        """#
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshotRecord.self, from: Data(json.utf8))

        #expect(snapshot.members.map(\.handle) == ["sebdd"])
    }
}
